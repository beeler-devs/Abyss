import { EmbeddingService } from "../src/contextGraph/embedding/embeddingService.js";
const svc = new EmbeddingService({
  modelId: "amazon.titan-embed-text-v2:0",
  dimensions: 256,
  awsRegion: "us-east-1",
});
svc.embed("Fix the login bug in the auth module").then(vec => {
  console.log(`Embedding OK: ${vec.length} dimensions, first 5: [${vec.slice(0, 5).map(v => v.toFixed(4)).join(", ")}]`);
  process.exit(0);
}).catch(err => {
  console.error("Embedding error:", err.message);
  process.exit(1);
});
