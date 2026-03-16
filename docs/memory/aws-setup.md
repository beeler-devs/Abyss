# AWS Setup for Memory

## S3 Bucket

Create (or reuse) a bucket to store conversation summaries.

```bash
aws s3api create-bucket \
  --bucket abyss-memory \
  --region us-east-1
```

Set `MEMORY_S3_BUCKET=abyss-memory` in `.env`. Summaries are written under the prefix controlled by `MEMORY_S3_PREFIX` (default: `memories/`).

### IAM Policy (add to `abyss-ecs-task-role`)

```json
{
  "Effect": "Allow",
  "Action": [
    "s3:PutObject",
    "s3:GetObject",
    "s3:ListObjectsV2"
  ],
  "Resource": "arn:aws:s3:::abyss-memory/*"
}
```

`ListObjectsV2` must also be granted on the bucket itself (not just `/*`):

```json
{
  "Effect": "Allow",
  "Action": "s3:ListBucket",
  "Resource": "arn:aws:s3:::abyss-memory"
}
```

---

## Optional: Bedrock Knowledge Base

Skip this section if you only want the S3 recent-memory fast path.

### 1. Create the Knowledge Base

In the AWS Console → Bedrock → Knowledge Bases → Create:

- **Embedding model**: `amazon.titan-embed-text-v2:0`
- **Vector store**: Amazon OpenSearch Serverless (auto-provisioned)
- **Data source**: S3 bucket `abyss-memory`, prefix `memories/`

Note the **Knowledge Base ID** (format: `XXXXXXXXXX`) and the **Data Source ID** — you will need both.

### 2. Additional IAM Permissions

Add to `abyss-ecs-task-role`:

```json
{
  "Effect": "Allow",
  "Action": [
    "bedrock:Retrieve",
    "bedrock:StartIngestionJob"
  ],
  "Resource": "arn:aws:bedrock:us-east-1::knowledge-base/*"
}
```

The summarization model (`bedrock:InvokeModel` for `us.amazon.nova-2-lite-v1:0`) should already be permitted if the existing task role covers Bedrock text inference.

### 3. Set Environment Variables

```
MEMORY_KB_ID=<your-kb-id>
MEMORY_KB_DATA_SOURCE_ID=<your-data-source-id>
```

`MEMORY_KB_DATA_SOURCE_ID` is required for the ingestion job trigger after each new summary is written. Without it, the KB will not automatically re-sync — you would need to trigger ingestion manually or on a schedule.

---

## Environment Variables

| Variable | Default | Notes |
|---|---|---|
| `MEMORY_ENABLED` | `false` | Set to `true` to enable |
| `MEMORY_S3_BUCKET` | — | S3 bucket name (required when enabled) |
| `MEMORY_S3_PREFIX` | `memories/` | S3 key prefix for all memory documents |
| `MEMORY_KB_ID` | — | Bedrock Knowledge Base ID (optional) |
| `MEMORY_KB_DATA_SOURCE_ID` | — | KB data source ID; required for auto-ingestion |
| `MEMORY_SUMMARY_MODEL_ID` | `us.amazon.nova-2-lite-v1:0` | Model used to generate summaries |
| `MEMORY_RETRIEVE_TIMEOUT_MS` | `1500` | Max ms to spend on retrieval before giving up |
| `MEMORY_MAX_INJECTED_CHARS` | `900` | Max characters injected into system prompt |
| `MEMORY_RECENT_COUNT` | `3` | Number of recent S3 summaries to fetch |

---

## Minimal Working Config (No KB)

The simplest way to enable memory — no vector store, no semantic search, just recent S3 summaries:

```env
MEMORY_ENABLED=true
MEMORY_S3_BUCKET=abyss-memory
```

All other variables use defaults. The S3 fast path will retrieve the 3 most recent summaries for the user on each new session.
