#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.artifacts"
APP_NAME="${APP_NAME:-wpsuite-flow}"
VERSION="${VERSION:-1.0.0}"
ARTIFACT_VERSION="${ARTIFACT_VERSION:-$VERSION}"
S3_PREFIX="${S3_PREFIX:-wpsuite-flow}"
PUBLISH_REGIONS="${PUBLISH_REGIONS:-us-east-1}"
SUPPORTED_REGIONS=(us-east-1 us-west-2 ca-central-1 eu-central-1 eu-west-2 ap-southeast-1 ap-northeast-1 ap-northeast-2 ap-southeast-2 me-central-1)
BUILD_BEFORE_PUBLISH="${BUILD_BEFORE_PUBLISH:-true}"
UPLOAD_BEFORE_PUBLISH="${UPLOAD_BEFORE_PUBLISH:-true}"
TEMPLATE_ONLY_PUBLISH="${TEMPLATE_ONLY_PUBLISH:-false}"
CONFIGURE_BUCKET_POLICY="${CONFIGURE_BUCKET_POLICY:-false}"
FULL_PREFIX="$S3_PREFIX/$ARTIFACT_VERSION"
WRAPPER_PREFIX="$S3_PREFIX/wrapper"

print_info(){ echo "[info] $1"; }
print_status(){ echo "[ok] $1"; }
print_warn(){ echo "[warn] $1"; }
print_error(){ echo "[error] $1"; exit 1; }

trim(){
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

normalize_publish_mode() {
  if [ "$TEMPLATE_ONLY_PUBLISH" = "true" ]; then
    BUILD_BEFORE_PUBLISH="false"
    UPLOAD_BEFORE_PUBLISH="false"
  fi
}

show_config() {
  print_info "Regional publish configuration"
  echo "  App Name: $APP_NAME"
  echo "  Version: $VERSION"
  echo "  Artifact Version: $ARTIFACT_VERSION"
  echo "  S3 Prefix: $S3_PREFIX"
  echo "  Publish Regions: $PUBLISH_REGIONS"
  echo "  Template Only Publish: $TEMPLATE_ONLY_PUBLISH"
  echo
}

default_bucket_for_region() {
  if [ "$1" = "me-central-1" ]; then
    printf '%s' "wpsuite-artifacts-637423296378-$1"
  else
    printf '%s' "wpsuite-artifacts-637423296378-$1-an"
  fi
}

get_bucket_for_region() {
  local region="$1"
  local env_var="ARTIFACT_BUCKET_$(printf '%s' "$region" | tr '[:lower:]-' '[:upper:]_')"
  local bucket_override="${!env_var:-}"

  case "$region" in
    us-east-1|eu-central-1|eu-west-2|us-west-2|ca-central-1|ap-southeast-1|ap-northeast-1|ap-northeast-2|ap-southeast-2|me-central-1)
      if [ -n "$bucket_override" ]; then
        printf '%s' "$bucket_override"
      else
        default_bucket_for_region "$region"
      fi
      ;;
    *) print_error "Unsupported publish region: $region" ;;
  esac
}

check_prerequisites() {
  command -v aws >/dev/null || print_error "AWS CLI is not installed"
  command -v python3 >/dev/null || print_error "python3 is required"
  aws sts get-caller-identity >/dev/null 2>&1 || print_error "AWS credentials not configured or invalid"
  [ -f "$ROOT_DIR/template.yaml" ] || print_error "template.yaml not found"
  [ -f "$ROOT_DIR/wrapper.yaml" ] || print_error "wrapper.yaml not found"
}

resolve_publish_regions() {
  TARGET_REGIONS=()

  if [ "$PUBLISH_REGIONS" = "all" ]; then
    TARGET_REGIONS=("${SUPPORTED_REGIONS[@]}")
    return
  fi

  IFS=',' read -r -a requested_regions <<< "$PUBLISH_REGIONS"
  for raw_region in "${requested_regions[@]}"; do
    local region
    region="$(trim "$raw_region")"
    [ -n "$region" ] || continue

    local supported=false
    for candidate in "${SUPPORTED_REGIONS[@]}"; do
      if [ "$candidate" = "$region" ]; then
        supported=true
        break
      fi
    done

    [ "$supported" = true ] || print_error "Unsupported publish region: $region"

    local duplicate=false
    for existing in "${TARGET_REGIONS[@]:-}"; do
      if [ "$existing" = "$region" ]; then
        duplicate=true
        break
      fi
    done
    [ "$duplicate" = true ] || TARGET_REGIONS+=("$region")
  done

  [ "${#TARGET_REGIONS[@]}" -gt 0 ] || print_error "No publish regions resolved from PUBLISH_REGIONS=$PUBLISH_REGIONS"
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

configure_bucket_policy() {
  local bucket="$1"
  local region="$2"
  [ "$CONFIGURE_BUCKET_POLICY" = "true" ] || return 0

  print_info "Configuring CloudFormation/public access for $bucket"
  mkdir -p "$BUILD_DIR"
  local tmp_policy="$BUILD_DIR/publish-bucket-policy-$region.json"

  python3 - "$bucket" <<'PY' > "$tmp_policy"
import json
import subprocess
import sys

bucket = sys.argv[1]
try:
    current = subprocess.check_output(
        [
            'aws', 's3api', 'get-bucket-policy', '--bucket', bucket,
            '--query', 'Policy', '--output', 'text'
        ],
        stderr=subprocess.DEVNULL,
        text=True,
    ).strip()
    policy = json.loads(current) if current and current != 'None' else {"Version": "2012-10-17", "Statement": []}
except Exception:
    policy = {"Version": "2012-10-17", "Statement": []}

statements = [
    s for s in policy.get("Statement", [])
    if s.get("Sid") not in {
        "AllowCloudFormationAccess",
        "AllowPublicAccess",
        "AllowCloudFormationReadPublishedArtifacts",
    }
]

statements.append({
    "Sid": "AllowCloudFormationAccess",
    "Effect": "Allow",
    "Principal": {"Service": "cloudformation.amazonaws.com"},
    "Action": "s3:GetObject",
    "Resource": [
        f"arn:aws:s3:::{bucket}/*/*/docs/*",
        f"arn:aws:s3:::{bucket}/*/*/functions/*",
        f"arn:aws:s3:::{bucket}/*/*/layers/*",
        f"arn:aws:s3:::{bucket}/*/*/template.yaml",
    ],
})
statements.append({
    "Sid": "AllowPublicAccess",
    "Effect": "Allow",
    "Principal": {"AWS": "*"},
    "Action": "s3:GetObject",
    "Resource": f"arn:aws:s3:::{bucket}/*/wrapper/*",
})

policy["Statement"] = statements
print(json.dumps(policy))
PY

  aws s3api put-bucket-policy --bucket "$bucket" --policy file://"$tmp_policy" --region "$region" >/dev/null
  rm -f "$tmp_policy"
}

upload_artifacts_if_needed() {
  local bucket="$1"
  local region="$2"
  [ "$UPLOAD_BEFORE_PUBLISH" = "true" ] || return 0

  print_info "Uploading packaged Lambda artifacts to s3://$bucket/$FULL_PREFIX"
  ARTIFACTS_BUCKET="$bucket" \
  AWS_REGION="$region" \
  APP_NAME="$APP_NAME" \
  S3_PREFIX="$S3_PREFIX" \
  ARTIFACT_VERSION="$ARTIFACT_VERSION" \
  VERSION="$VERSION" \
  bash "$ROOT_DIR/scripts/upload-artifacts.sh"
}

upload_documentation_files() {
  local bucket="$1"
  local region="$2"

  aws s3 cp "$ROOT_DIR/LICENSE" "s3://$bucket/$FULL_PREFIX/docs/LICENSE" --region "$region" >/dev/null
  aws s3 cp "$ROOT_DIR/SAR-README.md" "s3://$bucket/$FULL_PREFIX/docs/SAR-README.md" --region "$region" >/dev/null
}

materialize_template() {
  local input_file="$1"
  local output_file="$2"
  local bucket="$3"
  local prefix="$4"
  local artifact_version="$5"

  python3 - "$input_file" "$output_file" "$bucket" "$prefix" "$artifact_version" <<'PY'
import re
import sys
from pathlib import Path

input_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
bucket = sys.argv[3]
prefix = sys.argv[4]
artifact_version = sys.argv[5]

text = input_path.read_text(encoding='utf-8')
keys_to_remove = {"DeploymentVersion", "ArtifactBucketName", "ArtifactKeyPrefix"}
lines = text.splitlines(True)
out = []
in_parameters = False
skip_key = None
skip_indent = None
for line in lines:
    stripped = line.lstrip(' ')
    indent = len(line) - len(stripped)
    if indent == 0 and stripped.startswith('Parameters:'):
        in_parameters = True
        out.append(line)
        continue
    if in_parameters and indent == 0 and stripped and not stripped.startswith('#') and not stripped.startswith(' '):
        in_parameters = False
        skip_key = None
        skip_indent = None
    if in_parameters:
        if skip_key is not None:
            if stripped.strip() == '':
                continue
            if indent > skip_indent:
                continue
            skip_key = None
            skip_indent = None
        match = re.match(r'^(\s{2})([A-Za-z0-9]+):\s*$', line)
        if match and match.group(2) in keys_to_remove:
            skip_key = match.group(2)
            skip_indent = len(match.group(1))
            continue
    out.append(line)

text = ''.join(out)
text = text.replace('${DeploymentVersion}', artifact_version)
text = text.replace('${ArtifactBucketName}', bucket)
text = text.replace('${ArtifactKeyPrefix}', prefix)
text = re.sub(r'^(\s*SemanticVersion:\s*)!Ref\s+DeploymentVersion\s*$', rf'\1"{artifact_version}"', text, flags=re.MULTILINE)
text = re.sub(r'^(\s*LicenseUrl:\s*)!Sub\s+s3://\$\{ArtifactBucketName\}/\$\{ArtifactKeyPrefix\}/[^\s]+/docs/LICENSE\s*$', rf'\1"s3://{bucket}/{prefix}/{artifact_version}/docs/LICENSE"', text, flags=re.MULTILINE)
text = re.sub(r'^(\s*ReadmeUrl:\s*)!Sub\s+s3://\$\{ArtifactBucketName\}/\$\{ArtifactKeyPrefix\}/[^\s]+/docs/SAR-README\.md\s*$', rf'\1"s3://{bucket}/{prefix}/{artifact_version}/docs/SAR-README.md"', text, flags=re.MULTILINE)
text = re.sub(r'^(\s*SourceBucketName:\s*)!Ref\s+ArtifactBucketName\s*$', rf'\1{bucket}', text, flags=re.MULTILINE)
pattern = re.compile(r'^(?P<indent>\s*)(?P<kind>CodeUri|ContentUri):\s*\n(?P=indent)\s{2}Bucket:\s*(?P<bucket_val>.+?)\s*\n(?P=indent)\s{2}Key:\s*(?P<key_val>.+?)\s*$', flags=re.MULTILINE)

def clean_key(value: str) -> str:
    value = value.strip()
    if value.startswith('!Sub '):
        value = value[len('!Sub '):].strip()
    value = value.strip('"\'')
    value = value.replace('${DeploymentVersion}', artifact_version)
    value = value.replace('${ArtifactKeyPrefix}', prefix)
    return value

text = pattern.sub(lambda match: f"{match.group('indent')}{match.group('kind')}: s3://{bucket}/{clean_key(match.group('key_val'))}", text)
output_path.write_text(text, encoding='utf-8')
PY
}

materialize_wrapper() {
  local input_file="$1"
  local output_file="$2"
  local bucket="$3"
  local prefix="$4"
  local region="$5"

  python3 - "$input_file" "$output_file" "$bucket" "$prefix" "$region" <<'PY'
import re
import sys
from pathlib import Path

input_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
bucket = sys.argv[3]
prefix = sys.argv[4]
region = sys.argv[5]

text = input_path.read_text(encoding='utf-8')
keys_to_remove = {"ArtifactBucketName", "ArtifactKeyPrefix"}
lines = text.splitlines(True)
out = []
in_parameters = False
skip_key = None
skip_indent = None
for line in lines:
    stripped = line.lstrip(' ')
    indent = len(line) - len(stripped)
    if indent == 0 and stripped.startswith('Parameters:'):
        in_parameters = True
        out.append(line)
        continue
    if in_parameters and indent == 0 and stripped and not stripped.startswith('#') and not stripped.startswith(' '):
        in_parameters = False
        skip_key = None
        skip_indent = None
    if in_parameters:
        if skip_key is not None:
            if stripped.strip() == '':
                continue
            if indent > skip_indent:
                continue
            skip_key = None
            skip_indent = None
        match = re.match(r'^(\s{2})([A-Za-z0-9]+):\s*$', line)
        if match and match.group(2) in keys_to_remove:
            skip_key = match.group(2)
            skip_indent = len(match.group(1))
            continue
    out.append(line)

text = ''.join(out)
text = text.replace('${ArtifactBucketName}', bucket)
text = text.replace('${ArtifactKeyPrefix}', prefix)
text = text.replace('${AWS::Region}', region)
output_path.write_text(text, encoding='utf-8')
PY
}

publish_region() {
  local region="$1"
  local bucket
  bucket="$(get_bucket_for_region "$region")"
  local region_dir="$BUILD_DIR/published/$region"
  local template_output="$region_dir/template.yaml"
  local wrapper_output="$region_dir/wrapper.yaml"

  mkdir -p "$region_dir"
  print_info "Publishing $APP_NAME to $region using bucket $bucket"

  configure_bucket_policy "$bucket" "$region"
  upload_artifacts_if_needed "$bucket" "$region"
  upload_documentation_files "$bucket" "$region"

  materialize_template "$ROOT_DIR/template.yaml" "$template_output" "$bucket" "$S3_PREFIX" "$ARTIFACT_VERSION"
  materialize_wrapper "$ROOT_DIR/wrapper.yaml" "$wrapper_output" "$bucket" "$S3_PREFIX" "$region"

  aws s3 cp "$template_output" "s3://$bucket/$FULL_PREFIX/template.yaml" --region "$region" --content-type text/yaml >/dev/null
  aws s3 cp "$wrapper_output" "s3://$bucket/$WRAPPER_PREFIX/wrapper.yaml" --region "$region" --content-type text/yaml >/dev/null

  print_status "Published wrapper: https://$bucket.s3.$region.amazonaws.com/$WRAPPER_PREFIX/wrapper.yaml"
}

main() {
  local successful_regions=()
  local failed_regions=()

  show_config
  normalize_publish_mode
  check_prerequisites
  resolve_publish_regions
  ensure_local_artifacts

  for region in "${TARGET_REGIONS[@]}"; do
    if [ "$PUBLISH_REGIONS" = "all" ]; then
      if ( publish_region "$region" ); then
        successful_regions+=("$region")
      else
        failed_regions+=("$region")
        print_warn "Publish failed for $region, continuing because PUBLISH_REGIONS=all"
      fi
    else
      publish_region "$region"
      successful_regions+=("$region")
    fi
  done

  if [ "${#failed_regions[@]}" -gt 0 ]; then
    print_warn "Failed regions: ${failed_regions[*]}"
  fi

  if [ "${#successful_regions[@]}" -gt 0 ]; then
    print_status "Successfully published regions: ${successful_regions[*]}"
  fi

  if [ "$PUBLISH_REGIONS" = "all" ] && [ "${#successful_regions[@]}" -eq 0 ]; then
    print_error "Publishing failed in every target region"
  fi
}

main "$@"