import { BedrockRuntimeClient, InvokeModelCommand } from "@aws-sdk/client-bedrock-runtime";
import { logger } from "../../core/logger.js";

export interface EmbeddingServiceConfig {
  modelId: string;
  dimensions: number;
  awsRegion: string;
}

export interface EmbeddingServiceClients {
  bedrock?: BedrockRuntimeClient;
}

export class EmbeddingService {
  private readonly config: EmbeddingServiceConfig;
  private readonly bedrock: BedrockRuntimeClient;

  constructor(config: EmbeddingServiceConfig, clients?: EmbeddingServiceClients) {
    this.config = config;
    this.bedrock = clients?.bedrock ?? new BedrockRuntimeClient({ region: config.awsRegion });
  }

  async embed(text: string): Promise<number[]> {
    const start = Date.now();
    const textPreview = text.slice(0, 60).replace(/\n/g, " ");
    try {
      const response = await this.bedrock.send(
        new InvokeModelCommand({
          modelId: this.config.modelId,
          contentType: "application/json",
          accept: "application/json",
          body: JSON.stringify({
            inputText: text,
            dimensions: this.config.dimensions,
          }),
        }),
      );
      const result = JSON.parse(new TextDecoder().decode(response.body)) as { embedding: number[] };
      logger.info(`[embedding] embed ok durationMs=${Date.now() - start} dims=${result.embedding.length} text="${textPreview}"`);
      return result.embedding;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      logger.error(`[embedding] embed failed durationMs=${Date.now() - start} text="${textPreview}" error=${msg}`);
      throw err;
    }
  }

  async embedBatch(texts: string[]): Promise<number[][]> {
    logger.info(`[embedding] embedBatch start count=${texts.length}`);
    const results = await Promise.all(texts.map((t) => this.embed(t)));
    logger.info(`[embedding] embedBatch done count=${texts.length}`);
    return results;
  }
}
