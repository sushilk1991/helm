#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${HELM_VERSION:-0.1.0}"
ARCH="${HELM_ARCH:-arm64}"
SIGN_IDENTITY="${HELM_SIGN_IDENTITY:--}"
DERIVED_DATA="${ROOT}/.build/DerivedDataRelease"
DIST_DIR="${ROOT}/dist"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/helm-dmg-work.XXXXXX")"
STAGE_DIR="${WORK_DIR}/stage"
mkdir -p "${STAGE_DIR}"
DMG_NAME="Helm-${VERSION}-${ARCH}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
SHA_PATH="${DMG_PATH}.sha256"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Building Helm.app (Release, ${ARCH})..."
xcodebuild \
    -project "${ROOT}/Helm.xcodeproj" \
    -scheme Helm \
    -configuration Release \
    -destination "platform=macOS,arch=${ARCH}" \
    -derivedDataPath "${DERIVED_DATA}" \
    build

APP_PATH="${DERIVED_DATA}/Build/Products/Release/Helm.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: Built Helm.app not found at ${APP_PATH}" >&2
    exit 1
fi

echo "==> Staging Helm.app & Applications symlink..."
mkdir -p "${DIST_DIR}"
cp -R "$APP_PATH" "${STAGE_DIR}/Helm.app"
ln -s /Applications "${STAGE_DIR}/Applications"

if [[ -f "${ROOT}/Resources/AppIcon.icns" ]]; then
    cp "${ROOT}/Resources/AppIcon.icns" "${STAGE_DIR}/.VolumeIcon.icns"
fi

echo "==> Signing Helm.app (identity: ${SIGN_IDENTITY}) with Helm.entitlements..."
SIGN_ARGS=(--force --deep --sign "$SIGN_IDENTITY" --entitlements "${ROOT}/Helm.entitlements")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
else
    SIGN_ARGS+=(--timestamp=none)
fi
codesign "${SIGN_ARGS[@]}" "${STAGE_DIR}/Helm.app"
codesign --verify --deep --strict "${STAGE_DIR}/Helm.app"

echo "==> Creating compressed DMG at ${DMG_PATH}..."
rm -f "${DMG_PATH}" "${SHA_PATH}"

if command -v SetFile >/dev/null 2>&1 && [[ -f "${STAGE_DIR}/.VolumeIcon.icns" ]]; then
    RW_DMG="${WORK_DIR}/Helm-rw.dmg"
    hdiutil create \
        -volname "Helm" \
        -srcfolder "${STAGE_DIR}" \
        -fs HFS+ \
        -format UDRW \
        -ov \
        "${RW_DMG}"

    MOUNT_POINT="${WORK_DIR}/mount"
    mkdir -p "${MOUNT_POINT}"
    hdiutil attach "${RW_DMG}" -mountpoint "${MOUNT_POINT}" -nobrowse -quiet
    SetFile -a C "${MOUNT_POINT}" || true
    hdiutil detach "${MOUNT_POINT}" -quiet

    hdiutil convert "${RW_DMG}" -format UDZO -imagekey zlib-level=9 -ov -o "${DMG_PATH}"
else
    hdiutil create \
        -volname "Helm" \
        -srcfolder "${STAGE_DIR}" \
        -fs HFS+ \
        -format UDZO \
        -imagekey zlib-level=9 \
        -ov \
        "${DMG_PATH}"
fi

echo "==> Verifying DMG integrity and checksum..."
hdiutil verify "${DMG_PATH}"
(cd "${DIST_DIR}" && shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256")

echo "==> Done!"
ls -lh "${DMG_PATH}" "${SHA_PATH}"
cat "${SHA_PATH}"
