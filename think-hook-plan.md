# Hook Plan: `message:submit` + `message:response-ready`

## Background: Existing Hook Infrastructure

OpenClaw already has a mature dual-track hook system:

- **Internal hooks** (`src/hooks/internal-hooks.ts`) — typed events fired via
  `triggerInternalHook(createInternalHookEvent(type, action, sessionKey, context))`, wrapped in
  `fireAndForgetHook`. Handlers register with `registerInternalHook("message:received", handler)`.
- **Plugin hooks** (`src/plugins/hook-runner-global.ts`) — separate plugin-level lifecycle
  callbacks (`message_received`, `message_sending`, `message_sent`, etc.).

Existing `message` actions: `received`, `transcribed`, `preprocessed`, `sent`.

---

## Hook 1: `message:submit`

**Semantics:** fires after all enrichment (transcription, image/link understanding) is applied to
the inbound message — the fully enriched version the agent is about to see. This is the ideal
"user submitted a message" point.

**Why not `message:received`?** That fires at raw ingest, before transcription or media
understanding. Useful but limited context. `message:preprocessed` already fires at the richer
enriched point — but "submit" is a cleaner user-facing name for the concept.

**Approach:** Add a true `submit` action alongside `preprocessed` (additive, clean semantics).

1. Add `MessageSubmitHookContext` type in `src/hooks/internal-hooks.ts` — same shape as
   `MessagePreprocessedHookContext` (the context is identical at this lifecycle point), plus an
   optional `sessionId` field if available.
2. Add `isMessageSubmitEvent` guard following the existing pattern.
3. In `emitPreAgentMessageHooks` (`src/auto-reply/reply/message-preprocess-hooks.ts`), fire a
   second `"submit"` event after the `"preprocessed"` event — reusing the same
   `toInternalMessagePreprocessedContext` mapper (or a thin new `toInternalMessageSubmitContext`).

---

## Hook 2: `message:response-ready`

**Semantics:** fires once when the LLM has finished generating and the final response payloads are
assembled — just before they are dispatched to the channel. This is distinct from `message:sent`
which fires per-chunk post-delivery.

**Insertion point:** `src/auto-reply/reply/agent-runner.ts` ~line 691 — immediately before
`return finalizeWithFollowup(...)`.

At this point the following are all available in scope:

- `finalPayloads` — the assembled `ReplyPayload[]` (response text)
- `sessionKey` — the session key
- `runResult.meta?.agentMeta?.sessionId` — the agent session ID
- `modelUsed`, `providerUsed` — which model/provider ran
- `usage` — token usage object
- `runStartedAt` (add a timestamp at the start of the run)

**Implementation steps:**

1. **Add `MessageResponseReadyHookContext`** type in `src/hooks/internal-hooks.ts`:

   ```ts
   export type MessageResponseReadyHookContext = {
     /** The full response text (all payloads joined) */
     content: string;
     /** Session key */
     sessionKey?: string;
     /** Agent session ID */
     sessionId?: string;
     /** Provider used */
     provider?: string;
     /** Model used */
     model?: string;
     /** Token usage */
     usage?: { input?: number; output?: number; total?: number };
     /** How long the agent took in ms */
     durationMs?: number;
     /** Channel identifier */
     channelId?: string;
   };
   ```

2. **Add `isMessageResponseReadyEvent` guard** in `src/hooks/internal-hooks.ts` following the
   `isMessagePreprocessedEvent` pattern — check `type === "message"`, `action === "response-ready"`,
   `content` string present.

3. **Add `toInternalMessageResponseReadyContext` mapper** in `src/hooks/message-hook-mappers.ts`.

4. **Capture `runStartedAt`** near the top of the `runReplyAgent` function body (one `Date.now()`
   call) so `durationMs` is accurate.

5. **Fire the hook** in `agent-runner.ts` just before line 692:
   ```ts
   fireAndForgetHook(
     triggerInternalHook(
       createInternalHookEvent("message", "response-ready", sessionKey ?? "", {
         content: finalPayloads
           .map((p) => p.text ?? "")
           .filter(Boolean)
           .join("\n"),
         sessionId: cliSessionId,
         provider: providerUsed,
         model: modelUsed,
         usage,
         durationMs: Date.now() - runStartedAt,
         channelId: followupRun.run.channelId,
       }),
     ),
     "agent-runner: message:response-ready hook failed",
   );
   ```

---

## Files to Touch

| File                                               | Change                                                                                                      |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `src/hooks/internal-hooks.ts`                      | Add `MessageSubmitHookContext`, `MessageResponseReadyHookContext`, their event types, and `is*Event` guards |
| `src/hooks/message-hook-mappers.ts`                | Add `toInternalMessageSubmitContext` and `toInternalMessageResponseReadyContext` mappers                    |
| `src/auto-reply/reply/message-preprocess-hooks.ts` | Fire `"submit"` event after `"preprocessed"` in `emitPreAgentMessageHooks`                                  |
| `src/auto-reply/reply/agent-runner.ts`             | Capture `runStartedAt`; fire `"response-ready"` before `finalizeWithFollowup` return                        |
| colocated `*.test.ts`                              | Test cases for both new event types and guards                                                              |

---

## Deployed Installation Context

The installed version is `2026.3.2` (source is `2026.3.3`); neither new event type exists yet.

The `matrix-thinking` workspace hook (`~/.openclaw/workspace/hooks/matrix-thinking/`) is already
live and is the direct motivation for this plan. It drives a Matrix LED display and currently
listens on:

- **`message:received`** → POSTs `/think` (start thinking animation)
- **`message:sent`** → POSTs `/done` (stop thinking animation)

### Problems with the current hook events

**`message:received` starts the animation too early.** For voice messages or media-heavy messages
there is a gap while transcription and media/link understanding runs. The animation spins during
preprocessing, not just during actual agent inference.

**`message:sent` fires multiple times.** With streaming + Telegram partial mode the response can
be split into multiple chunks, each triggering `message:sent` — so `/done` fires mid-response,
then again, then again.

### How the new events fix this

| Signal          | Current (broken)                          | New (correct)                                                                       |
| --------------- | ----------------------------------------- | ----------------------------------------------------------------------------------- |
| Start animation | `message:received` — before enrichment    | `message:submit` — after enrichment, right as agent starts                          |
| Stop animation  | `message:sent` — per chunk, post-delivery | `message:response-ready` — exactly once, after LLM finishes, before first byte sent |

After this change `matrix-thinking` can be updated to listen on `message:submit` and
`message:response-ready` instead.

---

## Hook Lifecycle Summary

```
message arrives
  │
  ▼ message:received         (raw, earliest — already exists)
  │ enrichment (transcription, media understanding, link summaries)
  ▼ message:transcribed      (if audio — already exists)
  ▼ message:preprocessed     (after enrichment — already exists)
  ▼ message:submit           ← NEW (same point, cleaner semantic name)
  │ agent runs (LLM inference, tool calls)
  ▼ message:response-ready   ← NEW (after LLM, before dispatch)
  │ channel delivery
  ▼ message:sent             (per chunk, post-delivery — already exists)
```

---

## Installation Plan

### Diff vs installed `2026.3.2`

The installed bundle contains no `submit` or `response-ready` in any file. All changes are additive:

| File                                        | Installed `2026.3.2`                         | Source `2026.3.3`                                                           |
| ------------------------------------------- | -------------------------------------------- | --------------------------------------------------------------------------- |
| `internal-hooks` bundle                     | No `submit`/`response-ready` types or guards | +2 context types, +2 event types, +2 `is*Event` guards                      |
| `message-hook-mappers` bundle               | No submit/response-ready mappers             | +`toInternalMessageSubmitContext`, +`toInternalMessageResponseReadyContext` |
| `reply` bundle (`message-preprocess-hooks`) | Fires `preprocessed` only                    | Also fires `message:submit`                                                 |
| `reply` bundle (`agent-runner`)             | Has `runStartedAt` but no hook fire          | Fires `message:response-ready` before `finalizeWithFollowup`                |

### Steps

**1 — Build from source**

```sh
cd /mnt/sylvester/openclaw/openclaw
pnpm build
```

**2 — Install over the global location**

```sh
npm install -g . --prefix /mnt/sylvester/openclaw/.npm-global
```

Replaces the `2026.3.2` install with `2026.3.3` in-place, preserving the same binary at `~/.npm-global/bin/openclaw`.

**3 — Restart the gateway**

```sh
pkill -9 -f openclaw-gateway || true
nohup openclaw gateway run --bind loopback --port 18789 --force > /tmp/openclaw-gateway.log 2>&1 &
```

**4 — Update `matrix-thinking` hook**

In `~/.openclaw/workspace/hooks/matrix-thinking/`, change the event bindings:

```diff
- message:received  →  POST /think
+ message:submit    →  POST /think

- message:sent      →  POST /done
+ message:response-ready  →  POST /done
```

**5 — Verify**

```sh
tail -f /tmp/openclaw-gateway.log
```

Send a voice message and confirm the LED animation starts only after transcription completes, and stops exactly once after LLM inference finishes.
