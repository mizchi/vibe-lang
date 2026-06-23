#!/usr/bin/env bash
# No-op: the MoonBit host (src/) was retired (#594); vibe is selfhost-only and
# needs no MoonBit toolchain. Kept as a stub so legacy CI workflows/actions that
# still reference it (setup-vibe action, release.yml, flaker-scheduled.yml) do
# not fail on a missing file. Remove once those workflows are reworked/retired.
echo "install_moonbit.sh: no-op (selfhost-only; MoonBit retired, #594)"
exit 0
