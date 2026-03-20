// CloudFormation Custom Resource Types

import { JsonObject } from "../shared/types";

export type ResourcePropertyBag = Record<string, unknown>;

export interface CloudFormationCustomResourceEvent {
  RequestType: "Create" | "Update" | "Delete";
  ResponseURL: string;
  StackId: string;
  RequestId: string;
  ResourceType: string;
  LogicalResourceId: string;
  PhysicalResourceId?: string;
  ResourceProperties: ResourcePropertyBag;
  OldResourceProperties?: ResourcePropertyBag;
}

export interface CloudFormationCustomResourceResponse {
  Status: "SUCCESS" | "FAILED";
  Reason?: string;
  PhysicalResourceId: string;
  StackId: string;
  RequestId: string;
  LogicalResourceId: string;
  Data?: JsonObject;
}

export interface CustomResourceContext {
  logStreamName: string;
  getRemainingTimeInMillis(): number;
}

// Custom Resource Error Types
export class CustomResourceError extends Error {
  constructor(
    message: string,
    public readonly cause?: Error,
  ) {
    super(message);
    this.name = "CustomResourceError";
  }
}

export class ValidationError extends CustomResourceError {
  constructor(message: string) {
    super(message);
    this.name = "ValidationError";
  }
}

export class ResourceNotFoundError extends CustomResourceError {
  constructor(message: string) {
    super(message);
    this.name = "ResourceNotFoundError";
  }
}
