import { ContextBundle } from "../context/contextEngine.js";

export interface PatchGenerationResult {
  unifiedDiff: string;
  summaryForVoice: string;
}

export interface PatchGenerationRequest {
  provider?: string;
  model?: string;
  contextBundle: ContextBundle;
  constraints: {
    maxDiffLines?: number;
    allowedPaths?: string[];
    noReformat?: boolean;
    mustFixSignature?: string;
  };
}

export interface PatchGenerationProvider {
  readonly name: string;
  generateDiff(request: PatchGenerationRequest): Promise<PatchGenerationResult>;
}

function extractUnifiedDiff(text: string): string {
  const fenced = text.match(/```diff\n([\s\S]*?)```/);
  if (fenced?.[1]) {
    return fenced[1].trim();
  }

  const start = text.indexOf("--- ");
  if (start >= 0) {
    return text.slice(start).trim();
  }

  return text.trim();
}

export class AnthropicPatchGenerationProvider implements PatchGenerationProvider {
  readonly name = "anthropic-patch";

  private readonly apiKey: string;
  private readonly defaultModel: string;

  constructor(apiKey: string, defaultModel: string) {
    this.apiKey = apiKey;
    this.defaultModel = defaultModel;
  }

  async generateDiff(request: PatchGenerationRequest): Promise<PatchGenerationResult> {
    const model = request.model ?? this.defaultModel;

    const prompt = [
      "You are generating a minimal safe unified diff to fix a failing CI test.",
      "Return ONLY a unified diff (no explanations) with `---` / `+++` file headers and hunks.",
      "Do not touch lockfiles unless explicitly allowed.",
      "Respect max diff lines and no-reformat constraints.",
      "",
      `Goal: ${request.contextBundle.goal}`,
      `Failure summary: ${request.contextBundle.failureSummary}`,
      `Must fix signature: ${request.constraints.mustFixSignature ?? "n/a"}`,
      `Allowed paths: ${(request.constraints.allowedPaths ?? []).join(", ") || "any"}`,
      `Max diff lines: ${request.constraints.maxDiffLines ?? 200}`,
      "",
      "Logs excerpt:",
      request.contextBundle.logsExcerpt,
      "",
      "Full files:",
      ...request.contextBundle.fullFiles.map((file) => `FILE ${file.path}\n${file.content}`),
      "",
      "Snippets:",
      ...request.contextBundle.snippets.map((snippet) => `SNIPPET ${snippet.path}:${snippet.startLine}-${snippet.endLine}\n${snippet.text}`),
      "",
      "Configs:",
      ...request.contextBundle.configs.map((config) => `CONFIG ${config.path}\n${config.content}`),
      "",
      "Current PR diff:",
      ...(request.contextBundle.currentPrDiff ?? []).map((file) => `PRDIFF ${file.path}\n${file.patch}`),
    ].join("\n");

    const response = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": this.apiKey,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model,
        max_tokens: 2048,
        messages: [
          {
            role: "user",
            content: prompt,
          },
        ],
      }),
      signal: AbortSignal.timeout(45_000),
    });

    if (!response.ok) {
      const body = await response.text();
      throw new Error(`anthropic_patch_http_${response.status}:${body.slice(0, 200)}`);
    }

    const payload = await response.json() as { content?: Array<{ type?: string; text?: string }> };
    const text = (payload.content ?? [])
      .filter((block) => block.type === "text" && typeof block.text === "string")
      .map((block) => block.text ?? "")
      .join("\n")
      .trim();

    const unifiedDiff = extractUnifiedDiff(text);

    if (!unifiedDiff.startsWith("--- ")) {
      throw new Error("patch_provider_returned_non_diff_output");
    }

    return {
      unifiedDiff,
      summaryForVoice: "I generated a focused patch for the failing test and pushed it to the PR branch.",
    };
  }
}

export class DeterministicFallbackPatchProvider implements PatchGenerationProvider {
  readonly name = "deterministic-fallback";

  async generateDiff(_request: PatchGenerationRequest): Promise<PatchGenerationResult> {
    throw new Error("fallback_provider_requires_explicit_diff_input");
  }
}
