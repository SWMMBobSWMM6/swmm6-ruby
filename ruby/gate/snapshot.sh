#!/bin/bash
# snapshot.sh [COMMIT] - export ruby/ as committed at COMMIT (default HEAD) (git archive: uncommitted edits are left out) to
# /dev/shm/rb6_eng/<commit>/ruby and print the SAVE-file wrapper's path there, the ENGINE a gate chunk runs. The gate
# then runs a fixed commit, and work on the tree while a chunk is queued or running cannot change what it runs.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
C=$(git -C "$ROOT" rev-parse --short=7 "${1:-HEAD}")
D=/dev/shm/rb6_eng/$C
if [ ! -f "$D/ruby/runswmm6_saves.sh" ]; then
	rm -rf "$D"; mkdir -p "$D"
	git -C "$ROOT" archive "$C" ruby/cpp ruby/gen ruby/runswmm6 ruby/runswmm6.rb ruby/runswmm6_saves.sh | tar -x -C "$D"
fi
echo "$D/ruby/runswmm6_saves.sh"
