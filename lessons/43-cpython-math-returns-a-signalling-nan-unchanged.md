CPython's math.log, log10 and log2 hand a signalling NaN back unchanged, and the Python runtime's floor, ceil, trunc, round and sqrt did the same; glibc quiets it.

Found by the Hy port's math check (`hy/test/run_libm_tests.sh`), which replays the vector files of `tools/libm/test`
(about a million arguments per function, NaNs of both signs with several payloads among them) through the runtime
exactly as the engine calls it and compares every result's 64 bits with the system's glibc. The Hy runtime started as
the Python runtime re-spelled (`py/cpp/crtmath.py`), which had passed the Python port's own check
(`tests/crtcheck/pycheck`, whose special values are quiet NaNs). The new vectors found 1,940 differences in the edge
set (`log`, `log10`), 4 in set 2 (`log2`) and 7,296 in the exact operations (`sqrt`, `floor`, `ceil`, `trunc`,
`round`), every one a signalling NaN argument:

```
  log(nan[fff510b684b9d045]) = fffd10b684b9d045  hy: nan [fff510b684b9d045]
  sqrt(nan[7ff0000000000123]) = 7ff8000000000123  hy: nan [7ff0000000000123]
```

The code, as it was in `py/cpp/crtmath.py`:

```python
def Math_Log_d(x):
    try:
        return _log(x)          # math.log: for a NaN, CPython returns its argument itself
    except ValueError:
        return _c_log(x)

def Math_Floor_d(x):
    if -_TWO52 < x < _TWO52:
        return x // 1.0
    return x                    # NaN, infinities and huge numbers: x as it came
```

CPython's `m_log` returns a NaN argument without calling libm (`if (isnan(x)) return x;`), and so do `log10` and
`log2`; glibc's routines compute with it, and any arithmetic on a signalling NaN on x86 returns it quieted (bit 51
set: `fff5...` becomes `fffd...`). x86's `sqrtsd` and `roundsd` (glibc's floor, ceil, trunc and round) quiet it too.

The fix, in the Hy runtime only (`hy/cpp/crtmath.hy`, now written by hand; `tools/cs2x/py2hy.py` leaves it alone and
its check requires that exactly these eight functions differ from the Python file): the three logarithms send a NaN
result to glibc through ctypes, as `Math_Pow_d` already did, and the other five return `x + 0.0`, which quiets a
signalling NaN and leaves an infinity or a number beyond 2^52 as it is. After it: 0 differences on 38.4 million cases
apart from the cast in lesson 44.

No output can have changed: the engine never makes a signalling NaN (every NaN it computes is an arithmetic result,
quiet by definition, and the ones it parses or names are quiet). The Python runtime keeps the difference; per lesson
25 it is reported here for its owner.

The rule: a library check is only as good as its NaNs. Test signalling NaNs and payloads, not only "a NaN", and test
each function through the wrapper the engine calls, because the wrapper (here CPython's) can decide a case before the
library sees it.
