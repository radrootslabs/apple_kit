#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

command=${1:-}
case "$command" in
  build|test) shift ;;
  *) echo "usage: $0 {build|test} [SwiftPM arguments...]" >&2; exit 64 ;;
esac

scratch_path=${SWIFTPM_SCRATCH:-"$repo_root/.build"}
case "$scratch_path" in
  /*) ;;
  *) echo "error: SWIFTPM_SCRATCH must be an absolute path" >&2; exit 64 ;;
esac
output_args=(--scratch-path "$scratch_path")
if [[ -n "${SWIFTPM_CACHE:-}" ]]; then
  case "$SWIFTPM_CACHE" in
    /*) ;;
    *) echo "error: SWIFTPM_CACHE must be an absolute path" >&2; exit 64 ;;
  esac
  output_args+=(--cache-path "$SWIFTPM_CACHE")
fi

exec swift "$command" "${output_args[@]}" --disable-automatic-resolution "$@"
