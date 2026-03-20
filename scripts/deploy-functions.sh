#!/usr/bin/env bash
# Deploy all Lambda functions from .artifacts folder
# Usage: ./scripts/deploy-functions.sh [function-prefix]

set -uo pipefail

# Configuration
FUNCTION_PREFIX="${1:-wswf}"
ARTIFACTS_DIR=".artifacts"

# Functions to deploy (zip name -> Lambda function name)
declare -A FUNCTION_MAP=(
  ["forms-api"]="forms-api"
  ["workflow-dispatcher"]="workflow-dispatcher"
  ["email-sender"]="email-sender"
  ["webhook-dispatcher"]="webhook-dispatcher"
  ["custom-resource"]="custom-resource-manager"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 Deploying Lambda Functions${NC}"
echo "=================================="
echo ""
echo "Function Prefix: ${FUNCTION_PREFIX}-"
echo "Artifacts Directory: ${ARTIFACTS_DIR}"
echo ""

# Check if artifacts directory exists
if [ ! -d "$ARTIFACTS_DIR" ]; then
  echo -e "${RED}❌ Error: Artifacts directory not found: $ARTIFACTS_DIR${NC}"
  echo "Please run 'BUILD_MODE=minified bash scripts/build.sh' first"
  exit 1
fi

# Cross-platform file size helper (echo bytes or 0)
file_size_bytes() {
  local p="$1"
  # Linux (GNU coreutils)
  if size=$(stat -c%s "$p" 2>/dev/null); then
    echo "$size"; return 0
  fi
  # macOS / BSD
  if size=$(stat -f%z "$p" 2>/dev/null); then
    echo "$size"; return 0
  fi
  echo 0
}

DEPLOYED=0
FAILED=0
SKIPPED=0

echo "=================================="
echo -e "${BLUE}📦 Deploying Lambda Functions${NC}"
echo "=================================="
echo ""

# Deploy each function
for zip_file in forms-api workflow-dispatcher email-sender webhook-dispatcher custom-resource; do
  func_name="${FUNCTION_MAP[$zip_file]}"
  full_func_name="${FUNCTION_PREFIX}-${func_name}"
  zip_path="${ARTIFACTS_DIR}/${zip_file}.zip"

  if [ ! -f "$zip_path" ]; then
    echo -e "${YELLOW}⚠️  Skipping $full_func_name: $zip_path not found${NC}"
    SKIPPED=$((SKIPPED+1))
    echo ""
    continue
  fi

  file_size=$(file_size_bytes "$zip_path")
  file_size_mb=$(awk -v s="$file_size" 'BEGIN{ if (s+0==0) {printf "0.00"} else {printf "%.2f", s/1024/1024} }')

  echo -e "${BLUE}📦 Deploying $full_func_name${NC}"
  echo "   Artifact: $zip_path (${file_size_mb}MB)"

  # Run the aws command and capture output and status
  result="$(
    aws lambda update-function-code \
      --function-name "$full_func_name" \
      --zip-file "fileb://$zip_path" \
      --output json \
      --query '{FunctionName: FunctionName, LastModified: LastModified, CodeSize: CodeSize, Runtime: Runtime}' 2>&1
  )"
  status=$?

  if [ $status -eq 0 ]; then
    echo -e "${GREEN}   ✅ Deployed successfully${NC}"
    if command -v jq >/dev/null 2>&1; then
      echo "$result" | jq -r '"   Last Modified: \(.LastModified)\n   Code Size: \(.CodeSize) bytes\n   Runtime: \(.Runtime)"' 2>/dev/null || echo "   $result"
    else
      echo "   $result"
    fi
    DEPLOYED=$((DEPLOYED+1))
  else
    echo -e "${RED}   ❌ Deployment failed${NC}"
    echo "   $result"
    FAILED=$((FAILED+1))
  fi

  echo ""
done

# Summary
echo "=================================="
echo -e "${BLUE}📊 Deployment Summary${NC}"
echo "=================================="
echo -e "${GREEN}✅ Deployed: $DEPLOYED${NC}"
if [ $FAILED -gt 0 ]; then
  echo -e "${RED}❌ Failed: $FAILED${NC}"
fi
if [ $SKIPPED -gt 0 ]; then
  echo -e "${YELLOW}⚠️  Skipped: $SKIPPED${NC}"
fi
echo ""

# Exit code based on collected status
if [ $FAILED -gt 0 ]; then
  echo -e "${RED}❌ Some deployments failed!${NC}"
  exit 1
else
  echo -e "${GREEN}🎉 All deployments completed successfully!${NC}"
  exit 0
fi
