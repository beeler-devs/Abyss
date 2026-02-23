import { ToolDefinition } from "../../core/types.js";
import { ToolExecutionContext, ToolExecutionResult, ToolRegistration } from "./types.js";

function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

export class ToolRegistry {
  private readonly tools = new Map<string, ToolRegistration>();

  register(tool: ToolRegistration): void {
    this.tools.set(tool.definition.name, tool);
  }

  registerMany(tools: ToolRegistration[]): void {
    for (const tool of tools) {
      this.register(tool);
    }
  }

  getDefinitions(): ToolDefinition[] {
    return [...this.tools.values()].map((entry) => entry.definition);
  }

  isClientTool(name: string): boolean {
    return this.tools.get(name)?.target === "client";
  }

  isServerTool(name: string): boolean {
    return this.tools.get(name)?.target === "server";
  }

  get(name: string): ToolRegistration | undefined {
    return this.tools.get(name);
  }

  async executeServerTool(
    name: string,
    context: ToolExecutionContext,
    args: Record<string, unknown>,
  ): Promise<ToolExecutionResult> {
    const tool = this.tools.get(name);
    if (!tool || tool.target !== "server" || !tool.execute) {
      return {
        ok: false,
        error: `unknown_server_tool:${name}`,
        sideEffect: "read",
      };
    }

    if (tool.supportsIdempotency) {
      const idempotencyKey = asString(args.idempotencyKey);
      if (idempotencyKey) {
        const key = `${name}:${idempotencyKey}`;
        const cached = context.session.idempotencyResults.get(key);
        if (cached) {
          try {
            return {
              ok: true,
              result: JSON.parse(cached) as unknown,
              sideEffect: tool.sideEffect,
            };
          } catch {
            context.session.idempotencyResults.delete(key);
          }
        }

        try {
          const result = await tool.execute(context, args);
          context.session.idempotencyResults.set(key, JSON.stringify(result));
          return {
            ok: true,
            result,
            sideEffect: tool.sideEffect,
          };
        } catch (error) {
          const message = error instanceof Error ? error.message : "unknown_tool_error";
          return {
            ok: false,
            error: message,
            sideEffect: tool.sideEffect,
          };
        }
      }
    }

    try {
      const result = await tool.execute(context, args);
      return {
        ok: true,
        result,
        sideEffect: tool.sideEffect,
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : "unknown_tool_error";
      return {
        ok: false,
        error: message,
        sideEffect: tool.sideEffect,
      };
    }
  }
}
