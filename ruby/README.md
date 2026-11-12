# The OpenSWMM 6 1D engine in Ruby, byte for byte

A translation of the 1D engine of OpenSWMM 6 (HydroCouple/openswmm.engine, branch `swmm6_rel`, commit 88329d6) into
Ruby, held to the same output as the C++ engine: the same binary `.out` file and the same `.rpt` report, apart from
the three clock lines. It is not SWMM6 and not a HydroCouple or EPA release; it is a translation checked against
SWMM6.

## Result

**478 of 480 models byte-identical** against the C++ reference engine built from the same commit and run on one
thread, on the 480-model gate set the SWMM5 ports were checked on, drawn from 1729-SWMM5-Models-2030. **Two models were
not run: they timed out after 1800 s**, the time limit set for this port: `EPA/72_H&H_Elements(2).inp` (run
`rb6_c05b`) and `Hydrology/SCANLON.inp` (`rb6_c05a2`). They are not passes. The bytes of `.out` each had written when
it was stopped are the reference's (2,351 of 440,275 bytes and 42,334,342 of 78,975,850; `results/NAME_stopped.txt`);
the Python port, which runs at about this port's speed, took 4,056 s on `SCANLON.inp` and was stopped at 7,000 s on
`72_H&H_Elements(2).inp`. Gate runs `rb6_c04` (431 of 431), `rb6_c01` (8 of 8), `rb6_c02` (12 of 12), `rb6_c03a` and
`rb6_c03b` (11 of 11 each), `rb6_c06b` (2 of 2), `rb6_c06a1`, `rb6_c06a2`, `rb6_c05a1` (1 of 1 each), `rb6_c05a2` and
`rb6_c05b` (not run, timed out); 7.04 hours of running in all, a median of 2.9 s per model, the slowest model that
passed `attenuation_DW_High_CE.inp` (1,433 s).

**450 of 452 extra decks byte-identical**: SWMM6's own tests (the input files in the upstream repository's `tests`
folder at 88329d6) and the synthetic decks of swmm6-rust's gate (the finite-volume solver, its structure coupling,
the newer hydrology and the input checks). **Two decks were not run: they timed out after 1800 s**,
`legacy_small.inp` (run `rb6_x02a1`) and `refactored_small.inp` (`rb6_x02b2`); each had written 11.3% of its
155,158,965-byte `.out`, every byte the reference's. The Python port was stopped on both at 7,000 s and the TypeScript
port took 1,704 s and 1,613 s. Gate runs `rb6_x01a` (223 of 223), `rb6_x01b` (225 of 225), `rb6_x02a2` and
`rb6_x02b1` (1 of 1 each), `rb6_x02a1` and `rb6_x02b2` (not run, timed out); 2.27 hours in all, a median of 1.1 s
per deck, the slowest deck that passed `sdm_fv_o2_superbee.inp` (657 s).

**The independent rerun: 142 of 142.** A clean copy of commit b4bb6ac (`git archive`) in memory, where the translator
was rebuilt, the engine regenerated from `cs/gen` (`engine.rb` and the translator's three reports byte-identical to
the committed ones) and the one generated runtime file written again (`cpp/primelist.rb`, byte-identical;
`results/rb6_v_build.txt`), then gated as it was, on a sample: 100 corpus models drawn from the 478 that passed with
`random.Random(20261110).sample(sorted(passed), 100)` plus the three decks that SAVE and USE `Hydrology/cho.txt`
(`save_rtk_long.inp`, `one_sub_one_rdii_node.inp`, `Use_SeasonalRDIIn.inp`), runs `rb6_v_a` (50 of 50) and
`rb6_v_b` (52 of 52); and 40 extra decks drawn the same way from the 450, run `rb6_vx` (40 of 40); 1.57 hours in
all (`gate/sample_rerun.py`, `gate/ids_v.txt`, `gate/ids_vx.txt`). Every `.out` and `.rpt` hash equals the first
run's.

**The main session's check: 48 of 48 and 12 of 12.** A clean `git clone` of commit 63edc2e (in memory), where the
translator was rebuilt and the engine and `primelist.rb` regenerated (no file changed: `git status` empty; `ruby -c`
reports Syntax OK), then gated with no build step: run `rb6_main` on 45 corpus models drawn at random
(`random.Random(20261110)`) plus `Hydrology/save_rtk_long.inp`, `one_sub_one_rdii_node.inp` and
`Use_SeasonalRDIIn.inp`, the decks that SAVE and USE `cho.txt` (48 of 48; 1,918 s), and run `rb6_main_x` on 12 extra
decks drawn the same way (12 of 12; 19 s); the same samples as the Kotlin, Groovy, JavaScript, F# and Hy ports'
checks. Ids in `gate/ids_main_check.txt` and `gate/ids_main_check_extra.txt`; `Hydrology/cho.txt` was unchanged
afterwards (1,114,474 bytes, md5 5b0ca1fe78588202fa779dbfa417b089).

Every result, with the SHA-256 of each `.out` and `.rpt`, is in `results/NAME.json`, with the run's log beside it
(`results/NAME_run.txt`); the start and end of each run, and the engine it ran, are in `gate/NAME_times.txt`.
`gate/summarize.py` puts them in one table.

A model passes when its `.out` is byte-identical to the reference's (when the reference writes one), its `.rpt` is
identical after removing the lines "Analysis begun", "Analysis ended" and "Total elapsed time", and its exit code is
the same. The gate runs every model through `runswmm6_saves.sh`, which backs up the files a deck SAVEs and restores
them afterwards, so that no deck changes a file another deck reads.

The gate runs used a fixed copy of the port, `ruby/` as committed in d8b1363 (`gate/snapshot.sh`), so that work on the
tree could not change what a queued run executed. The later commits changed the runtime in two places the gate never
reached: `crt.rb` builds the exact value of a number that sscanf stores into a `float` only when it is used (the eager
form failed on exponents beyond 10^400), and `streams.rb` gained the manipulator objects and `std::fstream` that the
stream check calls. The independent rerun ran the final code.

The machine is shared: the gate runs waited for one lock with other ports' runs, and the container restarted twice
during the corpus gate (`gate/rb6_c02_times.txt`, `rb6_c03_times.txt`); the chunks stopped by a restart were run
again from the start, and the ones not yet run were cut into smaller ones (`gate/plan_chunks.py`).

Speed: on three decks run back to back with the Python port (`results/rb_vs_py.txt`) the Ruby engine took 0.97 to
1.16 times Python's time. On the seven slowest corpus models that passed it took 0.57 to 1.31 times the Python
port's recorded gate times (`27_Subs_Horton.inp`, 740 s against 1,300 s; `short_trap_SW5.inp`, 1,095 s against
833 s).

## How it was made

The C++ engine was translated to C# first (`cs/gen`, 480 of 480), and this engine is translated from that C#, not
from the C++, by a translator written for it: `tools/cs2x/Cs2Rb.cs`, `RbTypes.cs` and `RbFn.cs` (3,983 lines), which
read the C# (`cs/gen`, and the engine's hand-written partial classes `cs/runtime/Hand_*.cs`) through Roslyn's semantic
model and print one Ruby file, `gen/engine.rb` (193,058 lines). The translator began as a copy of the Python back end
(`Cs2Py.cs`): the analysis and the names are the Python port's, so the Ruby runtime is a port of the Python runtime,
module by module. Ruby's integers are unbounded, so fixed-width arithmetic is reduced to its type's range where the
width matters, as in Python; a conversion of a signed index to `ulong` is written as a comparison rather than a mask,
because the 64-bit mask is a Bignum and `&` with it is a method call (lesson 47). The mapping is in
`tools/cs2x/RB.md`; how often each translation choice was made is in `cs2rb_stats.txt`, every runtime name the engine
uses in `cs2rb_runtime.txt` (592), and the constructs left untranslated in `cs2rb_todo.txt` (none).

The runtime (`cpp/`, module `Cpp`, 8,719 lines) is the part of the C++ standard library and of the C library that the
engine calls: vectors, maps and sets with libstdc++'s hash-table node order and growth, strings, iterators, pointers,
introsort step for step, glibc-exact printf (every `%f`, `%e`, `%g` and `%a` by exact integer arithmetic; Ruby's
`format` is not correctly rounded), strtod with exact rounding and glibc's ERANGE, glibc's sscanf, stdio files,
iostreams and the file system as the C# port has them. It is written in Ruby; only `cpp/primelist.rb` (libstdc++'s
bucket counts) is written by a script (`make_primelist.sh`). `runswmm6.rb` is the command line (`src/cli/main.cpp`, by
way of the C# port's `Program.cs` and the Python port's `runswmm6.py`). Nothing calls another port's engine or
runtime.

The math is glibc's own. MRI's `Math` module calls the C library's functions at the same symbol versions the C++
engine imports (`exp`, `log`, `pow` and `log2` at GLIBC_2.29, `hypot` at GLIBC_2.35, `fmod` at GLIBC_2.38, the rest at
GLIBC_2.2.5), so on the common path the result is glibc's. Where MRI decides the result itself, the runtime calls
glibc through Fiddle instead (`cpp/crtmath.rb`): MRI raises `Math::DomainError` for `acos`, `asin`, `log` outside
their domains, `Float#**` returns a Complex for a negative base, `Math.cbrt` adds a Newton step after glibc's `cbrt`
(it differs from glibc on more than half of all arguments), and `expm1`, `log1p`, `remainder`, `fmod` and `nextafter`
are not in `Math`. `sqrt` of a positive number is MRI's (IEEE's); `floor`, `ceil`, `trunc`, `round` and `copysign`,
whose results IEEE fixes, are computed in Ruby.

Nothing in the generated engine is edited by hand: every fix went into the translator or the runtime.

## How it was checked

- **The math**: `test/run_libm_tests.sh` compares the functions as the engine calls them with the system's glibc
  2.39, bit for bit, by the method of `tools/libm/test`: a million arguments per function over the ranges SWMM uses
  with special values, and 200,000 to 700,000 edge cases each, for exp, log, log10, pow, sin, cos, tan, asin, acos and
  atan; a million per function over wide ranges and every branch threshold, with signed zeros, infinities,
  subnormals and NaNs of both signs with several payloads, for cbrt, hypot, atan2, cosh, sinh, tanh, log2, expm1 and
  log1p; a million each for sqrt, floor, ceil, trunc, fabs, round and copysign. 29,364,615 results, **0 differences**,
  NaN signs and payloads included (`results/libm_tests.txt`).
- **The C library**: `test/run_crtcheck.sh` runs the cases of `tests/crtcheck` (C programs using the system's own
  glibc) through the runtime (`test/crtcheck.rb`, after `tests/crtcheck/pycheck/crtcheck.py`): libm through the
  runtime, 0 differences in 300,576 cases for each of 27 functions; printf, 0 differences in 179,756 cases and in
  101,800 more covering every conversion the engine's format strings use; sscanf, 0 in 1,728; from_chars, strtol,
  strtod, atoi, ctime, ctype and get_nprocs, 0 in 752; and 105 unit checks of the rest (files, raw memory, atomics,
  variants, strings), 0 failures (`results/crtcheck.txt`). The runtime follows glibc where the C# runtime differs from
  it (a negative int printed with `%u`, `%hd`, the `#` flag, the sign of a NaN read from "nan").
- **libstdc++**: `test/run_std_checks.sh` runs the cases of `tests/stdcheck`: the permutations std::sort,
  std::stable_sort and std::partial_sort leave on keys with many ties (6,447 cases, through the generic sort and the
  double, int and long specialisations) and the hash tables' iteration order, bucket counts and std::hash (167
  lines), identical to libstdc++; the streams and the file system (2,963, 86 and 1 lines), identical to libstdc++ in
  section a, to the C# runtime in section b and to both in section c (`results/std_checks.txt`).
- **The engine**: the gate (above), run on the corpus and on the extra decks, and the independent rerun.

## Build and run

Needs Ruby 3.3 (3.3.6 was used) with its standard library (`fiddle` 1.1.2 and `etc`; no gems) and glibc on x86-64.
There is no build step. Run a model the way the C++ command line runs it:

    ruby/runswmm6 model.inp model.rpt model.out

The translator needs the .NET 8 SDK (8.0.132 was used). To regenerate the engine from `cs/gen`:
`tools/cs2x/build_rb.sh && dotnet tools/cs2x/bin/cs2rb.dll cs ruby/gen` (about 45 seconds); `ruby/make_primelist.sh`
writes `cpp/primelist.rb` again.

The gate: `ruby/gate/run_chunk.sh NAME corpus|extra [IDS_FILE] [ENGINE]` runs `gate/gate.py` on this port with the
SAVE-file wrapper, inside the shared lock (`WAIT` seconds at most); `gate/snapshot.sh [COMMIT]` makes the fixed copy a
chunk runs; `gate/rerun_build.sh` makes the clean copy of a commit that the independent rerun gates.

## What this does not show

- Four models, two of the corpus and two of the extra decks: they were stopped at the 1800 s limit and are not
  results.
- Agreement on models outside the 480 and the 452. A feature no gate model or deck uses is untested.
- The reference's parallel runs: every parallel loop runs on one thread, in order, as the C++ engine does when it
  is held to one thread.
- The 2D and other modules of OpenSWMM 6 beyond the 1D engine the command line runs.
- Every input to the math functions: they are glibc's own (through MRI's `Math` or Fiddle), and the tests check that
  each call reaches glibc with the right argument; another glibc would give that glibc's results.
- The core containers, iterators and pointers on their own: `tests/pycheck/corecheck.py` (the Python runtime's core
  helpers against the C# runtime's) was not ported to Ruby; the core runtime is exercised only through the engine
  and the checks above.
- Speed. The times above were measured on a shared two-core machine while other ports' gate runs were going.

## License and attribution

The engine is a translation of the OpenSWMM Engine, Copyright 2026 HydroCouple Developers, licensed under the
Apache License, Version 2.0 (https://github.com/HydroCouple/openswmm.engine, branch `swmm6_rel`, commit 88329d6).
Portions derive from the USEPA Storm Water Management Model, which is in the public domain; the USEPA does not
endorse this translation, and neither does HydroCouple. The math is the system's glibc, called at run time and not
copied; glibc and glibc-derived math are under the GNU Lesser General Public License 2.1 or later.

## AI use

The translator (`tools/cs2x/Cs2Rb.cs`, `RbTypes.cs`, `RbFn.cs`), the runtime (the Python port's runtime written again
in Ruby), the port's scripts and checks and these notes were written by Claude, Anthropic's AI model, for Robert
Dickinson, who directed the work. The engine is a mechanical translation of OpenSWMM 6 (Apache-2.0, HydroCouple
Developers), itself derived in part from the public-domain EPA SWMM; it was checked by running it against the C++
engine, not by reading it. glibc-derived math is LGPL-2.1-or-later. See `../AI-USE.md`.
