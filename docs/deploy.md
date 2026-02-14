# VoiceIDE Phase 2 — Deployment Guide

## Prerequisites

- **AWS CLI** configured with credentials (`aws configure`)
- **Node.js 20+** (`node --version`)
- **AWS CDK CLI** (`npm install -g aws-cdk`)
- **Bedrock model access** enabled for Nova Lite in your target region
  - Go to AWS Console > Bedrock > Model access > Enable `Amazon Nova Lite`

## Step 1: Build the Backend

```bash
cd backend
npm install
npm run build
```

This compiles TypeScript to `dist/`.

## Step 2: Run Backend Tests

```bash
cd backend
npm test
```

All tests should pass.

## Step 3: Deploy Infrastructure

```bash
cd infra
npm install

# Bootstrap CDK (first time only)
cdk bootstrap

# Preview changes
cdk diff

# Deploy
cdk deploy
```

CDK will:
1. Create the API Gateway WebSocket API
2. Create three Lambda functions (Connect, Disconnect, Message)
3. Create three DynamoDB tables (Connections, Sessions, Pending)
4. Set up IAM roles with Bedrock, DynamoDB, and API Gateway permissions
5. Output the WebSocket URL

### Deployment Output

After `cdk deploy`, note the outputs:
```
Outputs:
VoiceIDEStack.WebSocketURL = wss://abc123xyz.execute-api.us-east-1.amazonaws.com/prod
VoiceIDEStack.WebSocketApiId = abc123xyz
VoiceIDEStack.ConnectionsTableName = VoiceIDE-Connections
VoiceIDEStack.SessionsTableName = VoiceIDE-Sessions
VoiceIDEStack.PendingTableName = VoiceIDE-Pending
```

**Copy the WebSocket URL** — you'll need it for the iOS app.

## Step 4: Verify Deployment

```bash
# Test WebSocket connection
npm install -g wscat
wscat -c "wss://YOUR-API-ID.execute-api.us-east-1.amazonaws.com/prod?sessionId=$(uuidgen)"

# In wscat, send a session.start event:
> {"id":"test-1","timestamp":"2025-01-01T00:00:00Z","kind":{"sessionStart":{"sessionId":"test-session"}}}
```

You should see the connection succeed (no error).

## Step 5: Configure iOS App

Update `ios/VoiceIDE/VoiceIDE/App/Secrets.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ELEVENLABS_API_KEY</key>
    <string>YOUR_ELEVENLABS_KEY</string>
    <key>ELEVENLABS_VOICE_ID</key>
    <string>21m00Tcm4TlvDq8ikWAM</string>
    <key>ELEVENLABS_MODEL_ID</key>
    <string>eleven_turbo_v2_5</string>
    <key>BACKEND_WS_URL</key>
    <string>wss://YOUR-API-ID.execute-api.us-east-1.amazonaws.com/prod</string>
    <key>USE_CLOUD_CONDUCTOR</key>
    <string>true</string>
</dict>
</plist>
```

## Step 6: Build and Run iOS App

1. Open `ios/VoiceIDE/Package.swift` in Xcode
2. Select an iOS 17+ device
3. Build and Run (Cmd+R)
4. Verify the "Cloud Conductor" banner appears (green)

## Step 7: Smoke Test

1. Tap the mic button
2. Say "Hello"
3. Tap the mic button again
4. You should hear a spoken response from the AI
5. Check the Event Timeline for:
   - `user.audio.transcript.final`
   - `tool.call: convo.setState` (thinking)
   - `tool.call: convo.appendMessage` (user message)
   - `assistant.speech.partial` / `assistant.speech.final`
   - `tool.call: tts.speak`
   - `tool.result: OK`
   - `tool.call: convo.setState` (idle)

## Updating

### Backend Code Changes

```bash
cd backend
npm run build
cd ../infra
cdk deploy
```

### Changing the Bedrock Model

Update the `BEDROCK_MODEL_ID` environment variable:

```bash
# In infra/lib/voiceide-stack.ts, change:
BEDROCK_MODEL_ID: 'amazon.nova-lite-v1:0'
# Then redeploy:
cd infra && cdk deploy
```

Or update directly:
```bash
aws lambda update-function-configuration \
  --function-name VoiceIDE-Message \
  --environment "Variables={BEDROCK_MODEL_ID=amazon.nova-pro-v1:0,...}"
```

## Teardown

```bash
cd infra
cdk destroy
```

This removes all AWS resources. DynamoDB tables have `DESTROY` removal policy so they'll be deleted with the stack.

## Cost Estimate (Hackathon)

For light usage (~100 conversations/day):
- **API Gateway**: ~$0 (free tier covers 1M messages/month)
- **Lambda**: ~$0 (free tier covers 1M requests/month)
- **DynamoDB**: ~$0 (on-demand, free tier covers 25 WCU/RCU)
- **Bedrock Nova Lite**: ~$0.30/1M input tokens, ~$1.20/1M output tokens
  - Estimate: <$1/day for light usage

Total: Under $5/month for hackathon usage.
