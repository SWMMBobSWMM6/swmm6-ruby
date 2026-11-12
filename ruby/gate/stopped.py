# stopped.py NAME MEMDIR SET - after a gate run of the Ruby port: for every model the gate stopped at the time limit,
# write how much of its .out had been written and whether those bytes are the reference's (the first bytes of a
# stopped run are evidence of how far it got, not a result), then delete a partial .out over 5 MB so that the copy of
# the run's failures to the shared disk stays small. Other failures' outputs are left as they are (evidence).
# Appends to ruby/results/NAME_stopped.txt. Copied from hy/gate/stopped.py. Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports.
import json, os, sys
name, mem, kind = sys.argv[1], sys.argv[2], sys.argv[3]
H = os.path.dirname(os.path.abspath(__file__)); G = os.path.join(H, '..', '..', 'gate')
ref = os.path.join(G, 'ref_outputs_extra' if kind == 'extra' else 'ref_outputs')
recs = {}
jl = os.path.join(G, 'results', name + '.jsonl')
if os.path.exists(jl):
    for l in open(jl):
        try:
            r = json.loads(l); recs[r['id']] = r
        except ValueError:
            pass
lines = []
for mid, r in sorted(recs.items()):
    if 'TIMEOUT' not in r['status']:
        continue
    o, ro = os.path.join(mem, mid, 'r.out'), os.path.join(ref, mid, 'r.out')
    n = os.path.getsize(o) if os.path.exists(o) else 0
    rn = os.path.getsize(ro) if os.path.exists(ro) else 0
    same = 0
    if n and rn:
        with open(o, 'rb') as a, open(ro, 'rb') as b:
            while True:
                x, y = a.read(1 << 20), b.read(1 << 20)
                m = min(len(x), len(y))
                if m == 0:
                    break
                if x[:m] == y[:m]:
                    same += m
                    if len(x) != len(y):
                        break
                    continue
                lo, hi = 0, m                   # the first differing byte: x[:lo] == y[:lo], x[:hi] != y[:hi]
                while lo + 1 < hi:
                    mid = (lo + hi) // 2
                    if x[:mid] == y[:mid]:
                        lo = mid
                    else:
                        hi = mid
                same += lo
                break
    lines.append('%s %s %s: stopped after %.0f s; .out %d of %d bytes written (%.1f%%), the first %d identical to the reference%s'
                 % (name, mid, r['path'], r['sec'], n, rn, 100.0 * n / rn if rn else 0.0, same,
                    ' (all written bytes)' if n and same == n else ''))
    if n > 5 << 20:
        os.remove(o)
if lines:
    with open(os.path.join(H, '..', 'results', name + '_stopped.txt'), 'a') as f:
        f.write(''.join(l + '\n' for l in lines))
    print('\n'.join(lines))
