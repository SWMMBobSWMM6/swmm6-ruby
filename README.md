# swmm6-ruby: the OpenSWMM 6 1D engine in Ruby, byte for byte

A translation of the 1D engine of OpenSWMM 6 (HydroCouple/openswmm.engine, branch `swmm6_rel`, commit 88329d6)
into Ruby, held to the same output as the C++ engine: the same binary `.out` file and the same `.rpt`
report, apart from the three clock lines. It is not SWMM6 and not a HydroCouple or EPA release; it is a
translation checked against SWMM6.

## Result

**478 of 480 models byte-identical** (the other 2 did not finish within the time limit, `Hydrology/SCANLON.inp` after 1800 s, `EPA/72_H&H_Elements(2).inp` after 1800 s; untested, not failed) against the C++ reference engine built from the same commit and run on one thread
(`OMP_NUM_THREADS=1`), on the 480-model gate set (the one the SWMM5 ports were checked on), drawn from
[1729-SWMM5-Models-2030](https://github.com/SWMMBobSWMM6/1729-SWMM5-Models-2030). Gate runs
`rb6_c01`, `rb6_c02`, `rb6_c03a`, `rb6_c03b`, `rb6_c04`, `rb6_c05a1`, `rb6_c05a2`, `rb6_c05b`, `rb6_c06a1`, `rb6_c06a2`, `rb6_c06b`; every result, with the SHA-256 of each `.out` and `.rpt`, is in `gate/evidence/`.

The same engine on the 452 extra decks: **450 of 452 extra decks byte-identical** (2 did not finish within the time limit: `legacy_small.inp`, `refactored_small.inp`; untested, not failed). These are SWMM6's own tests, which the corpus cannot be:
the input files in the upstream repository's `tests` folder at 88329d6, and the synthetic decks of
[swmm6-rust](https://github.com/SWMMBobSWMM6/swmm6-rust)'s gate, which probe the finite-volume solver, its
structure coupling, the newer hydrology and the input checks. Gate runs
`rb6_x01a`, `rb6_x01b`, `rb6_x02a1`, `rb6_x02a2`, `rb6_x02b1`, `rb6_x02b2`, in `gate/evidence/` with the same hashes.

Checked twice more. An independent rerun of a sample (100 corpus models drawn at random from those that passed, plus the three decks that SAVE and USE `cho.txt`, and 40 extra decks drawn the same way; a sample, not the full set, because Ruby runs at about Python's speed) from a clean copy of the repository (`git archive`), with
the translator rebuilt there and the engine (`ruby/gen/engine.rb`, with the translator's three reports) and `ruby/cpp/primelist.rb` regenerated there, all byte-identical to the committed files (`ruby/results/rb6_v_build.txt`): gate runs
`rb6_v_a`, `rb6_v_b`, `rb6_vx`, **142 of 142 byte-identical**. Then the main session's own check, from a
clean `git clone`: the translator rebuilt and the engine and `primelist.rb` regenerated (identical again; `ruby -c` reports Syntax OK); and gate runs `rb6_main` on 45 corpus models drawn at random (seed 20261110) plus the three decks that
SAVE and USE `cho.txt` (**48 of 48 byte-identical**) and `rb6_main_x` on 12 extra decks drawn the same way
(**12 of 12 byte-identical**). The math's own tests are in `ruby/results/libm_tests.txt`.

The four that did not finish were stopped at the gate's 1,800-second limit, and no longer limit was tried. Every byte of `.out` each had written by then is identical to the reference (`ruby/results/*_stopped.txt`): `SCANLON.inp` 42,334,342 of 78,975,850 bytes (53.6%), `legacy_small.inp` 17,545,557 of 155,158,965 (11.3%), `refactored_small.inp` 17,600,169 of 155,158,965 (11.3%), and `72_H&H_Elements(2).inp` only its first 2,351 of 440,275 bytes (0.5%), which is next to no evidence. They are slow in the other interpreted ports too: the Python port took 4,056 s on `SCANLON.inp` and did not finish the other three in 7,000 s.

A model passes when its `.out` is byte-identical to the reference's (when the reference writes one), its `.rpt` is
identical after removing the lines "Analysis begun", "Analysis ended" and "Total elapsed time", and its exit code is
the same (the command line exits nonzero when a model stops on an input error).

The translations, all from the same C# and gated the same way: swmm6-csharp, swmm6-go, swmm6-java, swmm6-typescript, swmm6-fortran, swmm6-python, swmm6-kotlin, swmm6-groovy, swmm6-javascript, swmm6-fsharp, swmm6-hy, swmm6-ruby, under
[SWMMBobSWMM6](https://github.com/SWMMBobSWMM6).

## How it was made

The C++ engine was translated to C# first, and the C# gated to 480 of 480. The other languages are translated
from that C#, not from the C++. `tools/cs2x/Cs2Rb.cs`, begun from the Python back end, translates the verified C# engine (`cs/gen`) through Roslyn into one Ruby file (`ruby/gen/engine.rb`; the mapping is in `tools/cs2x/RB.md`). `ruby/cpp` is the runtime library in Ruby, written by hand from the Python port's runtime. Math is glibc's own: MRI's `Math` where it calls glibc directly, and glibc called through Fiddle where MRI would decide a result itself or has no function (`cbrt`, `expm1`, `log1p`, `fmod`, `remainder`, `nextafter`, `pow` of a negative base, and `acos`, `asin` and the logarithms outside their domains). Nothing in `ruby/` loads anything from the other ports.

Nothing in the generated engine is edited by hand. Where the output depends on the C library (printf's rounding,
strtod, sscanf, the order of a hash table's nodes, introsort's swaps), the runtime reproduces glibc and libstdc++
exactly; the checks in `tests/` compare it with them case by case.

## Build and run

Needs Ruby 3.3 (standard library only: fiddle and etc; run here with 3.3.6, no YJIT) on x86-64 Linux with glibc; the .NET 8 SDK only to regenerate the engine. No build step. Then run a model the way the C++ command line runs it:

    ruby/runswmm6 model.inp model.rpt model.out

To regenerate the engine: tools/cs2x/build_rb.sh, then dotnet tools/cs2x/bin/cs2rb.dll cs ruby/gen, then ruby/make_primelist.sh. The C# engine it starts from is regenerated from the C++ source with
`tools/cpp2x` (see the header of `tools/cpp2x/emit_cs.py` and `cs/README.md`), which needs the OpenSWMM source at
commit 88329d6 and libclang.

## The gate

`gate/make_ref.sh` makes the reference outputs with the C++ engine (`ref/runswmm6`: build openswmm.engine at
88329d6 and run it single-threaded); `gate/gate.py NAME "ruby/runswmm6" --resume` runs this engine on every model in
`gate/models_all.tsv` (paths relative to the corpus; set `SWMM_CORPUS`) and compares; `gate/cmp1.sh` checks one
model. The extra decks are listed in `gate/models_extra.tsv`, with paths relative to a folder that holds clones of
openswmm.engine (at 88329d6) and swmm6-rust: make their references with
`SWMM_CORPUS=FOLDER MODELS=gate/models_extra.tsv REF=$PWD/gate/ref_outputs_extra gate/make_ref.sh`, then run
`gate/gate.py NAME "ruby/runswmm6" --models gate/models_extra.tsv --ref gate/ref_outputs_extra --root FOLDER --resume`.
The median time per model in the gate runs was 2.89 s (the C# engine's: 0.76 s, which includes .NET's start-up and JIT compilation). The times were measured on a shared two-core cloud machine while other runs were going, so they are a
rough guide, not a benchmark.

## What this does not show

- Agreement on models outside the 480 and the 452. The two sets are broad (EPA's examples, the OWA EXTRAN set,
  hydrology, hydraulics, water quality, LID, RDII, controls, hot start, input errors, the FV solver and SWMM6's own
  tests), but a feature no gate model or deck uses is untested.
- The reference's parallel runs. Every parallel loop runs on one thread, in order, which is what the C++ engine
  does when it is held to one thread; results with OpenMP threads can differ in the last bits.
- The 2D and other modules of OpenSWMM 6 beyond the 1D engine the command line runs.

## License and attribution

This repository is a translation of the OpenSWMM 6 engine.

OpenSWMM Engine — Copyright 2026 HydroCouple Developers, licensed under the Apache License, Version 2.0. See
[LICENSE](LICENSE) and [NOTICE](NOTICE). Source: https://github.com/HydroCouple/openswmm.engine (branch
`swmm6_rel`, commit `88329d6`).

Every generated engine file here is a modified, mechanically translated form of the OpenSWMM sources: its header
names what it was generated from, and each C# file in `cs/gen` names the OpenSWMM source file it came from.

Portions derive from the USEPA Storm Water Management Model, which is in the public domain under 17 USC § 105. The
USEPA does not endorse this product, and neither does HydroCouple.

The translators, the runtime, the gate and the notes: Copyright 2026 Robert Dickinson, licensed under the Apache
License, Version 2.0.

## AI use

Made with Claude (Anthropic): the translators, the runtime, the gate and the notes are Claude's work, directed by
Robert Dickinson; the engine itself is OpenSWMM's, translated mechanically. See [AI-USE.md](AI-USE.md).
