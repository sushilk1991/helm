#!/usr/bin/env bash
set -euo pipefail

CACHE_DIR="${HELM_VM_CACHE_DIR:-$HOME/Library/Application Support/Helm/vm}"
BASE_URL="${HELM_ALPINE_MIRROR_URL:-https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/netboot}"
BASE_URL="${BASE_URL%/}"

EXPECTED_KERNEL_SHA256="9e24e2ae4db247fe7f05034b7b2d351a0c8b1e5cb0f174e58789476493fd0b97"
EXPECTED_INITRD_SHA256="a42207383e03b28cc32e7856932885c66276c3d4caf633637a03ca1086f16344"

mkdir -p "$CACHE_DIR"

fetch_and_verify() {
  local filename="$1"
  local expected_sha="$2"
  local dest="$CACHE_DIR/$filename"
  local tmp="$CACHE_DIR/.${filename}.tmp.$$"

  if [[ -f "$dest" ]]; then
    local existing_sha
    existing_sha="$(shasum -a 256 "$dest" | awk '{print $1}')"
    if [[ "$existing_sha" == "$expected_sha" || "${HELM_ALPINE_ALLOW_UNPINNED:-0}" == "1" ]]; then
      echo "$dest already cached ($existing_sha)"
      return 0
    fi
  fi

  echo "Downloading $BASE_URL/$filename -> $dest"
  curl -fsSL --retry 3 "$BASE_URL/$filename" -o "$tmp"
  local actual_sha
  actual_sha="$(shasum -a 256 "$tmp" | awk '{print $1}')"

  if [[ "${HELM_ALPINE_ALLOW_UNPINNED:-0}" != "1" && -z "${HELM_ALPINE_MIRROR_URL:-}" ]]; then
    if [[ "$actual_sha" != "$expected_sha" ]]; then
      rm -f "$tmp"
      echo "SHA-256 mismatch for $filename: expected $expected_sha, got $actual_sha" >&2
      echo "Set HELM_ALPINE_ALLOW_UNPINNED=1 to allow unpinned Alpine releases." >&2
      exit 1
    fi
  fi

  mv -f "$tmp" "$dest"
  echo "Verified $dest ($actual_sha)"
}

fetch_and_verify "vmlinuz-virt" "$EXPECTED_KERNEL_SHA256"
fetch_and_verify "initramfs-virt" "$EXPECTED_INITRD_SHA256"
echo "VM assets ready in $CACHE_DIR"
