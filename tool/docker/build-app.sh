#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  printf 'Usage: %s PROJECT_DIRECTORY [apk|aab] [flutter build flags...]\n' "${0##*/}"
  printf 'Defaults to a release APK; aab builds a release Android App Bundle.\n'
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if (( $# == 0 )); then
  usage >&2
  exit 2
fi
project_dir="$1"
shift
if [[ ! -f "$project_dir/pubspec.yaml" || ! -d "$project_dir/android" ]]; then
  printf 'Error: project must contain pubspec.yaml and an android directory: %s\n' "$project_dir" >&2
  exit 2
fi

target=apk
case "${1:-}" in
  apk) shift ;;
  aab) target=appbundle; shift ;;
  --) shift ;;
  ''|-*) ;;
  *) printf 'Error: expected apk or aab, got: %s\n' "$1" >&2; exit 2 ;;
esac

exec "$script_dir/run.sh" "$project_dir" flutter build "$target" --release "$@"
