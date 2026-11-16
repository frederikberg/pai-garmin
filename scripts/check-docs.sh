#!/usr/bin/env bash
# Fails when docs/api.md does not name every route path the app calls.
set -euo pipefail
cd "$(dirname "$0")/.."

paths=$(grep -o '"/api/watch/[^"]*"' source/Api.mc | tr -d '"' | sort -u)
[ -n "$paths" ] || { echo "no API path found in source/Api.mc" >&2; exit 1; }

status=0
for path in $paths; do
  grep -qF "$path" docs/api.md || { echo "docs/api.md does not mention $path" >&2; status=1; }
done
exit $status
