A Ruby helper defined twice in the same module is replaced without a word, and the Ruby engine could not create itself: the second `Cpp.cb` returned a String where the first returned an Array.

The Ruby runtime (`ruby/cpp`) is one module, `Cpp`, opened again in each of its files. `core_str.rb` defined a helper
that gives the bytes of a C string as an Array of Integers, and `crt.rb`, written later, defined a helper of the same
name that gives them as a binary String:

```ruby
# ruby/cpp/core_str.rb
  def self.cb(p) = Cpp.cstr_bytes(p)            # [72, 101, ...]

# ruby/cpp/crt.rb (loaded after core_str.rb)
  def self.cb(p)                                # "He..." (binary String)
    b = p.B
    ...
    b[o, e - o].pack('C*')
  end
```

Ruby gives no warning when a method is redefined in a file loaded with `require` (only `ruby -w` reports it), so the
later definition won: every caller in `core_str.rb` received a String and `Array#+` failed in the first string
concatenation the engine makes. The engine catches every exception in its constructor and returns a null engine, so
the run said only

```
Error: failed to create engine instance.
```

and `SWMM6_CS_TRACE=1` (the runtime's trace of caught exceptions, `Dbg_Caught`) showed the cause:

```
[caught] TypeError: no implicit conversion of String into Array
  /home/claude/swmm6-ports/ruby/cpp/core_str.rb:573:in `+'
  /home/claude/swmm6-ports/ruby/cpp/core_str.rb:573:in `Str_Cat_Str_CPtr'
```

The fix gave the String form its own name (`Cpp.cbs`). A check of the whole runtime for any other repeated
definition (`grep -ho '^  def self\.[A-Za-z_0-9?!]*' ruby/cpp/*.rb | sort | uniq -d`) found two more: `Cpp.deq`
(both definitions agree on every argument the first handles) and `Cpp.out_of_range` (the stream one renamed
`aoor_exc`). When a runtime is one namespace spread over files, list its definitions for repeats before the first run;
an exception the engine swallows hides the failure, so trace caught exceptions in development.
