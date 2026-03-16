import { refreshGoogleToken } from "./gmailAuth.js";
import { logger } from "../core/logger.js";
import { SessionState } from "../core/types.js";

export interface GmailClientConfig {
  googleClientId?: string;
  googleClientSecret?: string;
  timeoutMs?: number;
}

export interface GmailListResult {
  messages: GmailMessageSummary[];
  nextPageToken?: string;
  resultSizeEstimate?: number;
}

export interface GmailMessageSummary {
  messageId: string;
  threadId: string;
  from: string;
  to: string[];
  subject: string;
  date: string;
  snippet: string;
}

export interface GmailMessage extends GmailMessageSummary {
  body: string;
  cc: string[];
}

export interface GmailSendResult {
  messageId: string;
  threadId: string;
}

const MAX_BODY_LENGTH = 10_000;

export class GmailClient {
  private readonly clientId: string;
  private readonly clientSecret: string;
  private readonly timeoutMs: number;

  constructor(config: GmailClientConfig) {
    this.clientId = config.googleClientId?.trim() ?? "";
    this.clientSecret = config.googleClientSecret?.trim() ?? "";
    this.timeoutMs = config.timeoutMs ?? 15_000;
  }

  isConfigured(): boolean {
    // Only client ID is required — iOS clients use PKCE and have no secret.
    return this.clientId.length > 0;
  }

  async getValidAccessToken(session: SessionState): Promise<string> {
    if (!session.gmailAccessToken) {
      throw new Error("gmail_not_authenticated");
    }

    if (session.gmailTokenExpiresAt) {
      // iOS stores expiresAt as epoch seconds; Date.now() returns milliseconds.
      // Heuristic: any value > 1e12 is already ms, otherwise convert s → ms.
      const expiresAtMs = session.gmailTokenExpiresAt > 1e12
        ? session.gmailTokenExpiresAt
        : session.gmailTokenExpiresAt * 1000;
      const isValid = Date.now() < expiresAtMs - 60_000;
      logger.info(`gmail token check: expiresAtMs=${expiresAtMs} now=${Date.now()} valid=${isValid} hasRefreshToken=${!!session.gmailRefreshToken}`);
      if (isValid) {
        return session.gmailAccessToken;
      }
    }

    if (!session.gmailRefreshToken) {
      throw new Error("gmail_token_expired");
    }

    try {
      logger.info(`gmail token refresh: clientId=${this.clientId.slice(0, 12)}... hasSecret=${!!this.clientSecret}`);
      const refreshed = await refreshGoogleToken(
        session.gmailRefreshToken,
        this.clientId,
        this.clientSecret || undefined,
      );
      session.gmailAccessToken = refreshed.access_token;
      session.gmailTokenExpiresAt = Date.now() + refreshed.expires_in * 1000;
      logger.info("gmail token refresh: success");
      return refreshed.access_token;
    } catch (err) {
      logger.warn(`gmail token refresh failed: ${err instanceof Error ? err.message : String(err)}`);
      throw new Error("gmail_token_expired");
    }
  }

  async list(
    session: SessionState,
    options: { maxResults?: number; pageToken?: string; labelIds?: string[] } = {},
  ): Promise<GmailListResult> {
    const token = await this.getValidAccessToken(session);
    const params = new URLSearchParams();
    params.set("maxResults", String(options.maxResults ?? 10));
    if (options.pageToken) params.set("pageToken", options.pageToken);
    if (options.labelIds?.length) {
      for (const label of options.labelIds) {
        params.append("labelIds", label);
      }
    }

    const listData = await this.gmailRequest(token, `messages?${params.toString()}`);
    const rawMessages = Array.isArray(listData.messages) ? listData.messages : [];

    const messages: GmailMessageSummary[] = [];
    for (const raw of rawMessages.slice(0, options.maxResults ?? 10)) {
      const msgId = typeof raw.id === "string" ? raw.id : undefined;
      if (!msgId) continue;

      try {
        const detail = await this.gmailRequest(token, `messages/${msgId}?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject&metadataHeaders=Date`);
        messages.push(this.parseMessageSummary(detail));
      } catch (error) {
        logger.warn(`gmail: failed to fetch message ${msgId}: ${error instanceof Error ? error.message : "unknown"}`);
      }
    }

    return {
      messages,
      nextPageToken: typeof listData.nextPageToken === "string" ? listData.nextPageToken : undefined,
      resultSizeEstimate: typeof listData.resultSizeEstimate === "number" ? listData.resultSizeEstimate : undefined,
    };
  }

  async search(
    session: SessionState,
    query: string,
    options: { maxResults?: number; pageToken?: string } = {},
  ): Promise<GmailListResult> {
    const token = await this.getValidAccessToken(session);
    const params = new URLSearchParams();
    params.set("q", query);
    params.set("maxResults", String(options.maxResults ?? 10));
    if (options.pageToken) params.set("pageToken", options.pageToken);

    const listData = await this.gmailRequest(token, `messages?${params.toString()}`);
    const rawMessages = Array.isArray(listData.messages) ? listData.messages : [];

    const messages: GmailMessageSummary[] = [];
    for (const raw of rawMessages.slice(0, options.maxResults ?? 10)) {
      const msgId = typeof raw.id === "string" ? raw.id : undefined;
      if (!msgId) continue;

      try {
        const detail = await this.gmailRequest(token, `messages/${msgId}?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject&metadataHeaders=Date`);
        messages.push(this.parseMessageSummary(detail));
      } catch (error) {
        logger.warn(`gmail: failed to fetch message ${msgId}: ${error instanceof Error ? error.message : "unknown"}`);
      }
    }

    return {
      messages,
      nextPageToken: typeof listData.nextPageToken === "string" ? listData.nextPageToken : undefined,
      resultSizeEstimate: typeof listData.resultSizeEstimate === "number" ? listData.resultSizeEstimate : undefined,
    };
  }

  async read(session: SessionState, messageId: string): Promise<GmailMessage> {
    const token = await this.getValidAccessToken(session);
    const data = await this.gmailRequest(token, `messages/${messageId}?format=full`);
    return this.parseFullMessage(data);
  }

  async send(
    session: SessionState,
    options: { to: string; cc?: string; subject: string; body: string },
  ): Promise<GmailSendResult> {
    const token = await this.getValidAccessToken(session);
    const raw = this.buildRawEmail({
      to: options.to,
      cc: options.cc,
      subject: options.subject,
      body: options.body,
    });

    const data = await this.gmailRequest(token, "messages/send", {
      method: "POST",
      body: JSON.stringify({ raw }),
    });

    return {
      messageId: typeof data.id === "string" ? data.id : "",
      threadId: typeof data.threadId === "string" ? data.threadId : "",
    };
  }

  async reply(
    session: SessionState,
    messageId: string,
    options: { body: string; to?: string; cc?: string },
  ): Promise<GmailSendResult> {
    const token = await this.getValidAccessToken(session);

    const original = await this.gmailRequest(token, `messages/${messageId}?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject&metadataHeaders=Message-ID`);
    const headers = this.extractHeaders(original);
    const replyTo = options.to || headers.from;
    const subject = headers.subject.startsWith("Re:") ? headers.subject : `Re: ${headers.subject}`;
    const messageIdHeader = headers.messageId;

    const raw = this.buildRawEmail({
      to: replyTo,
      cc: options.cc,
      subject,
      body: options.body,
      inReplyTo: messageIdHeader,
      references: messageIdHeader,
    });

    const threadId = typeof original.threadId === "string" ? original.threadId : undefined;

    const data = await this.gmailRequest(token, "messages/send", {
      method: "POST",
      body: JSON.stringify({
        raw,
        threadId,
      }),
    });

    return {
      messageId: typeof data.id === "string" ? data.id : "",
      threadId: typeof data.threadId === "string" ? data.threadId : "",
    };
  }

  private async gmailRequest(
    accessToken: string,
    path: string,
    options: { method?: string; body?: string } = {},
  ): Promise<Record<string, unknown>> {
    const url = `https://gmail.googleapis.com/gmail/v1/users/me/${path}`;
    const response = await fetch(url, {
      method: options.method ?? "GET",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: options.body,
      signal: AbortSignal.timeout(this.timeoutMs),
    });

    if (!response.ok) {
      const text = await response.text().catch(() => "");
      throw new Error(`gmail_http_${response.status}:${text.slice(0, 200)}`);
    }

    const result = await response.json();
    if (!result || typeof result !== "object" || Array.isArray(result)) {
      throw new Error("gmail_invalid_response");
    }
    return result as Record<string, unknown>;
  }

  private parseMessageSummary(data: Record<string, unknown>): GmailMessageSummary {
    const headers = this.extractHeaders(data);
    return {
      messageId: typeof data.id === "string" ? data.id : "",
      threadId: typeof data.threadId === "string" ? data.threadId : "",
      from: headers.from,
      to: headers.to ? headers.to.split(",").map((s) => s.trim()) : [],
      subject: headers.subject,
      date: headers.date,
      snippet: typeof data.snippet === "string" ? data.snippet : "",
    };
  }

  private parseFullMessage(data: Record<string, unknown>): GmailMessage {
    const summary = this.parseMessageSummary(data);
    const headers = this.extractHeaders(data);
    const body = this.extractBody(data);

    return {
      ...summary,
      body: body.slice(0, MAX_BODY_LENGTH),
      cc: headers.cc ? headers.cc.split(",").map((s) => s.trim()) : [],
    };
  }

  private extractHeaders(data: Record<string, unknown>): {
    from: string;
    to: string;
    cc: string;
    subject: string;
    date: string;
    messageId: string;
  } {
    const payload = data.payload as Record<string, unknown> | undefined;
    const headersArr = Array.isArray(payload?.headers) ? payload!.headers : [];

    const headerMap: Record<string, string> = {};
    for (const header of headersArr) {
      if (header && typeof header === "object" && !Array.isArray(header)) {
        const h = header as Record<string, unknown>;
        const name = typeof h.name === "string" ? h.name.toLowerCase() : "";
        const value = typeof h.value === "string" ? h.value : "";
        if (name) headerMap[name] = value;
      }
    }

    return {
      from: headerMap.from ?? "",
      to: headerMap.to ?? "",
      cc: headerMap.cc ?? "",
      subject: headerMap.subject ?? "",
      date: headerMap.date ?? "",
      messageId: headerMap["message-id"] ?? "",
    };
  }

  private extractBody(data: Record<string, unknown>): string {
    const payload = data.payload as Record<string, unknown> | undefined;
    if (!payload) return "";

    const plainText = this.findBodyPart(payload, "text/plain");
    if (plainText) return plainText;

    const html = this.findBodyPart(payload, "text/html");
    if (html) return this.stripHtml(html);

    return "";
  }

  private findBodyPart(part: Record<string, unknown>, mimeType: string): string | null {
    const partMime = typeof part.mimeType === "string" ? part.mimeType : "";

    if (partMime === mimeType) {
      const body = part.body as Record<string, unknown> | undefined;
      const bodyData = typeof body?.data === "string" ? body!.data : "";
      if (bodyData) {
        return Buffer.from(bodyData, "base64url").toString("utf8");
      }
    }

    const parts = Array.isArray(part.parts) ? part.parts : [];
    for (const child of parts) {
      if (child && typeof child === "object" && !Array.isArray(child)) {
        const result = this.findBodyPart(child as Record<string, unknown>, mimeType);
        if (result) return result;
      }
    }

    return null;
  }

  private stripHtml(html: string): string {
    return html
      .replace(/<style[^>]*>[\s\S]*?<\/style>/gi, "")
      .replace(/<script[^>]*>[\s\S]*?<\/script>/gi, "")
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<\/p>/gi, "\n\n")
      .replace(/<\/div>/gi, "\n")
      .replace(/<[^>]+>/g, "")
      .replace(/&nbsp;/gi, " ")
      .replace(/&amp;/gi, "&")
      .replace(/&lt;/gi, "<")
      .replace(/&gt;/gi, ">")
      .replace(/&quot;/gi, '"')
      .replace(/&#39;/gi, "'")
      .replace(/\n{3,}/g, "\n\n")
      .trim();
  }

  private buildRawEmail(options: {
    to: string;
    cc?: string;
    subject: string;
    body: string;
    inReplyTo?: string;
    references?: string;
  }): string {
    const lines: string[] = [
      `To: ${options.to}`,
      `Subject: ${options.subject}`,
      `Content-Type: text/plain; charset="UTF-8"`,
    ];

    if (options.cc) {
      lines.push(`Cc: ${options.cc}`);
    }
    if (options.inReplyTo) {
      lines.push(`In-Reply-To: ${options.inReplyTo}`);
    }
    if (options.references) {
      lines.push(`References: ${options.references}`);
    }

    lines.push("", options.body);
    const raw = lines.join("\r\n");
    return Buffer.from(raw, "utf8").toString("base64url");
  }
}
