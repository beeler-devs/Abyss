# ECS Service Notes

## Architecture

- **Launch type:** Fargate
- **Desired count:** 1 (single task — server holds session state in memory)
- **Port:** 8080
- **Health check:** `GET /healthz`

## IAM Roles

### Task Role (`abyss-ecs-task-role`)

The task role is what the running container assumes. It needs:

- `bedrock:Converse` — used by the text model provider (Nova 2 Lite via Converse API)
- `bedrock:InvokeModel` — used by Nova Sonic bidirectional streaming
- `bedrock:InvokeModelWithBidirectionalStream` — required for Nova Sonic voice

Scope these to the model ARNs used (Nova 2 Lite, Nova 2 Sonic).

Alternatively, if using a Bedrock API key (`AWS_BEARER_TOKEN_BEDROCK`), the task role only needs basic permissions — the API key handles Bedrock auth. Store the API key in Secrets Manager and reference it in the task definition's `secrets` block.

No static AWS credentials should be passed — the SDK credential chain picks up the task role automatically.

### Execution Role (`abyss-ecs-execution-role`)

The execution role is what ECS itself uses to pull images and write logs:

- `ecr:GetAuthorizationToken`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`
- `logs:CreateLogStream`, `logs:PutLogEvents`

## Networking

- Place the service in a VPC with private subnets + NAT gateway (for Bedrock API access)
- Or public subnets if simplicity is preferred for hackathon
- ALB target group pointing at port 8080, with WebSocket idle timeout increased (default 60s is too low)

## Sticky Sessions / Scaling

Not needed yet. Single task means all traffic goes to one container. When scaling beyond 1 task, you'll need sticky sessions (ALB cookie or IP-based) or externalized session state (Redis/DynamoDB).

## Secrets

If `CURSOR_API_KEY`, `GITHUB_CLIENT_SECRET`, or other secrets are needed at runtime, use AWS Secrets Manager or SSM Parameter Store and reference them in the task definition's `secrets` block — never in `environment`.

## Deploy Steps (manual for now)

1. Build and push image to ECR
2. Register task definition: `aws ecs register-task-definition --cli-input-json file://infra/ecs/task-definition.json`
3. Create or update service: `aws ecs update-service --cluster abyss --service abyss-server --task-definition abyss-server`
4. Verify health check passes in target group
