import {
  NeptuneGraphClient,
  ExecuteQueryCommand,
} from "@aws-sdk/client-neptune-graph";

import { logger } from "../../core/logger.js";
import {
  GraphNode,
  GraphNodeType,
  GraphSubgraph,
  ResumeNeighborhood,
  GoalNode,
  SessionNode,
  MemoryEpisodeNode,
  RepoNode,
  BranchNode,
  BlockerNode,
  NextStepNode,
  DecisionNode,
} from "../types.js";
import { GraphStore } from "./graphStore.js";

export interface NeptuneAnalyticsStoreConfig {
  graphId: string;
  endpoint?: string;
  region: string;
}

export interface NeptuneAnalyticsStoreClients {
  neptune?: NeptuneGraphClient;
}

export class NeptuneAnalyticsStore implements GraphStore {
  private readonly graphId: string;
  private readonly neptune: NeptuneGraphClient;

  constructor(
    config: NeptuneAnalyticsStoreConfig,
    clients?: NeptuneAnalyticsStoreClients,
  ) {
    this.graphId = config.graphId;
    this.neptune =
      clients?.neptune ??
      new NeptuneGraphClient({
        region: config.region,
        ...(config.endpoint ? { endpoint: config.endpoint } : {}),
      });
    logger.info(`[neptune] initialized — graphId=${config.graphId} region=${config.region} endpoint=${config.endpoint ?? "default"}`);
  }

  private async executeQuery(
    query: string,
    parameters?: Record<string, unknown>,
  ): Promise<Record<string, unknown>[]> {
    const start = Date.now();
    const queryPreview = query.replace(/\s+/g, " ").slice(0, 120);
    const command = new ExecuteQueryCommand({
      graphIdentifier: this.graphId,
      queryString: query,
      language: "OPEN_CYPHER" as any,
      parameters: parameters as any,
    });
    try {
      const response = await this.neptune.send(command);
      // Neptune Analytics returns results as a payload (Uint8Array)
      if (!response.payload) {
        logger.info(`[neptune] query ok durationMs=${Date.now() - start} rows=0 query="${queryPreview}"`);
        return [];
      }
      // SDK payload type is StreamingBlobPayloadOutputTypes; cast through unknown for mock compatibility
      const raw = response.payload as unknown;
      const bytes = raw instanceof Uint8Array
        ? raw
        : await new Response(raw as ReadableStream).arrayBuffer().then((ab) => new Uint8Array(ab));
      const text = new TextDecoder().decode(bytes);
      const parsed = JSON.parse(text) as {
        results?: Record<string, unknown>[];
      };
      const results = parsed.results ?? [];
      logger.info(`[neptune] query ok durationMs=${Date.now() - start} rows=${results.length} query="${queryPreview}"`);
      return results;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      logger.error(`[neptune] query failed durationMs=${Date.now() - start} query="${queryPreview}" error=${msg}`);
      throw err;
    }
  }

  async upsertNode(node: GraphNode): Promise<void> {
    const { id, type, ...props } = node;
    const setParts = Object.entries(props)
      .map(([k]) => `n.${k} = $${k}`)
      .join(", ");
    const query = `MERGE (n:${type} {id: $id}) SET ${setParts}, n.updatedAt = $updatedAt`;
    const parameters: Record<string, unknown> = { id, ...props };
    if (!parameters.updatedAt) parameters.updatedAt = new Date().toISOString();
    await this.executeQuery(query, parameters);
  }

  async deleteNode(id: string): Promise<void> {
    await this.executeQuery("MATCH (n {id: $id}) DETACH DELETE n", { id });
  }

  async upsertEdge(
    fromId: string,
    toId: string,
    label: string,
    properties?: Record<string, unknown>,
  ): Promise<void> {
    const propSet = properties
      ? ", " +
        Object.entries(properties)
          .map(([k]) => `r.${k} = $prop_${k}`)
          .join(", ")
      : "";
    const params: Record<string, unknown> = { fromId, toId };
    if (properties) {
      for (const [k, v] of Object.entries(properties)) {
        params[`prop_${k}`] = v;
      }
    }
    await this.executeQuery(
      `MATCH (a {id: $fromId}), (b {id: $toId}) MERGE (a)-[r:${label}]->(b)${propSet}`,
      params,
    );
  }

  async upsertEmbedding(
    nodeId: string,
    label: string,
    embedding: number[],
  ): Promise<void> {
    await this.executeQuery(
      `CALL neptune.algo.vectors.upsert(node_id := $nodeId, label := $label, embedding := $embedding)`,
      { nodeId, label, embedding },
    );
  }

  async topKByEmbedding(
    embedding: number[],
    k: number,
    label?: GraphNodeType,
  ): Promise<Array<{ nodeId: string; score: number }>> {
    const labelParam = label ? `, label := '${label}'` : "";
    const results = await this.executeQuery(
      `CALL neptune.algo.vectors.topKByEmbedding(embedding := $embedding, k := $k${labelParam}) YIELD node, score RETURN node.id AS nodeId, score`,
      { embedding, k },
    );
    return results.map((r) => ({
      nodeId: r.nodeId as string,
      score: r.score as number,
    }));
  }

  async queryNeighborhood(
    startId: string,
    maxDepth: number,
  ): Promise<GraphSubgraph> {
    const results = await this.executeQuery(
      `MATCH path = (start {id: $startId})-[*1..${maxDepth}]-(neighbor)
       UNWIND nodes(path) AS n
       UNWIND relationships(path) AS r
       RETURN DISTINCT
         n.id AS nodeId, labels(n)[0] AS nodeType, properties(n) AS nodeProps,
         startNode(r).id AS fromId, endNode(r).id AS toId, type(r) AS edgeLabel`,
      { startId },
    );

    const nodesMap = new Map<string, GraphNode>();
    const edges: Array<{ fromId: string; toId: string; label: string }> = [];

    for (const row of results) {
      if (row.nodeId && !nodesMap.has(row.nodeId as string)) {
        const props = (row.nodeProps ?? {}) as Record<string, unknown>;
        nodesMap.set(row.nodeId as string, {
          id: row.nodeId as string,
          type: ((row.nodeType as GraphNodeType) ?? "Session"),
          createdAt: (props.createdAt as string) ?? "",
          updatedAt: (props.updatedAt as string) ?? "",
          ...props,
        } as GraphNode);
      }
      if (row.fromId && row.toId) {
        edges.push({
          fromId: row.fromId as string,
          toId: row.toId as string,
          label: (row.edgeLabel as string) ?? "",
        });
      }
    }

    return { nodes: Array.from(nodesMap.values()), edges };
  }

  async queryByType(type: GraphNodeType): Promise<GraphNode[]> {
    const results = await this.executeQuery(
      `MATCH (n:${type}) RETURN properties(n) AS props`,
    );
    return results.map((r) => {
      const props = (r.props ?? {}) as Record<string, unknown>;
      return {
        type,
        ...props,
        id: props.id as string,
        createdAt: (props.createdAt as string) ?? "",
        updatedAt: (props.updatedAt as string) ?? "",
      } as GraphNode;
    });
  }

  async hybridResumeQuery(
    embedding: number[],
    memoryUserKey: string,
    k: number,
  ): Promise<ResumeNeighborhood> {
    // Step 1: Find top-K similar Goal nodes via vector search
    const vectorResults = await this.executeQuery(
      `CALL neptune.algo.vectors.topKByEmbedding(embedding := $embedding, k := $k, label := 'Goal')
       YIELD node, score
       RETURN node.id AS goalId, node.text AS goalText, node.sessionId AS sessionId, score`,
      { embedding, k },
    );

    if (vectorResults.length === 0) {
      return {
        goals: [],
        sessions: [],
        episodes: [],
        repos: [],
        branches: [],
        blockers: [],
        nextSteps: [],
        decisions: [],
      };
    }

    const goalIds = vectorResults.map((r) => r.goalId as string);
    const sessionIds = [
      ...new Set(
        vectorResults
          .map((r) => r.sessionId as string)
          .filter(Boolean),
      ),
    ];

    // Step 2: Traverse graph from matched sessions to get neighborhood
    const neighborhoodResults = await this.executeQuery(
      `MATCH (u:User {memoryUserKey: $memoryUserKey})-[:STARTED]->(s:Session)
       WHERE s.sessionId IN $sessionIds
       OPTIONAL MATCH (s)<-[:IN_SESSION]-(ep:MemoryEpisode)
       OPTIONAL MATCH (s)-[:USED_REPO]->(repo:Repo)
       OPTIONAL MATCH (s)-[:ON_BRANCH]->(branch:Branch)
       OPTIONAL MATCH (s)<-[:IN_SESSION]-(b:Blocker)
       OPTIONAL MATCH (s)<-[:IN_SESSION]-(ns:NextStep)
       OPTIONAL MATCH (s)<-[:IN_SESSION]-(d:Decision)
       RETURN s, ep, repo, branch, b, ns, d`,
      { memoryUserKey, sessionIds },
    );

    const result: ResumeNeighborhood = {
      goals: vectorResults.map((r) => ({
        id: r.goalId as string,
        type: "Goal" as const,
        text: (r.goalText as string) ?? "",
        sessionId: (r.sessionId as string) ?? "",
        createdAt: "",
        updatedAt: "",
      })),
      sessions: [],
      episodes: [],
      repos: [],
      branches: [],
      blockers: [],
      nextSteps: [],
      decisions: [],
    };

    const seen = new Set<string>();

    for (const row of neighborhoodResults) {
      this.collectNode<SessionNode>(row.s, "Session", result.sessions, seen);
      this.collectNode<MemoryEpisodeNode>(row.ep, "MemoryEpisode", result.episodes, seen);
      this.collectNode<RepoNode>(row.repo, "Repo", result.repos, seen);
      this.collectNode<BranchNode>(row.branch, "Branch", result.branches, seen);
      this.collectNode<BlockerNode>(row.b, "Blocker", result.blockers, seen);
      this.collectNode<NextStepNode>(row.ns, "NextStep", result.nextSteps, seen);
      this.collectNode<DecisionNode>(row.d, "Decision", result.decisions, seen);
    }

    return result;
  }

  private collectNode<T>(
    raw: unknown,
    type: string,
    arr: T[],
    seen: Set<string>,
  ): void {
    if (!raw || typeof raw !== "object") return;
    const node = raw as Record<string, unknown>;
    const id = node.id as string;
    if (!id || seen.has(id)) return;
    seen.add(id);
    arr.push({
      type,
      ...node,
      id,
      createdAt: (node.createdAt as string) ?? "",
      updatedAt: (node.updatedAt as string) ?? "",
    } as T);
  }
}
