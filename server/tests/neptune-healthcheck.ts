import { NeptuneAnalyticsStore } from "../src/contextGraph/store/neptuneAnalyticsStore.js";
const store = new NeptuneAnalyticsStore({
  graphId: "g-ntjx5zxri9",
  region: "us-east-1",
});
store.healthCheck().then(ok => {
  console.log("Health check:", ok ? "PASSED" : "FAILED");
  process.exit(0);
}).catch(err => {
  console.error("Health check error:", err.message);
  process.exit(1);
});
