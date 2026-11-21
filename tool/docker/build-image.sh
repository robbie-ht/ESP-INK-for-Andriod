#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID == 0 )); then
  printf 'Error: run this script as a regular user; do not use sudo.\n' >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
image="${FLUTTER_ANDROID_IMAGE:-flutter-android:3.47.8}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  printf 'Usage: %s [extra docker build arguments...]\n' "${0##*/}"
  printf 'Image: %s (override with FLUTTER_ANDROID_IMAGE)\n' "$image"
  exit 0
fi

command -v docker >/dev/null 2>&1 || {
  printf 'Error: Docker is not installed or is not on PATH.\n' >&2
  exit 1
}

exec docker build \
  --platform linux/amd64 \
  --build-arg "USER_UID=$(id -u)" \
  --build-arg "USER_GID=$(id -g)" \
  --tag "$image" \
  "$@" \
  "$script_dir"
