import {
  APIGatewayClient,
  CreateDeploymentCommand,
  CreateResourceCommand,
  GetMethodCommand,
  GetResourcesCommand,
  PutIntegrationCommand,
  PutIntegrationResponseCommand,
  PutMethodCommand,
  PutMethodResponseCommand,
  UpdateMethodCommand,
} from "@aws-sdk/client-api-gateway";
import {
  DeleteParameterCommand,
  PutParameterCommand,
  SSMClient,
} from "@aws-sdk/client-ssm";
import {
  AbortMultipartUploadCommand,
  DeleteObjectsCommand,
  ListMultipartUploadsCommand,
  ListObjectVersionsCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import {
  CreateMalwareProtectionPlanCommand,
  DeleteMalwareProtectionPlanCommand,
  GetMalwareProtectionPlanCommand,
  GuardDutyClient,
  UpdateMalwareProtectionPlanCommand,
} from "@aws-sdk/client-guardduty";
import {
  AssociateWebACLCommand,
  CreateIPSetCommand,
  CreateWebACLCommand,
  DefaultAction,
  DeleteIPSetCommand,
  DeleteWebACLCommand,
  DisassociateWebACLCommand,
  GetIPSetCommand,
  GetWebACLCommand,
  IPAddressVersion,
  Rule,
  Scope,
  UpdateIPSetCommand,
  UpdateWebACLCommand,
  VisibilityConfig,
  WAFV2Client,
} from "@aws-sdk/client-wafv2";
import { logError, logInfo } from "../shared/logger";
import {
  CloudFormationCustomResourceEvent,
  CustomResourceContext,
} from "./types";

const waf = new WAFV2Client({});
const ssm = new SSMClient({});
const apiGateway = new APIGatewayClient({});
const guardDuty = new GuardDutyClient({});
const s3 = new S3Client({});

type RouteSpec = {
  path: string;
  method: string;
  authorizationType?: "NONE" | "AWS_IAM" | "COGNITO_USER_POOLS";
  authorizerId?: string;
  authorizationScopes?: string[];
  integrationUri: string;
};

async function sendResponse(
  event: CloudFormationCustomResourceEvent,
  context: CustomResourceContext,
  status: "SUCCESS" | "FAILED",
  data: Record<string, unknown> = {},
  physicalResourceId?: string,
  reason?: string,
) {
  const body = JSON.stringify({
    Status: status,
    Reason: reason || `See CloudWatch Log Stream: ${context.logStreamName}`,
    PhysicalResourceId:
      physicalResourceId ||
      event.PhysicalResourceId ||
      `${event.LogicalResourceId}-${Date.now()}`,
    StackId: event.StackId,
    RequestId: event.RequestId,
    LogicalResourceId: event.LogicalResourceId,
    Data: data,
  });
  await fetch(event.ResponseURL, {
    method: "PUT",
    headers: {
      "Content-Type": "application/json",
      "Content-Length": String(body.length),
    },
    body,
  });
}

const toList = (value: unknown): string[] =>
  Array.isArray(value)
    ? value.filter(Boolean).map(String)
    : String(value || "")
        .split(",")
        .map((v) => v.trim())
        .filter(Boolean);
const parseJson = <T = unknown>(value: unknown, fallback: T): T => {
  try {
    return typeof value === "string"
      ? JSON.parse(value)
      : ((value as T) ?? fallback);
  } catch {
    return fallback;
  }
};
const methodKey = (path: string, method: string) =>
  `${method.toUpperCase()} ${path}`;

// Normalize CloudFormation YAML property types to proper WAF API types
function coerce(
  value: unknown,
  intProps: string[],
  boolProps: string[],
  keyPath: string[] = [],
): unknown {
  if (Array.isArray(value)) {
    return value.map((v, i) =>
      coerce(v, intProps, boolProps, [...keyPath, String(i)]),
    );
  } else if (value !== null && typeof value === "object") {
    const result: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) {
      result[k] = coerce(v, intProps, boolProps, [...keyPath, k]);
    }
    return result;
  } else if (typeof value === "string") {
    const key = keyPath[keyPath.length - 1];
    if (key) {
      if (intProps.includes(key)) {
        const num = Number(value);
        return isNaN(num) ? value : num;
      }
      if (boolProps.includes(key)) {
        const lowered = value.toLowerCase();
        return lowered === "true" || lowered === "1";
      }
    }
    return value;
  } else {
    return value;
  }
}

function normalizeWafData(input: unknown): unknown {
  return coerce(
    input,
    ["Priority", "Limit", "ResponseCode"],
    ["SampledRequestsEnabled", "CloudWatchMetricsEnabled"],
  );
}

async function handleSsmSecret(event: CloudFormationCustomResourceEvent) {
  const name = String(event.ResourceProperties.Name);
  const value = String(event.ResourceProperties.Value || "");
  const keyId = event.ResourceProperties.KeyId
    ? String(event.ResourceProperties.KeyId)
    : undefined;
  if (event.RequestType === "Delete") {
    try {
      await ssm.send(new DeleteParameterCommand({ Name: name }));
    } catch {
      /**/
    }
    return { PhysicalResourceId: name, Data: { Name: name } };
  }
  await ssm.send(
    new PutParameterCommand({
      Name: name,
      Value: value,
      Type: "SecureString",
      Overwrite: true,
      KeyId: keyId,
    }),
  );
  return { PhysicalResourceId: name, Data: { Name: name } };
}

async function handleBucketCleaner(event: CloudFormationCustomResourceEvent) {
  const bucketName = String(event.ResourceProperties.BucketName || "").trim();

  if (!bucketName) {
    throw new Error("BucketName is required");
  }

  if (event.RequestType !== "Delete") {
    return {
      PhysicalResourceId: bucketName,
      Data: {
        BucketName: bucketName,
        Status: event.RequestType === "Create" ? "Created" : "Updated",
      },
    };
  }

  let deletedObjects = 0;
  let deletedVersions = 0;
  let deletedMarkers = 0;
  let abortedUploads = 0;

  try {
    let keyMarker: string | undefined;
    let versionIdMarker: string | undefined;

    do {
      const listed = await s3.send(
        new ListObjectVersionsCommand({
          Bucket: bucketName,
          KeyMarker: keyMarker,
          VersionIdMarker: versionIdMarker,
          MaxKeys: 1000,
        }),
      );

      const objects = [
        ...(listed.Versions || []).flatMap((version) =>
          version.Key && version.VersionId
            ? [
                {
                  Key: version.Key,
                  VersionId: version.VersionId,
                },
              ]
            : [],
        ),
        ...(listed.DeleteMarkers || []).flatMap((marker) =>
          marker.Key && marker.VersionId
            ? [
                {
                  Key: marker.Key,
                  VersionId: marker.VersionId,
                },
              ]
            : [],
        ),
      ];

      deletedVersions += listed.Versions?.length || 0;
      deletedMarkers += listed.DeleteMarkers?.length || 0;

      if (objects.length > 0) {
        await s3.send(
          new DeleteObjectsCommand({
            Bucket: bucketName,
            Delete: {
              Objects: objects,
              Quiet: true,
            },
          }),
        );
        deletedObjects += objects.length;
      }

      keyMarker = listed.NextKeyMarker;
      versionIdMarker = listed.NextVersionIdMarker;
    } while (keyMarker || versionIdMarker);

    let uploadKeyMarker: string | undefined;
    let uploadIdMarker: string | undefined;

    do {
      const uploads = await s3.send(
        new ListMultipartUploadsCommand({
          Bucket: bucketName,
          KeyMarker: uploadKeyMarker,
          UploadIdMarker: uploadIdMarker,
          MaxUploads: 1000,
        }),
      );

      for (const upload of uploads.Uploads || []) {
        if (!upload.Key || !upload.UploadId) {
          continue;
        }

        await s3.send(
          new AbortMultipartUploadCommand({
            Bucket: bucketName,
            Key: upload.Key,
            UploadId: upload.UploadId,
          }),
        );
        abortedUploads += 1;
      }

      uploadKeyMarker = uploads.NextKeyMarker;
      uploadIdMarker = uploads.NextUploadIdMarker;
    } while (uploadKeyMarker || uploadIdMarker);
  } catch (error) {
    logError("BucketCleaner delete failed", error as Error, { bucketName });
  }

  return {
    PhysicalResourceId: bucketName,
    Data: {
      BucketName: bucketName,
      Status: "Deleted",
      ObjectsDeleted: deletedObjects,
      VersionsDeleted: deletedVersions,
      DeleteMarkersDeleted: deletedMarkers,
      MultipartUploadsAborted: abortedUploads,
    },
  };
}

async function handleWafIpSet(event: CloudFormationCustomResourceEvent) {
  const name = String(event.ResourceProperties.Name);
  const scope = String(event.ResourceProperties.Scope || "REGIONAL") as Scope;
  const ipAddressVersion = String(
    event.ResourceProperties.IPAddressVersion || "IPV4",
  ) as IPAddressVersion;
  const addresses = toList(event.ResourceProperties.Addresses);
  const description = String(event.ResourceProperties.Description || "");

  if (event.RequestType === "Delete") {
    if (!event.PhysicalResourceId) return { Data: { Status: "Deleted" } };
    const [id, lockToken] = event.PhysicalResourceId.split("|");
    try {
      await waf.send(
        new DeleteIPSetCommand({
          Id: id,
          Name: name,
          Scope: scope,
          LockToken: lockToken,
        }),
      );
    } catch {
      /** */
    }
    return {
      PhysicalResourceId: event.PhysicalResourceId,
      Data: { Status: "Deleted" },
    };
  }

  if (event.RequestType === "Create" || !event.PhysicalResourceId) {
    const resp = await waf.send(
      new CreateIPSetCommand({
        Name: name,
        Scope: scope,
        IPAddressVersion: ipAddressVersion,
        Addresses: addresses,
        Description: description,
      }),
    );
    return {
      PhysicalResourceId: `${resp.Summary?.Id}|${resp.Summary?.LockToken}`,
      Data: { Arn: resp.Summary?.ARN, Id: resp.Summary?.Id },
    };
  }

  const [id] = event.PhysicalResourceId.split("|");
  const current = await waf.send(
    new GetIPSetCommand({ Id: id, Name: name, Scope: scope }),
  );
  await waf.send(
    new UpdateIPSetCommand({
      Id: id,
      Name: name,
      Scope: scope,
      Addresses: addresses,
      Description: description,
      LockToken: current.LockToken!,
    }),
  );
  const refreshed = await waf.send(
    new GetIPSetCommand({ Id: id, Name: name, Scope: scope }),
  );
  return {
    PhysicalResourceId: `${id}|${refreshed.LockToken}`,
    Data: { Arn: refreshed.IPSet?.ARN, Id: id },
  };
}

async function handleWafWebAcl(event: CloudFormationCustomResourceEvent) {
  const name = String(event.ResourceProperties.Name);
  const scope = String(event.ResourceProperties.Scope || "REGIONAL") as Scope;
  const description = String(event.ResourceProperties.Description || "");
  const rawRules = parseJson(event.ResourceProperties.Rules, []).filter(
    Boolean,
  );
  const rawDefaultAction = parseJson(event.ResourceProperties.DefaultAction, {
    Allow: {},
  });
  const rawVisibilityConfig = parseJson(
    event.ResourceProperties.VisibilityConfig,
    {
      SampledRequestsEnabled: true,
      CloudWatchMetricsEnabled: true,
      MetricName: name.replace(/[^A-Za-z0-9]/g, ""),
    },
  );

  // Normalize data types from CloudFormation strings
  const rules = normalizeWafData(rawRules) as Rule[];
  const defaultAction = normalizeWafData(rawDefaultAction) as DefaultAction;
  const visibilityConfig = normalizeWafData(
    rawVisibilityConfig,
  ) as VisibilityConfig;

  if (event.RequestType === "Delete") {
    if (!event.PhysicalResourceId) return { Data: { Status: "Deleted" } };
    const [id, lockToken] = event.PhysicalResourceId.split("|");
    try {
      await waf.send(
        new DeleteWebACLCommand({
          Id: id,
          Name: name,
          Scope: scope,
          LockToken: lockToken,
        }),
      );
    } catch {
      /** */
    }
    return {
      PhysicalResourceId: event.PhysicalResourceId,
      Data: { Status: "Deleted" },
    };
  }

  if (event.RequestType === "Create" || !event.PhysicalResourceId) {
    const resp = await waf.send(
      new CreateWebACLCommand({
        Name: name,
        Scope: scope,
        Description: description,
        DefaultAction: defaultAction,
        Rules: rules,
        VisibilityConfig: visibilityConfig,
      }),
    );
    return {
      PhysicalResourceId: `${resp.Summary?.Id}|${resp.Summary?.LockToken}`,
      Data: { Arn: resp.Summary?.ARN, Id: resp.Summary?.Id },
    };
  }

  const [id] = event.PhysicalResourceId.split("|");
  const current = await waf.send(
    new GetWebACLCommand({ Id: id, Name: name, Scope: scope }),
  );
  await waf.send(
    new UpdateWebACLCommand({
      Id: id,
      Name: name,
      Scope: scope,
      Description: description,
      DefaultAction: defaultAction,
      Rules: rules,
      VisibilityConfig: visibilityConfig,
      LockToken: current.LockToken!,
    }),
  );
  const refreshed = await waf.send(
    new GetWebACLCommand({ Id: id, Name: name, Scope: scope }),
  );
  return {
    PhysicalResourceId: `${id}|${refreshed.LockToken}`,
    Data: { Arn: refreshed.WebACL?.ARN, Id: id },
  };
}

async function handleWafAssociation(event: CloudFormationCustomResourceEvent) {
  const webACLArn = String(event.ResourceProperties.WebACLArn);
  const resourceArn = String(event.ResourceProperties.ResourceArn);
  const physicalId = `${webACLArn}|${resourceArn}`;
  if (event.RequestType === "Delete") {
    try {
      await waf.send(
        new DisassociateWebACLCommand({ ResourceArn: resourceArn }),
      );
    } catch {
      /** */
    }
    return { PhysicalResourceId: physicalId, Data: { Status: "Deleted" } };
  }
  await waf.send(
    new AssociateWebACLCommand({
      WebACLArn: webACLArn,
      ResourceArn: resourceArn,
    }),
  );
  return {
    PhysicalResourceId: physicalId,
    Data: { WebACLArn: webACLArn, ResourceArn: resourceArn },
  };
}

type MalwarePlanProperties = {
  Role: string;
  ProtectedResource: {
    S3Bucket: {
      BucketName?: string;
      ObjectPrefixes?: string[];
    };
  };
  Actions?: {
    Tagging?: {
      Status?: "ENABLED" | "DISABLED";
    };
  };
  Tags?: Array<{ Key: string; Value: string }>;
};

function getMalwarePlanProperties(
  event: CloudFormationCustomResourceEvent,
): MalwarePlanProperties {
  const props = event.ResourceProperties as Record<string, unknown>;
  return {
    Role: String(props.Role || ""),
    ProtectedResource: (props.ProtectedResource || {
      S3Bucket: {},
    }) as MalwarePlanProperties["ProtectedResource"],
    Actions: props.Actions as MalwarePlanProperties["Actions"],
    Tags: Array.isArray(props.Tags)
      ? (props.Tags as Array<{ Key: string; Value: string }>).filter(
          (tag) => tag?.Key && tag?.Value !== undefined,
        )
      : undefined,
  };
}

function bucketNameFromPlanProps(
  props: MalwarePlanProperties | undefined,
): string | undefined {
  return props?.ProtectedResource?.S3Bucket?.BucketName;
}

function tagsArrayToMap(tags?: Array<{ Key: string; Value: string }>) {
  if (!tags?.length) return undefined;
  return Object.fromEntries(tags.map((tag) => [tag.Key, tag.Value]));
}

async function safeDeleteMalwareProtectionPlan(planId?: string) {
  if (!planId) return;
  try {
    await guardDuty.send(
      new DeleteMalwareProtectionPlanCommand({
        MalwareProtectionPlanId: planId,
      }),
    );
  } catch (error) {
    if (
      error instanceof Error &&
      /not\s*found|resource.*does not exist|404/i.test(error.message)
    ) {
      return;
    }
    throw error;
  }
}

async function handleGuardDutyMalwareProtectionPlan(
  event: CloudFormationCustomResourceEvent,
) {
  const props = getMalwarePlanProperties(event);
  const oldProps = event.OldResourceProperties
    ? getMalwarePlanProperties({
        ...event,
        ResourceProperties: event.OldResourceProperties,
      })
    : undefined;

  if (event.RequestType === "Delete") {
    await safeDeleteMalwareProtectionPlan(event.PhysicalResourceId);
    return {
      PhysicalResourceId: event.PhysicalResourceId,
      Data: { Status: "Deleted" },
    };
  }

  if (!props.Role || !bucketNameFromPlanProps(props)) {
    throw new Error(
      "Role and ProtectedResource.S3Bucket.BucketName are required",
    );
  }

  const bucketChanged =
    bucketNameFromPlanProps(props) !== bucketNameFromPlanProps(oldProps);

  if (
    event.RequestType === "Create" ||
    !event.PhysicalResourceId ||
    bucketChanged
  ) {
    if (bucketChanged && event.PhysicalResourceId) {
      await safeDeleteMalwareProtectionPlan(event.PhysicalResourceId);
    }

    const createResponse = await guardDuty.send(
      new CreateMalwareProtectionPlanCommand({
        Role: props.Role,
        ProtectedResource: props.ProtectedResource,
        Actions: props.Actions,
        Tags: tagsArrayToMap(props.Tags),
      }),
    );

    const planId = createResponse.MalwareProtectionPlanId;
    const current = planId
      ? await guardDuty.send(
          new GetMalwareProtectionPlanCommand({
            MalwareProtectionPlanId: planId,
          }),
        )
      : undefined;

    return {
      PhysicalResourceId: planId,
      Data: {
        MalwareProtectionPlanId: planId,
        Arn: current?.Arn,
        Status: current?.Status,
      },
    };
  }

  await guardDuty.send(
    new UpdateMalwareProtectionPlanCommand({
      MalwareProtectionPlanId: event.PhysicalResourceId,
      Role: props.Role,
      Actions: props.Actions,
      ProtectedResource: {
        S3Bucket: {
          ObjectPrefixes: props.ProtectedResource.S3Bucket.ObjectPrefixes,
        },
      },
    }),
  );

  const current = await guardDuty.send(
    new GetMalwareProtectionPlanCommand({
      MalwareProtectionPlanId: event.PhysicalResourceId,
    }),
  );

  return {
    PhysicalResourceId: event.PhysicalResourceId,
    Data: {
      MalwareProtectionPlanId: event.PhysicalResourceId,
      Arn: current.Arn,
      Status: current.Status,
    },
  };
}

async function buildPathMap(
  restApiId: string,
): Promise<Record<string, string>> {
  const map: Record<string, string> = {};
  let position: string | undefined;
  do {
    const page = await apiGateway.send(
      new GetResourcesCommand({
        restApiId,
        position,
        limit: 500,
        embed: ["methods"],
      }),
    );
    for (const res of page.items || []) {
      if (res.path && res.id) map[res.path] = res.id;
    }
    position = page.position;
  } while (position);
  return map;
}

async function ensureResourcePath(
  restApiId: string,
  fullPath: string,
  existingMap?: Record<string, string>,
): Promise<string> {
  const pathParts = fullPath.split("/").filter(Boolean);
  const map = existingMap || (await buildPathMap(restApiId));
  let parentId = map["/"];
  if (!parentId) throw new Error("API root resource not found");
  let currentPath = "";

  for (const part of pathParts) {
    currentPath += `/${part}`;
    if (!map[currentPath]) {
      const resp = await apiGateway.send(
        new CreateResourceCommand({ restApiId, parentId, pathPart: part }),
      );
      if (!resp.id)
        throw new Error(`Failed to create API resource for ${currentPath}`);
      map[currentPath] = resp.id;
      parentId = resp.id;
      logInfo("Created API resource", { currentPath, resourceId: resp.id });
    } else {
      parentId = map[currentPath]!;
    }
  }
  return parentId;
}

async function ensureMethod(
  route: RouteSpec,
  restApiId: string,
  resourceId: string,
): Promise<void> {
  const httpMethod = route.method.toUpperCase();
  try {
    await apiGateway.send(
      new PutMethodCommand({
        restApiId,
        resourceId,
        httpMethod,
        authorizationType: route.authorizationType || "NONE",
        authorizerId:
          route.authorizationType === "COGNITO_USER_POOLS"
            ? route.authorizerId
            : undefined,
        authorizationScopes:
          route.authorizationType === "COGNITO_USER_POOLS"
            ? route.authorizationScopes
            : undefined,
        apiKeyRequired: false,
      }),
    );
  } catch (error) {
    if ((error as Error)?.name !== "ConflictException") throw error;

    // Method already exists, update it
    // Get current method settings to compare authorization scopes
    const current = await apiGateway.send(
      new GetMethodCommand({
        restApiId,
        resourceId,
        httpMethod,
      }),
    );

    const currentScopes = Array.isArray(current.authorizationScopes)
      ? current.authorizationScopes
      : [];

    // Normalize scopes for comparison
    const norm = (arr?: string[]) =>
      (arr ?? [])
        .map((s) => s.trim())
        .filter(Boolean)
        .sort();

    const desiredScopes = norm(route.authorizationScopes);
    const haveScopes = norm(currentScopes);
    const scopesEqual =
      JSON.stringify(haveScopes) === JSON.stringify(desiredScopes);

    // Build patch operations
    const patchOperations: Array<{
      op: "replace" | "add" | "remove";
      path: string;
      value?: string;
    }> = [
      {
        op: "replace",
        path: "/authorizationType",
        value: route.authorizationType || "NONE",
      },
    ];

    // authorizerId: only REPLACE for COGNITO mode if we have an ID
    if (
      route.authorizationType === "COGNITO_USER_POOLS" &&
      route.authorizerId
    ) {
      patchOperations.push({
        op: "replace",
        path: "/authorizerId",
        value: route.authorizerId,
      });
    }

    // authorizationScopes: only ADD/REMOVE allowed by AWS API Gateway
    if (!scopesEqual) {
      if (desiredScopes.length === 0) {
        // Remove all existing scopes
        for (const scope of haveScopes) {
          patchOperations.push({
            op: "remove",
            path: "/authorizationScopes",
            value: scope,
          });
        }
      } else {
        // Remove old scopes, then add new ones
        for (const scope of haveScopes) {
          patchOperations.push({
            op: "remove",
            path: "/authorizationScopes",
            value: scope,
          });
        }
        for (const scope of desiredScopes) {
          patchOperations.push({
            op: "add",
            path: "/authorizationScopes",
            value: scope,
          });
        }
      }
    }

    await apiGateway.send(
      new UpdateMethodCommand({
        restApiId,
        resourceId,
        httpMethod,
        patchOperations,
      }),
    );
  }

  await apiGateway.send(
    new PutIntegrationCommand({
      restApiId,
      resourceId,
      httpMethod,
      type: "AWS_PROXY",
      integrationHttpMethod: "POST",
      uri: route.integrationUri,
      passthroughBehavior: "WHEN_NO_MATCH",
    }),
  );
}

async function ensureOptionsCors(
  restApiId: string,
  resourceId: string,
  allowMethods: string[],
) {
  try {
    await apiGateway.send(
      new PutMethodCommand({
        restApiId,
        resourceId,
        httpMethod: "OPTIONS",
        authorizationType: "NONE",
        apiKeyRequired: false,
      }),
    );
  } catch (error) {
    if ((error as Error)?.name !== "ConflictException") throw error;
  }

  await apiGateway.send(
    new PutIntegrationCommand({
      restApiId,
      resourceId,
      httpMethod: "OPTIONS",
      type: "MOCK",
      requestTemplates: { "application/json": '{"statusCode": 200}' },
    }),
  );

  try {
    await apiGateway.send(
      new PutMethodResponseCommand({
        restApiId,
        resourceId,
        httpMethod: "OPTIONS",
        statusCode: "200",
        responseParameters: {
          "method.response.header.Access-Control-Allow-Origin": true,
          "method.response.header.Access-Control-Allow-Headers": true,
          "method.response.header.Access-Control-Allow-Methods": true,
        },
      }),
    );
  } catch (error) {
    if ((error as Error)?.name !== "ConflictException") throw error;
  }

  await apiGateway.send(
    new PutIntegrationResponseCommand({
      restApiId,
      resourceId,
      httpMethod: "OPTIONS",
      statusCode: "200",
      responseParameters: {
        "method.response.header.Access-Control-Allow-Origin": "'*'",
        "method.response.header.Access-Control-Allow-Headers":
          "'Content-Type,Authorization,X-Amz-Date,X-Api-Key,X-Amz-Security-Token,X-Request-Id,X-Recaptcha-Token'",
        "method.response.header.Access-Control-Allow-Methods": `'${Array.from(new Set([...allowMethods.map((m) => m.toUpperCase()), "OPTIONS"])).join(",")}'`,
      },
    }),
  );
}

function normalizeRoutes(props: Record<string, unknown>): RouteSpec[] {
  const restApiId = String(props.RestApiId);
  const formsApiUri = String(props.FormsApiIntegrationUri || "");
  if (!restApiId || !formsApiUri)
    throw new Error("RestApiId and FormsApiIntegrationUri are required");

  const frontendAuthMode = String(
    props.FrontendAuthMode || "NONE",
  ).toUpperCase();
  const adminAuthMode = String(props.AdminAuthMode || "COGNITO").toUpperCase();
  const adminScopes = toList(props.AdminAuthorizationScopes);

  const frontendRoutes: Array<Omit<RouteSpec, "integrationUri">> = [
    {
      path: "/frontend/forms/{formId}/submit",
      method: "POST",
      authorizationType:
        frontendAuthMode === "IAM" ? ("AWS_IAM" as const) : ("NONE" as const),
    },
    {
      path: "/frontend/forms/{formId}/upload-url",
      method: "POST",
      authorizationType:
        frontendAuthMode === "IAM" ? ("AWS_IAM" as const) : ("NONE" as const),
    },
  ];
  const adminRoutes: Array<Omit<RouteSpec, "integrationUri">> = [
    ["GET", "/admin/forms"],
    ["GET", "/admin/forms/{formId}"],
    ["POST", "/admin/forms"],
    ["PUT", "/admin/forms/{formId}"],
    ["DELETE", "/admin/forms/{formId}"],
    ["GET", "/admin/forms/{formId}/submissions"],
    ["GET", "/admin/forms/{formId}/submissions/{submissionId}"],
    ["GET", "/admin/forms/{formId}/submissions/{submissionId}/events"],
    ["PATCH", "/admin/forms/{formId}/submissions/{submissionId}"],
    ["DELETE", "/admin/forms/{formId}/submissions/{submissionId}"],
    [
      "POST",
      "/admin/forms/{formId}/submissions/{submissionId}/actions/{actionKey}",
    ],
    ["GET", "/admin/submissions"],
    ["GET", "/admin/templates"],
    ["GET", "/admin/templates/{templateKey}"],
    ["POST", "/admin/templates"],
    ["PUT", "/admin/templates/{templateKey}"],
    ["DELETE", "/admin/templates/{templateKey}"],
    ["POST", "/admin/templates/{templateKey}/preview"],
    ["GET", "/admin/workflows"],
    ["GET", "/admin/workflows/{workflowId}"],
    ["POST", "/admin/workflows"],
    ["PUT", "/admin/workflows/{workflowId}"],
    ["DELETE", "/admin/workflows/{workflowId}"],
    ["GET", "/admin/webhook-endpoints"],
    ["GET", "/admin/webhook-endpoints/{webhookKey}"],
    ["POST", "/admin/webhook-endpoints"],
    ["PUT", "/admin/webhook-endpoints/{webhookKey}"],
    ["DELETE", "/admin/webhook-endpoints/{webhookKey}"],
  ].map(([method, path]) => ({
    path,
    method,
    authorizationType:
      adminAuthMode === "IAM"
        ? ("AWS_IAM" as const)
        : adminAuthMode === "COGNITO"
          ? ("COGNITO_USER_POOLS" as const)
          : ("NONE" as const),
    authorizerId:
      adminAuthMode === "COGNITO"
        ? String(props.AdminAuthorizerId || "")
        : undefined,
    authorizationScopes: adminAuthMode === "COGNITO" ? adminScopes : undefined,
  }));

  return [...frontendRoutes, ...adminRoutes].map((route) => ({
    ...route,
    integrationUri: formsApiUri,
  }));
}

async function handleApiRoutes(event: CloudFormationCustomResourceEvent) {
  if (event.RequestType === "Delete") {
    return {
      PhysicalResourceId:
        event.PhysicalResourceId ||
        `${event.ResourceProperties.RestApiId}|routes`,
      Data: { Status: "Deleted" },
    };
  }

  const restApiId = String(event.ResourceProperties.RestApiId);
  const stageName = String(event.ResourceProperties.StageName || "prod");
  const routes = normalizeRoutes(event.ResourceProperties);
  const pathMap = await buildPathMap(restApiId);
  const methodsPerResource = new Map<string, Set<string>>();

  for (const route of routes) {
    const resourceId = await ensureResourcePath(restApiId, route.path, pathMap);
    await ensureMethod(route, restApiId, resourceId);
    if (!methodsPerResource.has(resourceId))
      methodsPerResource.set(resourceId, new Set());
    methodsPerResource.get(resourceId)!.add(route.method.toUpperCase());
    logInfo("Ensured API route", {
      route: methodKey(route.path, route.method),
      authorizationType: route.authorizationType,
    });
  }

  for (const [resourceId, methods] of methodsPerResource.entries()) {
    await ensureOptionsCors(restApiId, resourceId, Array.from(methods));
  }

  await apiGateway.send(
    new CreateDeploymentCommand({
      restApiId,
      stageName,
      description: `WP Suite Workflows routes updated at ${new Date().toISOString()}`,
    }),
  );
  return {
    PhysicalResourceId: `${restApiId}|routes`,
    Data: { RouteCount: routes.length },
  };
}

export const handler = async (
  event: CloudFormationCustomResourceEvent,
  context: CustomResourceContext,
): Promise<void> => {
  logInfo("Custom resource request received", {
    resourceType: event.ResourceType,
    requestType: event.RequestType,
    logicalResourceId: event.LogicalResourceId,
  });
  try {
    let result: { PhysicalResourceId?: string; Data?: Record<string, unknown> };
    switch (event.ResourceType) {
      case "Custom::SSMParameter":
        result = await handleSsmSecret(event);
        break;
      case "Custom::BucketCleaner":
        result = await handleBucketCleaner(event);
        break;
      case "Custom::WafIPSet":
        result = await handleWafIpSet(event);
        break;
      case "Custom::WafWebACL":
        result = await handleWafWebAcl(event);
        break;
      case "Custom::WafAssociation":
        result = await handleWafAssociation(event);
        break;
      case "Custom::ApiRoutes":
        result = await handleApiRoutes(event);
        break;
      case "Custom::GuardDutyMalwareProtectionPlan":
        result = await handleGuardDutyMalwareProtectionPlan(event);
        break;
      default:
        throw new Error(`Unsupported resource type: ${event.ResourceType}`);
    }
    await sendResponse(
      event,
      context,
      "SUCCESS",
      result.Data || {},
      result.PhysicalResourceId,
    );
  } catch (error) {
    logError("Custom resource operation failed", error, {
      resourceType: event.ResourceType,
      requestType: event.RequestType,
    });
    await sendResponse(
      event,
      context,
      "FAILED",
      { Error: error instanceof Error ? error.message : "Unknown" },
      event.PhysicalResourceId,
      error instanceof Error ? error.message : "Unknown",
    );
  }
};
