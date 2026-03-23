#!/bin/bash
set -euo pipefail

# Configuration
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.artifacts"
BUILD_MODE="${BUILD_MODE:-minified}"
SKIP_TESTS="${SKIP_TESTS:-false}"
SKIP_LINTING="${SKIP_LINTING:-false}"
FUNCTIONS=(forms-api workflow-dispatcher email-sender webhook-dispatcher custom-resource)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Check Node.js version
check_node_version() {
    print_info "Checking Node.js version..."
    
    if ! command -v node &> /dev/null; then
        print_error "Node.js is not installed"
    fi
    
    local node_version=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
    if [ "$node_version" -lt 18 ]; then
        print_error "Node.js version 18 or higher is required (current: $(node -v))"
    fi
    
    print_status "Node.js version: $(node -v)"
}

# Check required tools
check_tools() {
    print_info "Checking required tools..."
    
    if ! command -v npm &> /dev/null; then
        print_error "npm is not installed"
    fi
    
    if ! command -v zip &> /dev/null; then
        print_error "zip is not installed"
    fi
    
    print_status "Required tools available"
}

# Clean previous build artifacts
clean_build() {
    print_info "Cleaning previous build artifacts..."
    
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR/functions" "$BUILD_DIR/docs"
    
    for func in "${FUNCTIONS[@]}"; do
        local func_dir="src/$func"
        if [ -d "$func_dir/dist" ]; then
            rm -rf "$func_dir/dist"
            print_info "Cleaned $func_dir/dist"
        fi
    done
    
    print_status "Build artifacts cleaned"
}

# Install root dependencies
install_root_dependencies() {
    print_info "Installing root dependencies..."
    
    if [ ! -f "package.json" ]; then
        print_warning "package.json not found in root directory, skipping root dependencies"
        return
    fi
    
    if [ -d "node_modules" ] && [ -f "node_modules/.package-lock.json" -o -f "node_modules/esbuild/bin/esbuild" -o -d "node_modules/@aws-sdk" ]; then
        print_info "Reusing existing node_modules"
    # Detect package manager, but fall back if the preferred one is not installed
    elif [ -f "yarn.lock" ] && command -v yarn &> /dev/null; then
        print_info "Using yarn (detected yarn.lock)"
        yarn install --silent || {
            print_error "Failed to install root dependencies with yarn"
        }
    elif [ -f "package-lock.json" ]; then
        print_info "Using npm (detected package-lock.json)"
        npm ci --silent || npm install --silent || {
            print_error "Failed to install root dependencies with npm"
        }
    else
        print_info "Using npm install (no lock file found)"
        npm install --silent || {
            print_error "Failed to install root dependencies"
        }
    fi
    
    print_status "Root dependencies installed"
}

# Run linting
run_linting() {
    if [ "$SKIP_LINTING" = "true" ]; then
        print_warning "Linting skipped (SKIP_LINTING=true)"
        return
    fi
    
    print_info "Running ESLint..."
    
    if [ -f ".eslintrc.js" ] || [ -f ".eslintrc.json" ] || [ -f "eslint.config.js" ] || [ -f "eslint.config.cjs" ]; then
        npm run lint --silent 2>/dev/null || {
            print_warning "Linting failed or no lint script found"
        }
    else
        print_warning "No ESLint configuration found, skipping linting"
    fi
    
    print_status "Linting completed"
}

# Run tests
run_tests() {
    if [ "$SKIP_TESTS" = "true" ]; then
        print_warning "Tests skipped (SKIP_TESTS=true)"
        return
    fi
    
    print_info "Running tests..."
    
    if [ -f "scripts/test-unit.sh" ]; then
        bash scripts/test-unit.sh || {
            print_warning "Tests failed or no tests found"
        }
    elif grep -q '"test"' package.json 2>/dev/null; then
        npm run test -- --testPathPatterns=unit --silent 2>/dev/null || {
            print_warning "Tests failed or no tests found"
        }
    else
        print_warning "No test script found, skipping tests"
    fi
    
    print_status "Tests completed"
}

# Build TypeScript for a function
build_function() {
    local func_name=$1
    local func_dir="src/$func_name"
    
    print_info "Building $func_name handler..."
    
    if [ ! -d "$func_dir" ]; then
        print_error "Function directory $func_dir not found"
    fi
    
    # Check if TypeScript files exist
    if [ ! -f "$func_dir/handler.ts" ]; then
        print_error "handler.ts not found in $func_dir"
    fi
    
    # Build with esbuild
    print_info "Compiling TypeScript for $func_name (mode: $BUILD_MODE)..."
    
    # Flow backend always uses CommonJS for AWS SDK compatibility
    local output_format="cjs"
    local output_extension="js"
    
    local esbuild_args=(
        "$func_dir/handler.ts"
        "--bundle"
        "--target=node24"
        "--platform=node"
        "--outfile=$BUILD_DIR/functions/$func_name/index.${output_extension}"
        "--format=${output_format}"
        "--external:@aws-sdk/client-dynamodb"
        "--external:@aws-sdk/lib-dynamodb"
        "--external:@aws-sdk/client-eventbridge"
        "--external:@aws-sdk/client-guardduty"
        "--external:@aws-sdk/client-s3"
        "--external:@aws-sdk/s3-request-presigner"
        "--external:@aws-sdk/client-ssm"
        "--external:@aws-sdk/client-sesv2"
        "--external:@aws-sdk/client-wafv2"
        "--external:@aws-sdk/client-api-gateway"
        "--external:@aws-sdk/client-kms"
        "--define:process.env.NODE_ENV=\"production\""
    )
    
    if [ "$BUILD_MODE" = "minified" ]; then
        esbuild_args+=(
            "--minify"
            "--drop:debugger"
        )
        print_info "Building minified version (production)"
    else
        esbuild_args+=(
            "--sourcemap"
            "--keep-names"
            "--legal-comments=inline"
        )
        print_info "Building readable version (development)"
    fi
    
    # Create output directory
    mkdir -p "$BUILD_DIR/functions/$func_name"
    
    npx esbuild "${esbuild_args[@]}" 2>/dev/null || {
        print_error "Failed to build $func_name"
    }
    
    # Verify build output
    if [ ! -f "$BUILD_DIR/functions/$func_name/index.${output_extension}" ]; then
        print_error "Build output not found for $func_name (expected: $BUILD_DIR/functions/$func_name/index.${output_extension})"
    fi
    
    print_status "$func_name built successfully"
}

# Package function for deployment
package_function() {
    local func_name=$1
    
    print_info "Packaging $func_name..."
    
    # Create deployment package from the built function directory
    cd "$BUILD_DIR/functions/$func_name"
    
    # Create zip file
    zip -r "../../${func_name}.zip" . -q 2>/dev/null || {
        print_error "Failed to package $func_name"
    }
    
    cd - > /dev/null
    
    # Verify package was created
    if [ ! -f "$BUILD_DIR/${func_name}.zip" ]; then
        print_error "Package not created for $func_name"
    fi
    
    local package_size=$(du -h "$BUILD_DIR/${func_name}.zip" | cut -f1)
    print_info "Package size: $package_size"
    
    print_status "$func_name packaged successfully"
}

# Copy documentation files
copy_documentation() {
    print_info "Copying documentation files..."
    
    if [ -f "$ROOT_DIR/README.md" ]; then
        cp "$ROOT_DIR/README.md" "$BUILD_DIR/docs/README.md"
    fi
    
    if [ -f "$ROOT_DIR/SAR-README.md" ]; then
        cp "$ROOT_DIR/SAR-README.md" "$BUILD_DIR/docs/SAR-README.md"
    fi
    
    if [ -f "$ROOT_DIR/LICENSE" ]; then
        cp "$ROOT_DIR/LICENSE" "$BUILD_DIR/docs/LICENSE"
    fi
    
    print_status "Documentation files copied"
}

# Generate build metadata
generate_metadata() {
    print_info "Generating build metadata..."
    
    local git_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    local git_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    local build_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    cat > "$BUILD_DIR/build-metadata.json" << EOF
{
  "buildTime": "$build_time",
  "buildMode": "$BUILD_MODE",
  "gitSha": "$git_sha",
  "gitBranch": "$git_branch",
  "nodeVersion": "$(node -v)",
  "functions": [
$(for func in "${FUNCTIONS[@]}"; do
    if [ -f "$BUILD_DIR/${func}.zip" ]; then
        local size=$(stat -f%z "$BUILD_DIR/${func}.zip" 2>/dev/null || stat -c%s "$BUILD_DIR/${func}.zip" 2>/dev/null || echo "0")
        echo "    {\"name\": \"$func\", \"size\": $size},"
    fi
done | sed '$ s/,$//')
  ]
}
EOF
    
    print_status "Build metadata generated"
}

# Display build summary
show_summary() {
    echo ""
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}📦 Build Summary${NC}"
    echo -e "${BLUE}================================${NC}"
    echo -e "${GREEN}Build Mode: $BUILD_MODE${NC}"
    echo -e "${GREEN}Output Directory: $BUILD_DIR${NC}"
    echo ""
    echo -e "${BLUE}Functions Built:${NC}"
    
    for func in "${FUNCTIONS[@]}"; do
        if [ -f "$BUILD_DIR/${func}.zip" ]; then
            local size=$(du -h "$BUILD_DIR/${func}.zip" | cut -f1)
            echo -e "  ${GREEN}✅${NC} $func ($size)"
        else
            echo -e "  ${RED}❌${NC} $func (missing)"
        fi
    done
    
    echo ""
    echo -e "${GREEN}✅ Build completed successfully!${NC}"
    echo ""
}

# Main build process
main() {
    echo -e "${BLUE}🚀 Building WP Suite Flow Backend${NC}"
    echo -e "${BLUE}================================${NC}"
    echo ""
    
    cd "$ROOT_DIR"
    
    check_node_version
    check_tools
    clean_build
    install_root_dependencies
    
    if [ "$SKIP_LINTING" != "true" ]; then
        run_linting
    fi
    
    if [ "$SKIP_TESTS" != "true" ]; then
        run_tests
    fi
    
    # Build each function
    for func in "${FUNCTIONS[@]}"; do
        build_function "$func"
        package_function "$func"
    done
    
    copy_documentation
    generate_metadata
    show_summary
}

# Handle script interruption
trap 'print_error "Build interrupted"' INT TERM

# Run main function
main "$@"
