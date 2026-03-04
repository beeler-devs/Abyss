export const PROTOCOL_VERSION = 1;

export interface EventEnvelope {
  id: string;
  type: string;
  timestamp: string;
  sessionId: string;
  protocolVersion: number;
  payload: Record<string, unknown>;
}

export interface BridgePairRequestPayload {
  pairingCode: string;
  deviceName?: string;
}

export interface BridgeCapabilities {
  execRun: boolean;
  readFile: boolean;
  execStart?: boolean;
  execCancel?: boolean;
  execStatus?: boolean;
  execOutputEvents?: boolean;
  fsSearch?: boolean;
  fsReadRange?: boolean;
  fsApplyPatch?: boolean;
  gitStatus?: boolean;
  gitDiff?: boolean;
  gitStage?: boolean;
  gitCommit?: boolean;
  gitPush?: boolean;
  claudeRun?: boolean;
}

export interface BridgeRegisterPayload {
  pairingCode: string;
  deviceId: string;
  deviceName: string;
  workspaceRoot: string;
  workspaceRoots?: string[];
  capabilities: BridgeCapabilities;
  protocolVersion: number;
}

export interface BridgeExecRunArgs {
  deviceId?: string;
  command: string;
  cwd?: string;
  timeoutSec?: number;
}

export interface BridgeExecRunResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

export interface BridgeExecStartArgs {
  deviceId?: string;
  command: string;
  cwd?: string;
  env?: Record<string, string>;
  timeoutSec?: number;
}

export interface BridgeExecStartResult {
  commandId: string;
  startedAt: string;
}

export interface BridgeExecCancelArgs {
  deviceId?: string;
  commandId: string;
}

export interface BridgeExecCancelResult {
  cancelled: boolean;
}

export interface BridgeExecStatusArgs {
  deviceId?: string;
  commandId: string;
}

export type BridgeExecState = "running" | "finished" | "failed" | "cancelled" | "timed_out";

export interface BridgeExecStatusResult {
  state: BridgeExecState;
  exitCode?: number;
}

export interface BridgeExecOutputSubscribeArgs {
  deviceId?: string;
  commandId: string;
}

export interface BridgeExecOutputSubscribeResult {
  subscribed: boolean;
}

export interface BridgeExecOutputEventPayload {
  deviceId: string;
  commandId: string;
  stream: "stdout" | "stderr";
  chunk: string;
  isFinal: boolean;
}

export interface BridgeExecFinishedEventPayload {
  deviceId: string;
  commandId: string;
  exitCode: number;
  stdoutTail: string;
  stderrTail: string;
}

export interface BridgeReadFileArgs {
  deviceId?: string;
  path: string;
}

export interface BridgeReadFileResult {
  content: string;
}

export interface BridgeSearchArgs {
  deviceId?: string;
  query: string;
  root?: string;
  globs?: string[];
  maxResults?: number;
}

export interface BridgeSearchMatch {
  path: string;
  line: number;
  snippet: string;
}

export interface BridgeSearchResult {
  matches: BridgeSearchMatch[];
}

export interface BridgeReadRangeArgs {
  deviceId?: string;
  path: string;
  startLine: number;
  endLine: number;
}

export interface BridgeReadRangeResult {
  content: string;
}

export interface BridgeApplyPatchConstraints {
  allowedPaths?: string[];
  noReformat?: boolean;
  maxDiffLines?: number;
}

export interface BridgeApplyPatchArgs {
  deviceId?: string;
  unifiedDiff: string;
  constraints?: BridgeApplyPatchConstraints;
}

export interface BridgeApplyPatchResult {
  applied: boolean;
  filesChanged: string[];
  reason?: string;
}

export interface BridgeGitStatusArgs {
  deviceId?: string;
}

export interface BridgeGitStatusResult {
  branch: string;
  changedFiles: string[];
  stagedFiles: string[];
}

export interface BridgeGitDiffArgs {
  deviceId?: string;
  staged?: boolean;
}

export interface BridgeGitDiffResult {
  diff: string;
  truncated?: boolean;
  tail?: string;
}

export interface BridgeGitStageArgs {
  deviceId?: string;
  paths: string[];
}

export interface BridgeGitStageResult {
  staged: string[];
}

export interface BridgeGitCommitArgs {
  deviceId?: string;
  message: string;
}

export interface BridgeGitCommitResult {
  commitSha: string;
}

export interface BridgeGitPushArgs {
  deviceId?: string;
  remote: string;
  branch: string;
}

export interface BridgeGitPushResult {
  pushed: boolean;
}

export interface BridgeClaudeRunArgs {
  deviceId?: string;
  prompt: string;
  cwd?: string;
  timeoutSec?: number;
  allowedTools?: string;
  maxTurns?: number;
}

export interface BridgeClaudeRunResult {
  result: string;
  sessionId?: string;
}
