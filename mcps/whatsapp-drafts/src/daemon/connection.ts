// Baileys WebSocket lifecycle. Single source of truth for "are we connected
// to WhatsApp right now." Owns the socket; emits high-level events to the
// rest of the daemon (RPC server, message ingest).
//
// State machine:
//   connecting   ─► connected   ─► reconnecting ─► (back to connecting)
//                       │
//                       └─► logged_out (terminal; writes LOGGED_OUT sentinel)
//
// Reconnect backoff: 1s initial, 2x multiplier, 60s cap, ±10% jitter.
// loggedOut    → write sentinel, stop process. launchd will respawn but
//                the next startup checks the sentinel and exits 0 immediately
//                so the user has to clear it via the menu bar's Reconnect
//                flow.
// restartRequired → reconnect immediately, no backoff.

import { writeFileSync } from "node:fs";
import { EventEmitter } from "node:events";

import {
  type WAMessage,
  type WAMessageKey,
  type WASocket,
  Browsers,
  DisconnectReason,
  fetchLatestBaileysVersion,
  makeWASocket,
} from "@whiskeysockets/baileys";

// Baileys re-throws @hapi/boom errors with this shape — typed structurally
// to avoid taking @hapi/boom as a direct dependency.
type BoomLike = Error & { output?: { statusCode?: number } };

import { PATHS } from "../paths.ts";
import { insertMessage, upsertThread, upsertContact, type IngestMessage, type MessageType } from "../storage/messages.ts";
import { useSqliteAuthState } from "../storage/session.ts";

export type ConnectionState = "connecting" | "connected" | "reconnecting" | "logged_out";

export interface ConnectionEvents {
  state: (s: ConnectionState) => void;
  qr: (qr: string) => void;
  paired: (info: { phone_number?: string }) => void;
}

const BACKOFF_INITIAL_MS = 1000;
const BACKOFF_MULTIPLIER = 2;
const BACKOFF_CAP_MS = 60_000;
const BACKOFF_JITTER = 0.1;

export class WhatsAppConnection extends EventEmitter {
  private socket: WASocket | null = null;
  private state: ConnectionState = "connecting";
  private currentQr: string | null = null;
  private meJid: string | null = null;
  private mePhone: string | null = null;
  private backoffMs: number = BACKOFF_INITIAL_MS;
  private stopped = false;

  override on<K extends keyof ConnectionEvents>(event: K, listener: ConnectionEvents[K]): this {
    return super.on(event, listener as never);
  }
  override emit<K extends keyof ConnectionEvents>(event: K, ...args: Parameters<ConnectionEvents[K]>): boolean {
    return super.emit(event, ...(args as unknown[]));
  }

  getState(): ConnectionState { return this.state; }
  getQr(): string | null { return this.currentQr; }
  getMe(): { jid: string | null; phone: string | null } {
    return { jid: this.meJid, phone: this.mePhone };
  }

  async start(): Promise<void> {
    this.stopped = false;
    await this.connect();
  }

  /**
   * Set state to `logged_out` without starting Baileys. Called from
   * `index.ts` main() when the LOGGED_OUT sentinel is present so the
   * menubar UI reflects the recovery state while the RPC server stays
   * up to handle `unlinkAndReset`.
   */
  markLoggedOut(): void {
    this.setState("logged_out");
  }

  private setState(s: ConnectionState): void {
    if (s === this.state) return;
    this.state = s;
    this.emit("state", s);
  }

  private async connect(): Promise<void> {
    this.setState(this.socket == null ? "connecting" : "reconnecting");

    const { state: authState, saveCreds } = await useSqliteAuthState();
    const { version } = await fetchLatestBaileysVersion().catch(() => ({ version: [2, 3000, 0] as [number, number, number] }));

    const sock = makeWASocket({
      version,
      auth: authState,
      // Shows up in WhatsApp → Linked Devices as "Messages for AI on
      // Mac OS". Matches the user-visible brand of the .app bundle so
      // the user can identify it at a glance vs other WhatsApp Web
      // sessions they might have linked.
      browser: Browsers.macOS("Messages for AI"),
      printQRInTerminal: false,
      syncFullHistory: false,  // initial history-sync handled via messaging-history.set
      generateHighQualityLinkPreview: false,
    });

    sock.ev.on("creds.update", () => { void saveCreds(); });

    sock.ev.on("connection.update", (update) => {
      const { connection, lastDisconnect, qr } = update;
      if (qr != null && qr !== this.currentQr) {
        this.currentQr = qr;
        this.emit("qr", qr);
      }
      if (connection === "open") {
        this.currentQr = null;
        this.backoffMs = BACKOFF_INITIAL_MS;
        this.setState("connected");
        const meId = sock.user?.id ?? null;
        // Baileys appends ":N@s.whatsapp.net" device suffix (e.g.
        // "12025550001:42@s.whatsapp.net") — for sendMessage targeting
        // we want the bare user JID without the device part.
        this.meJid = meId != null ? meId.replace(/:\d+@/, "@") : null;
        this.mePhone = this.meJid != null ? jidToPhone(this.meJid) : null;
        this.emit("paired", { phone_number: this.mePhone ?? undefined });
      } else if (connection === "close") {
        this.handleClose(lastDisconnect?.error as Error | undefined);
      }
    });

    sock.ev.on("messages.upsert", ({ messages, type }) => {
      // type is "notify" (live), "append" (history), "prepend" (history), or "replace"
      const source = type === "notify" ? "live" : "history-sync";
      for (const msg of messages) {
        const ingest = toIngestMessage(msg, source);
        if (ingest != null) insertMessage(ingest);
      }
    });

    sock.ev.on("messaging-history.set", ({ chats, contacts, messages }) => {
      for (const c of chats) {
        // Baileys 7.x widened Chat.id from `string` to `string | null |
        // undefined` — intermediate history-sync states can ship null
        // ids. Skip those rather than poisoning the threads table with
        // an empty primary key.
        if (c.id == null) continue;
        upsertThread({
          thread_jid: c.id,
          display_name: c.name ?? null,
          is_group: c.id.endsWith("@g.us"),
          last_message_ts: typeof c.conversationTimestamp === "number"
            ? c.conversationTimestamp * 1000
            : 0,
        });
      }
      for (const contact of contacts) {
        upsertContact({
          jid: contact.id,
          display_name: contact.name ?? null,
          push_name: contact.notify ?? null,
        });
      }
      for (const msg of messages) {
        const ingest = toIngestMessage(msg, "history-sync");
        if (ingest != null) insertMessage(ingest);
      }
    });

    sock.ev.on("chats.upsert", (chats) => {
      for (const c of chats) {
        // See messaging-history.set: Baileys 7.x can pass null id.
        if (c.id == null) continue;
        upsertThread({
          thread_jid: c.id,
          display_name: c.name ?? null,
          is_group: c.id.endsWith("@g.us"),
          last_message_ts: typeof c.conversationTimestamp === "number"
            ? c.conversationTimestamp * 1000
            : Date.now(),
        });
      }
    });

    sock.ev.on("contacts.upsert", (contacts) => {
      for (const contact of contacts) {
        upsertContact({
          jid: contact.id,
          display_name: contact.name ?? null,
          push_name: contact.notify ?? null,
        });
      }
    });

    this.socket = sock;
  }

  private handleClose(err: Error | undefined): void {
    const statusCode = (err as BoomLike | undefined)?.output?.statusCode;
    this.socket = null;

    if (statusCode === DisconnectReason.loggedOut) {
      this.setState("logged_out");
      writeFileSync(PATHS.loggedOutSentinel, `${new Date().toISOString()}\n`, { mode: 0o600 });
      process.stderr.write("Baileys reports loggedOut — wrote LOGGED_OUT sentinel, exiting\n");
      process.exit(0);
    }

    if (this.stopped) return;

    if (statusCode === DisconnectReason.restartRequired) {
      // Server told us to restart, no backoff needed.
      this.setState("reconnecting");
      setImmediate(() => { void this.connect(); });
      return;
    }

    // Any other close → exponential backoff with jitter.
    const jitter = 1 + (Math.random() * 2 - 1) * BACKOFF_JITTER;
    const delay = Math.min(BACKOFF_CAP_MS, this.backoffMs) * jitter;
    this.backoffMs = Math.min(BACKOFF_CAP_MS, this.backoffMs * BACKOFF_MULTIPLIER);
    this.setState("reconnecting");
    setTimeout(() => { void this.connect(); }, delay);
  }

  /** Graceful shutdown for SIGTERM handling. */
  async stop(): Promise<void> {
    this.stopped = true;
    if (this.socket != null) {
      try { await this.socket.end(new Error("daemon shutting down")); } catch { /* ignore */ }
      this.socket = null;
    }
  }

  /** Send a message via Baileys. Used by daemon's sendDraft handler. */
  async sendText(jid: string, body: string): Promise<{ message_id: string }> {
    if (this.socket == null || this.state !== "connected") {
      throw new Error("Not connected to WhatsApp");
    }
    const result = await this.socket.sendMessage(jid, { text: body });
    return { message_id: result?.key.id ?? "" };
  }
}

function toIngestMessage(msg: WAMessage, source: "live" | "history-sync"): IngestMessage | null {
  const key: WAMessageKey = msg.key;
  if (key.remoteJid == null || key.id == null) return null;

  const ts = typeof msg.messageTimestamp === "number"
    ? msg.messageTimestamp * 1000
    : (msg.messageTimestamp as { low: number } | undefined)?.low != null
      ? (msg.messageTimestamp as { low: number }).low * 1000
      : Date.now();

  const { body, type, attachment_meta } = extractMessageContent(msg);

  return {
    message_id: key.id,
    thread_jid: key.remoteJid,
    sender_jid: key.participant ?? key.remoteJid,
    from_me: key.fromMe === true,
    ts,
    body,
    message_type: type,
    attachment_meta,
    reply_to_id: msg.message?.extendedTextMessage?.contextInfo?.stanzaId ?? null,
    source,
  };
}

function extractMessageContent(msg: WAMessage): {
  body: string | null;
  type: MessageType;
  attachment_meta: { caption?: string; filename?: string; mime?: string } | null;
} {
  const m = msg.message;
  if (m == null) return { body: null, type: "system", attachment_meta: null };

  if (m.conversation != null) {
    return { body: m.conversation, type: "text", attachment_meta: null };
  }
  if (m.extendedTextMessage?.text != null) {
    return { body: m.extendedTextMessage.text, type: "text", attachment_meta: null };
  }
  if (m.imageMessage != null) {
    return {
      body: m.imageMessage.caption ?? null,
      type: "image",
      attachment_meta: {
        caption: m.imageMessage.caption ?? undefined,
        mime: m.imageMessage.mimetype ?? undefined,
      },
    };
  }
  if (m.videoMessage != null) {
    return {
      body: m.videoMessage.caption ?? null,
      type: "video",
      attachment_meta: {
        caption: m.videoMessage.caption ?? undefined,
        mime: m.videoMessage.mimetype ?? undefined,
      },
    };
  }
  if (m.audioMessage != null) {
    return {
      body: null,
      type: "voice",
      attachment_meta: {
        mime: m.audioMessage.mimetype ?? undefined,
      },
    };
  }
  if (m.documentMessage != null) {
    return {
      body: m.documentMessage.caption ?? null,
      type: "document",
      attachment_meta: {
        caption: m.documentMessage.caption ?? undefined,
        filename: m.documentMessage.fileName ?? undefined,
        mime: m.documentMessage.mimetype ?? undefined,
      },
    };
  }
  // Reactions, protocol messages, etc. — store as system with no body.
  return { body: null, type: "system", attachment_meta: null };
}

/** "12025550001@s.whatsapp.net" → "+12025550001". Returns input unchanged on parse fail. */
function jidToPhone(jid: string): string {
  const at = jid.indexOf("@");
  if (at < 0) return jid;
  const num = jid.slice(0, at).replace(/[^0-9]/g, "");
  if (num.length === 0) return jid;
  return `+${num}`;
}
