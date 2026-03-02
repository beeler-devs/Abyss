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

export interface BridgeRegisterPayload {
  pairingCode: string;
  deviceId: string;
  deviceName: string;
  workspaceRoot: string;
  capabilities: {
    execRun: boolean;
    readFile: boolean;
  };
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

export interface BridgeReadFileArgs {
  deviceId?: string;
  path: string;
}

export interface BridgeReadFileResult {
  content: string;
}
