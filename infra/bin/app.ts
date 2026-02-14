#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { VoiceIDEStack } from '../lib/voiceide-stack';

const app = new cdk.App();

new VoiceIDEStack(app, 'VoiceIDEStack', {
  description: 'VoiceIDE Phase 2 — WebSocket API + Bedrock Conductor',
  env: {
    region: process.env.CDK_DEFAULT_REGION || 'us-east-1',
    account: process.env.CDK_DEFAULT_ACCOUNT,
  },
});
