/**
 * Tests for Lambda handler routing logic.
 */

import { handler as connectHandler } from '../src/handlers/connect';
import { handler as disconnectHandler } from '../src/handlers/disconnect';
import * as dynamoModule from '../src/services/dynamodb';

jest.mock('../src/services/dynamodb');

const mockDynamo = dynamoModule as jest.Mocked<typeof dynamoModule>;

// Helper to create API Gateway WebSocket event
function makeWsEvent(overrides: Record<string, unknown> = {}): any {
  return {
    requestContext: {
      connectionId: 'conn-test-123',
      requestId: 'req-1',
      domainName: 'abc123.execute-api.us-east-1.amazonaws.com',
      stage: 'prod',
      ...overrides.requestContext as object,
    },
    queryStringParameters: {
      sessionId: '550e8400-e29b-41d4-a716-446655440000',
      ...overrides.queryStringParameters as object,
    },
    body: overrides.body as string || null,
    ...overrides,
  };
}

beforeEach(() => {
  jest.clearAllMocks();
});

describe('$connect handler', () => {
  test('saves connection with valid sessionId', async () => {
    mockDynamo.putConnection.mockResolvedValue(undefined);

    const event = makeWsEvent();
    const result = await connectHandler(event);

    expect(result).toEqual({ statusCode: 200, body: 'Connected' });
    expect(mockDynamo.putConnection).toHaveBeenCalledWith(
      'conn-test-123',
      '550e8400-e29b-41d4-a716-446655440000',
    );
  });

  test('rejects missing sessionId', async () => {
    const event = makeWsEvent({
      queryStringParameters: {},
    });
    const result = await connectHandler(event);

    expect(result).toEqual(expect.objectContaining({ statusCode: 400 }));
    expect(mockDynamo.putConnection).not.toHaveBeenCalled();
  });

  test('rejects invalid sessionId format', async () => {
    const event = makeWsEvent({
      queryStringParameters: { sessionId: 'not-a-uuid' },
    });
    const result = await connectHandler(event);

    expect(result).toEqual(expect.objectContaining({ statusCode: 400 }));
  });

  test('returns 500 on DynamoDB failure', async () => {
    mockDynamo.putConnection.mockRejectedValue(new Error('DDB fail'));

    const event = makeWsEvent();
    const result = await connectHandler(event);

    expect(result).toEqual(expect.objectContaining({ statusCode: 500 }));
  });
});

describe('$disconnect handler', () => {
  test('cleans up connection mapping', async () => {
    mockDynamo.deleteConnection.mockResolvedValue(undefined);

    const event = makeWsEvent();
    const result = await disconnectHandler(event);

    expect(result).toEqual({ statusCode: 200, body: 'Disconnected' });
    expect(mockDynamo.deleteConnection).toHaveBeenCalledWith('conn-test-123');
  });

  test('returns 200 even if cleanup fails', async () => {
    mockDynamo.deleteConnection.mockRejectedValue(new Error('DDB fail'));

    const event = makeWsEvent();
    const result = await disconnectHandler(event);

    expect(result).toEqual({ statusCode: 200, body: 'Disconnected' });
  });
});
