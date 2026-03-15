# Abyss Server — Deploy & Run Guide

## 1. Local Dev

```bash
cd server
cp .env.example .env   # edit as needed
npm install
npm run dev
```

Server starts on `http://localhost:8080`. Health check: `GET /healthz`.

## 2. Bedrock Smoke Test

Verifies your AWS credentials and Bedrock access independently of WebSocket/iOS/Sonic.

```bash
cd server
AWS_PROFILE=your-profile npm run smoke:bedrock
```

This constructs the Bedrock provider directly, sends one user turn, and prints the response. Exits nonzero on failure.

## 3. Local Docker Run

```bash
cd server
docker build -t abyss-server .
docker run --rm -p 8080:8080 \
  -e MODEL_PROVIDER=bedrock \
  -e AWS_REGION=us-east-1 \
  -e AWS_ACCESS_KEY_ID="$(aws configure get aws_access_key_id)" \
  -e AWS_SECRET_ACCESS_KEY="$(aws configure get aws_secret_access_key)" \
  -e AWS_SESSION_TOKEN="$(aws configure get aws_session_token)" \
  abyss-server
```

Verify: `curl http://localhost:8080/healthz`

## 4. ECS / Fargate Deploy

See `infra/ecs/task-definition.json` and `infra/ecs/service-notes.md` for the full setup.

High-level steps:

1. **Create ECR repo:** `aws ecr create-repository --repository-name abyss-server`
2. **Build & push:**
   ```bash
   aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com
   docker build -t abyss-server server/
   docker tag abyss-server:latest ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/abyss-server:latest
   docker push ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/abyss-server:latest
   ```
3. **Register task definition:** `aws ecs register-task-definition --cli-input-json file://infra/ecs/task-definition.json`
4. **Create service** (first time) or **update service** (subsequent deploys)
5. **Verify** health check passes in ALB target group

## AWS Credentials

| Environment | How credentials work |
|---|---|
| **Local dev** (`npm run dev`) | Bedrock API key (`AWS_BEARER_TOKEN_BEDROCK` in `.env`) or SDK credential chain (`AWS_PROFILE` / env vars) |
| **Local Docker** | Pass `AWS_BEARER_TOKEN_BEDROCK` as env var, or pass IAM creds explicitly — the container has no access to your host's `~/.aws/` |
| **ECS / Fargate** | Bedrock API key via Secrets Manager, or SDK credential chain from IAM task role — no static creds in `environment` |

**Rules:**
- Never commit AWS credentials
- Never put static creds in the ECS task definition's `environment` block
- Use `secrets` block with Secrets Manager or SSM for any sensitive values (API keys, etc.)
- For local dev, prefer `AWS_PROFILE` over long-lived access keys
