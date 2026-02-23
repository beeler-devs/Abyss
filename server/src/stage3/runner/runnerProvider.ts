export interface RunnerProvider {
  readonly name: string;
  start(args: { repo: string; ref: string }): Promise<{ runId: string; state: string }>;
  exec(args: { runId: string; command: string; timeoutSec?: number }): Promise<{ exitCode: number; stdout: string; stderr: string }>;
  applyPatch(args: { runId: string; unifiedDiff: string }): Promise<{ applied: boolean }>;
  commitAndPush(args: { runId: string; message: string }): Promise<{ commitSha: string }>;
  stop(args: { runId: string }): Promise<{ stopped: boolean }>;
}

export class StubRunnerProvider implements RunnerProvider {
  readonly name = "stub-runner";

  async start(_args: { repo: string; ref: string }): Promise<{ runId: string; state: string }> {
    return { runId: "runner-not-implemented", state: "unsupported" };
  }

  async exec(_args: { runId: string; command: string; timeoutSec?: number }): Promise<{ exitCode: number; stdout: string; stderr: string }> {
    return {
      exitCode: 127,
      stdout: "",
      stderr: "runner_not_implemented",
    };
  }

  async applyPatch(_args: { runId: string; unifiedDiff: string }): Promise<{ applied: boolean }> {
    return { applied: false };
  }

  async commitAndPush(_args: { runId: string; message: string }): Promise<{ commitSha: string }> {
    return { commitSha: "" };
  }

  async stop(_args: { runId: string }): Promise<{ stopped: boolean }> {
    return { stopped: true };
  }
}
