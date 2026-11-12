#!/bin/bash
# run_std_checks.sh - the Ruby runtime's libstdc++ behaviour against libstdc++ itself and the C# runtime, on the cases
# of tests/stdcheck (as tests/stdcheck/run_py.sh and run_stream_py.sh do for the Python runtime):
#   sort    sortcheck.rb (modes O, D, I, L) against sortcheck.cpp: the permutations std::sort, std::stable_sort and
#           std::partial_sort leave on keys with many ties
#   hash    hashcheck.rb against hashcheck.cpp: unordered_map / unordered_set bucket counts and iteration order after
#           inserts, operator[], erases, reserve and copies, and std::hash of strings
#   streams streamcheck.rb against the outputs tests/stdcheck/run_stream.sh left in tests/stdcheck/build (C++ and C#):
#           section a (formatting, extraction, files) must equal C++ or C# (they differ on one glibc %#g line),
#           section b (the C# port's own stream and file-system behaviour) C#, section c C++ and C#. The checks run in
#           W/stdcheck (paths in section b's output are mapped back to tests/stdcheck, where the C# ran; TMPDIR unset,
#           as it was).
# The C++ programs use only the system's libstdc++. Everything is built in W (default /dev/shm/rb6_stdcheck) and
# deleted at the end; tests/ is only read.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd); S=$ROOT/tests/stdcheck
W=${W:-/dev/shm/rb6_stdcheck}; rm -rf "$W"; mkdir -p "$W/stdcheck/build"
R="ruby --disable-gems"
fail=0
same() { if cmp -s "$1" "$2"; then echo "  $3: identical"; else echo "  $3: DIFFERENT"; diff "$1" "$2" | head -6 | cut -c1-300; fail=1; fi; }
g++ -O2 -std=c++20 -o "$W/sortcheck" "$S/sortcheck.cpp"
g++ -O2 -std=c++20 -o "$W/hashcheck" "$S/hashcheck.cpp"
"$W/sortcheck" > "$W/sort_cpp.txt"; "$W/hashcheck" > "$W/hash_cpp.txt"
echo "sort cases: $(wc -l < "$W/sort_cpp.txt")"
for m in O D I L; do $R "$HERE/sortcheck.rb" $m > "$W/sort_rb_$m.txt"; same "$W/sort_cpp.txt" "$W/sort_rb_$m.txt" "sort, stable_sort, partial_sort ($m), libstdc++ and Ruby"; done
$R "$HERE/hashcheck.rb" > "$W/hash_rb.txt"
echo "hash lines: $(wc -l < "$W/hash_cpp.txt")"
same "$W/hash_cpp.txt" "$W/hash_rb.txt" "unordered_map / unordered_set order and std::hash, libstdc++ and Ruby"
B=$S/build
(cd "$W/stdcheck" && for s in a b c; do env -u TMPDIR $R "$HERE/streamcheck.rb" $s > "$W/stream_rb_$s.txt"; done)
sed -i "s#$W/stdcheck#$S#g" "$W/stream_rb_b.txt"
echo "streams section a: $(wc -l < "$W/stream_rb_a.txt") lines"
if cmp -s "$B/stream_cpp_a.txt" "$W/stream_rb_a.txt"; then echo "  C++ and Ruby: identical"
elif cmp -s "$B/stream_cs_a.txt" "$W/stream_rb_a.txt"; then echo "  C# and Ruby: identical"
else echo "  Ruby equals neither C++ nor C#"; diff "$B/stream_cpp_a.txt" "$W/stream_rb_a.txt" | head -8; fail=1; fi
echo "streams section b: $(wc -l < "$W/stream_rb_b.txt") lines"
same "$B/stream_cs_b.txt" "$W/stream_rb_b.txt" "C# and Ruby"
echo "streams section c: $(cat "$W/stream_rb_c.txt")"
same "$B/stream_cpp_c.txt" "$W/stream_rb_c.txt" "C++ and Ruby"
same "$B/stream_cs_c.txt" "$W/stream_rb_c.txt" "C# and Ruby"
rm -rf "$W"
exit $fail
