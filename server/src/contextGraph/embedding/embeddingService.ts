import { BedrockRuntimeClient, InvokeModelCommand } from "@aws-sdk/client-bedrock-runtime";

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
    return result.embedding;
  }

  async embedBatch(texts: string[]): Promise<number[][]> {
    return Promise.all(texts.map((t) => this.embed(t)));
  }
}
