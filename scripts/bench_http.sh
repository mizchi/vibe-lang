#!/usr/bin/env bash
set -euo pipefail

# Kill child processes on interrupt to prevent orphans
trap 'trap - EXIT; kill -- -$$ 2>/dev/null || true' INT TERM

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
echo "bench-http: unavailable." >&2
echo "bench-http: public \`vibe bench\` no longer supports the interpreter backend, and the compiled bench path does not provide Http builtins yet." >&2
echo "bench-http: use \`scripts/test_http_e2e.sh\` for HTTP coverage, or add a dedicated \`vibe run\` benchmark when compiled HTTP benchmarking is available." >&2
exit 2
