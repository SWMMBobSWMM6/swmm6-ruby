# C# to Ruby: how tools/cs2x/Cs2Rb.cs maps the generated engine

The Ruby engine is written from the verified C# engine (`cs/gen`, 480/480 against the SWMM6 reference) the way the
Python engine is: Roslyn's semantic model, one IOperation tree per method, printed as Ruby. The translator began as
a copy of the Python back end (`Cs2Py.cs`, `PyTypes.cs`, `PyFn.cs`; `PY.md`): the analysis (cells, written fields,
makers, overload names) and the runtime contract (`py/RUNTIME_HELPERS.md`) are the Python port's, so the Ruby runtime
(`ruby/cpp`, module `Cpp`) is a module-by-module port of the Python runtime (`py/cpp`) and every runtime name the
engine uses has the Python spelling. What is Ruby's is recorded here.

    tools/cs2x/build_rb.sh && dotnet tools/cs2x/bin/cs2rb.dll cs ruby/gen

writes `ruby/gen/engine.rb` (one file, 193,058 lines), `ruby/cs2rb_runtime.txt` (every runtime name the file uses,
with the C# member it stands for: 592), `ruby/cs2rb_todo.txt` (untranslated constructs: none) and
`ruby/cs2rb_stats.txt` (how often each translation choice was made).

## Output

- Engine classes, base classes first; `attr_accessor` for fields; `initialize` sets every field to its C# default
  (`0`, `0.0`, `false`, `nil`, a runtime struct's `_ZERO`); each C# constructor is a method (`ctor_<Type><sfx>`, or the
  C# engine's own `__init_*` methods, which hold the C++ member initialisers) and a factory function
  `<Type>__new<sfx>(...)` that allocates the object, calls it and returns the object.
- Free functions and static methods are top-level methods (`F_<file>_<name>`, `<Type>_<name>`, the Python names);
  static fields are globals (`$<Type>_<name>`), set by one initializer method per class (`_si_<Type>`) called in C#'s
  dependency order at load time. Top-level methods are private methods of Object, and so callable from every class
  body, as a module-level function is in Python.
- The runtime is module `Cpp`, included into Object before the engine is loaded (`ruby/runswmm6.rb`), so the engine
  calls `R_Lit`, `NewVecD`, `Math_Pow_d` by their bare names; runtime classes are written `Cpp::Name`.
- Every file starts with `# encoding: binary` and `# frozen_string_literal: true`: C strings are bytes, and a C#
  string literal becomes a binary Ruby String (each UTF-16 unit's low byte, as `R.Lit` stores it).

## Names

- Ruby keywords, and the names of Object's and Kernel's methods (`send`, `class`, `hash`, `display`, `format`,
  `method`, `freeze`, `then`, `p`, `print`, `test`, `select`, `exit`, `raise`, ... and Exception's), get a `_` suffix as
  method or field names, so an engine member never shadows what Ruby itself calls.
- A capitalised name is a constant in Ruby: locals and parameters are lowercased or prefixed (`_`), and an engine
  class whose name collides with a runtime or Ruby constant (`Cpp`, `Fiddle`, `Engine`, `Main`, ...) gets a `_`.
- Overloads, hiding and `M_` rules are the Python back end's (`MethodIdent`); the translator checks that no engine
  member name clashes with an engine or runtime function (`CheckNameClashes`).

## Numbers

Ruby's Integer is unbounded and its Float is an IEEE double.

- Fixed-width integers keep C#'s wrap-around as in the Python port: a value that may lie outside its type's range
  ("raw": the result of + - * << and unary -) is reduced only where it is stored or where the result depends on the
  width (comparison, / % >>, conversion, index, argument, return). Signed 32-bit: `((x + 0x80000000 & 0xFFFFFFFF) -
  0x80000000)`; unsigned: `x & 0xFFFFFFFF`; the same for 8, 16 and 64 bits.
- `(ulong)` of a signed value is written as a comparison, `(x < 0 ? x + 0x10000000000000000 : x)`: the 64-bit mask is
  a Bignum, and `&` with a Bignum is a method call where a Fixnum comparison is a VM instruction (lesson 47; 2,437
  array indexes took that path; the engine became about 15% faster).
- Integer `/` and `%` floor in Ruby; C# truncates: `idiv(a, b)` and `a.remainder(b)` for signed operands.
- An int converted to double is passed straight to Ruby's mixed arithmetic (`Integer#+(Float)` converts exactly), and
  made a Float with `.to_f` where it is stored or where both operands are integers (`Integer / Integer` floors).
- Division of doubles by a zero is `fdiv0(a, b)` (x86's results: infinities with the right sign, the default NaN for
  0/0, which MRI would give as +NaN); every other division is Ruby's `/`.
- `float` (C# single) is rounded to single precision after every operation and conversion (`f32`); an integer is
  rounded from its exact value, as C#'s `(float)long` does.
- Math goes to the runtime (`Math_Pow_d`, `Math_Log_d`, `LibM_expm1`, ...; `ruby/cpp/crtmath.rb`): MRI's `Math` is
  glibc's on the common path, and glibc itself through Fiddle where MRI raises (`Math::DomainError`), returns a
  Complex (`Float#**` of a negative base) or adds its own step (`Math.cbrt`). `Math.Sqrt` is inlined as
  `(x > 0.0 ? Math.sqrt(x) : Math_Sqrt_d(x))`.
- C# `bool` is `true` / `false`; Ruby treats 0 as true, so the translator never lets an integer stand for a condition.

## Values, references, lambdas

- `ref T` and `out T` are Ref objects with `v`: a local or parameter whose address is taken lives in a `Cpp::Cell`
  (read `x.v`); an array element is `ArrRef(a, i)`; a field is a field-reference class written per field (`FR_`, `SR_`).
- Generics are erased; element makers (`MK_D`, `MK_I`, `K_MKn` lambdas) are passed as in the Python port.
- C# structs are copied with `Clone` / `MoveFrom` at assignment, as in the Python port.
- A lambda is `->(args) do ... end` (in a lambda, `return` returns from the lambda, as in C#). C# gives each loop
  iteration a fresh copy of a variable declared in the loop body; a lambda that captures one is made by a factory
  called with the current values (`->(x) { ->(..) do .. end }.(x)`; 103 sites).
- `for (int i = a; i < n; i++)` with a bound the loop cannot change is a `while` loop over a counter that is not wrapped
  (2,130 loops; 245 with a field bound proved unchanged); other `for` loops keep their condition and step.
- `switch` on literals is `case`/`when`; other switches are `if`/`elsif`. The seven `goto`s (four methods of
  UebReference) make their methods dispatch loops over segments (`_st1 = k` and `next`); a goto from inside a loop
  would raise `Cpp::GotoSignal.new(k)` for the dispatch loop to rescue, but none of the seven is in one.
- Exceptions derive from `Cpp::CppException < StandardError`; C#'s `catch (Exception)` is `rescue StandardError`, and
  a .NET exception the C# throws itself is `Cpp::SysException` (kind, message). Each caught exception is passed to
  `Dbg_Caught`, which prints it when `SWMM6_CS_TRACE` is set.
- An assignment used as a value, and arguments whose evaluation order Ruby would change, are hoisted into
  temporaries (32 and 65 sites).

## Checks

`ruby -c ruby/gen/engine.rb` (Syntax OK); `ruby -wc` reports only unreachable `nil`s after a `return` in lambdas and
unused variables. Then the gate (`ruby/README.md`).

Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.
