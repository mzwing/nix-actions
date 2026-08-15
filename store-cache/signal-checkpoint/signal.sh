#!/usr/bin/env bash
# Request a mid-run checkpoint from the cache host.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

if ci_ssh "${CACHE_HOST}" 'touch /tmp/cache_checkpoint'; then
  notice 'Requested a mid-run Attic checkpoint.'
else
  warn 'Could not signal the Attic checkpoint; continuing without it.'
fi
