#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if command -v baton >/dev/null 2>&1 && [[ "${BATON:-on}" != "off" ]]; then
  baton run --lane auto -- swift build
else
  swift build
fi

BIN_PATH=".build/debug/helmctl"
if [[ ! -e "$BIN_PATH" ]]; then
  BIN_PATH=".build/arm64-apple-macosx/debug/helmctl"
fi

codesign --force --sign - --entitlements "$ROOT_DIR/Helm.entitlements" "$BIN_PATH"
codesign -d --entitlements :- "$BIN_PATH"
echo "Signed $BIN_PATH with Helm.entitlements"
