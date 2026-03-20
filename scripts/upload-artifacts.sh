#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ARTIFACTS_BUCKET="${ARTIFACTS_BUCKET:-wpsuite-artifacts}"
APP_NAME="${APP_NAME:-wpsuite-flow}"
GIT_SHA="${GIT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo 'latest')}"
VERSION="${VERSION:-}"
ARTIFACT_VERSION="${ARTIFACT_VERSION:-${VERSION:-$GIT_SHA}}"
AWS_REGION="${AWS_REGION:-us-east-1}"
BUILD_DIR=".artifacts"
UPDATE_LATEST=false
FUNCTIONS=(
    "forms-api"
    "workflow-dispatcher"
    "email-sender"
    "webhook-dispatcher"
    "custom-resource"
)

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --update-latest)
            UPDATE_LATEST=true
            shift
            ;;
        --version)
            VERSION="$2"
            ARTIFACT_VERSION="$2"
            shift 2
            ;;
        --bucket)
            ARTIFACTS_BUCKET="$2"
            shift 2
            ;;
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}📤 Uploading artifacts to S3...${NC}"

# Function to print colored output
print_status() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
    exit 1
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# Check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed"
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity > /dev/null 2>&1; then
        print_error "AWS credentials not configured or invalid"
    fi
    
    # Check build artifacts
    if [ ! -d "$BUILD_DIR" ]; then
        print_error "Build directory $BUILD_DIR not found. Run build.sh first."
    fi
    
    print_status "Prerequisites checked"
}

# Display configuration
show_config() {
    print_info "Upload configuration:"
    echo "  Bucket: $ARTIFACTS_BUCKET"
    echo "  Region: $AWS_REGION"
    echo "  App Name: $APP_NAME"
    echo "  Git SHA: $GIT_SHA"
    echo "  Artifact Version: $ARTIFACT_VERSION"
    echo "  S3 Prefix: $APP_NAME/$ARTIFACT_VERSION"
    echo "  Update Latest: $UPDATE_LATEST"
    echo
}

# Create S3 bucket if it doesn't exist
create_bucket_if_needed() {
    print_info "Checking S3 bucket: $ARTIFACTS_BUCKET"
    
    if ! aws s3 ls "s3://$ARTIFACTS_BUCKET" > /dev/null 2>&1; then
        print_info "Creating S3 bucket: $ARTIFACTS_BUCKET"
        
        if [ "$AWS_REGION" = "us-east-1" ]; then
            aws s3api create-bucket \
                --bucket "$ARTIFACTS_BUCKET" \
                --region "$AWS_REGION"
        else
            aws s3api create-bucket \
                --bucket "$ARTIFACTS_BUCKET" \
                --region "$AWS_REGION" \
                --create-bucket-configuration LocationConstraint="$AWS_REGION"
        fi
        
        # Enable versioning
        aws s3api put-bucket-versioning \
            --bucket "$ARTIFACTS_BUCKET" \
            --versioning-configuration Status=Enabled
        
        # Add lifecycle policy to clean up old versions
        cat > /tmp/lifecycle-policy.json << EOF
{
    "Rules": [
        {
            "Id": "DeleteOldVersions",
            "Status": "Enabled",
            "NoncurrentVersionExpiration": {
                "NoncurrentDays": 90
            },
            "AbortIncompleteMultipartUpload": {
                "DaysAfterInitiation": 7
            }
        }
    ]
}
EOF
        
        aws s3api put-bucket-lifecycle-configuration \
            --bucket "$ARTIFACTS_BUCKET" \
            --lifecycle-configuration file:///tmp/lifecycle-policy.json 2>/dev/null || {
            print_warning "Could not set lifecycle policy (bucket may not support it)"
        }
        
        rm -f /tmp/lifecycle-policy.json
        
        print_status "S3 bucket created and configured"
    else
        print_status "S3 bucket exists"
    fi
}

# Upload Lambda function packages
upload_functions() {
    print_info "Uploading Lambda function packages..."
    
    local s3_prefix="$APP_NAME/$ARTIFACT_VERSION"
    local uploaded_count=0
    
    for func in "${FUNCTIONS[@]}"; do
        local zip_file="$BUILD_DIR/${func}.zip"
        
        if [ ! -f "$zip_file" ]; then
            print_warning "$zip_file not found, skipping"
            continue
        fi
        
        local s3_key="$s3_prefix/functions/${func}.zip"
        local file_size=$(du -h "$zip_file" | cut -f1)
        
        print_info "Uploading $func ($file_size)..."
        
        aws s3 cp "$zip_file" "s3://$ARTIFACTS_BUCKET/$s3_key" \
            --region "$AWS_REGION" \
            --metadata "git-sha=$GIT_SHA,build-time=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --quiet || {
            print_error "Failed to upload $func"
        }
        
        # Update latest symlink if requested
        if [ "$UPDATE_LATEST" = true ]; then
            local latest_key="$APP_NAME/latest/functions/${func}.zip"
            aws s3 cp "$zip_file" "s3://$ARTIFACTS_BUCKET/$latest_key" \
                --region "$AWS_REGION" \
                --metadata "git-sha=$GIT_SHA,build-time=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                --quiet || {
                print_warning "Failed to update latest for $func"
            }
        fi
        
        uploaded_count=$((uploaded_count + 1))
        print_status "$func uploaded"
    done
    
    print_status "Uploaded $uploaded_count function packages"
}

# Upload CloudFormation templates
upload_templates() {
    print_info "Uploading CloudFormation templates..."
    
    local s3_prefix="$APP_NAME/$ARTIFACT_VERSION"
    local template_file="$BUILD_DIR/template.sar.yaml"
    
    if [ ! -f "$template_file" ]; then
        print_warning "Template file not found, skipping"
        return
    fi
    
    local s3_key="$s3_prefix/template.yaml"
    
    print_info "Uploading template.yaml..."
    
    aws s3 cp "$template_file" "s3://$ARTIFACTS_BUCKET/$s3_key" \
        --region "$AWS_REGION" \
        --content-type "text/yaml" \
        --metadata "git-sha=$GIT_SHA,build-time=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --quiet || {
        print_error "Failed to upload template"
    }
    
    # Update latest if requested
    if [ "$UPDATE_LATEST" = true ]; then
        local latest_key="$APP_NAME/latest/template.yaml"
        aws s3 cp "$template_file" "s3://$ARTIFACTS_BUCKET/$latest_key" \
            --region "$AWS_REGION" \
            --content-type "text/yaml" \
            --quiet
    fi
    
    print_status "Template uploaded"
}

# Upload documentation files
upload_documentation() {
    print_info "Uploading documentation files..."
    
    local s3_prefix="$APP_NAME/$ARTIFACT_VERSION"
    local uploaded_count=0
    
    for doc in README.md SAR-README.md LICENSE; do
        local doc_file="$BUILD_DIR/docs/$doc"
        
        if [ ! -f "$doc_file" ]; then
            print_warning "$doc not found, skipping"
            continue
        fi
        
        local s3_key="$s3_prefix/docs/$doc"
        
        aws s3 cp "$doc_file" "s3://$ARTIFACTS_BUCKET/$s3_key" \
            --region "$AWS_REGION" \
            --content-type "text/markdown" \
            --quiet || {
            print_warning "Failed to upload $doc"
            continue
        }
        
        # Update latest if requested
        if [ "$UPDATE_LATEST" = true ]; then
            local latest_key="$APP_NAME/latest/docs/$doc"
            aws s3 cp "$doc_file" "s3://$ARTIFACTS_BUCKET/$latest_key" \
                --region "$AWS_REGION" \
                --content-type "text/markdown" \
                --quiet
        fi
        
        uploaded_count=$((uploaded_count + 1))
    done
    
    print_status "Uploaded $uploaded_count documentation files"
}

# Upload build metadata
upload_metadata() {
    print_info "Uploading build metadata..."
    
    local metadata_file="$BUILD_DIR/build-metadata.json"
    local s3_prefix="$APP_NAME/$ARTIFACT_VERSION"
    
    if [ ! -f "$metadata_file" ]; then
        print_warning "Build metadata not found, skipping"
        return
    fi
    
    local s3_key="$s3_prefix/build-metadata.json"
    
    aws s3 cp "$metadata_file" "s3://$ARTIFACTS_BUCKET/$s3_key" \
        --region "$AWS_REGION" \
        --content-type "application/json" \
        --quiet || {
        print_warning "Failed to upload build metadata"
    }
    
    print_status "Build metadata uploaded"
}

# Generate and upload deployment manifest
generate_deployment_manifest() {
    print_info "Generating deployment manifest..."
    
    local s3_prefix="$APP_NAME/$ARTIFACT_VERSION"
    local manifest_file="/tmp/deployment-manifest.json"
    
    # Create deployment manifest
    cat > "$manifest_file" << EOF
{
  "version": "1.0",
  "appName": "$APP_NAME",
  "artifactVersion": "$ARTIFACT_VERSION",
  "gitSha": "$GIT_SHA",
  "buildTime": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "region": "$AWS_REGION",
  "bucket": "$ARTIFACTS_BUCKET",
  "s3Prefix": "$s3_prefix",
  "functions": {
$(for func in "${FUNCTIONS[@]}"; do
    if [ -f "$BUILD_DIR/${func}.zip" ]; then
        echo "    \"$func\": \"s3://$ARTIFACTS_BUCKET/$s3_prefix/functions/${func}.zip\","
    fi
done | sed '$ s/,$//')
  },
  "templates": {
    "main": "s3://$ARTIFACTS_BUCKET/$s3_prefix/template.yaml"
  },
  "urls": {
    "template": "https://$ARTIFACTS_BUCKET.s3.$AWS_REGION.amazonaws.com/$s3_prefix/template.yaml"
  }
}
EOF
    
    # Upload manifest
    local s3_key="$s3_prefix/deployment-manifest.json"
    
    aws s3 cp "$manifest_file" "s3://$ARTIFACTS_BUCKET/$s3_key" \
        --region "$AWS_REGION" \
        --content-type "application/json" \
        --quiet || {
        print_error "Failed to upload deployment manifest"
    }
    
    rm -f "$manifest_file"
    print_status "Deployment manifest uploaded"
}

# Export environment variables for packaging script
export_variables() {
    print_info "Exporting environment variables..."
    
    cat > "$BUILD_DIR/packaging-env.sh" << EOF
#!/bin/bash
# Generated by upload-artifacts.sh
export ARTIFACTS_BUCKET="$ARTIFACTS_BUCKET"
export S3_PREFIX="$APP_NAME/$ARTIFACT_VERSION"
export AWS_REGION="$AWS_REGION"
export APP_NAME="$APP_NAME"
export GIT_SHA="$GIT_SHA"
export ARTIFACT_VERSION="$ARTIFACT_VERSION"
export TEMPLATE_URL="https://$ARTIFACTS_BUCKET.s3.$AWS_REGION.amazonaws.com/$APP_NAME/$ARTIFACT_VERSION/template.yaml"
EOF
    
    chmod +x "$BUILD_DIR/packaging-env.sh"
    print_status "Environment variables exported to $BUILD_DIR/packaging-env.sh"
}

# Display upload summary
show_summary() {
    echo ""
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}📊 Upload Summary${NC}"
    echo -e "${BLUE}================================${NC}"
    echo -e "${GREEN}Bucket: $ARTIFACTS_BUCKET${NC}"
    echo -e "${GREEN}Prefix: $APP_NAME/$ARTIFACT_VERSION${NC}"
    echo ""
    echo -e "${BLUE}Uploaded Artifacts:${NC}"
    
    for func in "${FUNCTIONS[@]}"; do
        if [ -f "$BUILD_DIR/${func}.zip" ]; then
            local size=$(du -h "$BUILD_DIR/${func}.zip" | cut -f1)
            echo -e "  ${GREEN}✅${NC} functions/$func.zip ($size)"
        fi
    done
    
    echo -e "  ${GREEN}✅${NC} template.yaml"
    echo -e "  ${GREEN}✅${NC} build-metadata.json"
    echo -e "  ${GREEN}✅${NC} deployment-manifest.json"
    echo ""
    echo -e "${BLUE}Template URL:${NC}"
    echo -e "  https://$ARTIFACTS_BUCKET.s3.$AWS_REGION.amazonaws.com/$APP_NAME/$ARTIFACT_VERSION/template.yaml"
    echo ""
    echo -e "${GREEN}✅ Upload completed successfully!${NC}"
    echo ""
}

# Main upload process
main() {
    check_prerequisites
    show_config
    create_bucket_if_needed
    upload_functions
    upload_templates
    upload_documentation
    upload_metadata
    generate_deployment_manifest
    export_variables
    show_summary
}

# Handle script interruption
trap 'print_error "Upload interrupted"' INT TERM

# Run main function
main "$@"
