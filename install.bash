#!/usr/bin/env bash

# --- Configuration ---
owner="iamraphealc"
repo="zio"
base_asset_name="zio" # Prefix for all assets
install_name="zio"    # Name of the executable after installation

# Stop on first error
set -e

# --- Utility Functions ---

# Function to determine the OS and architecture
get_platform_info() {
    local os=""
    local arch=""

    # 1. Determine OS (Windows removed)
    case "$(uname -s)" in
        Linux*)
            os="linux"
            ;;
        Darwin*)
            os="macos"
            ;;
        *)
            echo "Error: Unsupported OS type: $(uname -s)" >&2
            echo "Only Linux and macOS are supported." >&2
            exit 1
            ;;
    esac

    # 2. Determine Architecture
    case "$(uname -m)" in
        x86_64|amd64)
            arch="x86_64"
            ;;
        aarch64|arm64)
            arch="aarch64"
            ;;
        *)
            echo "Error: Unsupported architecture: $(uname -m)" >&2
            exit 1
            ;;
    esac

    echo "$os,$arch"
}

# --- Main Logic ---

echo "--- ZIO Universal Installer (Linux/macOS) ---"

# Get platform info
IFS=',' read -r OS ARCH <<< "$(get_platform_info)"

echo "Detected OS: **$OS**"
echo "Detected Architecture: **$ARCH**"

# Construct Asset Name
asset_name="${base_asset_name}-${ARCH}-${OS}"
echo "Target Asset Name: **$asset_name**"

# Fetch Version from raw version file
echo "Fetching version from repository..."
raw_version=$(curl -sL "https://raw.githubusercontent.com/$owner/$repo/main/version" | tr -d '[:space:]')

if [ -z "$raw_version" ]; then
    echo "Error: Could not retrieve version from repository root." >&2
    exit 1
fi

# Ensure version has 'v' prefix if your GitHub release tags require it
if [[ "$raw_version" =~ ^[0-9] ]]; then
    latest_version="v${raw_version}"
else
    latest_version="${raw_version}"
fi

echo "Latest version: **$latest_version**"

# Construct Download URL
download_url="https://github.com/$owner/$repo/releases/download/$latest_version/$asset_name"

echo "Downloading from: **$download_url**"

# Download the Asset
curl -L -o "$asset_name" "$download_url"

echo "Download complete."

# Determine Install Directory
install_dir="/usr/local/bin"

# Check if we have write permissions to /usr/local/bin
if [ ! -w "$install_dir" ]; then
    echo "Warning: No write permissions to $install_dir"
    echo "You may need to run this script with sudo."
    
    # Try user's local bin directory as fallback
    user_bin_dir="$HOME/.local/bin"
    if [ -d "$user_bin_dir" ] || mkdir -p "$user_bin_dir" 2>/dev/null; then
        install_dir="$user_bin_dir"
        echo "Using user directory: $install_dir"
    else
        echo "Error: Cannot find a suitable installation directory." >&2
        exit 1
    fi
fi

mkdir -p "$install_dir"

echo "Installing to directory: **$install_dir**"

# Move and Rename (Install)
mv -f "$asset_name" "$install_dir/$install_name"

# Set executable permissions
chmod +x "$install_dir/$install_name"
echo "Set executable permissions."

echo "Installation complete as: **$install_dir/$install_name**"
echo

# Check if in PATH
# Check multiple shell config files
check_path_command() {
    if command -v "$install_name" >/dev/null 2>&1; then
        echo "✅ Installation successful! Run: **$install_name**"
        return 0
    fi
    return 1
}

# Check if directory is in PATH
check_in_path() {
    local dir="$1"
    echo "$PATH" | tr ':' '\n' | grep -q "^$dir$" && return 0
    return 1
}

if check_path_command; then
    # Already in PATH
    :
elif check_in_path "$install_dir"; then
    # Directory is in PATH but command not found immediately
    echo "⚠ Directory is in PATH. Try restarting your terminal or running:"
    if [ -f "$HOME/.bashrc" ]; then
        echo "  source ~/.bashrc"
    fi
    if [ -f "$HOME/.zshrc" ]; then
        echo "  source ~/.zshrc"
    fi
else
    # Not in PATH
    echo "⚠ Installation successful, but the executable is not in your PATH."
    echo "⚠ Please add **$install_dir** to your PATH environment variable."
    echo ""
    
    # Provide shell-specific instructions
    if [ -f "$HOME/.bashrc" ]; then
        echo "For bash, add this line to ~/.bashrc:"
        echo "  export PATH=\"\$PATH:$install_dir\""
    fi
    
    if [ -f "$HOME/.zshrc" ]; then
        echo "For zsh, add this line to ~/.zshrc:"
        echo "  export PATH=\"\$PATH:$install_dir\""
    fi
    
    if [ "$SHELL" = "/bin/fish" ]; then
        echo "For fish, run:"
        echo "  fish_add_path $install_dir"
    fi
    
    echo ""
    echo "Then restart your terminal or run the appropriate source command."
fi

# Verify installation
echo ""
echo "Verifying installation..."
if [ -x "$install_dir/$install_name" ]; then
    file_size=$(stat -f%z "$install_dir/$install_name" 2>/dev/null || stat -c%s "$install_dir/$install_name" 2>/dev/null)
    echo "✅ Executable installed: $install_dir/$install_name ($file_size bytes)"
    
    # Try to get version info
    if "$install_dir/$install_name" --version >/dev/null 2>&1; then
        version_output=$("$install_dir/$install_name" --version 2>&1 || echo "Version check failed")
        echo "✅ Version: $version_output"
    elif "$install_dir/$install_name" version >/dev/null 2>&1; then
        version_output=$("$install_dir/$install_name" version 2>&1 || echo "Version check failed")
        echo "✅ Version: $version_output"
    else
        echo "ℹ Executable appears to be working correctly"
    fi
else
    echo "❌ Installation verification failed"
    exit 1
fi