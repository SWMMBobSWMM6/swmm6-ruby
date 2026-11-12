# plan_chunks.py - cut the Ruby gate into chunks: each model's time estimated from the Python port's gate times
# (gate/evidence/py2.json, else py1.json; py_x2.json for the extra decks) times RATIO, the Ruby/Python ratio measured on
# three decks run back to back (1.15; README.md), times SAFETY for the load of the shared machine, plus a second for
# Ruby's start; a model the Python gate stopped is estimated from the TypeScript port's time (ts2.json, ts_x3.json)
# times 4.24 (the median Python/TypeScript ratio). Estimates are capped at the 1800 s limit. Models estimated at
# SLOW s or more go into chunks of their own (at most three); the rest are packed into chunks of at most BUDGET s.
# Writes ids_<prefix>NN.txt and prints each chunk's estimate. Written by Claude (Anthropic) for Robert Dickinson's
# SWMM6 ports; see ../README.md.
import json, os, sys
H = os.path.dirname(os.path.abspath(__file__)); E = os.path.join(H, '..', '..', 'gate', 'evidence')
RATIO, SAFETY, START, CAP, SLOW, BUDGET = 1.15, 1.25, 1.0, 1800.0, 1200.0, 5400.0
kind = sys.argv[1]                      # corpus or extra
def load(n): return {r['id']: r for r in json.load(open(os.path.join(E, n + '.json')))}
if kind == 'corpus':
    py = load('py1'); py.update(load('py2')); ts = load('ts2'); prefix = 'c'
else:
    py = load('py_x2'); ts = load('ts_x3'); prefix = 'x'
est = {}
for mid, t in ts.items():
    p = py.get(mid)
    base = p['sec'] if p and p['status'] != 'TIMEOUT' and p['rc'] != 'timeout' else t['sec'] * 4.24
    est[mid] = min(CAP, base * RATIO * SAFETY + START)
slow = sorted([m for m in est if est[m] >= SLOW], key=lambda m: -est[m])
rest = sorted([m for m in est if est[m] < SLOW], key=lambda m: -est[m])
chunks = [slow[i:i + 3] for i in range(0, len(slow), 3)]
bins = []
for m in rest:                          # first fit, largest first
    for b in bins:
        if sum(est[x] for x in b) + est[m] <= BUDGET:
            b.append(m); break
    else:
        bins.append([m])
chunks = bins + chunks
for k, c in enumerate(chunks, 1):
    open(os.path.join(H, 'ids_%s%02d.txt' % (prefix, k)), 'w').write(''.join(m + '\n' for m in sorted(c)))
    print('%s%02d %3d models  est %5.0f s' % (prefix, k, len(c), sum(est[m] for m in c)))
print('total %d models, est %.2f h' % (len(est), sum(est.values()) / 3600))
# After two container restarts on 10 November (each stopped a queued or running chunk; /dev/shm emptied), the chunks
# not yet run were cut smaller, at most about an hour each, by hand: c03 into c03a and c03b (two halves by estimate),
# c05 into c05a (27_Subs_Horton.inp, SCANLON.inp) and c05b (72_H&H_Elements(2).inp), c06 and c07 into c06a
# (CN_Horton.inp, 22_Subs.inp) and c06b (attenuation_DW_High_CE.inp, 17_Sub_90_Link_USA_Units.inp), x01 into x01a and
# x01b (two halves by estimate), x02 and x03 into x02a (legacy_small.inp, sdm_fv_o1.inp) and x02b (sdm_fv_o2.inp,
# refactored_small.inp).
# The corpus lock was then held for an hour or more at a time by other ports' runs, so the pairs not yet run (c05a,
# c06a, x02a, x02b) were cut into single models (c05a1, c05a2, c06a1, c06a2, x02a1, x02a2, x02b1, x02b2), each of
# which fits the 1800 s limit and leaves the longest wait for the lock inside the two hours.
