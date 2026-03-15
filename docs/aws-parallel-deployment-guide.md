# Parallel AWS Deployment Prep Guide

Do this as a separate track with a hard boundary: do not touch the Sonic code path except for shared env names. Treat this as "make the server runnable in AWS later, while still running locally now."

## Order

1. Containerize the server.
2. Make config AWS-first and explicit.
3. Add a local Bedrock smoke path.
4. Add ECS/Fargate artifacts.
5. Write the deploy/runbook doc.

## 1. Containerize the server

Work only under the server and infra/docs surface first.

Create:
- `/Users/bentontameling/Dev/VoiceBot2/server/Dockerfile`
- `/Users/bentontameling/Dev/VoiceBot2/server/.dockerignore`

What the Dockerfile should do:
- use Node 20
- copy `package.json` + `package-lock.json`
- run `npm ci`
- copy `src`, `tsconfig.json`
- run `npm run build`
- expose `8080`
- run `node dist/src/server.js`

Keep it simple. Do not optimize multi-stage builds until this works.

Validate locally:

```bash
cd /Users/bentontameling/Dev/VoiceBot2/server
docker build -t abyss-server .
docker run --rm -p 8080:8080 \
  -e MODEL_PROVIDER=bedrock \
  -e AWS_REGION=us-east-1 \
  abyss-server
```

Goal: `GET /healthz` returns healthy.

## 2. Make config AWS-first

Use the server env surface as the single source of truth.

Keep these as the main envs:
- `MODEL_PROVIDER=bedrock`
- `VOICE_PROVIDER=local`
- `BEDROCK_TEXT_MODEL_ID=us.amazon.nova-2-lite-v1:0`
- `BEDROCK_SONIC_MODEL_ID=us.amazon.nova-2-sonic-v1:0`
- `BEDROCK_SONIC_VOICE_ID=tiffany`
- `AWS_REGION=us-east-1`

For local dev:
- use `AWS_PROFILE` if possible
- otherwise `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, optional `AWS_SESSION_TOKEN`

For ECS later:
- do not pass static AWS creds
- use the ECS task role

This is the rule you want documented:
- local: SDK credential chain from your shell
- ECS: SDK credential chain from IAM task role

## 3. Add a real Bedrock smoke script

Create:
- `/Users/bentontameling/Dev/VoiceBot2/server/scripts/bedrockSmoke.ts`

It should:
- construct the Bedrock provider directly
- send one simple user turn like "Say hello in one sentence."
- print the full text
- optionally print any tool calls
- exit nonzero on Bedrock/API/config failure

Add an npm script in `/Users/bentontameling/Dev/VoiceBot2/server/package.json`:
- `smoke:bedrock`

Run it like:

```bash
cd /Users/bentontameling/Dev/VoiceBot2/server
AWS_PROFILE=your-profile npm run smoke:bedrock
```

This gives you a clean test independent of WebSocket/iOS/Sonic.

## 4. Add ECS/Fargate deployment artifacts

Create an `infra` folder, for example:
- `/Users/bentontameling/Dev/VoiceBot2/infra/ecs/task-definition.json`
- `/Users/bentontameling/Dev/VoiceBot2/infra/ecs/service-notes.md`

Keep it hackathon-simple:
- one task
- one service
- one container
- port `8080`
- health check path `/healthz`
- public or internal ALB depending on your plan
- env vars for model/provider config
- no sticky sessions or shared state solution yet

Important ECS choices:
- launch type: Fargate
- task role: Bedrock permissions
- execution role: ECR/log pull basics
- logs: CloudWatch
- desired count: `1`

Because your server keeps session state in memory, explicitly assume:
- single task only for now

## 5. Write the runbook while you build

Put this in:
- `/Users/bentontameling/Dev/VoiceBot2/docs/runbook.md`
- or a new AWS doc like `/Users/bentontameling/Dev/VoiceBot2/docs/aws-deploy.md`

Document four flows:
- local dev with `npm run dev`
- local Bedrock smoke
- local Docker run
- future ECS deploy

Make the AWS credential section explicit:
- local shell uses `AWS_PROFILE` or env creds
- ECS uses task role
- no committed secrets
- no long-lived static creds in task definitions

## How to work in parallel with Sonic

While you work on Sonic:
- do not touch the iOS audio/event pipeline unless an env name must match
- do not touch the Sonic provider implementation
- only touch container/config/docs/smoke/infra files
- if you need one shared change, keep it limited to env names in `/Users/bentontameling/Dev/VoiceBot2/server/.env.example` and `/Users/bentontameling/Dev/VoiceBot2/server/README.md`

That keeps the two tracks from stepping on each other:
- Sonic track: realtime voice behavior
- Deployment track: packaging, auth, and operations

If you want, I can implement this deployment-prep track next and keep it isolated from the Sonic work.
