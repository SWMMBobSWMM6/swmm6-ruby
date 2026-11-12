In Ruby, `i & 0xFFFFFFFFFFFFFFFF` is a call into the Bignum code, not a VM instruction; the C#-to-Ruby translator wrote it at every conversion of a signed index to `ulong`, 2,437 array accesses among them, and a cheaper exact form made the engine about 15% faster.

C# indexes the engine's vectors with `ulong`, so an `int` index `i` reaches `v.a[(ulong)i]`. The translator wrote
the conversion as a mask, which is exact for every `long`:

```ruby
r = @subtype_row.a[i & 0xFFFFFFFFFFFFFFFF]
```

YARV has an instruction for `&` of two Fixnums, but `0xFFFFFFFFFFFFFFFF` is above the Fixnum range (2^62 - 1), so the
mask is a Bignum and every `&` with it is a method call that builds and normalises a Bignum. A micro-benchmark of the
two forms over ten million accesses:

```
       user     system      total        real
mask  1.182180   0.000031   1.182211 (  1.192800)
plain  0.336491   0.000006   0.336497 (  0.344390)
```

The translator (`tools/cs2x/RbFn.cs`, `ToU64`) now writes `(ulong)x` of a signed value as a comparison and a branch
on Fixnums, which gives the same value for every argument (x itself when it is not negative, x + 2^64 when it is), with
a temporary when x is not a plain name:

```ruby
r = @subtype_row.a[(i < 0 ? i + 0x10000000000000000 : i)]
```

On a 25-subcatchment deck the run went from 23.4 s to 19.8 s, both byte-identical to the reference. The other masks
the translator writes (the wrap of `long` and `ulong` arithmetic, `x + 0x8000000000000000 & 0xFFFFFFFFFFFFFFFF`) are
Bignum operations too; they are rarer on the hot paths and were left as they are. In a language whose integers are
unbounded, a constant beyond the machine-word fast path costs a call wherever it appears.
