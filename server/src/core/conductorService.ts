import crypto from "node:crypto";

import { CalendarClient } from "../integrations/calendarClient.js";
import { CanvasClient } from "../integrations/canvasClient.js";
import { CursorClient } from "../integrations/cursorClient.js";
import { GmailClient } from "../integrations/gmailClient.js";
import { GitHubClient } from "../integrations/githubClient.js";
import {
  isTerminalAgentStatus,
  normalizeMode,
  normalizeStatus,
  ParsedCursorWebhookEvent,
  parseCursorAgentSnapshotFromResult,
  parseCursorWebhookPayload,
} from "../integrations/cursorPayload.js";
import { asString, makeDeterministicEventId, makeEvent } from "./events.js";
import { logger } from "./logger.js";
import { MemoryService } from "./memory/memoryService.js";
import { SessionStore } from "./sessionStore.js";
import { summarizeIfNeeded, SummarizationConfig, DEFAULT_SUMMARIZATION_CONFIG } from "./contextSummarizer.js";
import { asRecord, stringFromRecord, summarizeValueForLog } from "./utils.js";
import {
  BridgeToolExecutor,
  ConversationTurn,
  CursorAgentMode,
  CursorAgentRunRecord,
  EventEnvelope,
  ModelProvider,
  ModelResponse,
  SessionState,
  ToolCallRequest,
  ToolDefinition,
} from "./types.js";

export interface ConductorServiceConfig {
  maxTurns: number;
  rateLimitPerMinute: number;
  traceMaxEntries?: number;
}

export interface ConductorServiceDependencies {
  cursorClient?: CursorClient;
  gmailClient?: GmailClient;
  canvasClient?: CanvasClient;
  calendarClient?: CalendarClient;
  githubClient?: GitHubClient;
  webhookPendingTtlMs?: number;
  now?: () => Date;
  bridgeToolExecutor?: BridgeToolExecutor;
  bridgeToolAvailability?: (sessionId: string, toolName: string) => boolean;
  verboseToolRoutingLogs?: boolean;
  memoryService?: MemoryService;
  summarizationConfig?: SummarizationConfig;
}

export interface CursorWebhookHandleResult {
  statusCode: number;
  payload: Record<string, unknown>;
}

const LEGACY_CLIENT_TOOLS: ToolDefinition[] = [
  {
    name: "agent.spawn",
    description:
      "Launch a new Cursor Cloud Agent to work on a repository. Use for coding tasks, PR creation, analysis. Requires a prompt and either repository (format: owner/repo) or prUrl.",
    input_schema: {
      type: "object",
      properties: {
        prompt: { type: "string", description: "The task for the agent to perform" },
        repository: { type: "string", description: "GitHub repository in owner/repo format" },
        ref: { type: "string", description: "Git ref/branch to work from" },
        prUrl: { type: "string", description: "Existing PR URL to work on instead of a repo" },
        model: { type: "string", description: "Model to use (optional)" },
        autoCreatePr: {
          type: "boolean",
          description: "Whether to auto-create a PR. Default false for safety.",
        },
        autoBranch: {
          type: "boolean",
          description: "Whether to auto-create a branch. Default false for safety.",
        },
        skipReviewerRequest: { type: "boolean" },
        branchName: { type: "string" },
      },
      required: ["prompt"],
    },
  },
  {
    name: "agent.status",
    description: "Get the current status of a running Cursor Cloud Agent by its ID.",
    input_schema: {
      type: "object",
      properties: {
        id: { type: "string", description: "The agent ID returned from agent.spawn" },
      },
      required: ["id"],
    },
  },
  {
    name: "agent.cancel",
    description: "Stop a running Cursor Cloud Agent.",
    input_schema: {
      type: "object",
      properties: {
        id: { type: "string", description: "The agent ID to cancel" },
      },
      required: ["id"],
    },
  },
  {
    name: "agent.followup",
    description: "Add a follow-up instruction to an existing Cursor Cloud Agent.",
    input_schema: {
      type: "object",
      properties: {
        id: { type: "string", description: "The agent ID" },
        prompt: { type: "string", description: "Follow-up instruction" },
      },
      required: ["id", "prompt"],
    },
  },
  {
    name: "agent.list",
    description: "List Cursor Cloud Agents for the authenticated user.",
    input_schema: {
      type: "object",
      properties: {
        limit: { type: "number" },
        cursor: { type: "string" },
        prUrl: { type: "string" },
      },
    },
  },
  {
    name: "repositories.list",
    description:
      "List all GitHub repositories the user has connected to Cursor. Call this before agent.spawn when you do not know the exact owner/repo string, or when the user refers to a repo by name. Returns a list of {repository, owner, name} objects. Always prefer a repository from this list over guessing.",
    input_schema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "repositories.select",
    description:
      "Present an interactive repository selection UI to the user. Use this when the user refers to a repository ambiguously, when you cannot confidently identify which repository they mean, or when multiple matches exist. The UI displays all connected repositories grouped by organization. Returns the user's selection. This tool blocks until the user makes a choice or cancels.",
    input_schema: {
      type: "object",
      properties: {
        prompt: {
          type: "string",
          description: "Optional message explaining what the selection is for, shown to the user",
        },
        filter: {
          type: "string",
          description: "Optional partial name to pre-filter the repository list",
        },
      },
    },
  },
];

const SERVER_CURSOR_TOOLS: ToolDefinition[] = [
  {
    name: "cursor.agent.spawn",
    description:
      "Spawn a Cursor Cloud Agent from the server with webhook tracking enabled. Prefer this over agent.spawn when available.",
    input_schema: {
      type: "object",
      properties: {
        prompt: { type: "string" },
        repoUrl: { type: "string" },
        ref: { type: "string" },
        metadata: { type: "object" },
        mode: { type: "string", description: "code | computer_use | webqa" },
      },
      required: ["prompt"],
    },
  },
  {
    name: "cursor.agent.status",
    description: "Query status for a server-tracked Cursor Cloud Agent.",
    input_schema: {
      type: "object",
      properties: {
        agentId: { type: "string" },
      },
      required: ["agentId"],
    },
  },
  {
    name: "cursor.agent.followup",
    description: "Send follow-up instructions to a server-tracked Cursor Cloud Agent.",
    input_schema: {
      type: "object",
      properties: {
        agentId: { type: "string" },
        message: { type: "string" },
      },
      required: ["agentId", "message"],
    },
  },
  {
    name: "cursor.agent.cancel",
    description: "Cancel a server-tracked Cursor Cloud Agent.",
    input_schema: {
      type: "object",
      properties: {
        agentId: { type: "string" },
      },
      required: ["agentId"],
    },
  },
  {
    name: "webqa.cursor.run",
    description:
      "Run browser validation/computer-use QA in Cursor. Use this when the user asks to validate behavior in a browser.",
    input_schema: {
      type: "object",
      properties: {
        url: { type: "string" },
        flowSpec: { type: "object" },
        assertions: { type: "object" },
        budget: { type: "object" },
      },
      required: ["url", "flowSpec"],
    },
  },
  {
    name: "webqa.cursor.status",
    description: "Check status of a Cursor-based WebQA run.",
    input_schema: {
      type: "object",
      properties: {
        agentId: { type: "string" },
      },
      required: ["agentId"],
    },
  },
  {
    name: "webqa.cursor.followup",
    description: "Send follow-up instructions to a Cursor WebQA run.",
    input_schema: {
      type: "object",
      properties: {
        agentId: { type: "string" },
        instruction: { type: "string" },
      },
      required: ["agentId", "instruction"],
    },
  },
];

const SERVER_BRIDGE_TOOLS: ToolDefinition[] = [
  {
    name: "bridge.exec.run",
    description:
      "Run a shell command on a paired Abyss Bridge Mac device. Use for local tests/build checks.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string", description: "Optional bridge device ID. Omit when only one bridge is paired." },
        command: { type: "string", description: "Shell command to execute (example: npm test)." },
        cwd: { type: "string", description: "Optional relative directory under workspace root." },
        timeoutSec: { type: "number", description: "Optional command timeout in seconds (max 900)." },
      },
      required: ["command"],
    },
  },
  {
    name: "bridge.exec.start",
    description: "Start a shell command on Bridge and stream output with bridge.exec.output events.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string" },
        command: { type: "string" },
        cwd: { type: "string" },
        env: { type: "object" },
        timeoutSec: { type: "number" },
      },
      required: ["command"],
    },
  },
  {
    name: "bridge.exec.cancel",
    description: "Cancel a running Bridge command by commandId.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string" },
        commandId: { type: "string" },
      },
      required: ["commandId"],
    },
  },
  {
    name: "bridge.exec.status",
    description: "Check status for a Bridge commandId.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string" },
        commandId: { type: "string" },
      },
      required: ["commandId"],
    },
  },
  {
    name: "bridge.exec.output.subscribe",
    description: "Subscribe to output stream for a Bridge commandId (no-op when push events already enabled).",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string" },
        commandId: { type: "string" },
      },
      required: ["commandId"],
    },
  },
  {
    name: "bridge.fs.readFile",
    description:
      "Read a UTF-8 text file from a paired Abyss Bridge Mac device workspace.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string", description: "Optional bridge device ID. Omit when only one bridge is paired." },
        path: { type: "string", description: "Relative file path under workspace root." },
      },
      required: ["path"],
    },
  },
  {
    name: "bridge.fs.search",
    description: "Search text in the Bridge workspace using ripgrep when available.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string" },
        query: { type: "string" },
        root: { type: "string" },
        globs: { type: "array" },
        maxResults: { type: "number" },
      },
      required: ["query"],
    },
  },
  {
    name: "bridge.fs.readRange",
    description: "Read a line range from a Bridge workspace file.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string" },
        path: { type: "string" },
        startLine: { type: "number" },
        endLine: { type: "number" },
      },
      required: ["path", "startLine", "endLine"],
    },
  },
  {
    name: "bridge.fs.applyPatch",
    description: "Apply a unified diff patch inside the Bridge workspace.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string" },
        unifiedDiff: { type: "string" },
        constraints: { type: "object" },
      },
      required: ["unifiedDiff"],
    },
  },
  {
    name: "bridge.git.status",
    description: "Get git branch and changed/staged files for the Bridge workspace.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string" },
      },
    },
  },
  {
    name: "bridge.git.diff",
    description: "Get git diff (optionally staged) for the Bridge workspace.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string" },
        staged: { type: "boolean" },
      },
    },
  },
  {
    name: "bridge.git.stage",
    description: "Stage selected file paths in Bridge workspace.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string" },
        paths: { type: "array" },
      },
      required: ["paths"],
    },
  },
  {
    name: "bridge.git.commit",
    description: "Commit staged Bridge workspace changes.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string" },
        message: { type: "string" },
      },
      required: ["message"],
    },
  },
  {
    name: "bridge.git.push",
    description: "Push a branch from Bridge workspace to remote.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string" },
        remote: { type: "string" },
        branch: { type: "string" },
      },
      required: ["remote", "branch"],
    },
  },
  {
    name: "bridge.claude.run",
    description:
      "Run Claude Code on a paired Mac to execute an AI-assisted task (e.g. fix a bug, analyze code). Requires a bridge device with claudeRun capability. For simple shell commands use bridge.exec.run instead.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string", description: "Optional bridge device ID. Omit when only one bridge is paired." },
        prompt: { type: "string", description: "The task prompt for Claude Code (e.g. 'fix the failing test in src/auth.ts')." },
        cwd: { type: "string", description: "Optional relative directory under workspace root." },
        timeoutSec: { type: "integer", description: "Optional timeout in seconds (default 660, max 660)." },
        allowedTools: { type: "string", description: "Comma-separated Claude Code tools to allow (default: Bash,Read,Edit,Write,LS,Glob,Grep,MultiEdit)." },
        maxTurns: { type: "integer", description: "Max agentic turns for Claude Code (default 30, max 100). Lower values finish faster but may leave tasks incomplete." },
      },
      required: ["prompt"],
    },
  },
  {
    name: "bridge.nova.start",
    description:
      "Start a persistent Nova Act browser session on a paired Mac. Opens Chrome at the given URL. Session persists across subsequent bridge.nova.act calls.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string", description: "Optional bridge device ID. Omit when only one bridge is paired." },
        url: { type: "string", description: "The URL to open Chrome at." },
        headless: { type: "boolean", description: "Run Chrome headless (default true)." },
        userDataDir: { type: "string", description: "Optional Chrome user data directory for persistent profiles." },
      },
      required: ["url"],
    },
  },
  {
    name: "bridge.nova.act",
    description:
      "Execute a natural-language browser instruction in the active Nova Act session. Optionally extract structured data with a JSON schema.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string", description: "Optional bridge device ID. Omit when only one bridge is paired." },
        instruction: { type: "string", description: "Natural-language instruction for the browser (e.g. 'Click the Sign In button')." },
        schema: { type: "string", description: "Optional JSON schema string for structured data extraction from the page." },
      },
      required: ["instruction"],
    },
  },
  {
    name: "bridge.nova.stop",
    description:
      "Close the active Nova Act browser session.",
    input_schema: {
      type: "object",
      properties: {
        deviceId: { type: "string", description: "Optional bridge device ID. Omit when only one bridge is paired." },
      },
    },
  },
];

const SERVER_GMAIL_TOOLS: ToolDefinition[] = [
  {
    name: "gmail.inbox",
    description:
      "List recent emails from the user's Gmail inbox. Returns sender, subject, date, and snippet for each message.",
    input_schema: {
      type: "object",
      properties: {
        maxResults: { type: "number", description: "Number of emails to return (default 10, max 20)." },
        pageToken: { type: "string", description: "Pagination token from a previous result." },
      },
    },
  },
  {
    name: "gmail.search",
    description:
      "Search the user's Gmail using Gmail search syntax (e.g. 'from:alice subject:meeting after:2024/01/01'). Returns matching messages with sender, subject, date, and snippet.",
    input_schema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Gmail search query string." },
        maxResults: { type: "number", description: "Number of results to return (default 10, max 20)." },
        pageToken: { type: "string", description: "Pagination token from a previous result." },
      },
      required: ["query"],
    },
  },
  {
    name: "gmail.read",
    description:
      "Read the full content of a specific email by its message ID. Returns sender, recipients, subject, date, and body text.",
    input_schema: {
      type: "object",
      properties: {
        messageId: { type: "string", description: "The Gmail message ID to read." },
      },
      required: ["messageId"],
    },
  },
  {
    name: "gmail.send",
    description:
      "Send a new email on behalf of the user. The app will show the draft in a confirmation card before actually sending. Just call this tool with the composed email content.",
    input_schema: {
      type: "object",
      properties: {
        to: { type: "string", description: "Recipient email address." },
        cc: { type: "string", description: "CC email address (optional)." },
        subject: { type: "string", description: "Email subject line." },
        body: { type: "string", description: "Email body text." },
      },
      required: ["to", "subject", "body"],
    },
  },
  {
    name: "gmail.reply",
    description:
      "Reply to an existing email by message ID. The app will show the draft reply in a confirmation card before actually sending. Just call this tool with the composed reply.",
    input_schema: {
      type: "object",
      properties: {
        messageId: { type: "string", description: "The Gmail message ID to reply to." },
        body: { type: "string", description: "Reply body text." },
        to: { type: "string", description: "Override recipient (optional, defaults to original sender)." },
        cc: { type: "string", description: "CC email address (optional)." },
      },
      required: ["messageId", "body"],
    },
  },
];

const SERVER_CALENDAR_TOOLS: ToolDefinition[] = [
  {
    name: "calendar.list",
    description:
      "List events from the user's Google Calendar within a date range. Returns title, start/end times, location, and attendees for each event.",
    input_schema: {
      type: "object",
      properties: {
        timeMin: { type: "string", description: "Start of time range in ISO 8601 format (e.g. '2026-03-15T00:00:00Z'). Required." },
        timeMax: { type: "string", description: "End of time range in ISO 8601 format (e.g. '2026-03-16T00:00:00Z'). Required." },
        maxResults: { type: "number", description: "Max events to return (default 10, max 50)." },
        q: { type: "string", description: "Free-text search filter (optional)." },
      },
      required: ["timeMin", "timeMax"],
    },
  },
  {
    name: "calendar.get",
    description:
      "Get full details of a specific calendar event by its event ID.",
    input_schema: {
      type: "object",
      properties: {
        eventId: { type: "string", description: "The Google Calendar event ID." },
      },
      required: ["eventId"],
    },
  },
  {
    name: "calendar.create",
    description:
      "Create a new Google Calendar event. The app will show a confirmation card for the user to review before creating. Just call this tool with the event details.",
    input_schema: {
      type: "object",
      properties: {
        summary: { type: "string", description: "Event title." },
        startTime: { type: "string", description: "Start time in ISO 8601 format." },
        endTime: { type: "string", description: "End time in ISO 8601 format." },
        description: { type: "string", description: "Event description (optional)." },
        location: { type: "string", description: "Event location (optional)." },
        attendees: { type: "string", description: "Comma-separated attendee email addresses (optional)." },
      },
      required: ["summary", "startTime", "endTime"],
    },
  },
  {
    name: "calendar.update",
    description:
      "Update an existing Google Calendar event (change time, title, etc.). The app will show a confirmation card before applying changes.",
    input_schema: {
      type: "object",
      properties: {
        eventId: { type: "string", description: "The event ID to update." },
        summary: { type: "string", description: "New event title (optional)." },
        startTime: { type: "string", description: "New start time in ISO 8601 (optional)." },
        endTime: { type: "string", description: "New end time in ISO 8601 (optional)." },
        description: { type: "string", description: "New description (optional)." },
        location: { type: "string", description: "New location (optional)." },
        attendees: { type: "string", description: "New comma-separated attendee emails (optional)." },
      },
      required: ["eventId"],
    },
  },
  {
    name: "calendar.delete",
    description:
      "Delete a Google Calendar event. The app will show a confirmation card before deleting.",
    input_schema: {
      type: "object",
      properties: {
        eventId: { type: "string", description: "The event ID to delete." },
        summary: { type: "string", description: "Event title for display in the confirmation card." },
      },
      required: ["eventId"],
    },
  },
];

const SERVER_CANVAS_TOOLS: ToolDefinition[] = [
  {
    name: "canvas.courses",
    description:
      "List the user's active Canvas LMS courses. Returns course names, IDs, and enrollment info.",
    input_schema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "canvas.assignments",
    description:
      "List assignments for a Canvas course, ordered by due date. Returns assignment names, due dates, points, and submission status.",
    input_schema: {
      type: "object",
      properties: {
        courseId: { type: "string", description: "The Canvas course ID." },
      },
      required: ["courseId"],
    },
  },
  {
    name: "canvas.todo",
    description:
      "Get the user's Canvas TODO items across all courses. Returns upcoming assignments and grading tasks.",
    input_schema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "canvas.upcoming",
    description:
      "Get upcoming calendar events from Canvas. Returns event titles, dates, and course associations.",
    input_schema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "canvas.grades",
    description:
      "Get the user's grades/enrollment for a specific Canvas course. Returns current score, grade, and enrollment details.",
    input_schema: {
      type: "object",
      properties: {
        courseId: { type: "string", description: "The Canvas course ID." },
      },
      required: ["courseId"],
    },
  },
  {
    name: "canvas.announcements",
    description:
      "Get announcements for a Canvas course. Returns announcement titles, messages, and post dates.",
    input_schema: {
      type: "object",
      properties: {
        courseId: { type: "string", description: "The Canvas course ID." },
      },
      required: ["courseId"],
    },
  },
];

const SERVER_GITHUB_TOOLS: ToolDefinition[] = [
  {
    name: "github.repos.list",
    description:
      "List GitHub repositories accessible to the authenticated user. Use this before other GitHub tools when the exact owner/repo string is unknown. Never guess a repository name when this tool is available.",
    input_schema: {
      type: "object",
      properties: {
        limit: { type: "number", description: "Max results to return (default 20, max 100)." },
      },
    },
  },
  {
    name: "github.pr.list",
    description:
      "List the user's pull requests. Pass repo in owner/repo format when the user names a repo; otherwise omit it to search across repos for PRs authored by the user.",
    input_schema: {
      type: "object",
      properties: {
        repo: { type: "string", description: "GitHub repository in owner/repo format." },
        state: { type: "string", description: "'open' (default), 'closed', or 'all'." },
        limit: { type: "number", description: "Max results to return (default 10, max 50)." },
      },
    },
  },
  {
    name: "github.pr.get",
    description:
      "Get details for a specific pull request, including branches, file change counts, mergeability, and review state.",
    input_schema: {
      type: "object",
      properties: {
        repo: { type: "string", description: "GitHub repository in owner/repo format." },
        prNumber: { type: "number", description: "Pull request number." },
      },
      required: ["repo", "prNumber"],
    },
  },
  {
    name: "github.pr.reviews",
    description:
      "Summarize reviews and inline review comments on a pull request. Use when the user asks what feedback or approvals a PR has received.",
    input_schema: {
      type: "object",
      properties: {
        repo: { type: "string", description: "GitHub repository in owner/repo format." },
        prNumber: { type: "number", description: "Pull request number." },
      },
      required: ["repo", "prNumber"],
    },
  },
  {
    name: "github.actions.status",
    description:
      "Get recent GitHub Actions status for a repository, branch, or pull request. Use this for CI questions.",
    input_schema: {
      type: "object",
      properties: {
        repo: { type: "string", description: "GitHub repository in owner/repo format." },
        branch: { type: "string", description: "Branch name to inspect." },
        prNumber: { type: "number", description: "Optional pull request number if branch is unknown." },
      },
      required: ["repo"],
    },
  },
  {
    name: "github.issues.list",
    description:
      "List GitHub issues. Pass repo when known; otherwise omit it to search globally. If the user asks for issues assigned to them, set assignee to 'me'.",
    input_schema: {
      type: "object",
      properties: {
        repo: { type: "string", description: "GitHub repository in owner/repo format." },
        state: { type: "string", description: "'open' (default) or 'closed'." },
        assignee: { type: "string", description: "Use 'me' for the authenticated user or pass a GitHub login." },
        limit: { type: "number", description: "Max results to return (default 10, max 50)." },
      },
    },
  },
  {
    name: "github.pr.create",
    description:
      "Create a pull request. IMPORTANT: You MUST present the repo, title, head branch, base branch, and body to the user and get explicit confirmation before calling this tool.",
    input_schema: {
      type: "object",
      properties: {
        repo: { type: "string", description: "GitHub repository in owner/repo format." },
        title: { type: "string", description: "Pull request title." },
        body: { type: "string", description: "Pull request body (optional)." },
        head: { type: "string", description: "Source branch name." },
        base: { type: "string", description: "Target branch name (optional)." },
      },
      required: ["repo", "title", "head"],
    },
  },
  {
    name: "github.pr.merge",
    description:
      "Merge a pull request. IMPORTANT: You MUST confirm the repo, PR number, and merge method with the user before calling this tool.",
    input_schema: {
      type: "object",
      properties: {
        repo: { type: "string", description: "GitHub repository in owner/repo format." },
        prNumber: { type: "number", description: "Pull request number." },
        mergeMethod: { type: "string", description: "'merge', 'squash', or 'rebase'." },
      },
      required: ["repo", "prNumber"],
    },
  },
  {
    name: "github.issues.create",
    description:
      "Create a GitHub issue. IMPORTANT: You MUST present the repo, title, body, and labels to the user and get explicit confirmation before calling this tool.",
    input_schema: {
      type: "object",
      properties: {
        repo: { type: "string", description: "GitHub repository in owner/repo format." },
        title: { type: "string", description: "Issue title." },
        body: { type: "string", description: "Issue body (optional)." },
        labels: { type: "array", description: "Optional list of labels." },
      },
      required: ["repo", "title"],
    },
  },
];

const WEBHOOK_PENDING_TTL_MS = 10 * 60_000;

function waitForToolResult(
  session: SessionState,
  callId: string,
  timeoutMs: number,
): Promise<{ result: string | null; error: string | null }> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      session.toolResultResolvers.delete(callId);
      resolve({ result: null, error: "tool_result_timeout" });
    }, timeoutMs);

    session.toolResultResolvers.set(callId, (result, error) => {
      clearTimeout(timer);
      session.toolResultResolvers.delete(callId);
      resolve({ result, error });
    });
  });
}


export class ConductorService {
  private readonly provider: ModelProvider;
  private readonly sessions: SessionStore;
  private readonly cursorClient: CursorClient;
  private readonly gmailClient?: GmailClient;
  private readonly canvasClient?: CanvasClient;
  private readonly calendarClient?: CalendarClient;
  private readonly githubClient?: GitHubClient;
  private readonly webhookPendingTtlMs: number;
  private readonly now: () => Date;
  private readonly bridgeToolExecutor?: BridgeToolExecutor;
  private readonly conversationPollers = new Map<string, ReturnType<typeof setInterval>>();
  private static readonly CONVERSATION_POLL_INTERVAL_MS = 3_000;
  private readonly bridgeToolAvailability?: (sessionId: string, toolName: string) => boolean;
  private readonly verboseToolRoutingLogs: boolean;
  private readonly memoryService?: MemoryService;
  private readonly summarizationConfig: SummarizationConfig;

  constructor(provider: ModelProvider, config: ConductorServiceConfig, dependencies: ConductorServiceDependencies = {}) {
    this.provider = provider;
    this.sessions = new SessionStore(
      config.maxTurns,
      config.rateLimitPerMinute,
      config.traceMaxEntries ?? 120,
    );
    this.cursorClient = dependencies.cursorClient ?? new CursorClient({});
    this.gmailClient = dependencies.gmailClient;
    this.canvasClient = dependencies.canvasClient;
    this.calendarClient = dependencies.calendarClient;
    this.githubClient = dependencies.githubClient;
    this.webhookPendingTtlMs = dependencies.webhookPendingTtlMs ?? WEBHOOK_PENDING_TTL_MS;
    this.now = dependencies.now ?? (() => new Date());
    this.bridgeToolExecutor = dependencies.bridgeToolExecutor;
    this.bridgeToolAvailability = dependencies.bridgeToolAvailability;
    this.verboseToolRoutingLogs = dependencies.verboseToolRoutingLogs ?? false;
    this.memoryService = dependencies.memoryService;
    this.summarizationConfig = dependencies.summarizationConfig ?? DEFAULT_SUMMARIZATION_CONFIG;
  }

  createRateLimiter() {
    return this.sessions.createRateLimiter();
  }

  isCursorServerConfigured(): boolean {
    return this.cursorClient.isConfigured();
  }

  getCursorRun(agentId: string): CursorAgentRunRecord | undefined {
    return this.sessions.getCursorRun(agentId);
  }

  getAgentIdForSpawnCall(spawnCallId: string): string | undefined {
    return this.sessions.getAgentIdForSpawnCall(spawnCallId);
  }

  listAvailableTools(sessionId: string): ToolDefinition[] {
    return this.availableTools(sessionId);
  }

  async executeDirectToolCall(
    sessionId: string,
    toolCall: ToolCallRequest,
    emit: (event: EventEnvelope) => void,
  ): Promise<{ result: string | null; error: string | null }> {
    const session = this.sessions.getOrCreate(sessionId);
    const callId = crypto.randomUUID();

    if (this.shouldExecuteServerTool(toolCall.name)) {
      return this.executeServerTool(session, callId, toolCall.name, toolCall.input, emit);
    }

    const envelope = makeEvent("tool.call", sessionId, {
      callId,
      name: toolCall.name,
      arguments: JSON.stringify(toolCall.input),
    });
    session.pendingToolCalls.set(callId, {
      callId,
      toolName: toolCall.name,
      emittedAt: envelope.timestamp,
      toolArguments: toolCall.input,
    });
    emit(envelope);
    logger.info(`tool.client.call tool=${toolCall.name}`, { sessionId, callId });
    return waitForToolResult(session, callId, 30_000);
  }

  async handleCursorWebhook(
    payload: Record<string, unknown>,
    emit: (event: EventEnvelope) => void,
  ): Promise<CursorWebhookHandleResult> {
    const parsed = parseCursorWebhookPayload(payload);
    if (!parsed) {
      return {
        statusCode: 400,
        payload: {
          error: "invalid_cursor_webhook_payload",
          message: "Missing agentId or unsupported payload shape.",
        },
      };
    }

    const run = this.sessions.getCursorRun(parsed.agent.agentId);
    if (!run) {
      this.sessions.storePendingWebhook(
        parsed.agent.agentId,
        payload,
        this.webhookPendingTtlMs,
        this.now().getTime(),
      );
      logger.warn("cursor webhook agent not yet mapped; queued for retry", {
        agentId: parsed.agent.agentId,
        trace: parsed.eventType,
      });
      return {
        statusCode: 202,
        payload: {
          accepted: true,
          queued: true,
          agentId: parsed.agent.agentId,
        },
      };
    }

    await this.routeWebhookToSession(run.sessionId, parsed, emit);

    return {
      statusCode: 200,
      payload: {
        ok: true,
        sessionId: run.sessionId,
        agentId: parsed.agent.agentId,
      },
    };
  }

  async handleEvent(
    event: EventEnvelope,
    emit: (event: EventEnvelope) => void,
  ): Promise<void> {
    const session = this.sessions.getOrCreate(event.sessionId);

    switch (event.type) {
      case "session.start": {
        if (typeof event.payload.githubToken === "string" && event.payload.githubToken) {
          session.githubToken = event.payload.githubToken;
        }
        if (typeof event.payload.gmailAccessToken === "string" && event.payload.gmailAccessToken) {
          session.gmailAccessToken = event.payload.gmailAccessToken;
        }
        if (typeof event.payload.gmailRefreshToken === "string" && event.payload.gmailRefreshToken) {
          session.gmailRefreshToken = event.payload.gmailRefreshToken;
        }
        if (typeof event.payload.gmailTokenExpiresAt === "number") {
          session.gmailTokenExpiresAt = event.payload.gmailTokenExpiresAt;
        }
        if (typeof event.payload.memoryUserKey === "string" && event.payload.memoryUserKey) {
          session.memoryUserKey = event.payload.memoryUserKey;
        }
        if (typeof event.payload.canvasAccessToken === "string" && event.payload.canvasAccessToken) {
          session.canvasAccessToken = event.payload.canvasAccessToken;
        }
        if (typeof event.payload.canvasBaseURL === "string" && event.payload.canvasBaseURL) {
          session.canvasBaseURL = event.payload.canvasBaseURL;
        }
        if (event.payload.preferences && typeof event.payload.preferences === "object" && !Array.isArray(event.payload.preferences)) {
          session.userPreferences = event.payload.preferences as Record<string, string>;
        }

        // Pre-fetch Canvas courses for ambient context
        if (session.canvasAccessToken && this.canvasClient) {
          this.canvasClient.courses(session).then((courses) => {
            if (Array.isArray(courses) && courses.length > 0) {
              const summary = courses.map((c: any) =>
                `${c.name} (ID: ${c.id}${c.course_code ? ', ' + c.course_code : ''})`
              ).join(", ");
              session.canvasCourseContext = `Canvas courses: ${summary}`;
            }
          }).catch((err) => {
            logger.warn(`canvas course prefetch failed: ${String(err)}`);
          });
        }


        emit(makeEvent("session.started", event.sessionId, { sessionId: event.sessionId }));
        const integrations: string[] = [];
        if (session.githubToken) integrations.push("github");
        if (session.gmailAccessToken) integrations.push("gmail");
        if (session.canvasAccessToken) integrations.push("canvas");
        if (session.userPreferences && Object.keys(session.userPreferences).length > 0) {
          integrations.push(`prefs(${Object.keys(session.userPreferences).join(",")})`);
        }
        logger.info(`session started integrations=[${integrations.join(", ")}]`, { sessionId: event.sessionId, eventId: event.id });
        return;
      }

      case "user.audio.transcript.final": {
        const text = asString(event.payload.text)?.trim();
        if (!text) {
          emit(makeEvent("error", event.sessionId, {
            code: "invalid_transcript",
            message: "user.audio.transcript.final must include payload.text",
          }));
          logger.warn("empty transcript.final received", { sessionId: event.sessionId, eventId: event.id });
          return;
        }

        logger.info(`transcript.final: "${text}"`, { sessionId: event.sessionId, eventId: event.id });

        // Hydrate memory on first turn of session
        if (!session.memoryHydrated && session.memoryUserKey && this.memoryService) {
          session.memoryHydrated = true;
          try {
            const context = await this.memoryService.retrieveContext({
              memoryUserKey: session.memoryUserKey,
              transcript: text,
            });
            if (context) {
              this.sessions.appendTurn(session, { role: "user", content: `[Prior context from previous sessions]\n${context}` });
              emit(makeEvent("session.memory.loaded", event.sessionId, {
                memoryUserKey: session.memoryUserKey,
                contextLength: context.length,
              }));
            }
          } catch {
            // Memory retrieval failure is non-fatal
          }
        }


        await this.runConductorLoop(session, text, emit, event.id);
        this.trySummarizeHistory(session);
        return;
      }

      case "tool.result": {
        const callId = asString(event.payload.callId);
        const resultPayload = asString(event.payload.result);
        const errorText = asString(event.payload.error);

        if (callId) {
          const pending = session.pendingToolCalls.get(callId);
          session.pendingToolCalls.delete(callId);
          const resultSnippet = resultPayload ? ` result=${summarizeValueForLog(resultPayload, 120)}` : "";
          logger.info(
            errorText
              ? `tool.result error tool=${pending?.toolName ?? "?"} error=${errorText}`
              : `tool.result ok tool=${pending?.toolName ?? "?"}${resultSnippet}`,
            {
              sessionId: session.sessionId,
              eventId: event.id,
              callId,
              trace: pending?.toolName,
            },
          );

          if (!errorText) {
            await this.trackSpawnResultIfPresent(
              session,
              callId,
              pending?.toolName,
              pending?.toolArguments,
              resultPayload,
              emit,
            );
          }

          const resolver = session.toolResultResolvers.get(callId);
          if (resolver) {
            logger.info(`tool.result resolver found for callId=${callId} tool=${pending?.toolName ?? "?"}`, { sessionId: session.sessionId, callId });
            resolver(resultPayload ?? null, errorText ?? null);
          }
        }
        return;
      }

      case "gmail.send.execute": {
        const callId = asString(event.payload.callId);
        const confirmed = event.payload.confirmed === true;
        if (!callId) return;

        const pending = session.pendingGmailSends?.get(callId);
        session.pendingGmailSends?.delete(callId);

        if (!pending || !confirmed) {
          logger.info(`gmail.send.execute ${confirmed ? "no pending" : "cancelled"} callId=${callId}`, { sessionId: session.sessionId });
          if (!confirmed) {
            emit(makeEvent("gmail.send.result", session.sessionId, { callId, success: false, error: "User cancelled" }));
          }
          return;
        }

        // Use edited values from the event payload, falling back to original
        const to = asString(event.payload.to) || pending.to;
        const subject = asString(event.payload.subject) || pending.subject;
        const body = asString(event.payload.body) || pending.body;
        const cc = asString(event.payload.cc) || pending.cc || undefined;

        try {
          if (pending.isReply && pending.messageId) {
            const result = await this.gmailClient!.reply(session, pending.messageId, { body, to, cc });
            logger.info(`gmail.reply sent via execute callId=${callId}`, { sessionId: session.sessionId });
            emit(makeEvent("gmail.send.result", session.sessionId, { callId, success: true, ...result }));
          } else {
            const result = await this.gmailClient!.send(session, { to, cc, subject, body });
            logger.info(`gmail.send sent via execute callId=${callId}`, { sessionId: session.sessionId });
            emit(makeEvent("gmail.send.result", session.sessionId, { callId, success: true, ...result }));
          }
        } catch (err) {
          logger.error(`gmail.send.execute failed callId=${callId}: ${String(err)}`, { sessionId: session.sessionId });
          emit(makeEvent("gmail.send.result", session.sessionId, { callId, success: false, error: String(err) }));
        }
        return;
      }

      case "audio.output.interrupted": {
        if (this.bridgeToolExecutor && session.activeBridgeCommandId) {
          const cancelArgs: Record<string, unknown> = {
            commandId: session.activeBridgeCommandId,
          };
          if (session.activeBridgeDeviceId) {
            cancelArgs.deviceId = session.activeBridgeDeviceId;
          }

          const cancelResult = await this.bridgeToolExecutor({
            callId: crypto.randomUUID(),
            sessionId: session.sessionId,
            toolName: "bridge.exec.cancel",
            args: cancelArgs,
            timeoutMs: 5_000,
          }, emit);

          if (!cancelResult.error) {
            session.activeBridgeCommandId = undefined;
            session.activeBridgeDeviceId = undefined;
          }
        }

        logger.info("audio output interrupted", {
          sessionId: session.sessionId,
          eventId: event.id,
        });
        return;
      }

      case "preferences.sync": {
        if (event.payload.preferences && typeof event.payload.preferences === "object" && !Array.isArray(event.payload.preferences)) {
          session.userPreferences = event.payload.preferences as Record<string, string>;
          logger.info(`preferences synced: ${Object.keys(session.userPreferences).join(", ")}`, { sessionId: session.sessionId });
        }
        return;
      }

      case "agent.completed": {
        const agentId = asString(event.payload.agentId) ?? "unknown";
        const status = asString(event.payload.status) ?? "UNKNOWN";
        const summary = asString(event.payload.summary) ?? "";
        const name = asString(event.payload.name);
        const prompt = asString(event.payload.prompt);

        const outcome = status === "FINISHED" ? "finished successfully" : "failed";
        const agentRef = name ? `"${name}"` : `agent ${agentId}`;
        const taskDesc = prompt ? `Task: "${prompt}". ` : "";
        const summaryDesc = summary ? `Summary: ${summary}` : "No summary was provided.";

        const contextText = [
          `[Agent Update] Cursor agent ${agentRef} just ${outcome}.`,
          taskDesc,
          summaryDesc,
          "Tell the user what the agent accomplished (or what went wrong if it failed),",
          "in a concise, natural sentence or two. Do not repeat the raw summary verbatim.",
        ].join(" ").trim();

        logger.info("agent.completed received", {
          sessionId: session.sessionId,
          eventId: event.id,
          agentId,
          status,
        });

        await this.runConductorLoop(session, contextText, emit, event.id, {
          suppressUserMessage: true,
        });
        this.trySummarizeHistory(session);
        return;
      }

      default:
        logger.info(`ignored event type: ${event.type}`, {
          sessionId: session.sessionId,
          eventId: event.id,
        });
        return;
    }
  }

  async finalizeSession(sessionId: string): Promise<void> {
    if (!this.memoryService) return;
    const session = this.sessions.get(sessionId);
    if (!session || !session.memoryUserKey) return;
    try {
      const historyToSummarize = session.history.filter(
        (t) => !(t.role === "user" && typeof t.content === "string" && t.content.startsWith("[Prior context from previous sessions]")),
      );
      await this.memoryService.summarizeAndStore(
        session.memoryUserKey,
        sessionId,
        historyToSummarize,
        session.workingContext,
      );
    } catch {
      // Finalization failures are non-fatal
    }
  }

  private availableTools(sessionId: string): ToolDefinition[] {
    const tools: ToolDefinition[] = [...LEGACY_CLIENT_TOOLS];

    if (this.cursorClient.isConfigured()) {
      tools.push(...SERVER_CURSOR_TOOLS);
    }
    if (this.bridgeToolExecutor) {
      const bridgeTools = this.bridgeToolAvailability
        ? SERVER_BRIDGE_TOOLS.filter((tool) => this.bridgeToolAvailability!(sessionId, tool.name))
        : SERVER_BRIDGE_TOOLS;
      tools.push(...bridgeTools);
    }
    if (this.githubClient) {
      const session = this.sessions.getOrCreate(sessionId);
      if (session.githubToken) {
        tools.push(...SERVER_GITHUB_TOOLS);
      }
    }
    if (this.gmailClient?.isConfigured()) {
      const session = this.sessions.getOrCreate(sessionId);
      if (session.gmailAccessToken) {
        tools.push(...SERVER_GMAIL_TOOLS);
      } else {
        tools.push({
          name: "gmail.authenticate",
          description:
            "Prompt the user to connect their Gmail account. Call this when the user wants to use email features but hasn't connected Gmail yet. This opens the Google sign-in screen on their device.",
          input_schema: {
            type: "object",
            properties: {},
          },
        });
      }
    }

    if (this.calendarClient?.isConfigured()) {
      const session = this.sessions.getOrCreate(sessionId);
      if (session.gmailAccessToken) {
        tools.push(...SERVER_CALENDAR_TOOLS);
      }
    }

    // Canvas tools: available when token is present, otherwise offer authenticate
    {
      const session = this.sessions.getOrCreate(sessionId);
      if (session.canvasAccessToken) {
        tools.push(...SERVER_CANVAS_TOOLS);
      } else {
        tools.push({
          name: "canvas.authenticate",
          description:
            "Prompt the user to connect their Canvas LMS account. Call this when the user wants to check courses, assignments, or grades but hasn't connected Canvas yet. Directs the user to Settings → Connections → Canvas.",
          input_schema: {
            type: "object",
            properties: {},
          },
        });
      }
    }

    return tools;
  }

  private shouldExecuteServerTool(toolName: string): boolean {
    if (toolName.startsWith("bridge.")) {
      return Boolean(this.bridgeToolExecutor);
    }

    if (toolName.startsWith("gmail.") && toolName !== "gmail.authenticate") {
      return true;
    }

    if (toolName.startsWith("calendar.") && toolName !== "calendar.authenticate") {
      return true;
    }

    if (toolName.startsWith("canvas.") && toolName !== "canvas.authenticate") {
      return true;
    }

    if (toolName.startsWith("github.")) {
      return Boolean(this.githubClient);
    }

    if (this.cursorClient.isConfigured() && toolName === "repositories.list") {
      return true;
    }

    return this.cursorClient.isConfigured()
      && (toolName.startsWith("cursor.agent.") || toolName.startsWith("webqa.cursor."));
  }

  /** Returns true for server-side tools whose results should also be emitted
   *  to the iOS client so card managers can render inline cards. */
  private shouldEmitServerToolToClient(toolName: string): boolean {
    return toolName.startsWith("canvas.") ||
      toolName.startsWith("gmail.") ||
      toolName.startsWith("calendar.");
  }

  /**
   * Determines the card type for a tool name, or null if the tool doesn't
   * produce cards suitable for inline rendering.
   */
  private static cardTypeForTool(toolName: string): { type: string; mode: "array" | "single" } | null {
    const map: Record<string, { type: string; mode: "array" | "single" }> = {
      "gmail.inbox":            { type: "email",    mode: "array" },
      "gmail.search":           { type: "email",    mode: "array" },
      "gmail.read":             { type: "email",    mode: "single" },
      "calendar.list":          { type: "calendar",  mode: "array" },
      "calendar.get":           { type: "calendar",  mode: "single" },
      "canvas.courses":         { type: "canvas",   mode: "array" },
      "canvas.assignments":     { type: "canvas",   mode: "array" },
      "canvas.todo":            { type: "canvas",   mode: "array" },
      "canvas.grades":          { type: "canvas",   mode: "array" },
      "canvas.announcements":   { type: "canvas",   mode: "array" },
    };
    return map[toolName] ?? null;
  }

  /**
   * Enriches a tool result JSON with stable cardId fields so the LLM can
   * reference cards inline via ```card:TYPE:ID``` fenced blocks, and iOS
   * card managers can match cards to those IDs.
   */
  private enrichResultWithCardIds(
    toolName: string,
    resultJson: string,
  ): { enrichedResult: string; cardSummary: string } | null {
    const info = ConductorService.cardTypeForTool(toolName);
    if (!info) return null;

    try {
      const parsed = JSON.parse(resultJson);
      const cardRefs: string[] = [];

      if (info.mode === "array") {
        // Array results: the top-level value may be an array directly,
        // or wrapped in an object with a known key (e.g. { messages: [...] }, { events: [...] }).
        const arr = Array.isArray(parsed)
          ? parsed
          : (parsed.messages ?? parsed.events ?? parsed.items ?? null);
        if (Array.isArray(arr)) {
          for (const item of arr) {
            if (typeof item === "object" && item !== null) {
              const id = crypto.randomUUID();
              item.cardId = id;
              cardRefs.push("```card:" + info.type + ":" + id + "\n```");
            }
          }
        }
      } else {
        // Single-item result
        if (typeof parsed === "object" && parsed !== null) {
          const id = crypto.randomUUID();
          parsed.cardId = id;
          cardRefs.push("```card:" + info.type + ":" + id + "\n```");
        }
      }

      if (cardRefs.length === 0) return null;

      const enrichedResult = JSON.stringify(parsed);
      const cardSummary =
        "\n\n[Cards rendered to user. Reference each inline:\n" +
        cardRefs.join("\n") +
        "\n]";

      return { enrichedResult, cardSummary };
    } catch {
      return null;
    }
  }

  /**
   * Appends card reference fenced blocks for any cards the LLM failed to
   * reference inline, ensuring iOS always receives card refs in the final text.
   */
  private injectMissingCardReferences(
    responseText: string,
    pendingCardRefs: Array<{type: string, id: string}>,
  ): string {
    if (pendingCardRefs.length === 0) return responseText;
    const existingIds = new Set<string>();
    const re = /```card:\w+:([0-9a-f-]+)\s*\n?```/g;
    let m;
    while ((m = re.exec(responseText)) !== null) existingIds.add(m[1]);
    const missing = pendingCardRefs.filter(r => !existingIds.has(r.id));
    if (missing.length === 0) return responseText;
    return responseText + "\n" + missing.map(r => "```card:" + r.type + ":" + r.id + "\n```").join("\n");
  }

  /**
   * Build the conversation array for the LLM, prepending the history summary
   * as context if one exists.
   */
  private buildConversation(session: SessionState): ConversationTurn[] {
    if (!session.historySummary) {
      return session.history;
    }

    return [
      {
        role: "user" as const,
        content: `[Context from earlier in this conversation]\n${session.historySummary}\n[End of context — conversation continues below]`,
      },
      {
        role: "assistant" as const,
        content: "Understood, I have the context from our earlier conversation.",
      },
      ...session.history,
    ];
  }

  /**
   * Fire-and-forget: summarize history if it exceeds the threshold.
   * Runs after the conductor loop completes so it doesn't add latency.
   */
  private trySummarizeHistory(session: SessionState): void {
    if (session.history.length <= this.summarizationConfig.summarizeAfter) {
      return;
    }

    // Run asynchronously — don't block the current response
    summarizeIfNeeded(
      session.history,
      session.historySummary,
      this.provider,
      this.summarizationConfig,
    ).then(({ summarized, newSummary, newHistory }) => {
      if (summarized && newSummary && newHistory) {
        session.historySummary = newSummary;
        session.history = newHistory;
        logger.info(`History summarized for session ${session.sessionId}: summary=${newSummary.length} chars, history=${newHistory.length} turns`);
      }
    }).catch((error) => {
      logger.warn(`History summarization error for session ${session.sessionId}: ${error}`);
    });
  }

  private async runConductorLoop(
    session: SessionState,
    transcript: string,
    emit: (event: EventEnvelope) => void,
    sourceEventId: string,
    options: { suppressUserMessage?: boolean } = {},
  ): Promise<void> {
    session.transcriptCount += 1;
    session.recentTranscriptTrace = [];

    const transcriptPreview = transcript.length > 200 ? transcript.slice(0, 200) + "…" : transcript;
    logger.info(`conductor.loop.start turn=${session.transcriptCount} historyLen=${session.history.length} text="${transcriptPreview}"`, {
      sessionId: session.sessionId,
      eventId: sourceEventId,
    });

    const tracePush = (value: string): void => {
      this.sessions.recordTrace(session, value);
    };

    const emitToolCall = (toolName: string, args: Record<string, unknown>): void => {
      const callId = crypto.randomUUID();
      const envelope = makeEvent("tool.call", session.sessionId, {
        callId,
        name: toolName,
        arguments: JSON.stringify(args),
      });

      session.pendingToolCalls.set(callId, {
        callId,
        toolName,
        emittedAt: envelope.timestamp,
        toolArguments: args,
      });

      emit(envelope);
      tracePush(`tool.call:${toolName}`);
      logger.info(`tool.client.call tool=${toolName}`, {
        sessionId: session.sessionId,
        callId,
      });
    };

    this.sessions.appendTurn(session, {
      role: "user",
      content: transcript,
    });

    if (session.workingContext !== undefined) {
      session.workingContext.lastGoal = transcript;
    } else {
      session.workingContext = { lastGoal: transcript };
    }

    emitToolCall("convo.setState", { state: "thinking" });
    if (!options.suppressUserMessage) {
      emitToolCall("convo.appendMessage", {
        role: "user",
        text: transcript,
        isPartial: false,
      });
    }

    const MAX_TOOL_ROUNDS = 8;
    let toolRound = 0;
    let emittedFinalResponse = false;
    const pendingCardRefs: Array<{type: string, id: string}> = [];
    const deterministicBridgeToolCall = this.routeDeterministicBridgeIntent(transcript);

    while (toolRound < MAX_TOOL_ROUNDS) {
      toolRound += 1;

      let modelResponse: ModelResponse;
      if (toolRound === 1 && deterministicBridgeToolCall) {
        modelResponse = {
          fullText: "",
          chunks: (async function* stream() {})(),
          toolCalls: [deterministicBridgeToolCall],
        };
      } else {
        try {
          const conversation = this.buildConversation(session);
          const tools = this.availableTools(session.sessionId);
          logger.info(`conductor.llm.call round=${toolRound} conversationTurns=${conversation.length} toolCount=${tools.length}`, {
            sessionId: session.sessionId,
            eventId: sourceEventId,
          });
          const llmStartMs = Date.now();
          modelResponse = await this.provider.generateResponse(conversation, tools, session.userPreferences, session.canvasCourseContext);
          const hasToolCalls = modelResponse.toolCalls && modelResponse.toolCalls.length > 0;
          const hasText = modelResponse.fullText.trim().length > 0;
          logger.info(
            `conductor.llm.response round=${toolRound} durationMs=${Date.now() - llmStartMs} toolCalls=${modelResponse.toolCalls?.length ?? 0} hasText=${hasText}${hasToolCalls ? ` tools=[${modelResponse.toolCalls!.map(tc => tc.name).join(", ")}]` : ""}`,
            { sessionId: session.sessionId, eventId: sourceEventId },
          );
        } catch (error) {
          const message = error instanceof Error ? error.message : "Unknown model provider error";
          emit(makeEvent("error", session.sessionId, {
            code: "model_provider_failed",
            message,
          }));
          emitToolCall("convo.setState", { state: "idle" });
          logger.error(`model provider failed: ${message}`, {
            sessionId: session.sessionId,
            eventId: sourceEventId,
          });
          return;
        }
      }

      if (modelResponse.toolCalls && modelResponse.toolCalls.length > 0) {
        this.sessions.appendTurn(session, {
          role: "assistant",
          content: modelResponse.toolCalls,
        });

        for (const toolCall of modelResponse.toolCalls) {
          const callId = crypto.randomUUID();

          if (this.shouldExecuteServerTool(toolCall.name)) {
            tracePush(`tool.server:${toolCall.name}`);
            logger.info(
              `tool.server.dispatch tool=${toolCall.name} round=${toolRound} call=${callId} args=${summarizeArgsForLog(toolCall.input)}`,
              {
                sessionId: session.sessionId,
                eventId: sourceEventId,
                callId,
              },
            );
            const startedAtMs = Date.now();
            const execution = await this.executeServerTool(
              session,
              callId,
              toolCall.name,
              toolCall.input,
              emit,
            );
            const outcome = execution.error ? "error" : "ok";
            const resultPreview = execution.error
              ? ` error=${summarizeValueForLog(execution.error)}`
              : ` result=${summarizeValueForLog(execution.result, 120)}`;
            logger.info(
              `tool.server.result tool=${toolCall.name} outcome=${outcome} durationMs=${Date.now() - startedAtMs}${resultPreview}`,
              {
                sessionId: session.sessionId,
                eventId: sourceEventId,
                callId,
              },
            );

            // Enrich tool results with stable card IDs for inline card references
            const rawResult = execution.error ? null : (execution.result ?? "{}");
            const enrichment = rawResult ? this.enrichResultWithCardIds(toolCall.name, rawResult) : null;
            if (enrichment) {
              // Collect card refs for post-response injection
              try {
                const info = ConductorService.cardTypeForTool(toolCall.name);
                if (info) {
                  const parsed = JSON.parse(enrichment.enrichedResult);
                  const items = info.mode === "array"
                    ? (Array.isArray(parsed) ? parsed : (parsed.messages ?? parsed.events ?? parsed.items ?? []))
                    : [parsed];
                  for (const item of items) {
                    if (item?.cardId) pendingCardRefs.push({ type: info.type, id: item.cardId });
                  }
                }
              } catch { /* ignore parse errors */ }
            }
            const resultForLLM = enrichment
              ? enrichment.enrichedResult + enrichment.cardSummary
              : (execution.error ? `Error: ${execution.error}` : rawResult!);

            this.sessions.appendTurn(session, {
              role: "tool",
              content: resultForLLM,
              tool_use_id: toolCall.id,
              tool_name: toolCall.name,
            });

            // Emit tool.call + tool.result to iOS for tools with card representations
            // so ConversationCanvasManager / ConversationEmailManager / ConversationCalendarManager
            // can create inline cards from the results.
            if (this.shouldEmitServerToolToClient(toolCall.name)) {
              emit(makeEvent("tool.call", session.sessionId, {
                callId,
                name: toolCall.name,
                arguments: JSON.stringify(toolCall.input),
              }));
              emit(makeEvent("tool.result", session.sessionId, {
                callId,
                result: enrichment ? enrichment.enrichedResult : (execution.error ? null : rawResult!),
                error: execution.error ?? null,
              }));
            }

            continue;
          }

          const envelope = makeEvent("tool.call", session.sessionId, {
            callId,
            name: toolCall.name,
            arguments: JSON.stringify(toolCall.input),
          });

          session.pendingToolCalls.set(callId, {
            callId,
            toolName: toolCall.name,
            emittedAt: envelope.timestamp,
            toolArguments: toolCall.input,
          });

          emit(envelope);
          tracePush(`tool.call:${toolCall.name}`);
          logger.info(`tool.client.dispatch tool=${toolCall.name} round=${toolRound} call=${callId} args=${summarizeArgsForLog(toolCall.input)}`, {
            sessionId: session.sessionId,
            eventId: sourceEventId,
            callId,
          });

          const clientToolStartMs = Date.now();
          const { result, error } = await waitForToolResult(session, callId, 30_000);
          logger.info(`tool.client.result tool=${toolCall.name} outcome=${error ? "error" : "ok"} durationMs=${Date.now() - clientToolStartMs}${error ? ` error=${error}` : ""}`, {
            sessionId: session.sessionId,
            eventId: sourceEventId,
            callId,
          });

          this.sessions.appendTurn(session, {
            role: "tool",
            content: result ?? `Error: ${error ?? "unknown"}`,
            tool_use_id: toolCall.id,
            tool_name: toolCall.name,
          });
        }

        continue;
      }

      let responseText = "";
      let chunkCount = 0;
      for await (const chunk of modelResponse.chunks) {
        responseText += chunk;
        chunkCount += 1;
        emit(makeEvent("assistant.speech.partial", session.sessionId, { text: responseText }));
        tracePush("assistant.speech.partial");
      }

      if (!responseText.trim()) {
        responseText = modelResponse.fullText;
      }

      responseText = responseText.trim();
      responseText = this.injectMissingCardReferences(responseText, pendingCardRefs);

      const cardRefCount = (responseText.match(/```card:\w+:[0-9a-f-]+/g) || []).length;
      emit(makeEvent("assistant.speech.final", session.sessionId, { text: responseText }));
      tracePush("assistant.speech.final");
      logger.info(`assistant.speech.final chunks=${chunkCount} len=${responseText.length} cardRefs=${cardRefCount} pendingCards=${pendingCardRefs.length}: "${responseText.length > 200 ? responseText.slice(0, 200) + "…" : responseText}"`, {
        sessionId: session.sessionId,
        eventId: sourceEventId,
      });

      this.sessions.appendTurn(session, {
        role: "assistant",
        content: responseText,
      });

      emitToolCall("convo.appendMessage", {
        role: "assistant",
        text: responseText,
        isPartial: false,
      });
      emitToolCall("convo.setState", { state: "speaking" });
      emitToolCall("tts.speak", { text: responseText });
      emitToolCall("convo.setState", { state: "idle" });

      emittedFinalResponse = true;
      break;
    }

    if (!emittedFinalResponse) {
      emit(makeEvent("error", session.sessionId, {
        code: "tool_round_limit_exceeded",
        message: `Conductor reached max tool rounds (${MAX_TOOL_ROUNDS}) without a final response. The LLM kept calling tools without producing a text reply.`,
      }));
      emitToolCall("convo.setState", { state: "idle" });
      logger.warn(`tool round limit exceeded: ${toolRound}/${MAX_TOOL_ROUNDS} rounds exhausted. trace=[${session.recentTranscriptTrace.join(" -> ")}]`, {
        sessionId: session.sessionId,
        eventId: sourceEventId,
      });
    }

    const traceLabel = options.suppressUserMessage
      ? `agent.completed trace #${session.transcriptCount}`
      : `transcript.final trace #${session.transcriptCount}`;
    logger.info(
      `${traceLabel}: ${session.recentTranscriptTrace.join(" -> ")}`,
      { sessionId: session.sessionId, eventId: sourceEventId },
    );
  }

  private routeDeterministicBridgeIntent(transcript: string): ToolCallRequest | undefined {
    if (!this.bridgeToolExecutor) {
      return undefined;
    }

    const normalized = transcript.trim();
    if (!normalized) {
      return undefined;
    }

    const lower = normalized.toLowerCase();
    if (lower === "run tests" || lower === "run unit tests") {
      return {
        id: crypto.randomUUID(),
        name: "bridge.exec.run",
        input: { command: "npm test" },
      };
    }

    const runMatch = normalized.match(/^run\s+(.+)$/i);
    if (runMatch) {
      const command = runMatch[1]?.trim();
      if (command) {
        return {
          id: crypto.randomUUID(),
          name: "bridge.exec.run",
          input: { command },
        };
      }
    }

    const searchMatch = normalized.match(/^(search|find)(?: for)?\s+['"]?(.+?)['"]?$/i);
    if (searchMatch) {
      const query = searchMatch[2]?.trim();
      if (query) {
        return {
          id: crypto.randomUUID(),
          name: "bridge.fs.search",
          input: { query },
        };
      }
    }

    const rangeMatch = normalized.match(/^(open|read)\s+(.+?)\s+(?:around|at)\s+line\s+(\d+)$/i);
    if (rangeMatch) {
      const path = rangeMatch[2]?.trim();
      const center = Number.parseInt(rangeMatch[3] ?? "", 10);
      if (path && Number.isFinite(center) && center > 0) {
        const startLine = Math.max(1, center - 20);
        const endLine = center + 20;
        return {
          id: crypto.randomUUID(),
          name: "bridge.fs.readRange",
          input: { path, startLine, endLine },
        };
      }
    }

    const readMatch = normalized.match(/^(read file|open file)\s+(.+)$/i);
    if (readMatch) {
      const path = readMatch[2]?.trim();
      if (path) {
        return {
          id: crypto.randomUUID(),
          name: "bridge.fs.readFile",
          input: { path },
        };
      }
    }

    return undefined;
  }

  private async executeServerTool(
    session: SessionState,
    callId: string,
    toolName: string,
    args: Record<string, unknown>,
    emit: (event: EventEnvelope) => void,
  ): Promise<{ result: string | null; error: string | null }> {
    if (!this.cursorClient.isConfigured()) {
      if (toolName.startsWith("cursor.") || toolName.startsWith("webqa.") || toolName === "repositories.list") {
        return {
          result: null,
          error: "cursor_server_not_configured: CURSOR_API_KEY is not configured. Fall back to legacy agent.* tools.",
        };
      }
    }

    // Hard guard: reject cursor/agent spawn for email, calendar, or canvas tasks.
    // The LLM sometimes ignores system prompt instructions and routes these requests
    // to cursor.agent.spawn, which can't handle them. Return an actionable error.
    if (toolName === "cursor.agent.spawn" || toolName === "agent.spawn") {
      const tools = this.availableTools(session.sessionId);
      const toolNames = new Set(tools.map((t) => t.name));
      const prompt = (stringFromRecord(args, "prompt") ?? "").toLowerCase();

      if (toolNames.has("gmail.send") && /\b(email|e-mail|gmail|mail|send.*to|compose|draft)\b/i.test(prompt)) {
        return {
          result: null,
          error: "wrong_tool: Use gmail.send or gmail.reply for email tasks, not cursor.agent.spawn. The Gmail tools are available.",
        };
      }
      if (toolNames.has("calendar.create") && /\b(calendar|schedule|meeting|event|appointment)\b/i.test(prompt)) {
        return {
          result: null,
          error: "wrong_tool: Use calendar.* tools for scheduling tasks, not cursor.agent.spawn. The Calendar tools are available.",
        };
      }
      if (toolNames.has("canvas.courses") && /\b(canvas|course|assignment|grade|syllabus|class)\b/i.test(prompt)) {
        return {
          result: null,
          error: "wrong_tool: Use canvas.* tools for coursework tasks, not cursor.agent.spawn. The Canvas tools are available.",
        };
      }
    }

    try {
      switch (toolName) {
        case "cursor.agent.spawn": {
          const prompt = stringFromRecord(args, "prompt");
          if (!prompt) {
            return { result: null, error: "cursor_invalid_prompt" };
          }

          const metadata = asRecord(args.metadata) ?? {};
          const mode = normalizeMode(stringFromRecord(args, "mode") ?? stringFromRecord(metadata, "mode")) ?? "code";
          const repoUrl = stringFromRecord(args, "repoUrl", "repository");
          const ref = stringFromRecord(args, "ref");

          const spawned = await this.cursorClient.spawnAgent({
            prompt,
            repoUrl,
            ref,
            metadata,
            mode,
          });

          await this.recordSpawn(
            session.sessionId,
            callId,
            mode,
            {
              agentId: spawned.agentId,
              status: spawned.status,
              runUrl: spawned.runUrl,
              prUrl: spawned.prUrl,
              branchName: spawned.branchName,
              summary: spawned.summary,
            },
            emit,
          );

          return {
            result: stableJSONStringify({
              agentId: spawned.agentId,
              id: spawned.agentId,
              status: spawned.status ?? "CREATING",
              runUrl: spawned.runUrl,
              url: spawned.runUrl,
              prUrl: spawned.prUrl,
              branchName: spawned.branchName,
            }),
            error: null,
          };
        }

        case "cursor.agent.status": {
          const agentId = stringFromRecord(args, "agentId", "id");
          if (!agentId) {
            return { result: null, error: "cursor_missing_agent_id" };
          }

          const statusResult = await this.cursorClient.status(agentId);
          const existing = this.sessions.getCursorRun(agentId);
          const mode = existing?.mode ?? "code";

          this.sessions.upsertCursorRun({
            agentId,
            sessionId: existing?.sessionId ?? session.sessionId,
            createdAt: existing?.createdAt ?? this.now().toISOString(),
            mode,
            status: statusResult.status,
            runUrl: statusResult.runUrl,
            prUrl: statusResult.prUrl,
            branchName: statusResult.branchName,
            summary: statusResult.summary,
            spawnCallId: existing?.spawnCallId,
          });

          if (isTerminalAgentStatus(statusResult.status)) {
            this.stopConversationPolling(agentId);
          }

          return {
            result: stableJSONStringify({
              agentId,
              status: statusResult.status,
              runUrl: statusResult.runUrl,
              prUrl: statusResult.prUrl,
              summary: statusResult.summary,
            }),
            error: null,
          };
        }

        case "cursor.agent.followup": {
          const agentId = stringFromRecord(args, "agentId", "id");
          const message = stringFromRecord(args, "message", "prompt");
          if (!agentId || !message) {
            return { result: null, error: "cursor_followup_requires_agentId_and_message" };
          }

          await this.cursorClient.followup(agentId, message);
          return { result: stableJSONStringify({ ok: true }), error: null };
        }

        case "cursor.agent.cancel": {
          const agentId = stringFromRecord(args, "agentId", "id");
          if (!agentId) {
            return { result: null, error: "cursor_missing_agent_id" };
          }

          await this.cursorClient.cancel(agentId);
          return { result: stableJSONStringify({ ok: true }), error: null };
        }

        case "webqa.cursor.run": {
          const url = stringFromRecord(args, "url");
          if (!url) {
            return { result: null, error: "webqa_missing_url" };
          }

          const flowSpec = args.flowSpec ?? {};
          const assertions = args.assertions;
          const budget = args.budget;

          const prompt = this.buildWebQAPrompt(url, flowSpec, assertions, budget);
          const spawned = await this.cursorClient.spawnAgent({
            prompt,
            metadata: {
              mode: "webqa",
              provider: "cursor",
              url,
              flowSpec,
              assertions: assertions ?? null,
              budget: budget ?? null,
            },
            mode: "computer_use",
          });

          await this.recordSpawn(
            session.sessionId,
            callId,
            "webqa",
            {
              agentId: spawned.agentId,
              status: spawned.status,
              runUrl: spawned.runUrl,
              prUrl: spawned.prUrl,
              branchName: spawned.branchName,
              summary: spawned.summary,
            },
            emit,
          );

          return {
            result: stableJSONStringify({
              agentId: spawned.agentId,
              runUrl: spawned.runUrl,
              status: spawned.status,
            }),
            error: null,
          };
        }

        case "webqa.cursor.status": {
          const agentId = stringFromRecord(args, "agentId", "id");
          if (!agentId) {
            return { result: null, error: "cursor_missing_agent_id" };
          }

          const statusResult = await this.cursorClient.status(agentId);
          return {
            result: stableJSONStringify({
              agentId,
              status: statusResult.status,
              runUrl: statusResult.runUrl,
              prUrl: statusResult.prUrl,
              summary: statusResult.summary,
            }),
            error: null,
          };
        }

        case "webqa.cursor.followup": {
          const agentId = stringFromRecord(args, "agentId", "id");
          const instruction = stringFromRecord(args, "instruction", "message");
          if (!agentId || !instruction) {
            return { result: null, error: "webqa_followup_requires_agentId_and_instruction" };
          }

          await this.cursorClient.followup(agentId, instruction);
          return { result: stableJSONStringify({ ok: true }), error: null };
        }

        case "repositories.list": {
          const repositories = await this.cursorClient.repositories();
          return {
            result: stableJSONStringify({
              repositories,
              count: repositories.length,
            }),
            error: null,
          };
        }

        case "bridge.exec.run":
        case "bridge.exec.start":
        case "bridge.exec.cancel":
        case "bridge.exec.status":
        case "bridge.exec.output.subscribe":
        case "bridge.fs.readFile":
        case "bridge.fs.search":
        case "bridge.fs.readRange":
        case "bridge.fs.applyPatch":
        case "bridge.git.status":
        case "bridge.git.diff":
        case "bridge.git.stage":
        case "bridge.git.commit":
        case "bridge.git.push": {
          if (!this.bridgeToolExecutor) {
            return { result: null, error: "bridge_not_configured" };
          }

          const timeoutSecRaw = typeof args.timeoutSec === "number" ? args.timeoutSec : undefined;
          const timeoutMs = Math.max(1, Math.min(900, Math.trunc(timeoutSecRaw ?? 60))) * 1_000;
          const bridgeResult = await this.bridgeToolExecutor({
            callId,
            sessionId: session.sessionId,
            toolName,
            args,
            timeoutMs,
          }, emit);

          if (!bridgeResult.error && bridgeResult.result) {
            if (toolName === "bridge.exec.start") {
              try {
                const parsed = JSON.parse(bridgeResult.result) as Record<string, unknown>;
                const commandId = typeof parsed.commandId === "string" ? parsed.commandId : undefined;
                const deviceId = typeof args.deviceId === "string" ? args.deviceId : undefined;
                if (commandId) {
                  session.activeBridgeCommandId = commandId;
                  session.activeBridgeDeviceId = deviceId;
                }
              } catch {
                // ignore parse failure
              }
            }

            if (toolName === "bridge.exec.cancel") {
              session.activeBridgeCommandId = undefined;
              session.activeBridgeDeviceId = undefined;
            }
          }

          return bridgeResult;
        }

        case "bridge.claude.run": {
          if (!this.bridgeToolExecutor) {
            return { result: null, error: "bridge_not_configured" };
          }

          // Resolve allowedTools: explicit arg > user preference > prompt user
          const explicitTools = typeof args.allowedTools === "string" ? args.allowedTools : undefined;
          const prefTools = session.userPreferences?.["bridge.claude.allowedTools"];
          if (!explicitTools && !prefTools) {
            return {
              result: "The user has not configured their Claude Code tool permissions yet. "
                + "Before running this task, ask the user which Claude Code tools they want to allow. "
                + "Available tools: Bash (shell commands), Read (read files), Edit (edit files), "
                + "Write (create files), LS (list directories), Glob (find files by pattern), "
                + "Grep (search file contents), MultiEdit (batch edits). "
                + "Explain what each tool does in plain language and ask which ones to enable. "
                + "Once they decide, save their choice with preferences.set('bridge.claude.allowedTools', 'Tool1,Tool2,...') "
                + "and then retry this bridge.claude.run call.",
              error: null,
            };
          }

          const resolvedArgs = { ...args, allowedTools: explicitTools ?? prefTools };

          const claudeTimeoutRaw = typeof args.timeoutSec === "number" ? args.timeoutSec : undefined;
          const claudeTimeoutMs = Math.max(1, Math.min(660, Math.trunc(claudeTimeoutRaw ?? 660))) * 1_000;
          return await this.bridgeToolExecutor({
            callId,
            sessionId: session.sessionId,
            toolName,
            args: resolvedArgs,
            timeoutMs: claudeTimeoutMs,
          }, emit);
        }

        case "bridge.nova.start": {
          if (!this.bridgeToolExecutor) {
            return { result: null, error: "bridge_not_configured" };
          }
          return await this.bridgeToolExecutor({
            callId,
            sessionId: session.sessionId,
            toolName,
            args,
            timeoutMs: 60_000,
          }, emit);
        }

        case "bridge.nova.act": {
          if (!this.bridgeToolExecutor) {
            return { result: null, error: "bridge_not_configured" };
          }
          return await this.bridgeToolExecutor({
            callId,
            sessionId: session.sessionId,
            toolName,
            args,
            timeoutMs: 120_000,
          }, emit);
        }

        case "bridge.nova.stop": {
          if (!this.bridgeToolExecutor) {
            return { result: null, error: "bridge_not_configured" };
          }
          return await this.bridgeToolExecutor({
            callId,
            sessionId: session.sessionId,
            toolName,
            args,
            timeoutMs: 15_000,
          }, emit);
        }

        case "gmail.inbox": {
          if (!this.gmailClient) {
            return { result: null, error: "gmail_not_configured" };
          }
          const maxResults = Math.min(typeof args.maxResults === "number" ? args.maxResults : 10, 20);
          const pageToken = typeof args.pageToken === "string" ? args.pageToken : undefined;
          const listResult = await this.gmailClient.list(session, { maxResults, pageToken });
          return { result: stableJSONStringify(listResult), error: null };
        }

        case "gmail.search": {
          if (!this.gmailClient) {
            return { result: null, error: "gmail_not_configured" };
          }
          const query = stringFromRecord(args, "query");
          if (!query) {
            return { result: null, error: "gmail_missing_query" };
          }
          const maxResults = Math.min(typeof args.maxResults === "number" ? args.maxResults : 10, 20);
          const pageToken = typeof args.pageToken === "string" ? args.pageToken : undefined;
          const searchResult = await this.gmailClient.search(session, query, { maxResults, pageToken });
          return { result: stableJSONStringify(searchResult), error: null };
        }

        case "gmail.read": {
          if (!this.gmailClient) {
            return { result: null, error: "gmail_not_configured" };
          }
          const messageId = stringFromRecord(args, "messageId");
          if (!messageId) {
            return { result: null, error: "gmail_missing_message_id" };
          }
          const message = await this.gmailClient.read(session, messageId);
          return { result: stableJSONStringify(message), error: null };
        }

        case "gmail.send": {
          if (!this.gmailClient) {
            return { result: null, error: "gmail_not_configured" };
          }
          const to = stringFromRecord(args, "to");
          const subject = stringFromRecord(args, "subject");
          const body = stringFromRecord(args, "body");
          if (!to || !subject || !body) {
            return { result: null, error: "gmail_send_requires_to_subject_body" };
          }
          const cc = stringFromRecord(args, "cc");

          // Emit draft to iOS for user confirmation
          const confirmCallId = crypto.randomUUID();
          const confirmEnvelope = makeEvent("tool.call", session.sessionId, {
            callId: confirmCallId,
            name: "gmail.send.confirm",
            arguments: JSON.stringify({ to, cc: cc ?? undefined, subject, body }),
          });
          session.pendingToolCalls.set(confirmCallId, {
            callId: confirmCallId,
            toolName: "gmail.send.confirm",
            emittedAt: confirmEnvelope.timestamp,
            toolArguments: { to, cc, subject, body },
          });
          emit(confirmEnvelope);

          // Store pending send details for async execution on confirmation
          if (!session.pendingGmailSends) session.pendingGmailSends = new Map();
          session.pendingGmailSends.set(confirmCallId, { to, cc, subject, body, isReply: false });
          logger.info(`gmail.send draft emitted, awaiting user confirmation callId=${confirmCallId}`, { sessionId: session.sessionId, callId: confirmCallId });

          // Return immediately — don't block the conductor loop
          return {
            result: stableJSONStringify({
              status: "pending_confirmation",
              message: "Email draft shown to user. They can edit fields and confirm or cancel. The email will be sent when they confirm.",
            }),
            error: null,
          };
        }

        case "gmail.reply": {
          if (!this.gmailClient) {
            return { result: null, error: "gmail_not_configured" };
          }
          const messageId = stringFromRecord(args, "messageId");
          const body = stringFromRecord(args, "body");
          if (!messageId || !body) {
            return { result: null, error: "gmail_reply_requires_messageId_and_body" };
          }
          const to = stringFromRecord(args, "to");
          const cc = stringFromRecord(args, "cc");

          // Emit draft to iOS for user confirmation
          const confirmCallId = crypto.randomUUID();
          const confirmEnvelope = makeEvent("tool.call", session.sessionId, {
            callId: confirmCallId,
            name: "gmail.reply.confirm",
            arguments: JSON.stringify({ messageId, body, to: to ?? undefined, cc: cc ?? undefined }),
          });
          session.pendingToolCalls.set(confirmCallId, {
            callId: confirmCallId,
            toolName: "gmail.reply.confirm",
            emittedAt: confirmEnvelope.timestamp,
            toolArguments: { messageId, body, to, cc },
          });
          emit(confirmEnvelope);

          // Store pending reply details for async execution on confirmation
          if (!session.pendingGmailSends) session.pendingGmailSends = new Map();
          session.pendingGmailSends.set(confirmCallId, { to: to ?? "", cc, subject: "", body, messageId, isReply: true });
          logger.info(`gmail.reply draft emitted, awaiting user confirmation callId=${confirmCallId}`, { sessionId: session.sessionId, callId: confirmCallId });

          // Return immediately — don't block the conductor loop
          return {
            result: stableJSONStringify({
              status: "pending_confirmation",
              message: "Reply draft shown to user. They can edit and confirm or cancel. The reply will be sent when they confirm.",
            }),
            error: null,
          };
        }

        // Canvas LMS tools
        case "canvas.courses": {
          if (!this.canvasClient) {
            return { result: null, error: "canvas_not_configured" };
          }
          const courses = await this.canvasClient.courses(session);
          return { result: stableJSONStringify(courses), error: null };
        }

        case "canvas.assignments": {
          if (!this.canvasClient) {
            return { result: null, error: "canvas_not_configured" };
          }
          const courseId = stringFromRecord(args, "courseId");
          if (!courseId) {
            return { result: null, error: "canvas_missing_course_id" };
          }
          const assignments = await this.canvasClient.assignments(session, courseId);
          return { result: stableJSONStringify(assignments), error: null };
        }

        case "canvas.todo": {
          if (!this.canvasClient) {
            return { result: null, error: "canvas_not_configured" };
          }
          const todoItems = await this.canvasClient.todo(session);
          return { result: stableJSONStringify(todoItems), error: null };
        }

        case "canvas.upcoming": {
          if (!this.canvasClient) {
            return { result: null, error: "canvas_not_configured" };
          }
          const events = await this.canvasClient.upcomingEvents(session);
          return { result: stableJSONStringify(events), error: null };
        }

        case "canvas.grades": {
          if (!this.canvasClient) {
            return { result: null, error: "canvas_not_configured" };
          }
          const courseId = stringFromRecord(args, "courseId");
          if (!courseId) {
            return { result: null, error: "canvas_missing_course_id" };
          }
          const grades = await this.canvasClient.grades(session, courseId);
          return { result: stableJSONStringify(grades), error: null };
        }

        case "canvas.announcements": {
          if (!this.canvasClient) {
            return { result: null, error: "canvas_not_configured" };
          }
          const courseId = stringFromRecord(args, "courseId");
          if (!courseId) {
            return { result: null, error: "canvas_missing_course_id" };
          }
          const announcements = await this.canvasClient.announcements(session, courseId);
          return { result: stableJSONStringify(announcements), error: null };
        }

        case "calendar.list": {
          if (!this.calendarClient) {
            return { result: null, error: "calendar_not_configured" };
          }
          const timeMin = stringFromRecord(args, "timeMin");
          const timeMax = stringFromRecord(args, "timeMax");
          if (!timeMin || !timeMax) {
            return { result: null, error: "calendar_list_requires_timeMin_and_timeMax" };
          }
          const maxResults = Math.min(typeof args.maxResults === "number" ? args.maxResults : 10, 50);
          const q = stringFromRecord(args, "q");
          const listResult = await this.calendarClient.listEvents(session, { timeMin, timeMax, maxResults, q: q ?? undefined });
          return { result: stableJSONStringify(listResult), error: null };
        }

        case "calendar.get": {
          if (!this.calendarClient) {
            return { result: null, error: "calendar_not_configured" };
          }
          const eventId = stringFromRecord(args, "eventId");
          if (!eventId) {
            return { result: null, error: "calendar_get_requires_eventId" };
          }
          const eventDetail = await this.calendarClient.getEvent(session, eventId);
          return { result: stableJSONStringify(eventDetail), error: null };
        }

        case "calendar.create": {
          if (!this.calendarClient) {
            return { result: null, error: "calendar_not_configured" };
          }
          const summary = stringFromRecord(args, "summary");
          const startTime = stringFromRecord(args, "startTime");
          const endTime = stringFromRecord(args, "endTime");
          if (!summary || !startTime || !endTime) {
            return { result: null, error: "calendar_create_requires_summary_startTime_endTime" };
          }
          const description = stringFromRecord(args, "description");
          const location = stringFromRecord(args, "location");
          const attendees = stringFromRecord(args, "attendees");

          const confirmCallId = crypto.randomUUID();
          const confirmEnvelope = makeEvent("tool.call", session.sessionId, {
            callId: confirmCallId,
            name: "calendar.create.confirm",
            arguments: JSON.stringify({ summary, startTime, endTime, description: description ?? undefined, location: location ?? undefined, attendees: attendees ?? undefined }),
          });
          session.pendingToolCalls.set(confirmCallId, {
            callId: confirmCallId,
            toolName: "calendar.create.confirm",
            emittedAt: confirmEnvelope.timestamp,
            toolArguments: { summary, startTime, endTime, description, location, attendees },
          });
          emit(confirmEnvelope);

          const { result: confirmResult, error: confirmError } = await waitForToolResult(session, confirmCallId, 120_000);
          if (confirmError || !confirmResult) {
            return { result: null, error: confirmError ?? "calendar_create_not_confirmed" };
          }
          let confirmed = false;
          try { const parsed = JSON.parse(confirmResult); confirmed = parsed.confirmed === true; } catch { return { result: null, error: "calendar_create_invalid_confirmation" }; }
          if (!confirmed) {
            return { result: stableJSONStringify({ status: "cancelled", message: "User declined to create the event." }), error: null };
          }

          const attendeeList = attendees ? attendees.split(",").map(e => e.trim()).filter(Boolean) : undefined;
          const createResult = await this.calendarClient.createEvent(session, { summary, startTime, endTime, description: description ?? undefined, location: location ?? undefined, attendees: attendeeList });
          return { result: stableJSONStringify(createResult), error: null };
        }

        case "calendar.update": {
          if (!this.calendarClient) {
            return { result: null, error: "calendar_not_configured" };
          }
          const eventId = stringFromRecord(args, "eventId");
          if (!eventId) {
            return { result: null, error: "calendar_update_requires_eventId" };
          }
          const summary = stringFromRecord(args, "summary");
          const startTime = stringFromRecord(args, "startTime");
          const endTime = stringFromRecord(args, "endTime");
          const description = stringFromRecord(args, "description");
          const location = stringFromRecord(args, "location");
          const attendees = stringFromRecord(args, "attendees");

          const confirmCallId = crypto.randomUUID();
          const confirmEnvelope = makeEvent("tool.call", session.sessionId, {
            callId: confirmCallId,
            name: "calendar.update.confirm",
            arguments: JSON.stringify({ eventId, summary: summary ?? undefined, startTime: startTime ?? undefined, endTime: endTime ?? undefined, description: description ?? undefined, location: location ?? undefined, attendees: attendees ?? undefined }),
          });
          session.pendingToolCalls.set(confirmCallId, {
            callId: confirmCallId,
            toolName: "calendar.update.confirm",
            emittedAt: confirmEnvelope.timestamp,
            toolArguments: { eventId, summary, startTime, endTime, description, location, attendees },
          });
          emit(confirmEnvelope);

          const { result: confirmResult, error: confirmError } = await waitForToolResult(session, confirmCallId, 120_000);
          if (confirmError || !confirmResult) {
            return { result: null, error: confirmError ?? "calendar_update_not_confirmed" };
          }
          let confirmed = false;
          try { const parsed = JSON.parse(confirmResult); confirmed = parsed.confirmed === true; } catch { return { result: null, error: "calendar_update_invalid_confirmation" }; }
          if (!confirmed) {
            return { result: stableJSONStringify({ status: "cancelled", message: "User declined to update the event." }), error: null };
          }

          const attendeeList = attendees ? attendees.split(",").map(e => e.trim()).filter(Boolean) : undefined;
          const updateResult = await this.calendarClient.updateEvent(session, eventId, { summary: summary ?? undefined, startTime: startTime ?? undefined, endTime: endTime ?? undefined, description: description ?? undefined, location: location ?? undefined, attendees: attendeeList });
          return { result: stableJSONStringify(updateResult), error: null };
        }

        case "calendar.delete": {
          if (!this.calendarClient) {
            return { result: null, error: "calendar_not_configured" };
          }
          const eventId = stringFromRecord(args, "eventId");
          if (!eventId) {
            return { result: null, error: "calendar_delete_requires_eventId" };
          }
          const summary = stringFromRecord(args, "summary");

          const confirmCallId = crypto.randomUUID();
          const confirmEnvelope = makeEvent("tool.call", session.sessionId, {
            callId: confirmCallId,
            name: "calendar.delete.confirm",
            arguments: JSON.stringify({ eventId, summary: summary ?? undefined }),
          });
          session.pendingToolCalls.set(confirmCallId, {
            callId: confirmCallId,
            toolName: "calendar.delete.confirm",
            emittedAt: confirmEnvelope.timestamp,
            toolArguments: { eventId, summary },
          });
          emit(confirmEnvelope);

          const { result: confirmResult, error: confirmError } = await waitForToolResult(session, confirmCallId, 120_000);
          if (confirmError || !confirmResult) {
            return { result: null, error: confirmError ?? "calendar_delete_not_confirmed" };
          }
          let confirmed = false;
          try { const parsed = JSON.parse(confirmResult); confirmed = parsed.confirmed === true; } catch { return { result: null, error: "calendar_delete_invalid_confirmation" }; }
          if (!confirmed) {
            return { result: stableJSONStringify({ status: "cancelled", message: "User declined to delete the event." }), error: null };
          }

          const deleteResult = await this.calendarClient.deleteEvent(session, eventId);
          return { result: stableJSONStringify(deleteResult), error: null };
        }

        case "github.repos.list": {
          if (!this.githubClient) {
            return { result: null, error: "github_not_configured" };
          }
          const limit = typeof args.limit === "number" ? args.limit : undefined;
          const repositories = await this.githubClient.listRepos(session, { limit });
          return {
            result: stableJSONStringify({
              repositories,
              count: repositories.length,
            }),
            error: null,
          };
        }

        case "github.pr.list": {
          if (!this.githubClient) {
            return { result: null, error: "github_not_configured" };
          }
          const repo = stringFromRecord(args, "repo");
          const stateRaw = stringFromRecord(args, "state");
          const state = stateRaw === "closed" || stateRaw === "all" ? stateRaw : "open";
          const limit = typeof args.limit === "number" ? args.limit : undefined;
          const pullRequests = await this.githubClient.listPRs(session, { repo, state, limit });
          return {
            result: stableJSONStringify({
              pullRequests,
              count: pullRequests.length,
            }),
            error: null,
          };
        }

        case "github.pr.get": {
          if (!this.githubClient) {
            return { result: null, error: "github_not_configured" };
          }
          const repo = stringFromRecord(args, "repo");
          const prNumber = typeof args.prNumber === "number" ? Math.trunc(args.prNumber) : undefined;
          if (!repo || !prNumber || prNumber <= 0) {
            return { result: null, error: "github_pr_get_requires_repo_and_prNumber" };
          }
          const pullRequest = await this.githubClient.getPR(session, { repo, prNumber });
          return { result: stableJSONStringify(pullRequest), error: null };
        }

        case "github.pr.reviews": {
          if (!this.githubClient) {
            return { result: null, error: "github_not_configured" };
          }
          const repo = stringFromRecord(args, "repo");
          const prNumber = typeof args.prNumber === "number" ? Math.trunc(args.prNumber) : undefined;
          if (!repo || !prNumber || prNumber <= 0) {
            return { result: null, error: "github_pr_reviews_requires_repo_and_prNumber" };
          }
          const reviews = await this.githubClient.getReviews(session, { repo, prNumber });
          return { result: stableJSONStringify(reviews), error: null };
        }

        case "github.actions.status": {
          if (!this.githubClient) {
            return { result: null, error: "github_not_configured" };
          }
          const repo = stringFromRecord(args, "repo");
          if (!repo) {
            return { result: null, error: "github_actions_status_requires_repo" };
          }
          const branch = stringFromRecord(args, "branch");
          const prNumber = typeof args.prNumber === "number" ? Math.trunc(args.prNumber) : undefined;
          const status = await this.githubClient.getActionsStatus(session, {
            repo,
            branch,
            ...(prNumber && prNumber > 0 ? { prNumber } : {}),
          });
          return { result: stableJSONStringify(status), error: null };
        }

        case "github.issues.list": {
          if (!this.githubClient) {
            return { result: null, error: "github_not_configured" };
          }
          const repo = stringFromRecord(args, "repo");
          const stateRaw = stringFromRecord(args, "state");
          const state = stateRaw === "closed" ? "closed" : "open";
          const assignee = stringFromRecord(args, "assignee");
          const limit = typeof args.limit === "number" ? args.limit : undefined;
          const issues = await this.githubClient.listIssues(session, {
            repo,
            state,
            ...(assignee ? { assignee } : {}),
            limit,
          });
          return {
            result: stableJSONStringify({
              issues,
              count: issues.length,
            }),
            error: null,
          };
        }

        case "github.pr.create": {
          if (!this.githubClient) {
            return { result: null, error: "github_not_configured" };
          }
          const repo = stringFromRecord(args, "repo");
          const title = stringFromRecord(args, "title");
          const head = stringFromRecord(args, "head");
          if (!repo || !title || !head) {
            return { result: null, error: "github_pr_create_requires_repo_title_head" };
          }
          const body = stringFromRecord(args, "body");
          const base = stringFromRecord(args, "base");
          const pullRequest = await this.githubClient.createPR(session, { repo, title, head, body, base });
          return { result: stableJSONStringify(pullRequest), error: null };
        }

        case "github.pr.merge": {
          if (!this.githubClient) {
            return { result: null, error: "github_not_configured" };
          }
          const repo = stringFromRecord(args, "repo");
          const prNumber = typeof args.prNumber === "number" ? Math.trunc(args.prNumber) : undefined;
          if (!repo || !prNumber || prNumber <= 0) {
            return { result: null, error: "github_pr_merge_requires_repo_and_prNumber" };
          }
          const mergeMethodRaw = stringFromRecord(args, "mergeMethod");
          const mergeMethod = mergeMethodRaw === "squash" || mergeMethodRaw === "rebase" ? mergeMethodRaw : "merge";
          const mergeResult = await this.githubClient.mergePR(session, { repo, prNumber, mergeMethod });
          return { result: stableJSONStringify(mergeResult), error: null };
        }

        case "github.issues.create": {
          if (!this.githubClient) {
            return { result: null, error: "github_not_configured" };
          }
          const repo = stringFromRecord(args, "repo");
          const title = stringFromRecord(args, "title");
          if (!repo || !title) {
            return { result: null, error: "github_issue_create_requires_repo_and_title" };
          }
          const body = stringFromRecord(args, "body");
          const labels = Array.isArray(args.labels)
            ? args.labels.filter((label): label is string => typeof label === "string" && label.trim().length > 0)
            : undefined;
          const issue = await this.githubClient.createIssue(session, { repo, title, body, labels });
          return { result: stableJSONStringify(issue), error: null };
        }

        default:
          return { result: null, error: `unsupported_server_tool:${toolName}` };
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : "unknown_server_tool_error";
      logger.warn(`server tool execution failed: ${toolName}: ${message}`, {
        sessionId: session.sessionId,
        callId,
      });
      return { result: null, error: message };
    }
  }

  private buildWebQAPrompt(
    url: string,
    flowSpec: unknown,
    assertions: unknown,
    budget: unknown,
  ): string {
    return [
      "You are executing a deterministic browser QA run.",
      `TARGET_URL: ${url}`,
      "FLOW_SPEC_JSON:",
      stableJSONStringify(flowSpec ?? {}),
      "ASSERTIONS_JSON:",
      stableJSONStringify(assertions ?? {}),
      "BUDGET_JSON:",
      stableJSONStringify(budget ?? {}),
      "Instructions:",
      "1) Open TARGET_URL in the browser.",
      "2) Execute flow steps exactly in order from FLOW_SPEC_JSON.",
      "3) Capture available artifacts (screenshots, video, logs).",
      "4) Summarize pass/fail for each assertion.",
      "5) Include console/network errors if observed.",
    ].join("\n");
  }

  private async trackSpawnResultIfPresent(
    session: SessionState,
    spawnCallId: string,
    toolName: string | undefined,
    toolArguments: Record<string, unknown> | undefined,
    resultPayload: string | undefined,
    emit: (event: EventEnvelope) => void,
  ): Promise<void> {
    if (!toolName || !resultPayload) {
      return;
    }

    const isSpawnTool = toolName === "agent.spawn"
      || toolName === "cursor.agent.spawn"
      || toolName === "webqa.cursor.run";

    if (!isSpawnTool) {
      return;
    }

    const snapshot = parseCursorAgentSnapshotFromResult(resultPayload);
    if (!snapshot) {
      return;
    }

    const modeFromArgs = normalizeMode(stringFromRecord(toolArguments ?? {}, "mode"));
    const mode: CursorAgentMode = modeFromArgs
      ?? snapshot.mode
      ?? (toolName === "webqa.cursor.run" ? "webqa" : "code");

    await this.recordSpawn(
      session.sessionId,
      spawnCallId,
      mode,
      {
        agentId: snapshot.agentId,
        status: snapshot.status,
        runUrl: snapshot.runUrl,
        prUrl: snapshot.prUrl,
        branchName: snapshot.branchName,
        summary: snapshot.summary,
      },
      emit,
    );
  }

  private async recordSpawn(
    sessionId: string,
    spawnCallId: string,
    mode: CursorAgentMode,
    details: {
      agentId: string;
      status?: string;
      runUrl?: string;
      prUrl?: string;
      branchName?: string;
      summary?: string;
    },
    emit: (event: EventEnvelope) => void,
  ): Promise<void> {
    const run = this.sessions.upsertCursorRun({
      agentId: details.agentId,
      sessionId,
      createdAt: this.now().toISOString(),
      mode,
      status: details.status,
      runUrl: details.runUrl,
      prUrl: details.prUrl,
      branchName: details.branchName,
      summary: details.summary,
      spawnCallId,
    });

    this.sessions.setSpawnCallAgent(spawnCallId, details.agentId);

    this.emitAgentStatus(run, emit, {
      eventSeed: `spawn:${spawnCallId}`,
      webhookDriven: this.cursorClient.hasWebhookConfig(),
    });

    this.startConversationPolling(details.agentId, sessionId, emit);

    const pending = this.sessions.takePendingWebhook(run.agentId, this.now().getTime());
    if (!pending) {
      return;
    }

    const parsed = parseCursorWebhookPayload(pending.payload);
    if (!parsed) {
      return;
    }

    await this.routeWebhookToSession(sessionId, parsed, emit);
  }

  private async routeWebhookToSession(
    sessionId: string,
    parsedWebhook: ParsedCursorWebhookEvent,
    emit: (event: EventEnvelope) => void,
  ): Promise<void> {
    const normalizedStatus = normalizeStatus(parsedWebhook.agent.status) ?? "UNKNOWN";
    const existing = this.sessions.getCursorRun(parsedWebhook.agent.agentId);
    const updatedRun = this.sessions.upsertCursorRun({
      agentId: parsedWebhook.agent.agentId,
      sessionId,
      createdAt: this.now().toISOString(),
      mode: parsedWebhook.agent.mode ?? existing?.mode ?? "code",
      status: normalizedStatus,
      runUrl: parsedWebhook.agent.runUrl,
      prUrl: parsedWebhook.agent.prUrl,
      branchName: parsedWebhook.agent.branchName,
      summary: parsedWebhook.agent.summary,
    });

    this.emitAgentStatus(updatedRun, emit, {
      eventSeed: `webhook:${parsedWebhook.eventType ?? "unknown"}:${parsedWebhook.occurredAt ?? "na"}:${normalizedStatus}`,
      webhookDriven: true,
      timestamp: parsedWebhook.occurredAt,
    });

    if (!isTerminalAgentStatus(normalizedStatus)) {
      this.startConversationPolling(parsedWebhook.agent.agentId, sessionId, emit);
      return;
    }

    this.stopConversationPolling(parsedWebhook.agent.agentId);

    const completedPayload: Record<string, unknown> = {
      agentId: updatedRun.agentId,
      status: normalizedStatus,
      summary: updatedRun.summary ?? "",
      runUrl: updatedRun.runUrl,
      prUrl: updatedRun.prUrl,
      branchName: updatedRun.branchName,
    };

    const completedTimestamp = parsedWebhook.occurredAt ?? this.now().toISOString();
    const completedId = makeDeterministicEventId([
      "agent.completed",
      sessionId,
      updatedRun.agentId,
      normalizedStatus,
      completedTimestamp,
    ].join("|"));

    await this.handleEvent(
      makeEvent("agent.completed", sessionId, completedPayload, completedId, completedTimestamp),
      emit,
    );
  }

  private emitAgentStatus(
    run: CursorAgentRunRecord,
    emit: (event: EventEnvelope) => void,
    options: {
      eventSeed: string;
      webhookDriven: boolean;
      timestamp?: string;
    },
  ): void {
    const status = normalizeStatus(run.status) ?? "UNKNOWN";
    const timestamp = options.timestamp ?? this.now().toISOString();
    const eventId = makeDeterministicEventId([
      "agent.status",
      run.sessionId,
      run.agentId,
      status,
      options.eventSeed,
    ].join("|"));

    emit(makeEvent(
      "agent.status",
      run.sessionId,
      {
        agentId: run.agentId,
        status,
        detail: run.summary ?? `Agent status updated: ${status}`,
        summary: run.summary,
        runUrl: run.runUrl,
        prUrl: run.prUrl,
        branchName: run.branchName,
        webhookDriven: options.webhookDriven,
      },
      eventId,
      timestamp,
    ));
  }

  private startConversationPolling(
    agentId: string,
    sessionId: string,
    emit: (event: EventEnvelope) => void,
  ): void {
    if (this.conversationPollers.has(agentId)) {
      return;
    }

    const poll = async (): Promise<void> => {
      try {
        await this.pollConversation(agentId, sessionId, emit);
      } finally {
        // Check terminal status *after* the final poll so we capture any
        // remaining conversation messages before stopping.
        const run = this.sessions.getCursorRun(agentId);
        if (!run || isTerminalAgentStatus(run.status)) {
          this.stopConversationPolling(agentId);
        }
      }
    };

    const timer = setInterval(() => { poll().catch(() => {}); }, ConductorService.CONVERSATION_POLL_INTERVAL_MS);
    timer.unref?.();
    this.conversationPollers.set(agentId, timer);
    poll().catch(() => {});
  }

  private stopConversationPolling(agentId: string): void {
    const timer = this.conversationPollers.get(agentId);
    if (timer) {
      clearInterval(timer);
      this.conversationPollers.delete(agentId);
    }
  }

  private async pollConversation(
    agentId: string,
    sessionId: string,
    emit: (event: EventEnvelope) => void,
  ): Promise<void> {
    try {
      const result = await this.cursorClient.conversation(agentId);
      const run = this.sessions.getCursorRun(agentId);
      const lastSeenId = run?.lastSeenConversationMessageId;

      let newMessages = result.messages;
      if (lastSeenId) {
        const lastSeenIndex = result.messages.findIndex((m) => m.id === lastSeenId);
        if (lastSeenIndex >= 0) {
          newMessages = result.messages.slice(lastSeenIndex + 1);
        }
      }

      if (newMessages.length === 0) {
        return;
      }

      const lastMsg = newMessages[newMessages.length - 1]!;
      if (run) {
        run.lastSeenConversationMessageId = lastMsg.id;
      }

      const eventId = makeDeterministicEventId(
        `agent.conversation|${agentId}|${lastMsg.id}`,
      );

      emit(makeEvent("agent.conversation", sessionId, {
        agentId,
        messages: newMessages.map((m) => ({
          id: m.id,
          type: m.type,
          text: m.text,
        })),
      }, eventId));
    } catch (error) {
      const message = error instanceof Error ? error.message : "unknown";
      logger.warn(`conversation poll failed for ${agentId}: ${message}`, { agentId });
    }
  }
}

function stableJSONStringify(value: unknown): string {
  const serialized = JSON.stringify(sortJSONValue(value));
  return serialized ?? "null";
}

function sortJSONValue(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map((item) => sortJSONValue(item));
  }

  if (!value || typeof value !== "object") {
    return value;
  }

  const entries = Object.entries(value as Record<string, unknown>)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, nested]) => [key, sortJSONValue(nested)] as const);

  return Object.fromEntries(entries);
}

function summarizeArgsForLog(args: Record<string, unknown>, maxLen = 80): string {
  const preferredKeys = ["prompt", "command", "repoUrl", "repository", "path", "query", "pattern"];
  for (const key of preferredKeys) {
    if (!(key in args)) {
      continue;
    }
    const summary = summarizeValueForLog(args[key], maxLen);
    if (summary) {
      return `${key}=${summary}`;
    }
  }

  const keys = Object.keys(args).sort();
  if (keys.length === 0) {
    return "keys=[]";
  }
  return summarizeValueForLog(`keys=[${keys.join(",")}]`, maxLen) ?? "keys=[]";
}
