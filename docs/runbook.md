# VoiceIDE Phase 2 — Operations Runbook

## Debugging Guide

### Finding Logs

All backend logs are structured JSON in CloudWatch:

```bash
# View connect handler logs
aws logs tail /aws/lambda/VoiceIDE-Connect --follow

# View message handler logs (includes Bedrock interactions)
aws logs tail /aws/lambda/VoiceIDE-Message --follow

# Filter by sessionId
aws logs filter-log-events \
  --log-group-name /aws/lambda/VoiceIDE-Message \
  --filter-pattern '{ $.sessionId = "YOUR-SESSION-ID" }'

# Filter by connectionId
aws logs filter-log-events \
  --log-group-name /aws/lambda/VoiceIDE-Message \
  --filter-pattern '{ $.connectionId = "YOUR-CONNECTION-ID" }'
```

### Log Format

Every log line is structured JSON:
```json
{
  "level": "INFO",
  "message": "Handling transcript.final",
  "sessionId": "550e8400-...",
  "connectionId": "abc123=",
  "requestId": "req-xyz",
  "text": "Hello",
  "ts": "2025-01-15T10:30:00.000Z"
}
```

### Tracing a Request

1. Find the connectionId from the iOS client (logged in event timeline)
2. Search CloudWatch logs by connectionId
3. Follow the requestId through the chain:
   - `$connect` → connectionId assigned
   - `sendMessage` → event routed
   - Bedrock call → model response
   - tool.call forwarded → callId
   - tool.result received → callId matches

### DynamoDB Inspection

```bash
# Check connection mapping
aws dynamodb get-item \
  --table-name VoiceIDE-Connections \
  --key '{"connectionId": {"S": "YOUR-CONNECTION-ID"}}'

# Check session state
aws dynamodb get-item \
  --table-name VoiceIDE-Sessions \
  --key '{"sessionId": {"S": "YOUR-SESSION-ID"}}'

# Check pending tool call
aws dynamodb get-item \
  --table-name VoiceIDE-Pending \
  --key '{"sessionId": {"S": "YOUR-SESSION-ID"}}'
```

## Common Failure Modes

### 1. Missing BEDROCK_MODEL_ID

**Symptom**: Error event with `bedrock_error` code, message about model not found.

**Fix**: Ensure the `BEDROCK_MODEL_ID` environment variable is set correctly on the Message Lambda. Default is `amazon.nova-lite-v1:0`.

```bash
aws lambda update-function-configuration \
  --function-name VoiceIDE-Message \
  --environment "Variables={BEDROCK_MODEL_ID=amazon.nova-lite-v1:0,...}"
```

### 2. IAM Permissions — Bedrock

**Symptom**: `AccessDeniedException` in logs when calling Bedrock.

**Fix**: Ensure the Message Lambda role has:
```json
{
  "Effect": "Allow",
  "Action": [
    "bedrock:InvokeModel",
    "bedrock:InvokeModelWithResponseStream"
  ],
  "Resource": "*"
}
```

Also ensure Bedrock model access is enabled in the AWS console for the target region.

### 3. IAM Permissions — WebSocket Push

**Symptom**: `ForbiddenException` when trying to send events to clients.

**Fix**: Ensure the Message Lambda role has `execute-api:ManageConnections` on the WebSocket API.

### 4. Stale Connections (GoneException)

**Symptom**: `GoneException` in logs when pushing to a connectionId.

**Cause**: iOS client disconnected but the Connections table still has the entry.

**Resolution**: The backend handles this gracefully — GoneException is caught and logged as a warning. The connection entry will be cleaned up on the next `$disconnect` or can be manually deleted.

### 5. Pending Tool Call Stuck

**Symptom**: Session stops responding. Pending table has an entry that never gets cleared.

**Cause**: iOS client disconnected before sending tool.result, or tool execution crashed.

**Fix**: Pending entries have a TTL of 5 minutes. They auto-expire. To manually clear:
```bash
aws dynamodb delete-item \
  --table-name VoiceIDE-Pending \
  --key '{"sessionId": {"S": "YOUR-SESSION-ID"}}'
```

### 6. iOS WebSocket Connection Fails

**Symptom**: iOS shows "Backend URL not configured" or connection error.

**Fix**:
1. Ensure `BACKEND_WS_URL` is set in `Secrets.plist`
2. Ensure `USE_CLOUD_CONDUCTOR` is set to `true`
3. Verify the URL format: `wss://XXXXXXXXXX.execute-api.REGION.amazonaws.com/prod`
4. Test the WebSocket endpoint:
   ```bash
   wscat -c "wss://XXXXXXXXXX.execute-api.us-east-1.amazonaws.com/prod?sessionId=$(uuidgen)"
   ```

### 7. Lambda Timeout

**Symptom**: Bedrock stream takes too long, Lambda times out.

**Fix**: The Message Lambda has a 120-second timeout. If Bedrock is slow:
- Check Bedrock service health
- Consider reducing `maxTokens` in the inference config
- Check if the conversation is very long (bound check)

### 8. Conversation Too Large

**Symptom**: DynamoDB item size limit (400KB) exceeded.

**Fix**: Conversations are bounded to 50 turns by default. If items are still too large, reduce `MAX_CONVERSATION_TURNS` in the code and redeploy.

## Health Checks

### WebSocket API

```bash
# Check if WebSocket API is responding
wscat -c "wss://YOUR-API-ID.execute-api.REGION.amazonaws.com/prod?sessionId=$(uuidgen)"
# Should connect successfully
```

### Lambda Functions

```bash
# Check function status
aws lambda get-function --function-name VoiceIDE-Connect --query 'Configuration.State'
aws lambda get-function --function-name VoiceIDE-Message --query 'Configuration.State'
```

### DynamoDB Tables

```bash
# Check table status
aws dynamodb describe-table --table-name VoiceIDE-Connections --query 'Table.TableStatus'
aws dynamodb describe-table --table-name VoiceIDE-Sessions --query 'Table.TableStatus'
aws dynamodb describe-table --table-name VoiceIDE-Pending --query 'Table.TableStatus'
```

### Bedrock Model Access

```bash
# List available models
aws bedrock list-foundation-models --query 'modelSummaries[?contains(modelId, `nova`)]'
```

## Monitoring Alerts (Recommended)

Set up CloudWatch Alarms for:

1. **Lambda errors** > 5 in 5 minutes
2. **Lambda duration** > 60 seconds (p95)
3. **WebSocket 4xx errors** > 10 in 5 minutes
4. **DynamoDB throttled requests** > 0
