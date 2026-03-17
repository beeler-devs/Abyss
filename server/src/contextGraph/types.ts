export type GraphNodeType =
  | "User"
  | "Session"
  | "Goal"
  | "Repo"
  | "Branch"
  | "Decision"
  | "Blocker"
  | "NextStep"
  | "MemoryEpisode";

export interface GraphNodeBase {
  id: string;
  type: GraphNodeType;
  createdAt: string;
  updatedAt: string;
}

export interface UserNode extends GraphNodeBase {
  type: "User";
  memoryUserKey: string;
}

export interface SessionNode extends GraphNodeBase {
  type: "Session";
  sessionId: string;
  startedAt: string;
  endedAt?: string;
}

export interface GoalNode extends GraphNodeBase {
  type: "Goal";
  text: string;
  sessionId: string;
}

export interface RepoNode extends GraphNodeBase {
  type: "Repo";
  name: string;
}

export interface BranchNode extends GraphNodeBase {
  type: "Branch";
  name: string;
  repoId: string;
}

export interface DecisionNode extends GraphNodeBase {
  type: "Decision";
  text: string;
  sessionId: string;
}

export interface BlockerNode extends GraphNodeBase {
  type: "Blocker";
  text: string;
  sessionId: string;
}

export interface NextStepNode extends GraphNodeBase {
  type: "NextStep";
  text: string;
  sessionId: string;
}

export interface MemoryEpisodeNode extends GraphNodeBase {
  type: "MemoryEpisode";
  summary: string;
  sessionId: string;
  memoryUserKey: string;
}

export type GraphNode =
  | UserNode
  | SessionNode
  | GoalNode
  | RepoNode
  | BranchNode
  | DecisionNode
  | BlockerNode
  | NextStepNode
  | MemoryEpisodeNode;

export interface GraphEdge {
  fromId: string;
  toId: string;
  label: string;
  properties?: Record<string, unknown>;
}

export interface GraphSubgraph {
  nodes: GraphNode[];
  edges: GraphEdge[];
}

export interface ResumeNeighborhood {
  goals: GoalNode[];
  sessions: SessionNode[];
  episodes: MemoryEpisodeNode[];
  repos: RepoNode[];
  branches: BranchNode[];
  blockers: BlockerNode[];
  nextSteps: NextStepNode[];
  decisions: DecisionNode[];
}

export type ContextGraphUpdate =
  | { type: "session.start"; sessionId: string; payload: { memoryUserKey: string }; timestamp: string }
  | { type: "goal.started"; sessionId: string; payload: { goalText: string; memoryUserKey: string }; timestamp: string }
  | {
      type: "session.finalized";
      sessionId: string;
      payload: {
        memoryUserKey: string;
        workingContext?: { repo?: string; branch?: string; prUrl?: string; lastGoal?: string; activeExecutor?: string };
        summary: string;
        decisions?: string[];
        blockers?: string[];
        nextSteps?: string[];
      };
      timestamp: string;
    };
