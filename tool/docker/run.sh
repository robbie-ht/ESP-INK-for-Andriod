#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID == 0 )); then
  printf 'Error: run this script as a regular user; do not use sudo.\n' >&2
  exit 1
fi

usage() {
  printf 'Usage: %s PROJECT_DIRECTORY [command args...]\n' "${0##*/}"
  printf 'The project is mounted at /workspace; the default command is bash.\n'
  printf 'Optional: FLUTTER_ANDROID_BUILD_DIR selects an existing host build directory.\n'
  printf 'Absolute build symlinks use a local cache mount; normal build directories need no extra setting.\n'
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if (( $# == 0 )); then
  usage >&2
  exit 2
fi
if [[ ! -d "$1" ]]; then
  printf 'Error: project directory does not exist: %s\n' "$1" >&2
  exit 2
fi
project_dir="$(cd -- "$1" && pwd -P)"
shift

command -v docker >/dev/null 2>&1 || {
  printf 'Error: Docker is not installed or is not on PATH.\n' >&2
  exit 1
}

image="${FLUTTER_ANDROID_IMAGE:-flutter-android:3.47.8}"
host_user="$(id -u):$(id -g)"
if ! image_user="$(docker image inspect \
  --format '{{index .Config.Labels "io.flutter-android.builder.uid"}}:{{index .Config.Labels "io.flutter-android.builder.gid"}}' \
  "$image" 2>/dev/null)"; then
  printf 'Error: cannot inspect local image %s. Run build-image.sh as your current regular user first.\n' "$image" >&2
  exit 1
fi
if [[ "$image_user" != "$host_user" ]]; then
  printf 'Error: image %s lacks matching builder UID/GID labels. Run build-image.sh as your current regular user first.\n' "$image" >&2
  exit 1
fi

cache_dir="${FLUTTER_ANDROID_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/flutter-android-docker}"
mkdir -p -- "$cache_dir"/{pub,gradle,android}
cache_dir="$(cd -- "$cache_dir" && pwd -P)"

# Docker's --mount syntax treats commas as option separators.
if [[ "$project_dir" == *,* || "$cache_dir" == *,* ]]; then
  printf 'Error: project and cache directory paths must not contain commas.\n' >&2
  exit 2
fi

build_mount_args=()
build_override="${FLUTTER_ANDROID_BUILD_DIR:-}"
if [[ -n "$build_override" ]]; then
  if [[ ! -d "$build_override" ]]; then
    printf 'Error: FLUTTER_ANDROID_BUILD_DIR must be an existing host directory: %s\n' "$build_override" >&2
    exit 2
  fi
  build_override="$(cd -- "$build_override" && pwd -P)"
fi

if [[ -L "$project_dir/build" ]]; then
  build_link="$(readlink -- "$project_dir/build")"
  if [[ ! -d "$project_dir/build" ]]; then
    printf 'Error: the project build symlink does not resolve to an existing directory.\n' >&2
    exit 2
  fi
  build_source="$(cd -- "$project_dir/build" && pwd -P)"
  if [[ -n "$build_override" && "$build_override" != "$build_source" ]]; then
    printf 'Error: FLUTTER_ANDROID_BUILD_DIR must match the existing build symlink target: %s\n' "$build_source" >&2
    exit 2
  fi
  if [[ "$build_link" == /* ]]; then
    # Preserve the link's literal absolute destination inside the container.
    # Mounting onto /workspace/build directly makes runc follow the symlink;
    # its outside destination is otherwise absent in the container filesystem.
    build_target="$(realpath --canonicalize-missing --no-symlinks -- "$build_link")"
    case "$build_target" in
      /|/workspace|/workspace/*|/home|/home/builder|/home/builder/*|/opt|/opt/*|/usr|/usr/*|/etc|/etc/*|/bin|/sbin|/lib|/lib64|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*)
        printf 'Error: absolute build symlink overlaps a container runtime directory: %s\n' "$build_target" >&2
        exit 2 ;;
    esac
    if [[ "$build_source" == *,* || "$build_target" == *,* ]]; then
      printf 'Error: build directory paths must not contain commas.\n' >&2
      exit 2
    fi
    build_mount_args+=(--mount "type=bind,source=$build_source,target=$build_target")
    printf 'Using this machine\047s external build symlink cache: %s\n' "$build_source" >&2
  else
    # Relative links fully contained in the project already work at /workspace.
    # An outside relative link changes meaning when its parent is remapped.
    build_target="$(realpath --canonicalize-missing --no-symlinks -- "/workspace/$build_link")"
    if [[ "$build_target" != /workspace/* || "$build_source" != "$project_dir/"* ]]; then
      printf 'Error: build is a relative symlink outside the project; use an absolute build symlink or a normal build directory.\n' >&2
      exit 2
    fi
  fi
elif [[ -n "$build_override" ]]; then
  if [[ "$build_override" == *,* ]]; then
    printf 'Error: build directory paths must not contain commas.\n' >&2
    exit 2
  fi
  # Create the mountpoint as the caller, avoiding a root-owned Docker-created
  # directory in projects that do not yet have a build directory.
  mkdir -p -- "$project_dir/build"
  build_mount_args+=(--mount "type=bind,source=$build_override,target=/workspace/build")
fi

docker_args=(
  run --platform linux/amd64 --rm --init
  --user "$host_user"
  --workdir /workspace
  --env HOME=/home/builder
  --mount "type=bind,source=$project_dir,target=/workspace"
  --mount "type=bind,source=$cache_dir/pub,target=/home/builder/.pub-cache"
  --mount "type=bind,source=$cache_dir/gradle,target=/home/builder/.gradle"
  --mount "type=bind,source=$cache_dir/android,target=/home/builder/.android"
  "${build_mount_args[@]}"
  -i
)
if [[ -t 0 && -t 1 ]]; then
  docker_args+=(-t)
fi

# Pass names only, so proxy credentials do not appear in the command line.
for variable in \
  PUB_HOSTED_URL FLUTTER_STORAGE_BASE_URL \
  HTTP_PROXY HTTPS_PROXY NO_PROXY \
  http_proxy https_proxy no_proxy; do
  if [[ -v "$variable" ]]; then
    docker_args+=(--env "$variable")
  fi
done

if (( $# == 0 )); then
  set -- bash
fi
exec docker "${docker_args[@]}" "$image" "$@"
