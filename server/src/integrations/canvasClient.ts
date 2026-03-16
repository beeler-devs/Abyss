import { logger } from "../core/logger.js";
import { SessionState } from "../core/types.js";

const DEFAULT_BASE_URL = "https://canvas.cmu.edu";
const DEFAULT_TIMEOUT_MS = 15_000;
const DEFAULT_PER_PAGE = 50;

export class CanvasClient {
  private readonly timeoutMs: number;

  constructor(options: { timeoutMs?: number } = {}) {
    this.timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  }

  isConfigured(): boolean {
    return true; // No server-side config needed — tokens come from iOS client
  }

  async courses(session: SessionState): Promise<Record<string, unknown>[]> {
    return this.paginatedGet(
      session,
      `/api/v1/courses?enrollment_state=active&per_page=${DEFAULT_PER_PAGE}`,
    );
  }

  async assignments(
    session: SessionState,
    courseId: string,
  ): Promise<Record<string, unknown>[]> {
    return this.paginatedGet(
      session,
      `/api/v1/courses/${encodeURIComponent(courseId)}/assignments?per_page=${DEFAULT_PER_PAGE}&order_by=due_at`,
    );
  }

  async todo(session: SessionState): Promise<Record<string, unknown>[]> {
    return this.paginatedGet(session, `/api/v1/users/self/todo`);
  }

  async upcomingEvents(
    session: SessionState,
  ): Promise<Record<string, unknown>[]> {
    return this.paginatedGet(session, `/api/v1/users/self/upcoming_events`);
  }

  async grades(
    session: SessionState,
    courseId: string,
  ): Promise<Record<string, unknown>[]> {
    return this.paginatedGet(
      session,
      `/api/v1/courses/${encodeURIComponent(courseId)}/enrollments?user_id=self&type[]=StudentEnrollment`,
    );
  }

  async announcements(
    session: SessionState,
    courseId: string,
  ): Promise<Record<string, unknown>[]> {
    return this.paginatedGet(
      session,
      `/api/v1/courses/${encodeURIComponent(courseId)}/discussion_topics?only_announcements=true&per_page=${DEFAULT_PER_PAGE}`,
    );
  }

  // ---------- Internal ----------

  private getBaseURL(session: SessionState): string {
    return session.canvasBaseURL?.replace(/\/+$/, "") || DEFAULT_BASE_URL;
  }

  private getAccessToken(session: SessionState): string {
    if (!session.canvasAccessToken) {
      throw new Error("canvas_not_authenticated");
    }
    return session.canvasAccessToken;
  }

  private async canvasRequest(
    session: SessionState,
    path: string,
  ): Promise<{ data: unknown; linkHeader: string | null }> {
    const baseURL = this.getBaseURL(session);
    const token = this.getAccessToken(session);

    const url = path.startsWith("http") ? path : `${baseURL}${path}`;
    const response = await fetch(url, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
      },
      signal: AbortSignal.timeout(this.timeoutMs),
    });

    if (!response.ok) {
      const text = await response.text().catch(() => "");
      throw new Error(`canvas_http_${response.status}:${text.slice(0, 200)}`);
    }

    // Rate limit awareness
    const requestCost = response.headers.get("X-Request-Cost");
    const rateRemaining = response.headers.get("X-Rate-Limit-Remaining");
    if (requestCost && rateRemaining) {
      const remaining = parseFloat(rateRemaining);
      if (remaining < 50) {
        logger.warn(
          `canvas rate limit low: remaining=${remaining} cost=${requestCost}`,
        );
      }
    }

    const data = await response.json();
    const linkHeader = response.headers.get("Link");
    return { data, linkHeader };
  }

  private parseNextLink(linkHeader: string | null): string | null {
    if (!linkHeader) return null;

    const match = linkHeader.match(/<([^>]+)>;\s*rel="next"/);
    return match ? match[1]! : null;
  }

  private async paginatedGet(
    session: SessionState,
    initialPath: string,
    maxPages: number = 3,
  ): Promise<Record<string, unknown>[]> {
    const results: Record<string, unknown>[] = [];
    let path: string | null = initialPath;
    let page = 0;

    while (path && page < maxPages) {
      page++;
      const { data, linkHeader } = await this.canvasRequest(session, path);

      if (Array.isArray(data)) {
        for (const item of data) {
          if (item && typeof item === "object" && !Array.isArray(item)) {
            results.push(item as Record<string, unknown>);
          }
        }
      } else if (data && typeof data === "object" && !Array.isArray(data)) {
        results.push(data as Record<string, unknown>);
      }

      path = this.parseNextLink(linkHeader);
    }

    return results;
  }
}
