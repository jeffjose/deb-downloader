#!/bin/bash

set -e

# Colors
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
BLUE='\033[34m'
BOLD='\033[1m'
RESET='\033[0m'

# Default values
COMPONENT="main"
OUTPUT_DIR="/tmp"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --url)
            URL_INPUT="$2"
            shift 2
            ;;
        --dist|--distribution)
            DISTRIBUTION="$2"
            shift 2
            ;;
        --component)
            COMPONENT="$2"
            shift 2
            ;;
        --package)
            PACKAGE_NAME="$2"
            shift 2
            ;;
        --version)
            PACKAGE_VERSION="$2"
            shift 2
            ;;
        --arch)
            ARCH="$2"
            shift 2
            ;;
        --output-dir|-o)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --install)
            INSTALL=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --overwrite)
            OVERWRITE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 --url URL [OPTIONS]"
            echo ""
            echo "Download .deb packages from APT repositories"
            echo ""
            echo "Required:"
            echo "  --url URL              Repository URL or full deb line"
            echo ""
            echo "Optional:"
            echo "  --package NAME         Package name (auto-detected if only one available)"
            echo "  --dist DIST            Distribution name (required if --url is just a URL)"
            echo "  --component COMP       Component (default: main)"
            echo "  --version VERSION      Specific version (default: latest)"
            echo "  --arch ARCH            Architecture (default: auto-detect)"
            echo "  --output-dir DIR       Output directory (default: /tmp)"
            echo "  -o DIR                 Short form of --output-dir"
            echo "  --install              Install the package after downloading"
            echo "  --force                Force reinstall even if same version is installed"
            echo "  --overwrite            Overwrite existing file if it exists"
            echo ""
            echo "Examples:"
            echo "  $0 --url \"deb https://example.com/debian stable main\" --package mypackage"
            echo "  $0 --url https://example.com/debian --dist stable --package mypackage -o ~/downloads"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [ -z "$URL_INPUT" ]; then
    echo "Error: --url is required"
    exit 1
fi

# Parse URL input
clean_url_input() {
    local line="$1"

    # Remove leading/trailing whitespace
    line=$(echo "$line" | xargs)

    # Remove 'echo' command
    line=$(echo "$line" | sed -E 's/^echo\s+//')

    # Remove 'sudo tee' or similar commands
    line=$(echo "$line" | sed -E 's/\|\s*sudo\s+tee.*$//')

    # Remove trailing pipes and backslashes
    while [[ "$line" =~ [\|\\[:space:]]+$ ]]; do
        line=$(echo "$line" | sed -E 's/[\s|\\]+$//')
    done

    # Remove surrounding quotes
    line=$(echo "$line" | sed -E 's/^"(.*)"$/\1/' | sed -E "s/^'(.*)'$/\1/")

    echo "$line"
}

CLEANED=$(clean_url_input "$URL_INPUT")

# Check if it's a full deb line or just a URL
if [[ "$CLEANED" =~ ^deb[[:space:]] ]] || [[ "$CLEANED" =~ ^deb-src[[:space:]] ]]; then
    # Parse full deb line
    # Remove 'deb' or 'deb-src'
    CLEANED=$(echo "$CLEANED" | sed -E 's/^(deb|deb-src)\s+//')

    # Remove options in brackets
    CLEANED=$(echo "$CLEANED" | sed -E 's/\[[^\]]*\]\s*//')

    # Parse URL, distribution, component
    read -r REPO_URL DISTRIBUTION COMPONENT_PARSED REST <<< "$CLEANED"

    # Use parsed component if available
    if [ -n "$COMPONENT_PARSED" ]; then
        COMPONENT="$COMPONENT_PARSED"
    fi
elif [[ "$CLEANED" =~ ^https?:// ]]; then
    # Just a URL
    REPO_URL="$CLEANED"

    if [ -z "$DISTRIBUTION" ]; then
        # Try to auto-discover distribution
        echo "Discovering available distributions..."
        DISTS_URL="${REPO_URL}/dists/"

        # Fetch the dists directory and try to extract distribution names
        DISTS_HTML=$(curl -fsSL "$DISTS_URL" 2>/dev/null || echo "")

        if [ -n "$DISTS_HTML" ]; then
            # Extract directory names from HTML listing
            # Look for links ending with /
            DISTRIBUTIONS=$(echo "$DISTS_HTML" | grep -oE 'href="[^"]+/"' | sed 's/href="//;s/\/"$//' | grep -v '^\.\.' | grep -v '^by-hash' | sort -u)

            DIST_COUNT=$(echo "$DISTRIBUTIONS" | grep -c '^' 2>/dev/null || echo 0)

            if [ "$DIST_COUNT" -eq 1 ]; then
                DISTRIBUTION=$(echo "$DISTRIBUTIONS" | head -1)
                echo "Found distribution: $DISTRIBUTION"
            elif [ "$DIST_COUNT" -gt 1 ]; then
                echo "Error: Multiple distributions found:"
                echo "$DISTRIBUTIONS" | sed 's/^/  - /'
                echo ""
                echo "Please specify one with --dist"
                exit 1
            else
                echo "Error: Could not discover distributions. Please specify with --dist"
                exit 1
            fi
        else
            echo "Error: Could not access repository. Please specify distribution with --dist"
            exit 1
        fi
    fi
else
    echo "Error: Invalid URL format: $URL_INPUT"
    exit 1
fi

# Remove trailing slash from URL
REPO_URL=$(echo "$REPO_URL" | sed 's:/$::')

# Auto-detect architecture if not provided
if [ -z "$ARCH" ]; then
    ARCH=$(dpkg --print-architecture)
fi

echo -e "${BLUE}${REPO_URL}/${DISTRIBUTION}/${COMPONENT}/${ARCH}${RESET}"

# Download package index
PACKAGES_URL="${REPO_URL}/dists/${DISTRIBUTION}/${COMPONENT}/binary-${ARCH}/Packages"

# Try compressed first, then uncompressed
if curl -fsSL "${PACKAGES_URL}.gz" -o /tmp/Packages.gz 2>/dev/null; then
    gunzip -f /tmp/Packages.gz -c > /tmp/Packages
elif curl -fsSL "${PACKAGES_URL}" -o /tmp/Packages 2>/dev/null; then
    : # Downloaded uncompressed
else
    echo -e "${RED}Error: Could not download Packages index${RESET}"
    exit 1
fi

# Check if package name was provided, if not check if there's only one unique package
if [ -z "$PACKAGE_NAME" ]; then
    UNIQUE_PACKAGES=$(grep "^Package:" /tmp/Packages | awk '{print $2}' | sort -u)
    NUM_UNIQUE=$(echo "$UNIQUE_PACKAGES" | wc -l)

    if [ "$NUM_UNIQUE" -eq 1 ]; then
        PACKAGE_NAME=$(echo "$UNIQUE_PACKAGES" | head -1)
    else
        echo -e "${RED}Error: Multiple packages found. Specify with --package${RESET}"
        echo ""
        echo "Available packages:"
        echo "$UNIQUE_PACKAGES" | sed 's/^/  - /'
        exit 1
    fi
fi

# Extract all versions of the package
# Parse the Packages file to find all matching packages with their versions and filenames
TMP_PKGS="/tmp/matching_packages.$$"
rm -f "$TMP_PKGS"

awk -v pkg="$PACKAGE_NAME" '
/^Package:/ { current_pkg = $2 }
/^Version:/ { if (current_pkg == pkg) current_version = $2 }
/^Filename:/ {
    if (current_pkg == pkg && current_version != "") {
        print current_version "|" $2
        current_version = ""
    }
}
' /tmp/Packages > "$TMP_PKGS"

if [ ! -s "$TMP_PKGS" ]; then
    echo "Error: Package '${PACKAGE_NAME}' not found in repository"
    echo ""
    echo "Available packages:"
    grep "^Package:" /tmp/Packages | sed 's/Package: /  - /'
    rm -f "$TMP_PKGS"
    exit 1
fi

# Select version
if [ -n "$PACKAGE_VERSION" ] && [ "$PACKAGE_VERSION" != "latest" ]; then
    # Find specific version
    DEB_PATH=$(grep "^${PACKAGE_VERSION}|" "$TMP_PKGS" | cut -d'|' -f2)

    if [ -z "$DEB_PATH" ]; then
        echo "Error: Package '${PACKAGE_NAME}' version '${PACKAGE_VERSION}' not found"
        echo ""
        echo "Available versions:"
        cut -d'|' -f1 "$TMP_PKGS" | sed 's/^/  - /'
        rm -f "$TMP_PKGS"
        exit 1
    fi

    DEB_VERSION="$PACKAGE_VERSION"
else
    # Auto-select latest version using dpkg --compare-versions
    LATEST_VERSION=""
    LATEST_PATH=""

    while IFS='|' read -r ver path; do
        if [ -z "$LATEST_VERSION" ]; then
            LATEST_VERSION="$ver"
            LATEST_PATH="$path"
        else
            # Use dpkg to compare versions properly
            if dpkg --compare-versions "$ver" gt "$LATEST_VERSION"; then
                LATEST_VERSION="$ver"
                LATEST_PATH="$path"
            fi
        fi
    done < "$TMP_PKGS"

    DEB_VERSION="$LATEST_VERSION"
    DEB_PATH="$LATEST_PATH"
fi

rm -f "$TMP_PKGS"

DEB_FILENAME=$(basename "$DEB_PATH")
echo -e "${GREEN}→${RESET} ${PACKAGE_NAME} ${BOLD}${DEB_VERSION}${RESET}"

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

OUTPUT_PATH="${OUTPUT_DIR}/${DEB_FILENAME}"

if [ -f "$OUTPUT_PATH" ] && [ "$OVERWRITE" != "true" ]; then
    echo -e "${YELLOW}✓${RESET} Cached: ${DEB_FILENAME}"
else
    DEB_URL="${REPO_URL}/${DEB_PATH}"
    PARTIAL_PATH="${OUTPUT_PATH}.part"

    # Set up trap to clean up partial file on interrupt
    trap 'rm -f "$PARTIAL_PATH"; echo -e "\nDownload cancelled."; exit 130' INT TERM

    if curl -fL --progress-bar "$DEB_URL" -o "$PARTIAL_PATH"; then
        mv "$PARTIAL_PATH" "$OUTPUT_PATH"
        # Remove trap
        trap - INT TERM
        echo ""
        echo -e "${GREEN}✓${RESET} Downloaded: ${DEB_FILENAME}"
    else
        # Curl failed, clean up
        rm -f "$PARTIAL_PATH"
        echo ""
        echo -e "${RED}✗${RESET} Download failed"
        exit 1
    fi
fi

# Clean up temp files
rm -f /tmp/Packages /tmp/Packages.gz

if [ "$INSTALL" = "true" ]; then
    # Check if same version is already installed
    INSTALLED_VERSION=""
    if dpkg -s "$PACKAGE_NAME" &>/dev/null; then
        INSTALLED_VERSION=$(dpkg -s "$PACKAGE_NAME" 2>/dev/null | grep "^Version:" | awk '{print $2}')
    fi

    if [ "$INSTALLED_VERSION" = "$DEB_VERSION" ] && [ "$FORCE" != "true" ]; then
        echo -e "${GREEN}✓${RESET} Already installed"
    else
        if [ -n "$INSTALLED_VERSION" ]; then
            echo -e "${YELLOW}↑${RESET} Upgrading from ${INSTALLED_VERSION}"
        fi

        if sudo dpkg -i "$OUTPUT_PATH" >/dev/null 2>&1; then
            echo -e "${GREEN}✓${RESET} Installed"
        else
            if sudo apt-get install -f -y >/dev/null 2>&1; then
                echo -e "${GREEN}✓${RESET} Installed (dependencies fixed)"
            else
                echo -e "${RED}✗${RESET} Installation failed"
                exit 1
            fi
        fi
    fi
fi
