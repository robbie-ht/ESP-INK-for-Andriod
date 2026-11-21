#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  printf 'Usage: %s NEW_OR_EMPTY_DIRECTORY\n' "${0##*/}"
  printf 'Creates a disposable Flutter project and builds a release APK and AAB.\n'
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if (( $# != 1 )) || [[ -z "${1:-}" ]]; then
  usage >&2
  exit 2
fi
if [[ -e "$1" && ! -d "$1" ]]; then
  printf 'Error: target exists and is not a directory: %s\n' "$1" >&2
  exit 2
fi
mkdir -p -- "$1"
project_dir="$(cd -- "$1" && pwd -P)"
shopt -s nullglob dotglob
existing_entries=("$project_dir"/*)
if (( ${#existing_entries[@]} != 0 )); then
  printf 'Error: smoke-test directory must be empty: %s\n' "$project_dir" >&2
  exit 2
fi

"$script_dir/run.sh" "$project_dir" \
  flutter create --platforms=android --project-name flutter_android_smoke --org dev.example .
"$script_dir/build-app.sh" "$project_dir" apk
"$script_dir/build-app.sh" "$project_dir" aab

apk="$project_dir/build/app/outputs/flutter-apk/app-release.apk"
aab="$project_dir/build/app/outputs/bundle/release/app-release.aab"
for artifact in "$apk" "$aab"; do
  if [[ ! -s "$artifact" ]]; then
    printf 'Error: missing or empty build artifact: %s\n' "$artifact" >&2
    exit 1
  fi
done
printf 'Smoke test passed. Artifacts:\n%s\n%s\n' "$apk" "$aab"
