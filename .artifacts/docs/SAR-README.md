# WP Suite Flow Backend

AWS-native forms, submissions, email templates, and event-driven workflow automation for WordPress — packaged as a **Serverless Application Repository (SAR)** deployment.

---

## 1. Overview

WP Suite Flow combines a WordPress-native form building experience with an AWS-native execution layer. Site owners and teams can build forms in WordPress, optionally synchronize their form definitions to AWS, and run submission handling, email delivery, webhook dispatching, and workflow automation in **their own AWS account**.

This backend is designed for the broader WP Suite Flow product, where:

- **WordPress remains the CMS, editor, and presentation layer**
- **AWS provides durable storage, automation, delivery, and protection layers**
- **frontend and admin clients can talk directly to the backend API**
- **EventBridge acts as the internal automation bus**

In practice, this means you can keep content editing and form design inside WordPress while moving operational workflows, submission processing, and integration logic to AWS infrastructure you control.

### Key capabilities

- **Forms API for frontend and admin** – public form submissions, admin management endpoints, submission updates, template management, workflow management, webhook endpoint management, and form-definition CRUD.
- **Event-driven workflows** – submission lifecycle events can trigger downstream actions such as email sending, webhook delivery, status updates, and future custom event-based automation.
- **Email template management** – store template metadata in DynamoDB, template bodies in S3, and send workflow-driven emails through Amazon SES.
- **Webhook delivery pipeline** – workflow or manual-action driven outbound webhooks with a dedicated dispatcher worker.
- **WordPress-to-AWS form sync** – Flow can treat WordPress as the editing surface while AWS stores and executes canonical backend form definitions.
- **Customer-owned deployment model** – submissions, templates, workflow definitions, payloads, and integration secrets stay inside the customer’s own AWS account.
- **Optional hardening** – Cognito/IAM auth, AWS WAF, reCAPTCHA, SecureString secrets, and optional KMS-backed encryption.

### Shared authentication foundation with Gatey

Flow can operate as an independent backend, but one of its strongest deployment patterns is to use the **shared Cognito foundation created by the WP Suite Cognito / Gatey backend**.

In that model:

- users sign in through **Gatey** on the WordPress site
- Gatey-driven frontend and admin calls can automatically include the required **JWT** or **IAM-backed** credentials
- the Flow backend can protect selected `/admin/*` or `/frontend/*` endpoints with **Cognito** or **IAM**
- access can be narrowed further with **custom Cognito scopes** derived from Cognito group memberships

This last part is especially powerful together with the optional **pre-token-generation Lambda** from the shared Cognito stack. It can inject scopes such as `sc.group.<groupname>` into access tokens based on the user's Cognito groups. Those scopes can then be referenced in Flow deployment parameters, making it possible to protect APIs not only for authenticated users, but for specific roles such as administrators or internal operators.

As a result, Flow does not have to reinvent authentication. It can rely on Gatey and the shared Cognito foundation for sign-in, token issuance, role-aware authorization, and automatic credential propagation from the WordPress side.

---

## 2. Architecture Snapshot

### WordPress / Flow side

WP Suite Flow provides:

- Gutenberg-based form building
- frontend rendering through a single React runtime per form
- admin tooling for submissions, templates, workflows, and backend settings
- optional synchronization of form definitions from WordPress into AWS
- shortcode and Elementor-friendly rendering patterns on the WordPress side

### AWS backend side

This SAR application deploys the backend services that make those capabilities operational:

- **API Gateway REST API**
- **Forms API Lambda**
- **Workflow Dispatcher Lambda**
- **Email Sender Lambda**
- **Webhook Dispatcher Lambda**
- **Custom Resource Manager Lambda**
- **DynamoDB tables** for submissions, submission events, templates, workflows, form definitions, and webhook endpoints
- **S3 buckets** for email template bodies and uploaded payloads
- **EventBridge-based internal event flow**
- **SQS dead-letter queue**
- optional **WAF**, **SecureString parameters**, and **KMS key**

### Why EventBridge matters

Flow is not just a “submit form to database” backend. It is built as an **event-driven automation layer**.

The backend emits domain events such as:

- `submission.created`
- `submission.updated`
- `submission.status-changed`
- `submission.action-invoked`
- `email.requested`
- `integration.webhook.requested`

This allows submission handling, workflow orchestration, email sending, and webhook dispatching to remain decoupled and extensible.

---

## 3. What Gets Deployed

This SAR template provisions the complete operational backend for WP Suite Flow.

### API and compute

- **API Gateway REST API** with `/frontend/*` and `/admin/*` route groups
- **Forms API Lambda** for both frontend and admin-facing API operations
- **Workflow Dispatcher Lambda** listening to submission-related EventBridge events
- **Email Sender Lambda** listening to `email.requested`
- **Webhook Dispatcher Lambda** listening to `integration.webhook.requested`
- **Custom Resource Manager Lambda** for API route setup, WAF resources, and SecureString parameter management

### Storage

- **Submissions table**
- **Submission events table**
- **Templates table**
- **Workflow definitions table**
- **Form definitions table**
- **Webhook endpoints table**
- **Templates S3 bucket**
- **Payload S3 bucket**

### Reliability and operations

- **Shared SQS dead-letter queue**
- **Per-function CloudWatch log groups**
- **X-Ray tracing**
- configurable memory, timeout, data retention, and log retention settings

### Optional security infrastructure

- **AWS WAF WebACL**
- **public/admin allow lists**
- **block lists**
- **rate limiting**
- **SecureString parameters for secrets**
- optional **dedicated KMS key + alias** for secret protection

All Lambda functions run on **Node.js 24.x** and **ARM64**.

---

## 4. Endpoint Surface

The backend is designed to serve both the public Flow frontend and the WordPress admin application.

### Frontend endpoints

The public frontend surface includes form-submit operations such as:

- `POST /frontend/forms/{formId}/submit`
- `POST /frontend/forms/{formId}/upload-url`

These endpoints are intended for browser-to-API communication from Flow-rendered forms and frontend components.

### Admin endpoints

The admin surface includes CRUD and operational APIs for:

- forms
- submissions
- submission events / timeline
- templates
- workflows
- webhook endpoints

This enables the WordPress admin application to manage backend data directly once configured.

### Direct browser-to-AWS model

The Flow runtime is explicitly designed around **direct browser-to-API communication** rather than requiring WordPress/PHP to proxy every request. That is one of the key architectural differences of the product.

---

## 5. Workflow and Event Model

### Event-driven workflow orchestration

Submission-related domain events are emitted with:

- `source = wpsuite.forms`
- detail types such as `submission.created`, `submission.updated`, `submission.status-changed`, `submission.action-invoked`, `email.requested`, and `integration.webhook.requested`

The **Workflow Dispatcher** listens to submission lifecycle events and evaluates workflow definitions. Based on workflow rules and steps, it can request follow-up actions such as:

- send email
- call webhook
- update status
- publish further events
- trigger delay/wait style workflow behavior

### Email delivery

The **Email Sender** listens for `email.requested`, loads template data, and sends messages through Amazon SES.

### Webhook delivery

The **Webhook Dispatcher** listens for `integration.webhook.requested` and performs outbound HTTP requests to configured destinations.

### Status-aware duplicate prevention

A particularly important Flow behavior is that status-based workflow triggers are intended to fire when a submission **transitions into** a target status, not on every later edit while it remains in that status. This helps prevent duplicate notifications and repeated automation.

### Human-in-the-loop actions

The broader Flow product also supports **manual submission actions** from the admin UI, making it possible to re-trigger notifications or workflows intentionally when an operator needs to intervene.

---

## 6. Storage Model and Data Ownership

This backend is designed for **customer-owned AWS deployment**.

That means:

- submissions stay in the customer’s own DynamoDB tables
- template bodies stay in the customer’s own S3 bucket
- payloads stay in the customer’s own S3 bucket
- workflow definitions and webhook configuration stay in the customer’s own AWS account
- integration secrets stay under the customer’s own AWS governance controls

For many teams, this is a meaningful difference versus SaaS-hosted workflow tools or form services.

### Operational entities stored by the backend

The deployed tables support entities such as:

- submissions
- submission events / timeline history
- email templates
- workflow definitions
- backend form definitions
- webhook endpoints

### Large payload flow

The upload URL endpoint enables a two-phase pattern for larger uploads:

1. request a presigned upload URL
2. upload the file/payload to S3
3. submit the form with a reference to the uploaded payload

---

## 7. Security Model

### Authentication modes

The template supports different auth modes for the two API surfaces.

#### Frontend API auth

- `NONE`
- `IAM`

Frontend endpoints are typically public-facing and are expected to be protected through a combination of:

- reCAPTCHA
- AWS WAF
- optional IP allow rules
- rate limiting

#### Admin API auth

- `NONE`
- `IAM`
- `COGNITO`

In most real deployments, the admin API should be protected with **Cognito** or **IAM**.

When Flow is used together with the shared Gatey / WP Suite Cognito foundation, Cognito protection becomes especially valuable because the same sign-in layer can issue the tokens that the Flow admin API expects. This can include **group-based custom scopes** such as `sc.group.admin`, allowing admin routes to be restricted to selected Cognito groups instead of all authenticated users.

### reCAPTCHA

Optional reCAPTCHA support includes:

- `classic` and `enterprise` modes
- project / site key / secret parameters
- score threshold
- runtime secret resolution from SSM SecureString

### AWS WAF

Optional WAF deployment can add:

- allow lists for public traffic
- allow lists for admin traffic
- block lists
- AWS managed common rule set
- rate limiting
- API Gateway association

### Secrets and encryption

Secrets such as the reCAPTCHA secret and default webhook signing secret are stored as **SSM SecureString** parameters. You can also choose to create a dedicated **KMS key** for those secrets.

---

## 8. Parameter Quick Reference

### Core deployment and runtime

| Parameter | Default | Description |
|:--|:--|:--|
| `AppName` | `wpsuite-flow` | Prefix used for resource names. |
| `Environment` | `prod` | One of `dev`, `staging`, `prod`. |
| `DeploymentVersion` | `1.0.0` | Version marker used by the template and publication flow. |
| `LambdaMemorySize` | `1024` | Memory setting applied globally to Lambda functions. |
| `LambdaTimeout` | `30` | Timeout in seconds for Lambda functions. |
| `LogLevel` | `INFO` | Application log level. |
| `DataRetentionDays` | `30` | Retention horizon for data using TTL-style handling where applicable. |
| `LogRetentionDays` | `14` | CloudWatch log retention. |

### Authentication and protection

| Parameter | Default | Description |
|:--|:--|:--|
| `FrontendApiAuthMode` | `NONE` | Frontend auth mode: `NONE` or `IAM`. |
| `AdminApiAuthMode` | `COGNITO` | Admin auth mode: `NONE`, `IAM`, or `COGNITO`. |
| `AdminCognitoUserPoolId` | `""` | Cognito User Pool ID for admin protection. |
| `AdminCognitoAuthScopes` | `""` | Comma-delimited admin scopes. |
| `EnableRecaptcha` | `false` | Enable frontend reCAPTCHA checks. |
| `RecaptchaMode` | `classic` | reCAPTCHA mode: `classic` or `enterprise`. |
| `RecaptchaProjectId` | `""` | Google Cloud project ID for Enterprise mode. |
| `RecaptchaSiteKey` | `""` | Public site key used by the frontend. |
| `RecaptchaSecretKey` | `""` | Secret key stored securely via custom resource. |
| `RecaptchaScoreThreshold` | `0.5` | Minimum score threshold. |
| `EnableWAF` | `false` | Deploy WAF resources and API association. |
| `PublicAllowedIPs` | `""` | Optional public allow list. |
| `AdminAllowedIPs` | `""` | Optional admin allow list. |
| `BlockedIPs` | `""` | Optional block list. |
| `EnableKmsForSecrets` | `false` | Create a dedicated KMS key for secrets. |

### Storage and delivery

| Parameter | Default | Description |
|:--|:--|:--|
| `TemplatesBucketName` | `""` | Bring your own S3 bucket for template bodies, or leave blank to create one. |
| `PayloadBucketName` | `""` | Bring your own S3 bucket for payloads, or leave blank to create one. |
| `TemplatesPrefix` | `templates/` | Prefix for template objects inside the templates bucket. |
| `FromEmail` | `""` | Default SES sender address. |
| `DefaultWebhookSigningSecret` | `""` | Optional default signing secret stored as SecureString. |

---

## 9. Common Deployment Patterns

### Pattern 1: Basic public forms + protected admin

Use this when you want public form submissions but locked-down back-office management.

This is also the most natural setup when WordPress users sign in through Gatey and the Flow admin app relies on the shared WP Suite Cognito foundation.

Recommended settings:

- `FrontendApiAuthMode=NONE`
- `AdminApiAuthMode=COGNITO`
- `EnableRecaptcha=true`
- `EnableWAF=true`

This gives you a public submission surface with basic abuse protection and a separately protected admin API.

### Pattern 2: Internal or private workflow system

Use this when both public and admin usage should remain tightly controlled.

Recommended settings:

- `FrontendApiAuthMode=IAM`
- `AdminApiAuthMode=IAM` or `COGNITO`
- `EnableWAF=true`
- use allow lists where appropriate

### Pattern 3: Bring your own buckets

If you already manage S3 buckets centrally, provide:

- `TemplatesBucketName`
- `PayloadBucketName`

Otherwise the stack creates buckets automatically.

---

## 10. Post-Deployment

After deployment, the stack returns outputs including:

- **API base URL**
- **templates bucket**
- **payload bucket**
- optional **reCAPTCHA secret parameter name**

Typical next steps are:

1. deploy or configure the WP Suite Flow plugin on the WordPress side
2. configure the backend API connection in WordPress
3. if you use Gatey, connect Flow to the shared Cognito foundation so admin or frontend calls can use Gatey-issued credentials
4. choose frontend/admin auth settings that match your deployment
5. sync or create forms
6. create email templates and workflows
7. verify SES sender configuration before enabling live email sending

---

## 11. Updating Existing Stacks

When new Lambda artifacts are published, CloudFormation does not automatically detect changes in the S3 objects themselves.

To roll out updated code cleanly:

1. publish a new backend artifact version
2. update the deployed application version in SAR / CloudFormation
3. ensure the template points to the correct artifact paths for that version

If you rely on versioned artifact keys, treat version updates as part of your normal deployment process.

---

## 12. Intended Usage with WP Suite Flow

This backend is designed to be consumed by the WP Suite Flow WordPress plugin and admin application.

A typical setup looks like this:

1. build forms in Gutenberg
2. optionally sync form definitions into the AWS backend
3. accept submissions from the frontend directly into AWS
4. manage submissions, notes, tags, templates, and workflows from the Flow admin UI
5. let EventBridge-driven workers handle email and webhook automation

This architecture lets WordPress remain the familiar editing experience while AWS handles the operational backend.

---

## 13. Cost and Scope Expectations

This stack is intentionally broader than a simple form endpoint. It includes storage, workflow orchestration, event history, email delivery plumbing, and webhook dispatching.

Your cost profile will depend primarily on:

- API request volume
- Lambda invocation volume and duration
- DynamoDB usage
- S3 storage and request volume
- SES sending volume
- WAF usage, if enabled

For most early-stage or moderate-volume deployments, the main architectural question is usually not “can it scale?” but rather “which protection, auth, and delivery options do we want enabled from day one?”

---

## 14. Notes and Current Scope

A few important clarifications for readers evaluating the backend:

- webhook endpoints are currently most relevant as **workflow-triggered or manually triggered** outbound integrations
- the broader product direction clearly supports additional event-dispatch patterns over time
- the backend is meant to support not just public form submit handling, but also operational management from the WordPress admin side

In other words, this is best understood as a **workflow backend for WordPress-based forms**, not merely as an API endpoint for form posts.

---

**Repository / product home:** https://wpsuite.io/flow/
