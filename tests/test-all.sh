#!/usr/bin/env bash
#
# Run every check that does not need the NAS.
set -uo pipefail

REPO_DIR=${REPO_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
# shellcheck source=/dev/null
. "$REPO_DIR/scripts/lib.sh"

fail=0

"$REPO_DIR/tests/test-repo.sh" || fail=1

for fs in $(fs_list); do
    if [ -d "$(out_dir)/stage/qnap-$fs" ]; then
        "$REPO_DIR/tests/test-package.sh" "$fs" || fail=1
    else
        warn "$fs: no package built yet, skipping (run ./build.sh $fs package)"
    fi
done

if [ "$fail" = 0 ]; then
    log "all checks passed"
else
    die "some checks failed"
fi
