#!/bin/bash
# rerun_build.sh [COMMIT] [DIR] - the first half of the independent rerun: a clean copy of COMMIT (default HEAD) of
# this repository (git archive) in DIR (default /dev/shm/rb6_v), where the translator is rebuilt, the engine is
# regenerated from cs/gen and compared byte for byte with the committed ruby/gen/engine.rb (and the translator's three
# reports with the committed ruby/cs2rb_*.txt), the one generated runtime file (ruby/cpp/primelist.rb) is written
# again by ruby/make_primelist.sh and compared, and the engine is checked with ruby -c. Ruby needs no build step: the
# gate then runs that copy as it is:
#   ruby/gate/run_chunk.sh rb6_v corpus ruby/gate/ids_v.txt DIR/ruby/runswmm6_saves.sh   (and rb6_vx, extra)
# After kotlin/gate/rerun_build.sh. Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
set -e
K=$(cd "$(dirname "$0")/.." && pwd); ROOT=$(cd "$K/.." && pwd)
C=${1:-HEAD}; R=${2:-/dev/shm/rb6_v}
rm -rf "$R"; mkdir -p "$R"
git -C "$ROOT" archive "$C" | tar -x -C "$R"
echo "== clean copy of $(git -C "$ROOT" rev-parse --short "$C") in $R"
cd "$R"
echo "== the translator: tools/cs2x/build_rb.sh"
nice -n 10 tools/cs2x/build_rb.sh 2>&1 | grep -v 'warning CS' || true
echo "== the engine, regenerated from cs/gen into $R/regen and compared with ruby/gen/engine.rb and ruby/cs2rb_*.txt"
mkdir -p "$R/regen/gen"
nice -n 10 dotnet tools/cs2x/bin/cs2rb.dll cs "$R/regen/gen"
for f in gen/engine.rb cs2rb_runtime.txt cs2rb_todo.txt cs2rb_stats.txt; do
	if cmp -s "$R/regen/$f" "ruby/$f"; then echo "ruby/$f: $(wc -l < "ruby/$f") lines, byte-identical to the commit"; else echo "ruby/$f: DIFFERENT"; exit 1; fi
done
echo "== the generated runtime file, written again by ruby/make_primelist.sh"
cp ruby/cpp/primelist.rb "$R/primelist_committed.rb"
ruby/make_primelist.sh
if cmp -s "$R/primelist_committed.rb" ruby/cpp/primelist.rb; then echo "ruby/cpp/primelist.rb: byte-identical to the commit"; else echo "primelist.rb: DIFFERENT"; exit 1; fi
rm -rf "$R/regen" "$R/primelist_committed.rb"
echo "== syntax"
ruby -c ruby/gen/engine.rb
ruby --version
