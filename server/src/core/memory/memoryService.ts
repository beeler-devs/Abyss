import {
  BedrockRuntimeClient,
  InvokeModelCommand,
} from "@aws-sdk/client-bedrock-runtime";
import {
  BedrockAgentRuntimeClient,
  RetrieveCommand,
} from "@aws-sdk/client-bedrock-agent-runtime";
import {
  S3Client,
  PutObjectCommand,
  ListObjectsV2Command,
  GetObjectCommand,
} from "@aws-sdk/client-s3";

import { ConversationTurn } from "../types.js";

export interface MemoryServiceConfig {
  enabled: boolean;
  s3Bucket: string;
  s3Prefix: string;
  knowledgeBaseId?: string;
  awsRegion: string;
  summaryModelId: string;
  retrieveTimeoutMs: number;
  maxInjectedChars: number;
  recentMemoryCount: number;
}

export interface WorkingContextSnapshot {
  repo?: string;
  branch?: string;
  prUrl?: string;
  lastGoal?: string;
  activeExecutor?: string;
}

export interface MemoryDocument {
  memoryUserKey: string;
  sessionId: string;
  timestamp: string;
  summary: string;
  repo?: string;
  branch?: string;
  prUrl?: string;
  lastGoal?: string;
  activeExecutor?: string;
  decisions?: string[];
  blockers?: string[];
  nextSteps?: string[];
}

export interface MemoryRetrieveInput {
  memoryUserKey: string;
  transcript?: string;
}

function isMeaningfulHistory(history: ConversationTurn[]): boolean {
  const userTurns = history.filter((t) => t.role === "user" && typeof t.content === "string");
  if (userTurns.length >= 3) return true;

  // Has tool calls (assistant with array content)
  const hasTools = history.some(
    (t) => t.role === "assistant" && Array.isArray(t.content),
  );
  if (hasTools) return true;

  // Check for keywords in user messages
  const allText = history
    .filter((t) => typeof t.content === "string")
    .map((t) => t.content as string)
    .join(" ")
    .toLowerCase();

  const keywords = ["decision", "decided", "blocker", "blocked", "next step", "todo", "branch", "repo", "pr", "pull request"];
  return keywords.some((kw) => allText.includes(kw));
}

async function streamToString(stream: NodeJS.ReadableStream): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of stream) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk as string));
  }
  return Buffer.concat(chunks).toString("utf-8");
}

export class MemoryService {
  private readonly config: MemoryServiceConfig;
  private readonly s3: S3Client;
  private readonly bedrock: BedrockRuntimeClient;
  private readonly agentRuntime: BedrockAgentRuntimeClient;

  constructor(config: MemoryServiceConfig) {
    this.config = config;
    this.s3 = new S3Client({ region: config.awsRegion });
    this.bedrock = new BedrockRuntimeClient({ region: config.awsRegion });
    this.agentRuntime = new BedrockAgentRuntimeClient({ region: config.awsRegion });
  }

  async summarizeAndStore(
    memoryUserKey: string,
    sessionId: string,
    history: ConversationTurn[],
    workingContext?: WorkingContextSnapshot,
  ): Promise<void> {
    if (!this.config.enabled) return;
    if (!isMeaningfulHistory(history)) return;

    // Filter to meaningful turns for summary
    const relevantTurns = history.filter((t) => {
      if (t.role === "system") return false;
      if (t.role === "user" && typeof t.content === "string") return true;
      if (t.role === "assistant") return true;
      return false;
    });

    const conversationText = relevantTurns
      .map((t) => {
        const role = t.role === "assistant" ? "Assistant" : "User";
        const content = Array.isArray(t.content)
          ? t.content.map((c) => `[tool: ${c.name}]`).join(", ")
          : t.content;
        return `${role}: ${content}`;
      })
      .join("\n");

    const prompt = `Summarize this conversation for future context retrieval. Extract:
- Main goal/task discussed
- Repository and branch if mentioned
- Key decisions made
- Blockers encountered
- Next steps planned

Conversation:
${conversationText}

Respond with JSON only:
{
  "summary": "one paragraph summary",
  "decisions": ["decision1", "decision2"],
  "blockers": ["blocker1"],
  "nextSteps": ["step1", "step2"]
}`;

    let parsedSummary: { summary: string; decisions?: string[]; blockers?: string[]; nextSteps?: string[] } = {
      summary: "",
    };

    try {
      const response = await this.bedrock.send(
        new InvokeModelCommand({
          modelId: this.config.summaryModelId,
          contentType: "application/json",
          accept: "application/json",
          body: JSON.stringify({
            messages: [{ role: "user", content: prompt }],
            inferenceConfig: { max_new_tokens: 512 },
          }),
        }),
      );

      const responseText = new TextDecoder().decode(response.body);
      const responseJson = JSON.parse(responseText) as { output?: { message?: { content?: Array<{ text?: string }> } } };
      const text = responseJson.output?.message?.content?.[0]?.text ?? "";

      // Parse JSON from response
      const jsonMatch = text.match(/\{[\s\S]*\}/);
      if (jsonMatch) {
        parsedSummary = JSON.parse(jsonMatch[0]) as typeof parsedSummary;
      }
    } catch {
      // If summarization fails, store a minimal record
      parsedSummary = { summary: "Session summary unavailable." };
    }

    const doc: MemoryDocument = {
      memoryUserKey,
      sessionId,
      timestamp: new Date().toISOString(),
      summary: parsedSummary.summary || "No summary available.",
      repo: workingContext?.repo,
      branch: workingContext?.branch,
      prUrl: workingContext?.prUrl,
      lastGoal: workingContext?.lastGoal,
      activeExecutor: workingContext?.activeExecutor,
      decisions: parsedSummary.decisions,
      blockers: parsedSummary.blockers,
      nextSteps: parsedSummary.nextSteps,
    };

    const key = `${this.config.s3Prefix}${memoryUserKey}/${new Date().toISOString().replace(/[:.]/g, "-")}-${sessionId}.json`;

    await this.s3.send(
      new PutObjectCommand({
        Bucket: this.config.s3Bucket,
        Key: key,
        Body: JSON.stringify(doc, null, 2),
        ContentType: "application/json",
      }),
    );

    // Trigger KB ingestion if configured (fire-and-forget)
    if (this.config.knowledgeBaseId) {
      void this.triggerKbIngestion();
    }
  }

  private async triggerKbIngestion(): Promise<void> {
    // Bedrock KB sync requires a data source ID — if not configured, skip silently
    // Full implementation requires MEMORY_KB_DATA_SOURCE_ID env var
  }

  async retrieveContext(input: MemoryRetrieveInput): Promise<string | null> {
    if (!this.config.enabled) return null;

    const deadline = Date.now() + this.config.retrieveTimeoutMs;

    try {
      // Fast path: list recent S3 objects for user
      const listResult = await this.s3.send(
        new ListObjectsV2Command({
          Bucket: this.config.s3Bucket,
          Prefix: `${this.config.s3Prefix}${input.memoryUserKey}/`,
          MaxKeys: 10,
        }),
      );

      const objects = (listResult.Contents ?? [])
        .filter((o) => o.Key && o.LastModified)
        .sort((a, b) => (b.LastModified!.getTime()) - (a.LastModified!.getTime()))
        .slice(0, this.config.recentMemoryCount);

      if (objects.length === 0) return null;

      // Fetch docs in parallel, respect timeout
      const remaining = deadline - Date.now();
      if (remaining <= 0) return null;

      const fetchPromises = objects.map(async (obj) => {
        const response = await this.s3.send(
          new GetObjectCommand({
            Bucket: this.config.s3Bucket,
            Key: obj.Key!,
          }),
        );
        const text = await streamToString(response.Body as NodeJS.ReadableStream);
        return JSON.parse(text) as MemoryDocument;
      });

      const docs = await Promise.race([
        Promise.allSettled(fetchPromises),
        new Promise<null>((resolve) => setTimeout(() => resolve(null), remaining)),
      ]);

      if (!docs) return null;

      const successfulDocs = (docs as PromiseSettledResult<MemoryDocument>[])
        .filter((r): r is PromiseFulfilledResult<MemoryDocument> => r.status === "fulfilled")
        .map((r) => r.value);

      if (successfulDocs.length === 0) return null;

      // Optionally augment with KB semantic retrieval
      if (this.config.knowledgeBaseId && input.transcript) {
        const kbRemaining = deadline - Date.now();
        if (kbRemaining > 200) {
          try {
            const kbResult = await Promise.race([
              this.agentRuntime.send(
                new RetrieveCommand({
                  knowledgeBaseId: this.config.knowledgeBaseId,
                  retrievalQuery: { text: input.transcript },
                  retrievalConfiguration: {
                    vectorSearchConfiguration: { numberOfResults: 3 },
                  },
                }),
              ),
              new Promise<null>((resolve) => setTimeout(() => resolve(null), kbRemaining)),
            ]);

            if (kbResult && "retrievalResults" in kbResult) {
              for (const result of kbResult.retrievalResults ?? []) {
                const text = result.content?.text;
                if (text) {
                  try {
                    const kbDoc = JSON.parse(text) as MemoryDocument;
                    // Dedupe by sessionId
                    if (!successfulDocs.some((d) => d.sessionId === kbDoc.sessionId)) {
                      successfulDocs.push(kbDoc);
                    }
                  } catch {
                    // Skip non-JSON KB results
                  }
                }
              }
            }
          } catch {
            // KB retrieval failure is non-fatal
          }
        }
      }

      return this.formatContext(successfulDocs);
    } catch {
      return null;
    }
  }

  private formatContext(docs: MemoryDocument[]): string | null {
    if (docs.length === 0) return null;

    const lines: string[] = ["Prior context:"];

    for (const doc of docs.slice(0, 3)) {
      const date = new Date(doc.timestamp).toLocaleDateString();
      lines.push(`• [${date}] ${doc.summary}`);
      if (doc.repo) lines.push(`  Repo: ${doc.repo}${doc.branch ? ` (${doc.branch})` : ""}`);
      if (doc.nextSteps?.length) lines.push(`  Next: ${doc.nextSteps.slice(0, 2).join("; ")}`);
    }

    const result = lines.join("\n");
    if (result.length <= this.config.maxInjectedChars) return result;
    return result.slice(0, this.config.maxInjectedChars - 3) + "...";
  }
}
