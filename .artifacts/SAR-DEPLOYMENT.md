# SAR Deployment Instructions

## Application Information
- **Name**: wpsuite-flow
- **Version**: 1.0.0
- **Region**: us-east-1
- **Application ID**: arn:aws:serverlessrepo:us-east-1:637423296378:applications/wpsuite-flow
- **Published**: 2026-03-20T16:59:37Z

## Deployment via AWS Console

1. Go to the [AWS Serverless Application Repository](https://console.aws.amazon.com/serverlessrepo/home?region=us-east-1)
2. Search for "wpsuite-flow"
3. Click on the application
4. Click "Deploy"
5. Configure parameters as needed
6. Click "Deploy" to create the CloudFormation stack

## Deployment via AWS CLI

```bash
aws serverlessrepo create-cloud-formation-template \
  --application-id arn:aws:serverlessrepo:us-east-1:637423296378:applications/wpsuite-flow \
  --semantic-version 1.0.0 \
  --region us-east-1

# Use the returned TemplateUrl to deploy
aws cloudformation create-stack \
  --stack-name wpsuite-flow \
  --template-url <TEMPLATE_URL> \
  --capabilities CAPABILITY_IAM
```

## Key Parameters

### Core Configuration
- **AppName** – Resource name prefix (default: wpsuite-flow)
- **Environment** – Environment label (dev, staging, prod)
- **DeploymentVersion** – Artifact/template version used by the published SAR build

### Authentication
- **FrontendApiAuthMode** – Frontend auth mode (NONE, IAM)
- **AdminApiAuthMode** – Admin auth mode (NONE, IAM, COGNITO)
- **AdminCognitoUserPoolId** – Cognito User Pool ID for admin auth
- **AdminCognitoAuthScopes** – Required Cognito scopes

### Security
- **EnableRecaptcha** – Enable reCAPTCHA protection (true/false)
- **RecaptchaMode** – reCAPTCHA mode (classic, enterprise)
- **RecaptchaProjectId** – Google Cloud project ID for Enterprise
- **RecaptchaSiteKey** – reCAPTCHA site key
- **RecaptchaSecretKey** – reCAPTCHA secret key
- **RecaptchaScoreThreshold** – Minimum score threshold (0-1)

### WAF
- **EnableWAF** – Enable WAF protection (true/false)
- **PublicAllowedIPs** – Whitelist IPs for public endpoints
- **AdminAllowedIPs** – Whitelist IPs for admin endpoints
- **BlockedIPs** – Blacklist IPs

### Storage & Email
- **TemplatesBucketName** – S3 bucket for email template bodies
- **PayloadBucketName** – S3 bucket for submission payloads
- **FromEmail** – Email sender address (SES verified)

### Performance
- **LambdaMemorySize** – Lambda memory in MB (default: 1024)
- **LambdaTimeout** – Lambda timeout in seconds (default: 30)
- **DataRetentionDays** – DynamoDB retention period (default: 30)
- **LogRetentionDays** – CloudWatch log retention (default: 14)

## Post-Deployment

After deployment, you will receive:
- **ApiUrl** – REST API endpoint URL
- **TemplatesBucketOutput** – S3 bucket for templates
- **PayloadBucketOutput** – S3 bucket for payloads
- **Configure WP Suite Flow** – connect the WordPress plugin/admin app to the deployed API URL and matching auth model

## Support

For issues and questions:
- Documentation: https://wpsuite.io/docs
- GitHub: https://github.com/smartcloudsolutions/wpsuite
