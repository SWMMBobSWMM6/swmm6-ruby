# summarize.py [PREFIX...] - the Ruby port's gate runs in one table: for each run rb6_* (gate/results/NAME.json, or the
# .jsonl of a run still going), its models, statuses and engine seconds, and from ruby/gate/NAME_times.txt when it was
# queued, started and ended; then the totals per set (each model's last result counts) and every model that did not
# pass, with its status and first difference. Copied from hy/gate/summarize.py. Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports.
import glob, json, os, re, sys
from datetime import datetime
H = os.path.dirname(os.path.abspath(__file__)); G = os.path.join(H, '..', '..', 'gate')
prefixes = sys.argv[1:] or ['rb6_c', 'rb6_x']


def load(name):
    p = os.path.join(G, 'results', name + '.json')
    if os.path.exists(p):
        return json.load(open(p))
    p += 'l'
    return [json.loads(l) for l in open(p) if l.strip()] if os.path.exists(p) else []


def times(name):
    """first queued, first started, last ended, and the seconds spent inside the lock (each start to the next end
    or kill: a run stopped by the two-hour limit and resumed holds the lock twice)"""
    q = s = e = None
    inside, cur = 0.0, None
    p = os.path.join(H, name + '_times.txt')
    if os.path.exists(p):
        for l in open(p):
            m = re.match(r'(queued|started|ended|killed) (\S+)', l)
            if m:
                t = datetime.fromisoformat(m.group(2))
                if m.group(1) == 'queued':
                    q = q or t
                elif m.group(1) == 'started':
                    s = s or t
                    cur = t
                else:
                    if m.group(1) == 'ended':
                        e = t
                    if cur:
                        inside += (t - cur).total_seconds()
                        cur = None
    return q, s, e, inside


names = sorted({os.path.basename(f)[:-len('_times.txt')] for f in glob.glob(os.path.join(H, 'rb6_*_times.txt'))
                if any(os.path.basename(f).startswith(p) for p in prefixes)})
for pre in prefixes:
    last = {}
    tot_eng = tot_wall = 0.0
    print('%-10s %6s %-24s %9s  %-19s %-19s %-19s' % ('run', 'models', 'statuses', 'engine s', 'queued', 'started', 'ended'))
    for n in [x for x in names if x.startswith(pre)]:
        rs = load(n)
        for r in rs:
            last[r['id']] = r
        st = {}
        for r in rs:
            st[r['status']] = st.get(r['status'], 0) + 1
        q, s, e, inside = times(n)
        eng = sum(r['sec'] for r in rs)
        tot_eng += eng
        tot_wall += inside
        f = lambda t: t.strftime('%m-%d %H:%M:%S') if t else '-'
        print('%-10s %6d %-24s %9.0f  %-19s %-19s %-19s' % (n, len(rs), ' '.join('%s %d' % kv for kv in sorted(st.items())),
                                                       eng, f(q), f(s), f(e)))
    c = {}
    for r in last.values():
        c[r['status']] = c.get(r['status'], 0) + 1
    print('%s*: %d models, %s; engine time %.0f s (%.2f h), wall time inside the lock %.0f s (%.2f h)\n'
          % (pre, len(last), ', '.join('%s %d' % kv for kv in sorted(c.items())), tot_eng, tot_eng / 3600, tot_wall, tot_wall / 3600))
    for r in sorted(last.values(), key=lambda r: r['path']):
        if r['status'] != 'PASS':
            print('  %s %s %s after %.0f s; first .rpt difference %s' % (r['status'], r['id'], r['path'], r['sec'], r['first_rpt_diff']))
