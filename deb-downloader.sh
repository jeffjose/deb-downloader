#!/bin/bash

set -e

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
        --overwrite)
            OVERWRITE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 --url URL --package NAME [OPTIONS]"
            echo ""
            echo "Download .deb packages from APT repositories"
            echo ""
            echo "Required:"
            echo "  --url URL              Repository URL or full deb line"
            echo "  --package NAME         Package name to download"
            echo ""
            echo "Optional:"
            echo "  --dist DIST            Distribution name (required if --url is just a URL)"
            echo "  --component COMP       Component (default: main)"
            echo "  --arch ARCH            Architecture (default: auto-detect)"
            echo "  --output-dir DIR       Output directory (default: /tmp)"
            echo "  -o DIR                 Short form of --output-dir"
            echo "  --install              Install the package after downloading"
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

if [ -z "$PACKAGE_NAME" ]; then
    echo "Error: --package is required"
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

echo "=== Debian Package Downloader ==="
echo ""
echo "Repository: $REPO_URL"
echo "Distribution: $DISTRIBUTION"
echo "Component: $COMPONENT"
echo "Package: $PACKAGE_NAME"
echo "Architecture: $ARCH"
echo "Output: $OUTPUT_DIR"
echo ""

# Download package index
PACKAGES_URL="${REPO_URL}/dists/${DISTRIBUTION}/${COMPONENT}/binary-${ARCH}/Packages"

echo "Downloading package index..."

# Try compressed first, then uncompressed
if curl -fsSL "${PACKAGES_URL}.gz" -o /tmp/Packages.gz 2>/dev/null; then
    gunzip -f /tmp/Packages.gz -c > /tmp/Packages
elif curl -fsSL "${PACKAGES_URL}" -o /tmp/Packages 2>/dev/null; then
    echo "Downloaded uncompressed Packages file"
else
    echo "Error: Could not download Packages index from $PACKAGES_URL"
    exit 1
fi

echo "Finding ${PACKAGE_NAME} package..."

# Extract the filename from the Packages file
DEB_PATH=$(grep -A 20 "^Package: ${PACKAGE_NAME}" /tmp/Packages | grep "^Filename:" | head -1 | awk '{print $2}')

if [ -z "$DEB_PATH" ]; then
    echo "Error: Package '${PACKAGE_NAME}' not found in repository"
    echo ""
    echo "Available packages:"
    grep "^Package:" /tmp/Packages | sed 's/Package: /  - /'
    exit 1
fi

DEB_FILENAME=$(basename "$DEB_PATH")
echo "Found: $DEB_FILENAME"

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

OUTPUT_PATH="${OUTPUT_DIR}/${DEB_FILENAME}"

if [ -f "$OUTPUT_PATH" ] && [ "$OVERWRITE" != "true" ]; then
    echo "File already exists: $OUTPUT_PATH"
    echo "Skipping download (use --overwrite to force download)"
else
    echo "Downloading ${DEB_FILENAME}..."
    DEB_URL="${REPO_URL}/${DEB_PATH}"
    PARTIAL_PATH="${OUTPUT_PATH}.part"

    # Set up trap to clean up partial file on interrupt
    trap 'rm -f "$PARTIAL_PATH"; echo -e "\nDownload cancelled."; exit 130' INT TERM

    if curl -fL --progress-bar "$DEB_URL" -o "$PARTIAL_PATH"; then
        mv "$PARTIAL_PATH" "$OUTPUT_PATH"
        # Remove trap
        trap - INT TERM
        echo ""
        echo "✓ Downloaded: $OUTPUT_PATH"
    else
        # Curl failed, clean up
        rm -f "$PARTIAL_PATH"
        echo ""
        echo "Error: Download failed"
        exit 1
    fi
fi

# Clean up temp files
rm -f /tmp/Packages /tmp/Packages.gz

if [ "$INSTALL" = "true" ]; then
    echo ""
    echo "Installing $OUTPUT_PATH..."
    if sudo dpkg -i "$OUTPUT_PATH"; then
        echo ""
        echo "✓ Installation successful"
    else
        echo ""
        echo "Error during installation. Attempting to fix dependencies..."
        if sudo apt-get install -f -y; then
            echo ""
            echo "✓ Dependencies fixed"
        else
            echo ""
            echo "Failed to fix dependencies. Please check manually."
            exit 1
        fi
    fi
else
    echo ""
    echo "To install, run:"
    echo "  sudo dpkg -i $OUTPUT_PATH"
    echo ""
    echo "If there are dependency issues, run:"
    echo "  sudo apt-get install -f"
fi
