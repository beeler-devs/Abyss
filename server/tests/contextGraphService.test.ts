import test from "node:test";
import assert from "node:assert/strict";
import { ContextGraphService } from "../src/contextGraph/contextGraphService.js";
import { GraphStore } from "../src/contextGraph/store/graphStore.js";
import { ResumeNeighborhood, GraphNode, GraphNodeType, GraphSubgraph } from "../src/contextGraph/types.js";
import { MemoryService, MemoryDocument, WorkingContextSnapshot } from "../src/core/memory/memoryService.js";
import { EmbeddingService } from "../src/contextGraph/embedding/embeddingService.js";

// --- Mock helpers ---

interface MockGraphStoreCalls {
  upsertNode: GraphNode[];
  upsertEdge: Array<{ fromId: string; toId: string; label: string }>;
  upsertEmbedding: Array<{ nodeId: string; label: string }>;
  hybridResumeQuery: number;
}

function makeMockGraphStore(hybridResult?: ResumeNeighborhood): { store: GraphStore; calls: MockGraphStoreCalls } {
  const calls: MockGraphStoreCalls = { upsertNode: [], upsertEdge: [], upsertEmbedding: [], hybridResumeQuery: 0 };
  const store: GraphStore = {
    async upsertNode(node) { calls.upsertNode.push(node); },
    async deleteNode() {},
    async upsertEdge(fromId, toId, label) { calls.upsertEdge.push({ fromId, toId, label }); },
    async upsertEmbedding(nodeId, label) { calls.upsertEmbedding.push({ nodeId, label }); },
    async topKByEmbedding() { return []; },
    async queryNeighborhood(): Promise<GraphSubgraph> { return { nodes: [], edges: [] }; },
    async queryByType(): Promise<GraphNode[]> { return []; },
    async hybridResumeQuery(): Promise<ResumeNeighborhood> {
      calls.hybridResumeQuery++;
      return hybridResult ?? { goals: [], sessions: [], episodes: [], repos: [], branches: [], blockers: [], nextSteps: [], decisions: [] };
    },
    async healthCheck() { return true; },
  };
  return { store, calls };
}

function makeMockEmbeddingService(): EmbeddingService {
  return {
    embed: async () => [0.1, 0.2, 0.3],
    embedBatch: async (texts: string[]) => texts.map(() => [0.1, 0.2, 0.3]),
  } as unknown as EmbeddingService;
}

const defaultConfig = { retrieveTimeoutMs: 5000, maxInjectedChars: 4000 };

// --- Tests ---

test("apply session.start creates User and Session nodes with STARTED edge", async () => {
  const { store, calls } = makeMockGraphStore();
  const service = new ContextGraphService(defaultConfig, { graphStore: store });

  await service.apply({
    type: "session.start",
    sessionId: "sess-1",
    payload: { memoryUserKey: "alice" },
    timestamp: "2026-03-16T00:00:00Z",
  });

  assert.equal(calls.upsertNode.length, 2);
  const userNode = calls.upsertNode.find((n) => n.type === "User");
  const sessionNode = calls.upsertNode.find((n) => n.type === "Session");
  assert.ok(userNode);
  assert.ok(sessionNode);
  assert.equal(userNode.id, "user:alice");
  assert.equal(sessionNode.id, "session:sess-1");

  assert.equal(calls.upsertEdge.length, 1);
  assert.deepEqual(calls.upsertEdge[0], { fromId: "user:alice", toId: "session:sess-1", label: "STARTED" });
});

test("apply goal.started creates Goal node with HAS_GOAL edge and embedding", async () => {
  const { store, calls } = makeMockGraphStore();
  const embedding = makeMockEmbeddingService();
  const service = new ContextGraphService(defaultConfig, { graphStore: store, embeddingService: embedding });

  await service.apply({
    type: "goal.started",
    sessionId: "sess-1",
    payload: { goalText: "Fix the login bug", memoryUserKey: "alice" },
    timestamp: "2026-03-16T00:01:00Z",
  });

  const goalNode = calls.upsertNode.find((n) => n.type === "Goal");
  assert.ok(goalNode);
  assert.equal(goalNode.type, "Goal");
  assert.ok(goalNode.id.startsWith("goal:"));

  const hasGoalEdge = calls.upsertEdge.find((e) => e.label === "HAS_GOAL");
  assert.ok(hasGoalEdge);
  assert.equal(hasGoalEdge.fromId, "session:sess-1");
  assert.equal(hasGoalEdge.toId, goalNode.id);

  assert.equal(calls.upsertEmbedding.length, 1);
  assert.equal(calls.upsertEmbedding[0].nodeId, goalNode.id);
  assert.equal(calls.upsertEmbedding[0].label, "Goal");
});

test("apply session.finalized creates MemoryEpisode, Repo, Branch, Decision, Blocker, NextStep nodes", async () => {
  const { store, calls } = makeMockGraphStore();
  const embedding = makeMockEmbeddingService();
  const service = new ContextGraphService(defaultConfig, { graphStore: store, embeddingService: embedding });

  await service.apply({
    type: "session.finalized",
    sessionId: "sess-1",
    payload: {
      memoryUserKey: "alice",
      summary: "Worked on login bug fix",
      workingContext: { repo: "my-app", branch: "fix/login" },
      decisions: ["Use JWT tokens"],
      blockers: ["Waiting on API key"],
      nextSteps: ["Implement token refresh"],
    },
    timestamp: "2026-03-16T00:10:00Z",
  });

  const episodeNode = calls.upsertNode.find((n) => n.type === "MemoryEpisode");
  assert.ok(episodeNode, "MemoryEpisode node should be created");

  const repoNode = calls.upsertNode.find((n) => n.type === "Repo");
  assert.ok(repoNode, "Repo node should be created");
  assert.equal((repoNode as any).name, "my-app");

  const branchNode = calls.upsertNode.find((n) => n.type === "Branch");
  assert.ok(branchNode, "Branch node should be created");
  assert.equal((branchNode as any).name, "fix/login");

  const decisionNode = calls.upsertNode.find((n) => n.type === "Decision");
  assert.ok(decisionNode, "Decision node should be created");

  const blockerNode = calls.upsertNode.find((n) => n.type === "Blocker");
  assert.ok(blockerNode, "Blocker node should be created");

  const nextStepNode = calls.upsertNode.find((n) => n.type === "NextStep");
  assert.ok(nextStepNode, "NextStep node should be created");

  // Verify edges
  const inSessionEdges = calls.upsertEdge.filter((e) => e.label === "IN_SESSION");
  assert.ok(inSessionEdges.length >= 4, "Should have IN_SESSION edges for episode, decision, blocker, nextStep");

  const usedRepoEdge = calls.upsertEdge.find((e) => e.label === "USED_REPO");
  assert.ok(usedRepoEdge, "Should have USED_REPO edge");

  const onBranchEdge = calls.upsertEdge.find((e) => e.label === "ON_BRANCH");
  assert.ok(onBranchEdge, "Should have ON_BRANCH edge");

  // Verify embedding was called for episode
  const episodeEmbedding = calls.upsertEmbedding.find((e) => e.label === "MemoryEpisode");
  assert.ok(episodeEmbedding, "Episode should be embedded");
});

test("apply catches errors and does not throw", async () => {
  const throwingStore: GraphStore = {
    async upsertNode() { throw new Error("boom"); },
    async deleteNode() { throw new Error("boom"); },
    async upsertEdge() { throw new Error("boom"); },
    async upsertEmbedding() { throw new Error("boom"); },
    async topKByEmbedding() { throw new Error("boom"); },
    async queryNeighborhood() { throw new Error("boom"); },
    async queryByType() { throw new Error("boom"); },
    async hybridResumeQuery() { throw new Error("boom"); },
    async healthCheck() { throw new Error("boom"); },
  };

  const service = new ContextGraphService(defaultConfig, { graphStore: throwingStore });

  // Should not throw
  await service.apply({
    type: "session.start",
    sessionId: "sess-1",
    payload: { memoryUserKey: "alice" },
    timestamp: "2026-03-16T00:00:00Z",
  });
});

test("apply is no-op when graphStore is undefined", async () => {
  const service = new ContextGraphService(defaultConfig, {});

  // Should resolve without error
  await service.apply({
    type: "session.start",
    sessionId: "sess-1",
    payload: { memoryUserKey: "alice" },
    timestamp: "2026-03-16T00:00:00Z",
  });
});

test("retrieveResumeContext returns formatted graph context", async () => {
  const hybridResult: ResumeNeighborhood = {
    goals: [{ id: "g1", type: "Goal", text: "Fix login bug", sessionId: "s1", createdAt: "", updatedAt: "" }],
    sessions: [],
    episodes: [{ id: "e1", type: "MemoryEpisode", summary: "Debugged auth flow", sessionId: "s1", memoryUserKey: "alice", createdAt: "", updatedAt: "" }],
    repos: [{ id: "r1", type: "Repo", name: "my-app", createdAt: "", updatedAt: "" }],
    branches: [{ id: "b1", type: "Branch", name: "fix/login", repoId: "r1", createdAt: "", updatedAt: "" }],
    blockers: [{ id: "bl1", type: "Blocker", text: "Waiting on API key", sessionId: "s1", createdAt: "", updatedAt: "" }],
    nextSteps: [{ id: "ns1", type: "NextStep", text: "Implement token refresh", sessionId: "s1", createdAt: "", updatedAt: "" }],
    decisions: [{ id: "d1", type: "Decision", text: "Use JWT tokens", sessionId: "s1", createdAt: "", updatedAt: "" }],
  };

  const { store } = makeMockGraphStore(hybridResult);
  const embedding = makeMockEmbeddingService();
  const service = new ContextGraphService(defaultConfig, { graphStore: store, embeddingService: embedding });

  const result = await service.retrieveResumeContext({ memoryUserKey: "alice", transcript: "What was I working on?" });

  assert.ok(result);
  assert.ok(result.includes("Prior context (graph):"));
  assert.ok(result.includes("Goal: Fix login bug"));
  assert.ok(result.includes("Session: Debugged auth flow"));
  assert.ok(result.includes("Repo: my-app"));
  assert.ok(result.includes("Branch: fix/login"));
  assert.ok(result.includes("Blocker: Waiting on API key"));
  assert.ok(result.includes("Next: Implement token refresh"));
  assert.ok(result.includes("Decision: Use JWT tokens"));
});

test("retrieveResumeContext falls back to memoryService when graphStore unavailable", async () => {
  let retrieveCalled = false;
  const mockMemoryService = {
    retrieveContext: async (input: { memoryUserKey: string; transcript?: string }) => {
      retrieveCalled = true;
      return "Fallback context from memory service";
    },
    summarizeAndStore: async () => null,
  } as unknown as MemoryService;

  const service = new ContextGraphService(defaultConfig, { memoryService: mockMemoryService });

  const result = await service.retrieveResumeContext({ memoryUserKey: "alice", transcript: "Hello" });

  assert.ok(retrieveCalled, "memoryService.retrieveContext should have been called");
  assert.equal(result, "Fallback context from memory service");
});

test("retrieveResumeContext falls back to memoryService when graph query returns empty", async () => {
  // Empty hybrid result (no goals, episodes, etc.)
  const emptyResult: ResumeNeighborhood = {
    goals: [], sessions: [], episodes: [], repos: [], branches: [], blockers: [], nextSteps: [], decisions: [],
  };

  const { store } = makeMockGraphStore(emptyResult);
  const embedding = makeMockEmbeddingService();

  let retrieveCalled = false;
  const mockMemoryService = {
    retrieveContext: async () => {
      retrieveCalled = true;
      return "Fallback from memory";
    },
    summarizeAndStore: async () => null,
  } as unknown as MemoryService;

  const service = new ContextGraphService(defaultConfig, {
    graphStore: store,
    embeddingService: embedding,
    memoryService: mockMemoryService,
  });

  const result = await service.retrieveResumeContext({ memoryUserKey: "alice", transcript: "What was I doing?" });

  assert.ok(retrieveCalled, "memoryService.retrieveContext should have been called as fallback");
  assert.equal(result, "Fallback from memory");
});

test("summarizeAndStore delegates to memoryService", async () => {
  const expectedDoc: MemoryDocument = {
    memoryUserKey: "alice",
    sessionId: "sess-1",
    timestamp: "2026-03-16T00:00:00Z",
    summary: "Test summary",
    decisions: ["d1"],
    nextSteps: ["n1"],
  };

  interface SummarizeCall { memoryUserKey: string; sessionId: string; history: unknown[]; workingContext?: WorkingContextSnapshot }
  let calledWith: SummarizeCall | null = null;
  const mockMemoryService = {
    retrieveContext: async () => null,
    summarizeAndStore: async (memoryUserKey: string, sessionId: string, history: unknown[], workingContext?: WorkingContextSnapshot) => {
      calledWith = { memoryUserKey, sessionId, history, workingContext };
      return expectedDoc;
    },
  } as unknown as MemoryService;

  const service = new ContextGraphService(defaultConfig, { memoryService: mockMemoryService });

  const history = [{ role: "user" as const, content: "Hello" }];
  const workingContext: WorkingContextSnapshot = { repo: "my-app", branch: "main" };

  const result = await service.summarizeAndStore("alice", "sess-1", history, workingContext);

  assert.ok(calledWith, "memoryService.summarizeAndStore should have been called");
  assert.equal((calledWith as SummarizeCall).memoryUserKey, "alice");
  assert.equal((calledWith as SummarizeCall).sessionId, "sess-1");
  assert.deepEqual(result, expectedDoc);
});

// --- Payload validation tests ---

test("apply session.start with empty memoryUserKey creates no nodes", async () => {
  const { store, calls } = makeMockGraphStore();
  const service = new ContextGraphService(defaultConfig, { graphStore: store });

  await service.apply({
    type: "session.start",
    sessionId: "sess-empty",
    payload: { memoryUserKey: "" },
    timestamp: "2026-03-16T00:00:00Z",
  });

  assert.equal(calls.upsertNode.length, 0, "no nodes should be created for empty memoryUserKey");
  assert.equal(calls.upsertEdge.length, 0, "no edges should be created for empty memoryUserKey");
});

test("apply goal.started with empty goalText creates no nodes", async () => {
  const { store, calls } = makeMockGraphStore();
  const service = new ContextGraphService(defaultConfig, { graphStore: store });

  await service.apply({
    type: "goal.started",
    sessionId: "sess-empty",
    payload: { goalText: "", memoryUserKey: "alice" },
    timestamp: "2026-03-16T00:00:00Z",
  });

  assert.equal(calls.upsertNode.length, 0, "no nodes should be created for empty goalText");
});

test("apply goal.started with empty memoryUserKey creates no nodes", async () => {
  const { store, calls } = makeMockGraphStore();
  const service = new ContextGraphService(defaultConfig, { graphStore: store });

  await service.apply({
    type: "goal.started",
    sessionId: "sess-empty",
    payload: { goalText: "Fix the bug", memoryUserKey: "" },
    timestamp: "2026-03-16T00:00:00Z",
  });

  assert.equal(calls.upsertNode.length, 0, "no nodes should be created for empty memoryUserKey");
});

test("apply session.finalized with empty summary creates no nodes", async () => {
  const { store, calls } = makeMockGraphStore();
  const service = new ContextGraphService(defaultConfig, { graphStore: store });

  await service.apply({
    type: "session.finalized",
    sessionId: "sess-empty",
    payload: { memoryUserKey: "alice", summary: "" },
    timestamp: "2026-03-16T00:00:00Z",
  });

  assert.equal(calls.upsertNode.length, 0, "no nodes should be created for empty summary");
});

test("apply session.finalized with empty memoryUserKey creates no nodes", async () => {
  const { store, calls } = makeMockGraphStore();
  const service = new ContextGraphService(defaultConfig, { graphStore: store });

  await service.apply({
    type: "session.finalized",
    sessionId: "sess-empty",
    payload: { memoryUserKey: "", summary: "Some summary" },
    timestamp: "2026-03-16T00:00:00Z",
  });

  assert.equal(calls.upsertNode.length, 0, "no nodes should be created for empty memoryUserKey");
});
