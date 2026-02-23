import crypto from "node:crypto";

export interface WebQAStep {
  action: "navigate" | "click" | "type" | "assertTextVisible";
  selector?: string;
  value?: string;
}

export interface WebQAFlowSpec {
  name: string;
  steps: WebQAStep[];
}

export interface WebQARunArtifacts {
  screenshots: Array<{ url: string; caption: string }>;
  steps: Array<{ step: string; ok: boolean; detail?: string }>;
  consoleErrors: string[];
  pass: boolean;
}

export interface WebQAProvider {
  readonly name: string;
  run(url: string, flowSpec: WebQAFlowSpec, assertions: string[]): Promise<{ runId: string }>;
  status(runId: string): Promise<{ state: "queued" | "running" | "completed"; progress: number }>;
  artifacts(runId: string): Promise<WebQARunArtifacts>;
}

interface WebQARunRecord {
  state: "queued" | "running" | "completed";
  progress: number;
  artifacts: WebQARunArtifacts;
}

function extractTitle(html: string): string {
  const match = html.match(/<title>([\s\S]*?)<\/title>/i);
  return match?.[1]?.trim() ?? "";
}

export class StubWebQAProvider implements WebQAProvider {
  readonly name = "stub-http-webqa";

  private readonly runs = new Map<string, WebQARunRecord>();

  async run(url: string, flowSpec: WebQAFlowSpec, assertions: string[]): Promise<{ runId: string }> {
    const runId = crypto.randomUUID();
    const record: WebQARunRecord = {
      state: "running",
      progress: 0.1,
      artifacts: {
        screenshots: [],
        steps: [],
        consoleErrors: [],
        pass: false,
      },
    };
    this.runs.set(runId, record);

    void (async () => {
      try {
        const response = await fetch(url, { signal: AbortSignal.timeout(10_000) });
        const html = await response.text();
        const title = extractTitle(html);

        const stepResults: Array<{ step: string; ok: boolean; detail?: string }> = [];
        stepResults.push({
          step: `navigate ${url}`,
          ok: response.ok,
          detail: `status ${response.status}`,
        });

        for (const assertion of assertions) {
          const ok = title.toLowerCase().includes(assertion.toLowerCase()) || html.toLowerCase().includes(assertion.toLowerCase());
          stepResults.push({
            step: `assert ${assertion}`,
            ok,
            detail: ok ? "found" : "missing",
          });
        }

        for (const step of flowSpec.steps) {
          if (step.action === "navigate") {
            continue;
          }
          stepResults.push({
            step: `${step.action}${step.selector ? ` ${step.selector}` : ""}`,
            ok: true,
            detail: "stubbed",
          });
        }

        const pass = stepResults.every((step) => step.ok);
        const screenshotUrl = `data:text/plain;base64,${Buffer.from(`WebQA stub screenshot for ${url}`).toString("base64")}`;

        record.state = "completed";
        record.progress = 1;
        record.artifacts = {
          screenshots: [
            {
              url: screenshotUrl,
              caption: `Stub screenshot for ${url}`,
            },
          ],
          steps: stepResults,
          consoleErrors: [],
          pass,
        };
      } catch (error) {
        const message = error instanceof Error ? error.message : "webqa_unknown_error";
        record.state = "completed";
        record.progress = 1;
        record.artifacts = {
          screenshots: [],
          steps: [{ step: "navigate", ok: false, detail: message }],
          consoleErrors: [message],
          pass: false,
        };
      }
    })();

    return { runId };
  }

  async status(runId: string): Promise<{ state: "queued" | "running" | "completed"; progress: number }> {
    const run = this.runs.get(runId);
    if (!run) {
      throw new Error(`webqa_run_not_found:${runId}`);
    }
    return {
      state: run.state,
      progress: run.progress,
    };
  }

  async artifacts(runId: string): Promise<WebQARunArtifacts> {
    const run = this.runs.get(runId);
    if (!run) {
      throw new Error(`webqa_run_not_found:${runId}`);
    }
    return run.artifacts;
  }
}
