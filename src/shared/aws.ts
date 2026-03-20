import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient } from '@aws-sdk/lib-dynamodb';
import { EventBridgeClient } from '@aws-sdk/client-eventbridge';
import { S3Client } from '@aws-sdk/client-s3';
import { SSMClient } from '@aws-sdk/client-ssm';
import { SESv2Client } from '@aws-sdk/client-sesv2';

const ddbClient = new DynamoDBClient({});
export const ddb = DynamoDBDocumentClient.from(ddbClient, {
  marshallOptions: { removeUndefinedValues: true }
});
export const eventBridge = new EventBridgeClient({});
export const s3 = new S3Client({});
export const ssm = new SSMClient({});
export const ses = new SESv2Client({});
