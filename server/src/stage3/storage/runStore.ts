export interface Stage3RunRecord {
  runId: string;
  sessionId: string;
  repo: string;
  branch: string;
  baseRef: string;
  prNumber?: number;
  prUrl?: string;
  status: "created" | "running" | "waiting_ci" | "blocked" | "green" | "merged" | "failed";
  iteration: number;
  createdAt: string;
  updatedAt: string;
  lastSignature?: string;
  previewUrl?: string;
  webqaPass?: boolean;
}

export interface RunStore {
  put(record: Stage3RunRecord): Promise<void>;
  get(runId: string): Promise<Stage3RunRecord | null>;
  findBySession(sessionId: string): Promise<Stage3RunRecord[]>;
}

export class InMemoryRunStore implements RunStore {
  private readonly runs = new Map<string, Stage3RunRecord>();

  async put(record: Stage3RunRecord): Promise<void> {
    this.runs.set(record.runId, { ...record });
  }

  async get(runId: string): Promise<Stage3RunRecord | null> {
    return this.runs.get(runId) ?? null;
  }

  async findBySession(sessionId: string): Promise<Stage3RunRecord[]> {
    return [...this.runs.values()]
      .filter((record) => record.sessionId === sessionId)
      .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  }
}
