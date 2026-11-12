The C# runtime's Conv.D2UL, and so every port's, turns a NaN into 0; the C++ reference's (unsigned long) cast turns it into 2^63.

Found by the Hy port's check of the exact operations (`hy/test/mkexact6.c`, which casts in C what the runtime casts
by hand): 7,764 of a million cases differ, every one a NaN argument.

```
  d2ul(nan[7ff8000000000000]) = 8000000000000000  hy: 0 [0000000000000000]
```

`cs/runtime/Misc.cs`, which the other runtimes copy:

```csharp
        public static ulong D2UL(double x)
        {
            if (x < 9223372036854775808.0) return unchecked((ulong)D2L(x));
            return unchecked((ulong)D2L(x - 9223372036854775808.0) ^ 0x8000000000000000UL);
        }
```

A NaN fails `x < 2^63`, takes the second branch, and `D2L(NaN)` is long.MinValue, whose top bit the xor clears: 0.
GCC compiles the cast the other way round, and the reference library (`libopenswmm.engine.so.6`) has the pattern 30
times:

```
  vcomisd %xmm?,%xmm0 ; jae big      (a NaN is unordered: CF is set, so the jump is not taken)
  vcvttsd2si %xmm0,%rax              (x86's invalid result for a NaN: 0x8000000000000000)
  ...
big:
  vsubsd ...; vcvttsd2si ...; btc $0x3f,%rax
```

The engine casts a double to `size_t` in four places, each an index: the hourly meteorology record (`offset` is
checked finite first), the RDII grid row (`elapsed_sec` is the simulation clock), and two pattern factors
(`fmod(step, count)` of a step count). A NaN reaching one would be a defect of its own, and the two values even land
in the same place for an 8-byte element (index 2^63 times 8 wraps to 0 in C++'s address arithmetic), unless a
bounds test sees 2^63 first, as the RDII row test would. Nothing was changed: the Hy runtime keeps the C# definition,
and the check's report names the difference (`hy/results/libm_tests.txt`).

The rule: a hand-written conversion is a claim about the compiler's code. Check it against the compiler (cast in C
with the same flags) on NaN and both out-of-range sides, not against the runtime it was copied from.
