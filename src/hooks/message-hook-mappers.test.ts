import { describe, expect, it } from "vitest";
import type { FinalizedMsgContext } from "../auto-reply/templating.js";
import type { OpenClawConfig } from "../config/config.js";
import {
  buildCanonicalSentMessageHookContext,
  deriveInboundMessageHookContext,
  toInternalMessagePreprocessedContext,
  toInternalMessageReceivedContext,
  toInternalMessageResponseReadyContext,
  toInternalMessageSentContext,
  toInternalMessageSubmitContext,
  toInternalMessageTranscribedContext,
  toPluginMessageContext,
  toPluginMessageReceivedEvent,
  toPluginMessageSentEvent,
} from "./message-hook-mappers.js";

function makeInboundCtx(overrides: Partial<FinalizedMsgContext> = {}): FinalizedMsgContext {
  return {
    From: "telegram:user:123",
    To: "telegram:chat:456",
    Body: "body",
    BodyForAgent: "body-for-agent",
    BodyForCommands: "commands-body",
    RawBody: "raw-body",
    Transcript: "hello transcript",
    Timestamp: 1710000000,
    Provider: "telegram",
    Surface: "telegram",
    OriginatingChannel: "telegram",
    OriginatingTo: "telegram:chat:456",
    AccountId: "acc-1",
    MessageSid: "msg-1",
    SenderId: "sender-1",
    SenderName: "User One",
    SenderUsername: "userone",
    SenderE164: "+15551234567",
    MessageThreadId: 42,
    MediaPath: "/tmp/audio.ogg",
    MediaType: "audio/ogg",
    GroupSubject: "ops",
    GroupChannel: "ops-room",
    GroupSpace: "guild-1",
    ...overrides,
  } as FinalizedMsgContext;
}

describe("message hook mappers", () => {
  it("derives canonical inbound context with body precedence and group metadata", () => {
    const canonical = deriveInboundMessageHookContext(makeInboundCtx());

    expect(canonical.content).toBe("commands-body");
    expect(canonical.channelId).toBe("telegram");
    expect(canonical.conversationId).toBe("telegram:chat:456");
    expect(canonical.messageId).toBe("msg-1");
    expect(canonical.isGroup).toBe(true);
    expect(canonical.groupId).toBe("telegram:chat:456");
    expect(canonical.guildId).toBe("guild-1");
  });

  it("supports explicit content/messageId overrides", () => {
    const canonical = deriveInboundMessageHookContext(makeInboundCtx(), {
      content: "override-content",
      messageId: "override-msg",
    });

    expect(canonical.content).toBe("override-content");
    expect(canonical.messageId).toBe("override-msg");
  });

  it("maps canonical inbound context to plugin/internal received payloads", () => {
    const canonical = deriveInboundMessageHookContext(makeInboundCtx());

    expect(toPluginMessageContext(canonical)).toEqual({
      channelId: "telegram",
      accountId: "acc-1",
      conversationId: "telegram:chat:456",
    });
    expect(toPluginMessageReceivedEvent(canonical)).toEqual({
      from: "telegram:user:123",
      content: "commands-body",
      timestamp: 1710000000,
      metadata: expect.objectContaining({
        messageId: "msg-1",
        senderName: "User One",
        threadId: 42,
      }),
    });
    expect(toInternalMessageReceivedContext(canonical)).toEqual({
      from: "telegram:user:123",
      content: "commands-body",
      timestamp: 1710000000,
      channelId: "telegram",
      accountId: "acc-1",
      conversationId: "telegram:chat:456",
      messageId: "msg-1",
      metadata: expect.objectContaining({
        senderUsername: "userone",
        senderE164: "+15551234567",
      }),
    });
  });

  it("maps transcribed and preprocessed internal payloads", () => {
    const cfg = {} as OpenClawConfig;
    const canonical = deriveInboundMessageHookContext(makeInboundCtx({ Transcript: undefined }));

    const transcribed = toInternalMessageTranscribedContext(canonical, cfg);
    expect(transcribed.transcript).toBe("");
    expect(transcribed.cfg).toBe(cfg);

    const preprocessed = toInternalMessagePreprocessedContext(canonical, cfg);
    expect(preprocessed.transcript).toBeUndefined();
    expect(preprocessed.isGroup).toBe(true);
    expect(preprocessed.groupId).toBe("telegram:chat:456");
    expect(preprocessed.cfg).toBe(cfg);
  });

  it("toInternalMessageSubmitContext matches preprocessed context plus sessionId", () => {
    const cfg = {} as OpenClawConfig;
    const canonical = deriveInboundMessageHookContext(makeInboundCtx());
    const submit = toInternalMessageSubmitContext(canonical, cfg, "session-abc");
    const preprocessed = toInternalMessagePreprocessedContext(canonical, cfg);

    expect(submit.channelId).toBe(preprocessed.channelId);
    expect(submit.from).toBe(preprocessed.from);
    expect(submit.bodyForAgent).toBe(preprocessed.bodyForAgent);
    expect(submit.sessionId).toBe("session-abc");
  });

  it("toInternalMessageSubmitContext works without sessionId", () => {
    const cfg = {} as OpenClawConfig;
    const canonical = deriveInboundMessageHookContext(makeInboundCtx());
    const submit = toInternalMessageSubmitContext(canonical, cfg);
    expect(submit.sessionId).toBeUndefined();
  });

  it("toInternalMessageResponseReadyContext maps all fields", () => {
    const ctx = toInternalMessageResponseReadyContext({
      content: "Hello there",
      sessionKey: "sk-1",
      sessionId: "sess-1",
      provider: "anthropic",
      model: "claude-opus-4-6",
      usage: { input: 100, output: 50, total: 150 },
      durationMs: 800,
      channelId: "telegram",
    });

    expect(ctx.content).toBe("Hello there");
    expect(ctx.sessionKey).toBe("sk-1");
    expect(ctx.sessionId).toBe("sess-1");
    expect(ctx.provider).toBe("anthropic");
    expect(ctx.model).toBe("claude-opus-4-6");
    expect(ctx.usage).toEqual({ input: 100, output: 50, total: 150 });
    expect(ctx.durationMs).toBe(800);
    expect(ctx.channelId).toBe("telegram");
  });

  it("toInternalMessageResponseReadyContext works with minimal params", () => {
    const ctx = toInternalMessageResponseReadyContext({ content: "hi" });
    expect(ctx.content).toBe("hi");
    expect(ctx.provider).toBeUndefined();
    expect(ctx.usage).toBeUndefined();
  });

  it("maps sent context consistently for plugin/internal hooks", () => {
    const canonical = buildCanonicalSentMessageHookContext({
      to: "telegram:chat:456",
      content: "reply",
      success: false,
      error: "network error",
      channelId: "telegram",
      accountId: "acc-1",
      messageId: "out-1",
      isGroup: true,
      groupId: "telegram:chat:456",
    });

    expect(toPluginMessageContext(canonical)).toEqual({
      channelId: "telegram",
      accountId: "acc-1",
      conversationId: "telegram:chat:456",
    });
    expect(toPluginMessageSentEvent(canonical)).toEqual({
      to: "telegram:chat:456",
      content: "reply",
      success: false,
      error: "network error",
    });
    expect(toInternalMessageSentContext(canonical)).toEqual({
      to: "telegram:chat:456",
      content: "reply",
      success: false,
      error: "network error",
      channelId: "telegram",
      accountId: "acc-1",
      conversationId: "telegram:chat:456",
      messageId: "out-1",
      isGroup: true,
      groupId: "telegram:chat:456",
    });
  });
});
