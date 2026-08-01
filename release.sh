#!/usr/bin/env bash
set -euo pipefail

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "❌ Working tree not clean. Commit or stash changes first."
  exit 1
fi


# -------------------------------
# 🏷️ Configuration
# -------------------------------
VERSION="${1:-v0.0.1}" # optional CLI arg (e.g. ./release.sh v0.1.0)
TITLE="$VERSION"
NOTES=""

REPO="iamraphealc/zio"

# -------------------------------
# 🧱 Build artifacts (optional)
# -------------------------------
echo "🔨 Building release binaries..."
zig build

# -------------------------------
# 📂 Artifact list
# -------------------------------
ARTIFACTS=(
  "zig-out/aarch64-linux/zio"
  "zig-out/x86_64-linux-gnu/zio"
  "zig-out/aarch64-macos/zio"
  "zig-out/x86_64-macos/zio"
  "zig-out/x86_64-windows/zio.exe"
  "zig-out/x86-windows/zio.exe"
)

# -------------------------------
# 🧩 Validate artifacts
# -------------------------------
echo "🕵️ Checking built binaries..."
for file in "${ARTIFACTS[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "❌ Missing: $file"
    exit 1
  fi
done
echo "✅ All binaries found."

# -------------------------------
# 📝 Update version file
# -------------------------------
echo "📝 Updating version file to $VERSION"

echo "$VERSION" > version

git add version

if git diff --cached --quiet; then
  echo "ℹ️ Version file already up to date"
else
  git commit -m "chore: bump version to $VERSION"
fi


# -------------------------------
# 🏷️ Create and push tag
# -------------------------------
if git rev-parse "$VERSION" >/dev/null 2>&1; then
  echo "❌ Tag $VERSION already exists. Aborting."
  exit 1
fi

echo "🏷️ Creating tag $VERSION"
git tag "$VERSION"

echo "📤 Pushing commit and tag"
git push origin HEAD
git push origin "$VERSION"


echo "📦 Preparing assets with unique filenames..."
TMPDIR=$(mktemp -d)

cp zig-out/aarch64-linux/zio           "$TMPDIR/zio-aarch64-linux"
cp zig-out/x86_64-linux-gnu/zio        "$TMPDIR/zio-x86_64-linux"
cp zig-out/aarch64-macos/zio           "$TMPDIR/zio-aarch64-macos"
cp zig-out/x86_64-macos/zio            "$TMPDIR/zio-x86_64-macos"
cp zig-out/x86_64-windows/zio.exe      "$TMPDIR/zio-x86_64-windows.exe"
cp zig-out/x86-windows/zio.exe         "$TMPDIR/zio-x86-windows.exe"

ARTIFACTS=("$TMPDIR"/*)


# -------------------------------
# 🚀 Create release
# -------------------------------
gh release create "$VERSION" \
  "${ARTIFACTS[@]}" \
  --title "$TITLE" \
  --notes "$NOTES" \
  --repo "$REPO"


echo "🎉 Release $VERSION published successfully!"

rm -rf "$TMPDIR"