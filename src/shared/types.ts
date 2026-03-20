export type JsonPrimitive = string | number | boolean | null;
export type JsonValue = JsonPrimitive | JsonObject | JsonValue[];
export interface JsonObject {
  [key: string]: JsonValue | undefined;
}

export interface SubmissionRecord extends JsonObject {
  PK: string;
  SK: string;
  GSI1PK: string;
  GSI1SK: string;
  GSI2PK: string;
  GSI2SK: string;
  GSI3PK: string;
  GSI3SK: string;
  entityType: "submission";
  submissionId: string;
  accountId: string;
  siteId: string;
  formId: string;
  status: string;
  createdAt: string;
  updatedAt: string;
  fields?: Record<string, JsonValue>;
  payloadRef?: {
    bucket: string;
    key: string;
    size?: number;
    contentType?: string;
  };
  email?: string;
  draftPasswordHash?: string;
  draftLastAccessedAt?: string;
  draftSaveCount?: number;
  emailSource?: "field" | "token" | "none";
  actor?: {
    type: "anonymous" | "authenticated" | "admin";
    sub?: string;
    email?: string;
  draftPasswordHash?: string;
  draftLastAccessedAt?: string;
  draftSaveCount?: number;
  };
  source?: {
    pageUrl?: string;
    pageTitle?: string;
    locale?: string;
    ipHash?: string;
    uaHash?: string;
  };
  tags?: string[];
  deletedAt?: string;
  internalNotes?: string;
  primaryLabel?: string;
  summary?: string;
  schemaVersion?: number;
  expiresAt?: number;
}

export interface TemplateRecord extends JsonObject {
  PK: string;
  SK: string;
  GSI1PK?: string;
  GSI1SK?: string;
  entityType: "template";
  templateKey: string;
  accountId: string;
  siteId?: string;
  scope: "account" | "site";
  name: string;
  subject: string;
  htmlBodyRef?: { bucket: string; key: string };
  textBodyRef?: { bucket: string; key: string };
  enabled: boolean;
  variablesSchema?: string[];
  createdAt: string;
  updatedAt: string;
}

export interface WorkflowDefinition extends JsonObject {
  PK: string;
  SK: string;
  GSI1PK?: string;
  GSI1SK?: string;
  entityType: "workflow";
  workflowId: string;
  accountId: string;
  siteId: string;
  enabled: boolean;
  name: string;
  trigger: {
    type: string;
    formId?: string;
    actionKey?: string;
    status?: string;
  };
  filters?: Array<{
    field: string;
    op: "eq" | "neq" | "contains" | "exists";
    value?: string;
  }>;
  steps: Array<JsonObject>;
  createdAt: string;
  updatedAt: string;
}

export interface SubmissionActionDefinition extends JsonObject {
  actionKey: string;
  label: string;
  allowedFromStatuses?: string[];
  targetStatus?: string;
  templateKey?: string;
  eventName?: string;
  wpHookName?: string;
  enabled: boolean;
}

export interface FormDefinition extends JsonObject {
  PK: string;
  SK: string;
  GSI1PK?: string;
  GSI1SK?: string;
  entityType: "form";
  formId: string;
  accountId: string;
  siteId: string;
  enabled: boolean;
  name: string;
  description?: string;
  locale?: string;
  siteName?: string;
  autoReplyTemplateKey?: string;
  actions?: SubmissionActionDefinition[];
  fieldSchema?: Record<string, JsonValue>;
  settings?: Record<string, JsonValue>;
  createdAt: string;
  updatedAt: string;
}

export interface WebhookEndpointRecord extends JsonObject {
  PK: string;
  SK: string;
  GSI1PK?: string;
  GSI1SK?: string;
  entityType: "webhook-endpoint";
  webhookKey: string;
  accountId: string;
  siteId: string;
  enabled: boolean;
  name: string;
  description?: string;
  url: string;
  method: "POST" | "PUT";
  headers?: Record<string, string>;
  signingMode?: "none" | "hmac";
  signingSecretParameterName?: string;
  createdAt: string;
  updatedAt: string;
}
