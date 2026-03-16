import { refreshGoogleToken } from "./gmailAuth.js";
import { logger } from "../core/logger.js";
import { SessionState } from "../core/types.js";

export interface CalendarClientConfig {
  googleClientId?: string;
  googleClientSecret?: string;
  timeoutMs?: number;
}

export interface CalendarEventSummary {
  eventId: string;
  summary: string;
  start: string;       // ISO 8601
  end: string;         // ISO 8601
  location?: string;
  description?: string;
  attendees: string[];  // email addresses
  status: string;
  htmlLink: string;
  isAllDay: boolean;
}

export interface CalendarListResult {
  events: CalendarEventSummary[];
  nextPageToken?: string;
}

export interface CalendarEventDetail extends CalendarEventSummary {
  creator?: string;
  organizer?: string;
  recurrence?: string[];
}

export interface CalendarMutationResult {
  eventId: string;
  htmlLink: string;
  status: string;
}

export class CalendarClient {
  private readonly clientId: string;
  private readonly clientSecret: string;
  private readonly timeoutMs: number;

  constructor(config: CalendarClientConfig) {
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

    if (session.gmailTokenExpiresAt && Date.now() < session.gmailTokenExpiresAt - 60_000) {
      return session.gmailAccessToken;
    }

    if (!session.gmailRefreshToken) {
      throw new Error("gmail_token_expired");
    }

    try {
      const refreshed = await refreshGoogleToken(
        session.gmailRefreshToken,
        this.clientId,
        this.clientSecret || undefined,
      );
      session.gmailAccessToken = refreshed.access_token;
      session.gmailTokenExpiresAt = Date.now() + refreshed.expires_in * 1000;
      return refreshed.access_token;
    } catch {
      throw new Error("gmail_token_expired");
    }
  }

  async listEvents(
    session: SessionState,
    options: { timeMin: string; timeMax: string; maxResults?: number; q?: string; pageToken?: string },
  ): Promise<CalendarListResult> {
    const token = await this.getValidAccessToken(session);
    const params = new URLSearchParams();
    params.set("singleEvents", "true");
    params.set("orderBy", "startTime");
    params.set("timeMin", options.timeMin);
    params.set("timeMax", options.timeMax);
    if (options.maxResults !== undefined) params.set("maxResults", String(options.maxResults));
    if (options.q) params.set("q", options.q);
    if (options.pageToken) params.set("pageToken", options.pageToken);

    const data = await this.calendarRequest(token, `/calendars/primary/events?${params.toString()}`);
    const rawItems = Array.isArray(data.items) ? data.items : [];

    const events: CalendarEventSummary[] = [];
    for (const item of rawItems) {
      if (item && typeof item === "object" && !Array.isArray(item)) {
        try {
          events.push(this.parseEvent(item as Record<string, unknown>));
        } catch (error) {
          logger.warn(`calendar: failed to parse event: ${error instanceof Error ? error.message : "unknown"}`);
        }
      }
    }

    return {
      events,
      nextPageToken: typeof data.nextPageToken === "string" ? data.nextPageToken : undefined,
    };
  }

  async getEvent(session: SessionState, eventId: string): Promise<CalendarEventDetail> {
    const token = await this.getValidAccessToken(session);
    const data = await this.calendarRequest(token, `/calendars/primary/events/${encodeURIComponent(eventId)}`);

    const base = this.parseEvent(data);

    const creator = data.creator as Record<string, unknown> | undefined;
    const organizer = data.organizer as Record<string, unknown> | undefined;

    return {
      ...base,
      creator: typeof creator?.email === "string" ? creator.email : undefined,
      organizer: typeof organizer?.email === "string" ? organizer.email : undefined,
      recurrence: Array.isArray(data.recurrence)
        ? (data.recurrence as unknown[]).map(r => String(r))
        : undefined,
    };
  }

  async createEvent(
    session: SessionState,
    options: {
      summary: string;
      startTime: string;
      endTime: string;
      description?: string;
      location?: string;
      attendees?: string[];
    },
  ): Promise<CalendarMutationResult> {
    const token = await this.getValidAccessToken(session);

    const body: Record<string, unknown> = {
      summary: options.summary,
      start: { dateTime: options.startTime },
      end: { dateTime: options.endTime },
    };
    if (options.description !== undefined) body.description = options.description;
    if (options.location !== undefined) body.location = options.location;
    if (options.attendees !== undefined) body.attendees = options.attendees.map(email => ({ email }));

    const data = await this.calendarRequest(token, "/calendars/primary/events", {
      method: "POST",
      body: JSON.stringify(body),
    });

    return {
      eventId: typeof data.id === "string" ? data.id : "",
      htmlLink: typeof data.htmlLink === "string" ? data.htmlLink : "",
      status: typeof data.status === "string" ? data.status : "confirmed",
    };
  }

  async updateEvent(
    session: SessionState,
    eventId: string,
    options: {
      summary?: string;
      startTime?: string;
      endTime?: string;
      description?: string;
      location?: string;
      attendees?: string[];
    },
  ): Promise<CalendarMutationResult> {
    const token = await this.getValidAccessToken(session);

    const body: Record<string, unknown> = {};
    if (options.summary !== undefined) body.summary = options.summary;
    if (options.startTime !== undefined) body.start = { dateTime: options.startTime };
    if (options.endTime !== undefined) body.end = { dateTime: options.endTime };
    if (options.description !== undefined) body.description = options.description;
    if (options.location !== undefined) body.location = options.location;
    if (options.attendees !== undefined) body.attendees = options.attendees.map(email => ({ email }));

    const data = await this.calendarRequest(token, `/calendars/primary/events/${encodeURIComponent(eventId)}`, {
      method: "PATCH",
      body: JSON.stringify(body),
    });

    return {
      eventId: typeof data.id === "string" ? data.id : "",
      htmlLink: typeof data.htmlLink === "string" ? data.htmlLink : "",
      status: typeof data.status === "string" ? data.status : "confirmed",
    };
  }

  async deleteEvent(session: SessionState, eventId: string): Promise<{ deleted: true }> {
    const token = await this.getValidAccessToken(session);
    await this.calendarRequest(token, `/calendars/primary/events/${encodeURIComponent(eventId)}`, {
      method: "DELETE",
    });
    return { deleted: true };
  }

  private async calendarRequest(
    accessToken: string,
    path: string,
    options: { method?: string; body?: string } = {},
  ): Promise<Record<string, unknown>> {
    const url = `https://www.googleapis.com/calendar/v3${path}`;
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
      throw new Error(`calendar_http_${response.status}:${text.slice(0, 200)}`);
    }

    // DELETE returns 204 No Content
    if (response.status === 204) {
      return {};
    }

    const result = await response.json();
    if (!result || typeof result !== "object" || Array.isArray(result)) {
      throw new Error("calendar_invalid_response");
    }
    return result as Record<string, unknown>;
  }

  private parseEvent(item: Record<string, unknown>): CalendarEventSummary {
    const start = item.start as Record<string, unknown> | undefined;
    const end = item.end as Record<string, unknown> | undefined;
    const isAllDay = typeof start?.date === "string";
    const attendeeList = Array.isArray(item.attendees)
      ? (item.attendees as Array<Record<string, unknown>>).map(a => String(a.email ?? "")).filter(Boolean)
      : [];

    return {
      eventId: String(item.id ?? ""),
      summary: String(item.summary ?? "(No title)"),
      start: String(isAllDay ? start?.date : start?.dateTime ?? ""),
      end: String(isAllDay ? end?.date : end?.dateTime ?? ""),
      location: typeof item.location === "string" ? item.location : undefined,
      description: typeof item.description === "string" ? item.description : undefined,
      attendees: attendeeList,
      status: String(item.status ?? "confirmed"),
      htmlLink: String(item.htmlLink ?? ""),
      isAllDay,
    };
  }
}
