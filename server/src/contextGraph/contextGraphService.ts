import crypto from "node:crypto";

import { logger } from "../core/logger.js";
import { MemoryService, MemoryDocument, WorkingContextSnapshot } from "../core/memory/memoryService.js";
import { ConversationTurn } from "../core/types.js";
import { EmbeddingService } from "./embedding/embeddingService.js";
import { GraphStore } from "./store/graphStore.js";
import {
  ContextGraphUpdate,
  ResumeNeighborhood,
  UserNode,
  SessionNode,
  GoalNode,
  MemoryEpisodeNode,
  RepoNode,
  BranchNode,
  DecisionNode,
  BlockerNode,
  NextStepNode,
} from "./types.js";

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T | null> {
  let timer: ReturnType<typeof setTimeout>;
  const timeout = new Promise<null>((resolve) => {
    timer = setTimeout(() => resolve(null), ms);
  });
  return Promise.race([
    promise.then((result) => { clearTimeout(timer); return result; }),
    timeout,
  ]);
}

export interface ContextGraphServiceConfig {
  retrieveTimeoutMs: number;  // timeout for Neptune hybrid queries
  maxInjectedChars: number;   // max chars for formatted resume context
}

export class ContextGraphService {
  private readonly graphStore?: GraphStore;
  private readonly embeddingService?: EmbeddingService;
  private readonly memoryService?: MemoryService;
  private readonly config: ContextGraphServiceConfig;

  constructor(
    config: ContextGraphServiceConfig,
    deps: {
      graphStore?: GraphStore;
      embeddingService?: EmbeddingService;
      memoryService?: MemoryService;
    },
  ) {
    this.config = config;
    this.graphStore = deps.graphStore;
    this.embeddingService = deps.embeddingService;
    this.memoryService = deps.memoryService;
    logger.info(`[contextGraph] initialized — graphStore=${!!deps.graphStore} embeddingService=${!!deps.embeddingService} memoryService=${!!deps.memoryService} retrieveTimeoutMs=${config.retrieveTimeoutMs}`);
  }

  /**
   * Fire-and-forget handler for graph updates from the conductor.
   * Each update type creates/links graph nodes. Errors are caught and logged.
   */
  async apply(update: ContextGraphUpdate): Promise<void> {
    if (!this.graphStore) return;
    const start = Date.now();
    try {
      switch (update.type) {
        case "session.start":
          await this.handleSessionStart(update);
          break;
        case "goal.started":
          await this.handleGoalStarted(update);
          break;
        case "session.finalized":
          await this.handleSessionFinalized(update);
          break;
      }
      logger.info(`[contextGraph] apply(${update.type}) ok durationMs=${Date.now() - start}`, { sessionId: update.sessionId });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      logger.error(`[contextGraph] apply(${update.type}) failed durationMs=${Date.now() - start}: ${msg}`, { sessionId: update.sessionId });
    }
  }

  /**
   * Retrieve resume context: tries hybrid graph query first, falls back to MemoryService.
   */
  async retrieveResumeContext(input: { memoryUserKey: string; transcript?: string }): Promise<string | null> {
    const start = Date.now();
    logger.info(`[contextGraph] retrieveResumeContext start — user=${input.memoryUserKey} hasTranscript=${!!input.transcript} graphStore=${!!this.graphStore} embeddingService=${!!this.embeddingService}`);

    // Try graph-based retrieval first
    if (this.graphStore && this.embeddingService && input.transcript) {
      try {
        const embedStart = Date.now();
        const embedding = await this.embeddingService.embed(input.transcript);
        logger.info(`[contextGraph] embed ok durationMs=${Date.now() - embedStart} dims=${embedding.length}`);

        const queryStart = Date.now();
        const neighborhood = await withTimeout(
          this.graphStore.hybridResumeQuery(embedding, input.memoryUserKey, 5),
          this.config.retrieveTimeoutMs,
        );

        if (neighborhood) {
          const counts = `goals=${neighborhood.goals.length} sessions=${neighborhood.sessions.length} episodes=${neighborhood.episodes.length} repos=${neighborhood.repos.length} blockers=${neighborhood.blockers.length} nextSteps=${neighborhood.nextSteps.length} decisions=${neighborhood.decisions.length}`;
          logger.info(`[contextGraph] hybridResumeQuery ok durationMs=${Date.now() - queryStart} ${counts}`);
          const formatted = this.formatResumeContext(neighborhood);
          if (formatted) {
            logger.info(`[contextGraph] retrieveResumeContext done source=graph durationMs=${Date.now() - start} chars=${formatted.length}`);
            return formatted;
          }
          logger.info(`[contextGraph] graph returned results but formatted to empty — falling back to memoryService`);
        } else {
          logger.warn(`[contextGraph] hybridResumeQuery timed out after ${this.config.retrieveTimeoutMs}ms — falling back to memoryService`);
        }
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        logger.error(`[contextGraph] retrieveResumeContext graph query failed durationMs=${Date.now() - start}: ${msg}`);
      }
    }

    // Fall back to existing MemoryService
    if (this.memoryService) {
      logger.info(`[contextGraph] falling back to memoryService.retrieveContext`);
      const result = await this.memoryService.retrieveContext(input);
      logger.info(`[contextGraph] retrieveResumeContext done source=memoryService durationMs=${Date.now() - start} chars=${result?.length ?? 0}`);
      return result;
    }

    logger.info(`[contextGraph] retrieveResumeContext done source=none durationMs=${Date.now() - start} — no graph or memory service`);
    return null;
  }

  /**
   * Delegate summarization to MemoryService, return the MemoryDocument.
   */
  async summarizeAndStore(
    memoryUserKey: string,
    sessionId: string,
    history: ConversationTurn[],
    workingContext?: WorkingContextSnapshot,
  ): Promise<MemoryDocument | null> {
    if (!this.memoryService) {
      logger.info(`[contextGraph] summarizeAndStore skipped — no memoryService`, { sessionId });
      return null;
    }
    const start = Date.now();
    logger.info(`[contextGraph] summarizeAndStore start turns=${history.length} user=${memoryUserKey}`, { sessionId });
    const doc = await this.memoryService.summarizeAndStore(memoryUserKey, sessionId, history, workingContext);
    logger.info(`[contextGraph] summarizeAndStore done durationMs=${Date.now() - start} result=${doc ? "doc" : "null"}`, { sessionId });
    return doc;
  }

  // --- Private handlers ---

  private async handleSessionStart(update: Extract<ContextGraphUpdate, { type: "session.start" }>): Promise<void> {
    const now = update.timestamp;
    const { memoryUserKey } = update.payload;

    logger.info(`[contextGraph] session.start — upsert User(${memoryUserKey}) + Session(${update.sessionId})`, { sessionId: update.sessionId });

    const userNode: UserNode = {
      id: `user:${memoryUserKey}`,
      type: "User",
      memoryUserKey,
      createdAt: now,
      updatedAt: now,
    };
    await this.graphStore!.upsertNode(userNode);

    const sessionNode: SessionNode = {
      id: `session:${update.sessionId}`,
      type: "Session",
      sessionId: update.sessionId,
      startedAt: now,
      createdAt: now,
      updatedAt: now,
    };
    await this.graphStore!.upsertNode(sessionNode);

    await this.graphStore!.upsertEdge(userNode.id, sessionNode.id, "STARTED");
    logger.info(`[contextGraph] session.start — User->STARTED->Session edge created`, { sessionId: update.sessionId });
  }

  private async handleGoalStarted(update: Extract<ContextGraphUpdate, { type: "goal.started" }>): Promise<void> {
    const now = update.timestamp;
    const { goalText, memoryUserKey } = update.payload;
    const goalId = `goal:${this.hashShort(goalText)}:${update.sessionId}`;

    logger.info(`[contextGraph] goal.started — upsert Goal(${goalId}) text="${goalText.slice(0, 80)}"`, { sessionId: update.sessionId });

    const goalNode: GoalNode = {
      id: goalId,
      type: "Goal",
      text: goalText,
      sessionId: update.sessionId,
      createdAt: now,
      updatedAt: now,
    };
    await this.graphStore!.upsertNode(goalNode);
    await this.graphStore!.upsertEdge(`session:${update.sessionId}`, goalId, "HAS_GOAL");

    // Embed goal text
    if (this.embeddingService) {
      try {
        const embedStart = Date.now();
        const embedding = await this.embeddingService.embed(goalText);
        await this.graphStore!.upsertEmbedding(goalId, "Goal", embedding);
        logger.info(`[contextGraph] goal embedding upserted durationMs=${Date.now() - embedStart} dims=${embedding.length}`, { sessionId: update.sessionId });
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        logger.error(`[contextGraph] goal embedding failed: ${msg}`, { sessionId: update.sessionId });
      }
    }
  }

  private async handleSessionFinalized(update: Extract<ContextGraphUpdate, { type: "session.finalized" }>): Promise<void> {
    const now = update.timestamp;
    const { memoryUserKey, workingContext, summary, decisions, blockers, nextSteps } = update.payload;
    const sessionNodeId = `session:${update.sessionId}`;

    logger.info(`[contextGraph] session.finalized — user=${memoryUserKey} repo=${workingContext?.repo ?? "none"} branch=${workingContext?.branch ?? "none"} decisions=${decisions?.length ?? 0} blockers=${blockers?.length ?? 0} nextSteps=${nextSteps?.length ?? 0} summaryLen=${summary.length}`, { sessionId: update.sessionId });

    // Create MemoryEpisode node
    const episodeId = `episode:${update.sessionId}`;
    const episodeNode: MemoryEpisodeNode = {
      id: episodeId,
      type: "MemoryEpisode",
      summary,
      sessionId: update.sessionId,
      memoryUserKey,
      createdAt: now,
      updatedAt: now,
    };
    await this.graphStore!.upsertNode(episodeNode);
    await this.graphStore!.upsertEdge(episodeId, sessionNodeId, "IN_SESSION");
    logger.info(`[contextGraph] MemoryEpisode(${episodeId}) created`, { sessionId: update.sessionId });

    // Embed the episode summary
    if (this.embeddingService) {
      try {
        const embedStart = Date.now();
        const embedding = await this.embeddingService.embed(summary);
        await this.graphStore!.upsertEmbedding(episodeId, "MemoryEpisode", embedding);
        logger.info(`[contextGraph] episode embedding upserted durationMs=${Date.now() - embedStart}`, { sessionId: update.sessionId });
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        logger.error(`[contextGraph] episode embedding failed: ${msg}`, { sessionId: update.sessionId });
      }
    }

    // Repo + Branch nodes
    if (workingContext?.repo) {
      const repoId = `repo:${workingContext.repo}`;
      const repoNode: RepoNode = {
        id: repoId,
        type: "Repo",
        name: workingContext.repo,
        createdAt: now,
        updatedAt: now,
      };
      await this.graphStore!.upsertNode(repoNode);
      await this.graphStore!.upsertEdge(sessionNodeId, repoId, "USED_REPO");
      logger.info(`[contextGraph] Repo(${workingContext.repo}) linked`, { sessionId: update.sessionId });

      if (workingContext.branch) {
        const branchId = `branch:${workingContext.repo}:${workingContext.branch}`;
        const branchNode: BranchNode = {
          id: branchId,
          type: "Branch",
          name: workingContext.branch,
          repoId,
          createdAt: now,
          updatedAt: now,
        };
        await this.graphStore!.upsertNode(branchNode);
        await this.graphStore!.upsertEdge(sessionNodeId, branchId, "ON_BRANCH");
        logger.info(`[contextGraph] Branch(${workingContext.branch}) linked`, { sessionId: update.sessionId });
      }
    }

    // Decision nodes
    if (decisions?.length) {
      for (const text of decisions) {
        const id = `decision:${this.hashShort(text)}:${update.sessionId}`;
        const node: DecisionNode = { id, type: "Decision", text, sessionId: update.sessionId, createdAt: now, updatedAt: now };
        await this.graphStore!.upsertNode(node);
        await this.graphStore!.upsertEdge(id, sessionNodeId, "IN_SESSION");
      }
      logger.info(`[contextGraph] ${decisions.length} Decision node(s) created`, { sessionId: update.sessionId });
    }

    // Blocker nodes
    if (blockers?.length) {
      for (const text of blockers) {
        const id = `blocker:${this.hashShort(text)}:${update.sessionId}`;
        const node: BlockerNode = { id, type: "Blocker", text, sessionId: update.sessionId, createdAt: now, updatedAt: now };
        await this.graphStore!.upsertNode(node);
        await this.graphStore!.upsertEdge(id, sessionNodeId, "IN_SESSION");
      }
      logger.info(`[contextGraph] ${blockers.length} Blocker node(s) created`, { sessionId: update.sessionId });
    }

    // NextStep nodes
    if (nextSteps?.length) {
      for (const text of nextSteps) {
        const id = `nextstep:${this.hashShort(text)}:${update.sessionId}`;
        const node: NextStepNode = { id, type: "NextStep", text, sessionId: update.sessionId, createdAt: now, updatedAt: now };
        await this.graphStore!.upsertNode(node);
        await this.graphStore!.upsertEdge(id, sessionNodeId, "IN_SESSION");
      }
      logger.info(`[contextGraph] ${nextSteps.length} NextStep node(s) created`, { sessionId: update.sessionId });
    }
  }

  private formatResumeContext(neighborhood: ResumeNeighborhood): string | null {
    const lines: string[] = ["Prior context (graph):"];

    for (const goal of neighborhood.goals.slice(0, 3)) {
      lines.push(`• Goal: ${goal.text}`);
    }

    for (const episode of neighborhood.episodes.slice(0, 3)) {
      lines.push(`• Session: ${episode.summary}`);
    }

    for (const repo of neighborhood.repos.slice(0, 2)) {
      lines.push(`  Repo: ${repo.name}`);
    }

    for (const branch of neighborhood.branches.slice(0, 2)) {
      lines.push(`  Branch: ${branch.name}`);
    }

    for (const blocker of neighborhood.blockers.slice(0, 2)) {
      lines.push(`  Blocker: ${blocker.text}`);
    }

    for (const step of neighborhood.nextSteps.slice(0, 3)) {
      lines.push(`  Next: ${step.text}`);
    }

    for (const decision of neighborhood.decisions.slice(0, 2)) {
      lines.push(`  Decision: ${decision.text}`);
    }

    if (lines.length <= 1) return null;

    const result = lines.join("\n");
    if (result.length <= this.config.maxInjectedChars) return result;
    return result.slice(0, this.config.maxInjectedChars - 3) + "...";
  }

  private hashShort(text: string): string {
    return crypto.createHash("sha256").update(text).digest("hex").slice(0, 12);
  }
}
