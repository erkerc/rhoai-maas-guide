#!/usr/bin/env bash
# Convenience wrapper - delegates to the canonical verification script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/../manifests/06-verification/verify.sh" "$@"
