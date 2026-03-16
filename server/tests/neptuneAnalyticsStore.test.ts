import test from "node:test";
import assert from "node:assert/strict";
import { NeptuneAnalyticsStore } from "../src/contextGraph/store/neptuneAnalyticsStore.js";

function makeStore(responses: Record<string, unknown>[][] = []) {
  let callIndex = 0;
  const queries: string[] = [];
  const paramsList: Array<Record<string, unknown> | undefined> = [];
  const mockNeptune = {
    send: async (cmd: unknown) => {
      const c = cmd as { input?: { queryString?: string; parameters?: Record<string, unknown> } };
      queries.push(c.input?.queryString ?? "");
      paramsList.push(c.input?.parameters);
      const result = responses[callIndex] ?? [];
      callIndex++;
      return {
        payload: new TextEncoder().encode(JSON.stringify({ results: result })),
      };
    },
  };
  const store = new NeptuneAnalyticsStore(
    { graphId: "test-graph", region: "us-east-1" },
    { neptune: mockNeptune as never },
  );
  return { store, queries, paramsList };
}

test("upsertNode sends MERGE query with correct label", async () => {
  const { store, queries } = makeStore([[]]);
  await store.upsertNode({
    id: "goal-1",
    type: "Goal",
    text: "Fix the bug",
    sessionId: "sess-1",
    createdAt: "2026-01-01T00:00:00Z",
    updatedAt: "2026-01-01T00:00:00Z",
  });
  assert.equal(queries.length, 1);
  assert.ok(queries[0].includes("MERGE (n:Goal {id: $id})"), "query should MERGE with Goal label");
  assert.ok(queries[0].includes("SET"), "query should include SET clause");
});

test("deleteNode sends DETACH DELETE", async () => {
  const { store, queries } = makeStore([[]]);
  await store.deleteNode("node-42");
  assert.equal(queries.length, 1);
  assert.ok(queries[0].includes("DETACH DELETE"), "query should contain DETACH DELETE");
  assert.ok(queries[0].includes("{id: $id}"), "query should match by id parameter");
});

test("upsertEdge sends MERGE relationship", async () => {
  const { store, queries } = makeStore([[]]);
  await store.upsertEdge("a-1", "b-2", "STARTED", { weight: 1.0 });
  assert.equal(queries.length, 1);
  assert.ok(queries[0].includes("MERGE (a)-[r:STARTED]->(b)"), "query should MERGE with STARTED label");
  assert.ok(queries[0].includes("r.weight = $prop_weight"), "query should set edge properties");
});

test("upsertEdge without properties omits SET clause", async () => {
  const { store, queries } = makeStore([[]]);
  await store.upsertEdge("a-1", "b-2", "IN_SESSION");
  assert.equal(queries.length, 1);
  assert.ok(queries[0].includes("MERGE (a)-[r:IN_SESSION]->(b)"), "query should MERGE with edge label");
  assert.ok(!queries[0].includes("r."), "query should not contain property assignments");
});

test("topKByEmbedding returns scored results", async () => {
  const { store, queries } = makeStore([
    [{ nodeId: "g1", score: 0.95 }, { nodeId: "g2", score: 0.82 }],
  ]);
  const results = await store.topKByEmbedding([0.1, 0.2, 0.3], 5, "Goal");
  assert.equal(results.length, 2);
  assert.equal(results[0].nodeId, "g1");
  assert.equal(results[0].score, 0.95);
  assert.equal(results[1].nodeId, "g2");
  assert.equal(results[1].score, 0.82);
  assert.ok(queries[0].includes("topKByEmbedding"), "query should use vector search");
  assert.ok(queries[0].includes("label := 'Goal'"), "query should filter by label");
});

test("topKByEmbedding without label omits label parameter", async () => {
  const { store, queries } = makeStore([[{ nodeId: "n1", score: 0.5 }]]);
  await store.topKByEmbedding([0.1], 3);
  assert.ok(!queries[0].includes("label :="), "query should not include label filter");
});

test("hybridResumeQuery returns empty neighborhood when no vectors match", async () => {
  const { store } = makeStore([
    [], // vector search returns nothing
  ]);
  const result = await store.hybridResumeQuery([0.1, 0.2], "user-1", 5);
  assert.deepEqual(result.goals, []);
  assert.deepEqual(result.sessions, []);
  assert.deepEqual(result.episodes, []);
  assert.deepEqual(result.repos, []);
  assert.deepEqual(result.branches, []);
  assert.deepEqual(result.blockers, []);
  assert.deepEqual(result.nextSteps, []);
  assert.deepEqual(result.decisions, []);
});

test("hybridResumeQuery performs vector search then graph traversal", async () => {
  const { store, queries } = makeStore([
    // First call: vector search returns matching goals
    [
      { goalId: "goal-1", goalText: "Implement auth", sessionId: "sess-1", score: 0.9 },
      { goalId: "goal-2", goalText: "Add tests", sessionId: "sess-2", score: 0.7 },
    ],
    // Second call: graph traversal returns session neighborhood
    [
      {
        s: { id: "sess-1", sessionId: "sess-1", startedAt: "2026-01-01", createdAt: "2026-01-01", updatedAt: "2026-01-01" },
        ep: { id: "ep-1", summary: "Worked on auth", sessionId: "sess-1", memoryUserKey: "user-1", createdAt: "2026-01-01", updatedAt: "2026-01-01" },
        repo: { id: "repo-1", name: "my-app", createdAt: "2026-01-01", updatedAt: "2026-01-01" },
        branch: null,
        b: null,
        ns: { id: "ns-1", text: "Add OAuth", sessionId: "sess-1", createdAt: "2026-01-01", updatedAt: "2026-01-01" },
        d: null,
      },
    ],
  ]);

  const result = await store.hybridResumeQuery([0.1, 0.2], "user-1", 5);

  // Should have made 2 queries: vector search + graph traversal
  assert.equal(queries.length, 2);
  assert.ok(queries[0].includes("topKByEmbedding"), "first query should be vector search");
  assert.ok(queries[1].includes("MATCH (u:User"), "second query should be graph traversal");

  // Goals from vector search
  assert.equal(result.goals.length, 2);
  assert.equal(result.goals[0].id, "goal-1");
  assert.equal(result.goals[0].text, "Implement auth");

  // Neighborhood from graph traversal
  assert.equal(result.sessions.length, 1);
  assert.equal(result.episodes.length, 1);
  assert.equal(result.repos.length, 1);
  assert.equal(result.nextSteps.length, 1);
  assert.equal(result.branches.length, 0);
  assert.equal(result.blockers.length, 0);
  assert.equal(result.decisions.length, 0);
});

test("queryNeighborhood returns subgraph with nodes and edges", async () => {
  const { store } = makeStore([
    [
      {
        nodeId: "sess-1",
        nodeType: "Session",
        nodeProps: { id: "sess-1", sessionId: "sess-1", startedAt: "2026-01-01", createdAt: "2026-01-01", updatedAt: "2026-01-01" },
        fromId: "sess-1",
        toId: "goal-1",
        edgeLabel: "HAS_GOAL",
      },
      {
        nodeId: "goal-1",
        nodeType: "Goal",
        nodeProps: { id: "goal-1", text: "Fix bug", sessionId: "sess-1", createdAt: "2026-01-01", updatedAt: "2026-01-01" },
        fromId: "sess-1",
        toId: "goal-1",
        edgeLabel: "HAS_GOAL",
      },
    ],
  ]);

  const subgraph = await store.queryNeighborhood("sess-1", 2);
  assert.equal(subgraph.nodes.length, 2);
  assert.equal(subgraph.edges.length, 2); // Both rows produce edge entries (dedupe is on nodes only)
  assert.ok(subgraph.nodes.some((n) => n.id === "sess-1"));
  assert.ok(subgraph.nodes.some((n) => n.id === "goal-1"));
});

test("queryByType returns nodes of the specified type", async () => {
  const { store, queries } = makeStore([
    [
      { props: { id: "r1", name: "repo-alpha", createdAt: "2026-01-01", updatedAt: "2026-01-01" } },
      { props: { id: "r2", name: "repo-beta", createdAt: "2026-01-02", updatedAt: "2026-01-02" } },
    ],
  ]);

  const nodes = await store.queryByType("Repo");
  assert.equal(nodes.length, 2);
  assert.equal(nodes[0].type, "Repo");
  assert.equal((nodes[0] as any).name, "repo-alpha");
  assert.ok(queries[0].includes("MATCH (n:Repo)"), "query should match by Repo label");
});

test("upsertEmbedding calls neptune.algo.vectors.upsert", async () => {
  const { store, queries } = makeStore([[]]);
  await store.upsertEmbedding("goal-1", "Goal", [0.1, 0.2, 0.3]);
  assert.equal(queries.length, 1);
  assert.ok(queries[0].includes("neptune.algo.vectors.upsert"), "query should call vector upsert");
});

test("executeQuery handles empty payload gracefully", async () => {
  const mockNeptune = {
    send: async () => ({ payload: undefined }),
  };
  const store = new NeptuneAnalyticsStore(
    { graphId: "test-graph", region: "us-east-1" },
    { neptune: mockNeptune as never },
  );
  const nodes = await store.queryByType("Session");
  assert.deepEqual(nodes, []);
});
