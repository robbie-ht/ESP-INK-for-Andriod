#!/usr/bin/env bash
set -Eeuo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export FLUTTER_ANDROID_CACHE_DIR="${MOINK_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/moink-app-docker}"
exec "$project_dir/tool/docker/build-app.sh" "$project_dir" "${@:-apk}"
