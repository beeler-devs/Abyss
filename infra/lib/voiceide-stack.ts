import * as cdk from 'aws-cdk-lib';
import * as apigatewayv2 from 'aws-cdk-lib/aws-apigatewayv2';
import * as integrations from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';
import { Construct } from 'constructs';
import * as path from 'path';

export class VoiceIDEStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // ─── DynamoDB Tables ──────────────────────────────────────────────

    const connectionsTable = new dynamodb.Table(this, 'ConnectionsTable', {
      tableName: 'VoiceIDE-Connections',
      partitionKey: { name: 'connectionId', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const sessionsTable = new dynamodb.Table(this, 'SessionsTable', {
      tableName: 'VoiceIDE-Sessions',
      partitionKey: { name: 'sessionId', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const pendingTable = new dynamodb.Table(this, 'PendingTable', {
      tableName: 'VoiceIDE-Pending',
      partitionKey: { name: 'sessionId', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      timeToLiveAttribute: 'ttl',
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ─── Shared Lambda environment ────────────────────────────────────

    const backendCodePath = path.join(__dirname, '../../backend/dist');

    const sharedEnv: Record<string, string> = {
      CONNECTIONS_TABLE: connectionsTable.tableName,
      SESSIONS_TABLE: sessionsTable.tableName,
      PENDING_TABLE: pendingTable.tableName,
      BEDROCK_MODEL_ID: 'amazon.nova-lite-v1:0',
      LOG_LEVEL: 'INFO',
    };

    // ─── Lambda: $connect ─────────────────────────────────────────────

    const connectFn = new lambda.Function(this, 'ConnectFunction', {
      functionName: 'VoiceIDE-Connect',
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'handlers/connect.handler',
      code: lambda.Code.fromAsset(backendCodePath),
      timeout: cdk.Duration.seconds(10),
      memorySize: 256,
      environment: sharedEnv,
      logRetention: logs.RetentionDays.TWO_WEEKS,
    });

    // ─── Lambda: $disconnect ──────────────────────────────────────────

    const disconnectFn = new lambda.Function(this, 'DisconnectFunction', {
      functionName: 'VoiceIDE-Disconnect',
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'handlers/disconnect.handler',
      code: lambda.Code.fromAsset(backendCodePath),
      timeout: cdk.Duration.seconds(10),
      memorySize: 256,
      environment: sharedEnv,
      logRetention: logs.RetentionDays.TWO_WEEKS,
    });

    // ─── Lambda: sendMessage ──────────────────────────────────────────

    const messageFn = new lambda.Function(this, 'MessageFunction', {
      functionName: 'VoiceIDE-Message',
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'handlers/message.handler',
      code: lambda.Code.fromAsset(backendCodePath),
      timeout: cdk.Duration.seconds(120),  // Long timeout for Bedrock streaming
      memorySize: 512,
      environment: sharedEnv,
      logRetention: logs.RetentionDays.TWO_WEEKS,
    });

    // ─── DynamoDB permissions ─────────────────────────────────────────

    connectionsTable.grantReadWriteData(connectFn);
    connectionsTable.grantReadWriteData(disconnectFn);
    connectionsTable.grantReadWriteData(messageFn);

    sessionsTable.grantReadWriteData(messageFn);
    pendingTable.grantReadWriteData(messageFn);

    // ─── Bedrock permissions ──────────────────────────────────────────

    messageFn.addToRolePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: [
        'bedrock:InvokeModel',
        'bedrock:InvokeModelWithResponseStream',
      ],
      resources: ['*'],  // Bedrock model ARNs vary by region
    }));

    // ─── WebSocket API ────────────────────────────────────────────────

    const webSocketApi = new apigatewayv2.WebSocketApi(this, 'WebSocketApi', {
      apiName: 'VoiceIDE-WebSocket',
      connectRouteOptions: {
        integration: new integrations.WebSocketLambdaIntegration('ConnectIntegration', connectFn),
      },
      disconnectRouteOptions: {
        integration: new integrations.WebSocketLambdaIntegration('DisconnectIntegration', disconnectFn),
      },
      defaultRouteOptions: {
        integration: new integrations.WebSocketLambdaIntegration('DefaultIntegration', messageFn),
      },
    });

    // Add sendMessage route
    webSocketApi.addRoute('sendMessage', {
      integration: new integrations.WebSocketLambdaIntegration('MessageIntegration', messageFn),
    });

    const stage = new apigatewayv2.WebSocketStage(this, 'WebSocketStage', {
      webSocketApi,
      stageName: 'prod',
      autoDeploy: true,
    });

    // ─── API Gateway Management permissions ───────────────────────────

    // The message Lambda needs to push events back to clients
    messageFn.addToRolePolicy(new iam.PolicyStatement({
      effect: iam.Effect.ALLOW,
      actions: ['execute-api:ManageConnections'],
      resources: [
        `arn:aws:execute-api:${this.region}:${this.account}:${webSocketApi.apiId}/${stage.stageName}/*`,
      ],
    }));

    // ─── Outputs ──────────────────────────────────────────────────────

    new cdk.CfnOutput(this, 'WebSocketURL', {
      value: stage.url,
      description: 'WebSocket API URL for iOS client',
      exportName: 'VoiceIDE-WebSocketURL',
    });

    new cdk.CfnOutput(this, 'WebSocketApiId', {
      value: webSocketApi.apiId,
      description: 'WebSocket API ID',
    });

    new cdk.CfnOutput(this, 'ConnectionsTableName', {
      value: connectionsTable.tableName,
    });

    new cdk.CfnOutput(this, 'SessionsTableName', {
      value: sessionsTable.tableName,
    });

    new cdk.CfnOutput(this, 'PendingTableName', {
      value: pendingTable.tableName,
    });
  }
}
