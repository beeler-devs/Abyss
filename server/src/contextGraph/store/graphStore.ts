import { GraphNode, GraphNodeType, GraphSubgraph, ResumeNeighborhood } from "../types.js";

export interface GraphStore {
  upsertNode(node: GraphNode): Promise<void>;
  deleteNode(id: string): Promise<void>;
  upsertEdge(fromId: string, toId: string, label: string, properties?: Record<string, unknown>): Promise<void>;
  upsertEmbedding(nodeId: string, label: string, embedding: number[]): Promise<void>;
  topKByEmbedding(embedding: number[], k: number, label?: GraphNodeType): Promise<Array<{ nodeId: string; score: number }>>;
  queryNeighborhood(startId: string, maxDepth: number): Promise<GraphSubgraph>;
  queryByType(type: GraphNodeType): Promise<GraphNode[]>;
  hybridResumeQuery(embedding: number[], memoryUserKey: string, k: number): Promise<ResumeNeighborhood>;
  healthCheck(): Promise<boolean>;
}
