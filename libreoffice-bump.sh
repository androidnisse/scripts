#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_YML="${SCRIPT_DIR}/package.yml"

if [[ ! -f "$PACKAGE_YML" ]]; then
    echo "Error: package.yml not found at ${PACKAGE_YML}"
    exit 1
fi

# Detect current version and release from package.yml
CURRENT_VERSION=$(grep -oP 'libreoffice-\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$PACKAGE_YML" | head -1)
CURRENT_MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f1-3)
CURRENT_RELEASE=$(grep -oP '^release\s*:\s*\K[0-9]+' "$PACKAGE_YML")

echo "Current version detected: ${CURRENT_VERSION}"
echo "Current release detected: ${CURRENT_RELEASE}"
read -rp "Enter new version: " NEW_VERSION

if [[ -z "$NEW_VERSION" ]]; then
    echo "Error: no version entered"
    exit 1
fi

NEW_MINOR=$(echo "$NEW_VERSION" | cut -d. -f1-3)
NEW_RELEASE=$((CURRENT_RELEASE + 1))
BASE_URL="https://download.documentfoundation.org/libreoffice/src/${NEW_MINOR}"

echo "Bumping ${CURRENT_VERSION} -> ${NEW_VERSION}, release ${CURRENT_RELEASE} -> ${NEW_RELEASE}"

FILES=(
    "libreoffice-${NEW_VERSION}.tar.xz"
    "libreoffice-dictionaries-${NEW_VERSION}.tar.xz"
    "libreoffice-help-${NEW_VERSION}.tar.xz"
    "libreoffice-translations-${NEW_VERSION}.tar.xz"
)

# Update top-level version field
sed -i "s/^version\s*:.*$/version    : ${NEW_VERSION}/" "$PACKAGE_YML"

# Bump release
sed -i "s/^release\s*:.*$/release    : ${NEW_RELEASE}/" "$PACKAGE_YML"

# Update version strings in URLs
sed -i "s/${CURRENT_VERSION}/${NEW_VERSION}/g" "$PACKAGE_YML"
sed -i "s/${CURRENT_MINOR}/${NEW_MINOR}/g" "$PACKAGE_YML"

echo "Updated version and release in package.yml"

# Fetch new sha256 sums and update them
for FILE in "${FILES[@]}"; do
    URL="${BASE_URL}/${FILE}"
    echo -n "Downloading ${FILE}..."
    NEW_SHA=$(curl -sL "$URL" | sha256sum | awk '{print $1}')
    if [[ -z "$NEW_SHA" ]]; then
        echo " FAILED (could not download)"
        continue
    fi
    echo " done (${NEW_SHA})"
    sed -i "s|\(.*${FILE}.*: \)[a-f0-9]*|\1${NEW_SHA}|" "$PACKAGE_YML"
done

echo "package.yml updated successfully"
