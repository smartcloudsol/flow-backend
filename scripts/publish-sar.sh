#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.artifacts"
APP_NAME="${APP_NAME:-wpsuite-flow}"
VERSION="${VERSION:-0.2.0}"
SAR_REGION="${SAR_REGION:-us-east-1}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ARTIFACTS_BUCKET="${ARTIFACTS_BUCKET:-wpsuite-artifacts}"
S3_PREFIX="${S3_PREFIX:-wpsuite-flow}"
ARTIFACT_VERSION="${ARTIFACT_VERSION:-$VERSION}"
FULL_PREFIX="$S3_PREFIX/$ARTIFACT_VERSION"
CONFIGURE_BUCKET_POLICY="${CONFIGURE_BUCKET_POLICY:-false}"
BUILD_BEFORE_PUBLISH="${BUILD_BEFORE_PUBLISH:-true}"
UPLOAD_BEFORE_PUBLISH="${UPLOAD_BEFORE_PUBLISH:-true}"

print_status(){ echo -e "${GREEN}✅ $1${NC}"; }
print_warning(){ echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error(){ echo -e "${RED}❌ $1${NC}"; exit 1; }
print_info(){ echo -e "${BLUE}ℹ️  $1${NC}"; }

show_config() {
  print_info "SAR publishing configuration:"
  echo "  App Name: $APP_NAME"
  echo "  Version: $VERSION"
  echo "  Artifact Version: $ARTIFACT_VERSION"
  echo "  SAR Region: $SAR_REGION"
  echo "  AWS Region: $AWS_REGION"
  echo "  S3 Bucket: $ARTIFACTS_BUCKET"
  echo "  S3 Prefix: $S3_PREFIX"
  echo "  Build Before Publish: $BUILD_BEFORE_PUBLISH"
  echo "  Upload Before Publish: $UPLOAD_BEFORE_PUBLISH"
  echo "  Configure Bucket Policy: $CONFIGURE_BUCKET_POLICY"
  echo
}

check_prerequisites() {
  command -v aws >/dev/null || print_error "AWS CLI is not installed"
  command -v python3 >/dev/null || print_error "python3 is required"
  aws sts get-caller-identity >/dev/null 2>&1 || print_error "AWS credentials not configured or invalid"
  [ -f "$ROOT_DIR/template.yaml" ] || print_error "template.yaml not found"
}

ensure_local_artifacts() {
  local required=(
    "$ROOT_DIR/.artifacts/forms-api.zip"
    "$ROOT_DIR/.artifacts/custom-resource.zip"
    "$ROOT_DIR/.artifacts/workflow-dispatcher.zip"
    "$ROOT_DIR/.artifacts/webhook-dispatcher.zip"
    "$ROOT_DIR/.artifacts/email-sender.zip"
  )

  local missing=false
  for file in "${required[@]}"; do
    if [ ! -f "$file" ]; then
      missing=true
      break
    fi
  done

  if [ "$BUILD_BEFORE_PUBLISH" = "true" ] || [ "$missing" = true ]; then
    print_info "Building local artifacts"
    bash "$ROOT_DIR/scripts/build.sh"
  fi
}

# Configure S3 bucket policy for SAR access
configure_bucket_policy() {
    [ "$CONFIGURE_BUCKET_POLICY" = "true" ] || return 0
    print_info "Configuring S3 bucket policy for SAR access"
    local tmp_policy="$BUILD_DIR/sar-bucket-policy.json"
    mkdir -p "$BUILD_DIR"
    python3 - "$ARTIFACTS_BUCKET" <<'PY2' > "$tmp_policy"
import json, sys, subprocess
bucket = sys.argv[1]
try:
    current = subprocess.check_output([
        'aws','s3api','get-bucket-policy','--bucket',bucket,'--query','Policy','--output','text'
    ], stderr=subprocess.DEVNULL, text=True).strip()
    policy = json.loads(current) if current and current != 'None' else {"Version":"2012-10-17","Statement":[]}
except Exception:
    policy = {"Version":"2012-10-17","Statement":[]}
new_statements = [
  {"Sid":"AllowServerlessRepoReadDocs","Effect":"Allow","Principal":{"Service":"serverlessrepo.amazonaws.com"},"Action":"s3:GetObject","Resource":f"arn:aws:s3:::{bucket}/*/docs/*"},
  {"Sid":"AllowServerlessRepoReadArtifacts","Effect":"Allow","Principal":{"Service":"serverlessrepo.amazonaws.com"},"Action":"s3:GetObject","Resource":[f"arn:aws:s3:::{bucket}/*/templates/*",f"arn:aws:s3:::{bucket}/*/functions/*",f"arn:aws:s3:::{bucket}/*/layers/*",f"arn:aws:s3:::{bucket}/*/wrapper/*"]},
  {"Sid":"AllowCloudFormationReadArtifacts","Effect":"Allow","Principal":{"Service":"cloudformation.amazonaws.com"},"Action":"s3:GetObject","Resource":[f"arn:aws:s3:::{bucket}/*/templates/*",f"arn:aws:s3:::{bucket}/*/functions/*",f"arn:aws:s3:::{bucket}/*/layers/*",f"arn:aws:s3:::{bucket}/*/wrapper/*"]}
]
by_sid = {s.get('Sid'): s for s in policy.get('Statement', []) if isinstance(s, dict) and s.get('Sid')}
for stmt in new_statements:
    by_sid[stmt['Sid']] = stmt
other = [s for s in policy.get('Statement', []) if not (isinstance(s, dict) and s.get('Sid'))]
policy['Statement'] = other + list(by_sid.values())
print(json.dumps(policy))
PY2
    aws s3api put-bucket-policy --bucket "$ARTIFACTS_BUCKET" --policy file://"$tmp_policy" --region "$AWS_REGION" >/dev/null || print_warning "Failed to update bucket policy"
    rm -f "$tmp_policy"
}

upload_artifacts_if_needed() {
  [ "$UPLOAD_BEFORE_PUBLISH" = "true" ] || return 0
  print_info "Uploading versioned artifacts to S3"
  ARTIFACTS_BUCKET="$ARTIFACTS_BUCKET" AWS_REGION="$AWS_REGION" APP_NAME="$APP_NAME" S3_PREFIX="$S3_PREFIX" ARTIFACT_VERSION="$ARTIFACT_VERSION" VERSION="$VERSION" bash "$ROOT_DIR/scripts/upload-artifacts.sh"
}

upload_documentation_files() {
  aws s3 cp "$ROOT_DIR/LICENSE" "s3://$ARTIFACTS_BUCKET/$FULL_PREFIX/docs/LICENSE" --region "$AWS_REGION" >/dev/null
  aws s3 cp "$ROOT_DIR/SAR-README.md" "s3://$ARTIFACTS_BUCKET/$FULL_PREFIX/docs/SAR-README.md" --region "$AWS_REGION" >/dev/null
  export LICENSE_S3_URL="s3://$ARTIFACTS_BUCKET/$FULL_PREFIX/docs/LICENSE"
  export README_S3_URL="s3://$ARTIFACTS_BUCKET/$FULL_PREFIX/docs/SAR-README.md"
}

prepare_sar_template() {
    print_info "Preparing SAR template..."
    
    local input_template="$ROOT_DIR/template.yaml"
    local output_template="$BUILD_DIR/template.sar.yaml"
    
    if [ ! -f "$input_template" ]; then
        print_error "Template file not found: $input_template"
    fi
    
    # Set APP_NAME for the Python script
    export APP_NAME
    
    # Use Python to process the template
    python3 - "$input_template" "$output_template" "$VERSION" "$ARTIFACTS_BUCKET" << 'PY'
import re
import sys
import os
from pathlib import Path

input_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
version = sys.argv[3]
bucket = sys.argv[4]
app_name = os.environ.get('APP_NAME', 'wpsuite-flow')

text = input_path.read_text(encoding="utf-8")

# 1) Remove DeploymentVersion parameter
text = re.sub(
    r'  DeploymentVersion:\s*\n(?:    .*\n)*?(?=  \w|\nConditions:|\nGlobals:|\nResources:)',
    '',
    text,
    flags=re.MULTILINE
)

# 2) Replace ${DeploymentVersion} with concrete version
text = text.replace("${DeploymentVersion}", version)

# 3) Replace DeploymentVersion tag references
text = re.sub(
    r'DeploymentVersion: !Ref DeploymentVersion',
    f'DeploymentVersion: {version}',
    text
)

# 4) Update S3 URLs
old_pattern = f's3://{bucket}/{app_name}/${{DeploymentVersion}}'
new_pattern = f's3://{bucket}/{app_name}/{version}'
text = text.replace(old_pattern, new_pattern)

output_path.write_text(text, encoding="utf-8")
PY
    
    print_status "SAR template prepared: $output_template"
}

# Upload SAR template to S3
upload_sar_template() {
    print_info "Uploading SAR template to S3..."
    
    local template_file="$BUILD_DIR/template.sar.yaml"
    local s3_key="$APP_NAME/$VERSION/template.yaml"
    
    if [ ! -f "$template_file" ]; then
        print_error "SAR template not found: $template_file"
    fi
    
    aws s3 cp "$template_file" "s3://$ARTIFACTS_BUCKET/$s3_key" \
        --region "$SAR_REGION" \
        --content-type "text/yaml" || {
        print_error "Failed to upload SAR template"
    }
    
    export TEMPLATE_URL="https://s3.amazonaws.com/$ARTIFACTS_BUCKET/$s3_key"
    print_status "SAR template uploaded: $TEMPLATE_URL"
}

# Validate semantic version
validate_version() {
    print_info "Validating version: $VERSION"
    
    if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        print_error "Invalid semantic version: $VERSION (expected format: X.Y.Z)"
    fi
    
    print_status "Version is valid"
}

# Create new SAR application
create_application() {
    print_info "Creating new SAR application..."
    
    local description="Event-driven forms, submissions, email templates, and workflow automation backend for WordPress sites using WP Suite Flow"
    local author="Smart Cloud Solutions"
    local license="MIT"
    local readme_url="https://s3.amazonaws.com/$ARTIFACTS_BUCKET/$APP_NAME/$VERSION/docs/SAR-README.md"
    local license_url="https://s3.amazonaws.com/$ARTIFACTS_BUCKET/$APP_NAME/$VERSION/docs/LICENSE"
    
    # Check if documentation files are uploaded
    if ! aws s3 ls "s3://$ARTIFACTS_BUCKET/$APP_NAME/$VERSION/docs/SAR-README.md" --region "$SAR_REGION" > /dev/null 2>&1; then
        print_error "SAR-README.md not found in S3. Please run upload-artifacts.sh first."
    fi
    
    if ! aws s3 ls "s3://$ARTIFACTS_BUCKET/$APP_NAME/$VERSION/docs/LICENSE" --region "$SAR_REGION" > /dev/null 2>&1; then
        print_error "LICENSE not found in S3. Please run upload-artifacts.sh first."
    fi
    
    local result=$(aws serverlessrepo create-application \
        --name "$APP_NAME" \
        --description "$description" \
        --author "$author" \
        --spdx-license-id "$license" \
        --license-url "$license_url" \
        --readme-url "$readme_url" \
        --home-page-url "https://wpsuite.io/flow/" \
        --semantic-version "$VERSION" \
        --source-code-url "https://github.com/smartcloudsol/flow-backend/" \
        --template-url "$TEMPLATE_URL" \
        --region "$SAR_REGION" \
        --output json 2>&1) || {
        print_error "Failed to create application: $result"
    }
    
    export SAR_APP_ID=$(echo "$result" | jq -r '.ApplicationId' 2>/dev/null || echo "$result" | grep -o '"ApplicationId": "[^"]*"' | cut -d'"' -f4)
    
    if [ -z "$SAR_APP_ID" ]; then
        print_error "Failed to extract Application ID from response: $result"
    fi
    
    print_status "Application created: $SAR_APP_ID"
}

# Create new application version
create_application_version() {
    print_info "Creating application version $VERSION..."
    
    aws serverlessrepo create-application-version \
        --application-id "$SAR_APP_ID" \
        --semantic-version "$VERSION" \
        --source-code-url "https://github.com/smartcloudsol/flow-backend/" \
        --template-url "$TEMPLATE_URL" \
        --region "$SAR_REGION" || {
        print_error "Failed to create application version"
    }
    
    print_status "Application version created: $VERSION"
}

# Generate SAR deployment instructions
generate_sar_instructions() {
    print_info "Generating SAR deployment instructions..."
    
    local instructions_file="$BUILD_DIR/SAR-DEPLOYMENT.md"
    
    cat > "$instructions_file" << EOF
# SAR Deployment Instructions

## Application Information
- **Name**: $APP_NAME
- **Version**: $VERSION
- **Region**: $SAR_REGION
- **Application ID**: ${SAR_APP_ID:-<pending>}
- **Published**: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Deployment via AWS Console

1. Go to the [AWS Serverless Application Repository](https://console.aws.amazon.com/serverlessrepo/home?region=$SAR_REGION)
2. Search for "$APP_NAME"
3. Click on the application
4. Click "Deploy"
5. Configure parameters as needed
6. Click "Deploy" to create the CloudFormation stack

## Deployment via AWS CLI

\`\`\`bash
aws serverlessrepo create-cloud-formation-template \\
  --application-id ${SAR_APP_ID:-<APP_ID>} \\
  --semantic-version $VERSION \\
  --region $SAR_REGION

# Use the returned TemplateUrl to deploy
aws cloudformation create-stack \\
  --stack-name wpsuite-flow \\
  --template-url <TEMPLATE_URL> \\
  --capabilities CAPABILITY_IAM
\`\`\`

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
EOF
    
    print_status "SAR deployment instructions generated: $instructions_file"
}

# Display summary
show_summary() {
    echo ""
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}📊 Publication Summary${NC}"
    echo -e "${BLUE}================================${NC}"
    echo -e "${GREEN}App Name: $APP_NAME${NC}"
    echo -e "${GREEN}Version: $VERSION${NC}"
    echo -e "${GREEN}Region: $SAR_REGION${NC}"
    echo -e "${GREEN}Application ID: ${SAR_APP_ID:-<not set>}${NC}"
    echo ""
    echo -e "${BLUE}Template URL:${NC}"
    echo -e "  $TEMPLATE_URL"
    echo ""
    echo -e "${GREEN}✅ Publication completed successfully!${NC}"
    echo ""
}

# Main process
main() {
  show_config
  check_prerequisites
  ensure_local_artifacts
  configure_bucket_policy
  upload_artifacts_if_needed
  upload_documentation_files
  validate_version
  prepare_sar_template
  upload_sar_template
  
  if [ -z "${SAR_APP_ID:-}" ]; then
    create_application
  else
    create_application_version
  fi
  
  generate_sar_instructions
  show_summary
}

# Handle script interruption
trap 'print_error "Publication interrupted"' INT TERM

# Run main function
main "$@"
