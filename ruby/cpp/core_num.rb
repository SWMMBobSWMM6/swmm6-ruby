# encoding: binary
# frozen_string_literal: true
# core_num.rb - the value layer of the Ruby runtime (module Cpp): IEEE and integer helpers with C#'s results (f32,
# fdiv0, idiv, fmod, the x86-64 cvttsd2si conversions of cs/runtime/Misc.cs Conv and CRuntime.cs R.D2I/D2L), bit
# casts, the typed boxes for params object[] arguments, the Ref protocol (Cell, ArrRef and friends), the runtime
# interfaces engine classes include (ICopy, IDisposable, IDestroyElems), how containers copy, compare and order
# their elements (C#'s Elem<T>.Copy, ArrCopy.Deep, EqualityComparer<T>.Default, Comparer<T>.Default), the element
# makers MK_I, MK_D, MK_Z, MK_N, and C#'s ToString of a value.
# A port of the Python runtime's py/cpp/core_num.py (the contract is py/RUNTIME_HELPERS.md, with the Ruby
# spellings of tools/cs2x/RB.md); the C# runtime (cs/runtime) is the specification.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md and ruby/README.md.

module Cpp
  INF = Float::INFINITY

  # ------------------------------------------------------------------------------------------------- IEEE
  # Bits through pack/unpack: 'E' and 'Q<' copy the eight bytes of a double as they are (a NaN keeps its sign and
  # payload; MRI changes NaNs only when it converts a double to a single, in pack('e'/'f')).

  def f64_from_bits(b)
    # BitConverter.Int64BitsToDouble: the double with these 64 bits (signed or unsigned pattern)
    [b & 0xFFFFFFFFFFFFFFFF].pack('Q<').unpack1('E')
  end

  def f64_to_bits(x)
    # the 64 bits of a double as an unsigned integer
    [x].pack('E').unpack1('Q<')
  end

  def f64_to_bits_signed(x)
    # BitConverter.DoubleToInt64Bits
    [x].pack('E').unpack1('q<')
  end

  def signbit(x)
    # double.IsNegative: the sign bit (true for -0.0 and for a NaN with the sign set)
    [x.to_f].pack('E').getbyte(7) > 127
  end

  def self.signbit(x) = [x.to_f].pack('E').getbyte(7) > 127
  def self.bits(x) = [x].pack('E').unpack1('Q<')
  def self.from_bits(b) = [b & 0xFFFFFFFFFFFFFFFF].pack('Q<').unpack1('E')

  DNAN = [0xFFF8000000000000].pack('Q<').unpack1('E')    # x86's default NaN (0/0, inf-inf, sqrt(-1)); glibc prints it "-nan"
  QNAN = [0x7FF8000000000000].pack('Q<').unpack1('E')    # C++'s quiet_NaN() (Cpp.Std.QNaN)

  FLT_MAX = 3.4028234663852886e38

  # A double rounded once to the nearest single, ties to even, as cvtsd2ss does (MRI's pack('e') sends every value
  # above FLT_MAX to infinity and turns every NaN into +NaN, VALUE_to_float in pack.c, so neither is used for those):
  # the 32-bit pattern, then widened back exactly.
  def self.f32_double(x)
    if x != x
      b = [x].pack('E').unpack1('Q<')
      s = (b >> 32) & 0x80000000
      return [s | 0x7FC00000 | ((b >> 29) & 0x3FFFFF)].pack('L<').unpack1('e')
    end
    a = x.abs
    if a > FLT_MAX
      # the halfway point between FLT_MAX and 2^128 rounds to even, that is to 2^128: infinity
      return x if a == INF
      return a >= 3.4028235677973366e38 ? (x < 0 ? -INF : INF) : (x < 0 ? -FLT_MAX : FLT_MAX)
    end
    [x].pack('e').unpack1('e')
  end

  # An Integer rounded once to the nearest single (ties to even) from its exact value: no double rounding
  def self.f32_int(x)
    m = x < 0 ? -x : x
    e = m.bit_length - 24
    if e > 0
      q = m >> e
      r = m - (q << e)
      half = 1 << (e - 1)
      q += 1 if r > half || (r == half && q.odd?)
      m = q << e
      return x < 0 ? -INF : INF if m.bit_length > 128
    end
    f32_double((x < 0 ? -m : m).to_f)
  end

  def f32(x)
    # C#'s float: x (a Float or an Integer) rounded once to the nearest IEEE single, ties to even; overflow gives
    # +-inf, a NaN stays a NaN (quieted, its payload truncated, as x86's cvtsd2ss does)
    if x.is_a?(Float)
      return [x].pack('e').unpack1('e') if x.abs <= FLT_MAX
      return Cpp.f32_double(x)
    end
    return [x.to_f].pack('e').unpack1('e') if x > -9007199254740992 && x < 9007199254740992
    Cpp.f32_int(x)
  end

  def fdiv0(a, b)
    # a / b for b == 0 (+0.0, -0.0 or Integer 0): x86 SSE's result as C# computes it. A NaN dividend comes back
    # quieted; 0/0 is the default NaN; otherwise infinity with the sign of a times the sign of b
    if a != a
      return [[a].pack('E').unpack1('Q<') | 0x0008000000000000].pack('Q<').unpack1('E')
    end
    return DNAN if a == 0
    (a < 0) != Cpp.signbit(b.to_f) ? -INF : INF
  end

  # ------------------------------------------------------------------------------------------------- integers

  def idiv(a, b)
    # C# signed integer /: truncates toward zero; ZeroDivisionError when b is 0 (C#'s DivideByZeroException)
    q = a / b
    q < 0 && q * b != a ? q + 1 : q
  end

  def irem(a, b)
    # C# signed integer %: the remainder with the sign of the dividend
    a.remainder(b)
  end

  def self.i32(x) = ((x + 0x80000000) & 0xFFFFFFFF) - 0x80000000
  def self.i64(x) = ((x + 0x8000000000000000) & 0xFFFFFFFFFFFFFFFF) - 0x8000000000000000

  # ---- double -> integer, as .NET 8 on x86-64 computes unchecked casts (cvttsd2si: NaN and out of range give the
  # "integer indefinite" value, the most negative integer). They accept Integers too.

  def f2i32(x)
    x > -2147483649.0 && x < 2147483648.0 ? x.to_i : -2147483648
  end

  def f2i64(x)
    x >= -9223372036854775808.0 && x < 9223372036854775808.0 ? x.to_i : -9223372036854775808
  end

  def f2u32(x) = f2i64(x) & 0xFFFFFFFF

  def f2u64(x)
    return f2i64(x) & 0xFFFFFFFFFFFFFFFF if x < 9223372036854775808.0
    (f2i64(x - 9223372036854775808.0) & 0xFFFFFFFFFFFFFFFF) ^ 0x8000000000000000
  end

  def f2i16(x) = ((f2i32(x) + 0x8000) & 0xFFFF) - 0x8000
  def f2u16(x) = f2i32(x) & 0xFFFF
  def f2i8(x) = ((f2i32(x) + 0x80) & 0xFF) - 0x80
  def f2u8(x) = f2i32(x) & 0xFF

  # Cpp.Conv (cs/runtime/Misc.cs): GCC's double -> integer conversions on x86-64.
  def Conv_D2I(x)
    x > -2147483649.0 && x < 2147483648.0 ? x.to_i : -2147483648
  end

  def Conv_D2L(x)
    x >= -9223372036854775808.0 && x < 9223372036854775808.0 ? x.to_i : -9223372036854775808
  end

  def Conv_D2U(x)
    x >= -9223372036854775808.0 && x < 9223372036854775808.0 ? x.to_i & 0xFFFFFFFF : 0
  end

  def Conv_D2UL(x)
    if x < 9223372036854775808.0
      return x.to_i & 0xFFFFFFFFFFFFFFFF if x >= -9223372036854775808.0
      return 0x8000000000000000
    end
    (Conv_D2L(x - 9223372036854775808.0) & 0xFFFFFFFFFFFFFFFF) ^ 0x8000000000000000
  end

  def Conv_D2S(x) = ((Conv_D2I(x) + 0x8000) & 0xFFFF) - 0x8000
  def Conv_D2US(x) = Conv_D2I(x) & 0xFFFF
  def Conv_D2SB(x) = ((Conv_D2I(x) + 0x80) & 0xFF) - 0x80
  def Conv_D2B(x) = Conv_D2I(x) & 0xFF

  # Cpp.R.D2I / D2L (cs/runtime/CRuntime.cs)
  def R_D2I(x)
    x != x || x >= 2147483648.0 || x <= -2147483649.0 ? -2147483648 : x.to_i
  end

  def R_D2L(x)
    x != x || x >= 9223372036854775808.0 || x < -9223372036854775808.0 ? -9223372036854775808 : x.to_i
  end

  # ------------------------------------------------------------------------------------------------- typed boxes
  # A params object[] argument whose C# type is not int, double, bool or a reference arrives wrapped (Integers have
  # no width): the formatter treats each as the C# runtime treats that .NET type. .v is the value.
  class TBox
    attr_reader :v

    def initialize(v)
      @v = v
    end

    def inspect = "#{self.class.name.split('::').last}(#{@v.inspect})"
  end

  class I64 < TBox; end
  class U32 < TBox; end
  class U64 < TBox; end
  class I16 < TBox; end
  class U16 < TBox; end
  class I8 < TBox; end
  class U8 < TBox; end
  class Ch < TBox; end
  class F32 < TBox; end

  def I64(v) = I64.new(v)
  def U32(v) = U32.new(v)
  def U64(v) = U64.new(v)
  def I16(v) = I16.new(v)
  def U16(v) = U16.new(v)
  def I8(v) = I8.new(v)
  def U8(v) = U8.new(v)
  def Ch(v) = Ch.new(v)
  def F32(v) = F32.new(v)

  # ------------------------------------------------------------------------------------------------- references
  # A Ref is any object with v and v= (the engine's own field references FR_<Class>_<field> are classes the
  # engine file defines); these are the runtime's.
  class Ref; end

  # A variable whose address is taken: one slot v.
  class Cell < Ref
    attr_accessor :v

    def initialize(v = nil)
      @v = v
    end

    def inspect = "Cell(#{@v.inspect})"
  end

  # A reference to element i of an Array: C#'s ref a[i]. For a Vec element it is made on the backing Array.
  class ArrRef < Ref
    attr_reader :l, :i

    def initialize(l, i)
      @l = l
      @i = i
    end

    def v = @l[@i]

    def v=(x)
      @l[@i] = x
    end
  end

  # A reference to an attribute of an object (a field reference made at run time).
  class AttrRef < Ref
    def initialize(o, name)
      @o = o
      @g = name.to_sym
      @s = :"#{name}="
    end

    def v = @o.__send__(@g)

    def v=(x)
      @o.__send__(@s, x)
    end
  end

  # A reference made of a getter (no arguments) and a setter (one argument).
  class FnRef < Ref
    def initialize(g, s)
      @g = g
      @s = s
    end

    def v = @g.call

    def v=(x)
      @s.call(x)
    end
  end

  # C#'s CPtr element as a reference (typed as the indexer, int): reads sign-extend the byte (x86 C's char), writes
  # store the low 8 bits.
  class ByteRef < Ref
    def initialize(b, k)
      @b = b
      @k = k
    end

    def v
      x = @b[@k]
      x > 127 ? x - 256 : x
    end

    def v=(x)
      @b[@k] = x & 0xFF
    end
  end

  # ------------------------------------------------------------------------------------------------- interfaces
  # Engine classes include the runtime interfaces they implement; the runtime's own classes do too, so is_a? decides
  # what C# decides from the static type (Elem<T>.IsClass, Dtor.Run's cases).
  module ICopy; end            # Cpp.ICopy<T>: Clone() is the copy constructor, Assign(o) the copy assignment
  module IDisposable; end      # System.IDisposable: Dispose()
  module IDestroyElems; end    # Cpp.IDestroyElems: DestroyElems() runs the destructors of a container's elements

  # ------------------------------------------------------------------------------------------------- elements

  # Cpp.ArrCopy.Deep: a C array copied with its object: every row and element (an ICopy cloned, an Array copied
  # deeply, anything else shared).
  def self.deep(x)
    x.map { |e| e.is_a?(ICopy) ? e.Clone() : (e.instance_of?(Array) ? Cpp.deep(e) : e) }
  end

  def Elem_Deep(x) = Cpp.deep(x)

  # Cpp.Elem<T>.Copy: C++ copy construction of an element.
  def self.copy(x)
    return x.Clone() if x.is_a?(ICopy)
    return Cpp.deep(x) if x.instance_of?(Array)
    x
  end

  def Elem_Copy(x) = Cpp.copy(x)

  def self.copies(src)
    src.map { |x| x.is_a?(ICopy) ? x.Clone() : (x.instance_of?(Array) ? Cpp.deep(x) : x) }
  end

  def Elem_NeedsCopy(x) = x.is_a?(ICopy) || x.instance_of?(Array)

  # double.Equals: == except that NaN equals NaN
  def self.deq(a, b) = a == b || (a != a && b != b)

  # EqualityComparer<T>.Default.Equals: numbers by value (a double NaN equals NaN), strings and Str by content,
  # runtime structs by their Equals, an object with an Equals method by it, other objects by identity.
  def self.elem_eq(a, b)
    return true if a.equal?(b)
    return false if a.nil? || b.nil?
    case a
    when Float then a == b || (a != a && b != b)
    when Integer, true, false, String then a == b
    else
      a.respond_to?(:Equals) ? a.Equals(b) : false
    end
  end

  def Elem_Eq(a, b) = Cpp.elem_eq(a, b)

  # Comparer<T>.Default.Compare(a, b) as -1, 0 or 1: null before non-null, double by double.CompareTo (NaN before
  # every number, NaN equal to NaN), false before true, numbers and strings by value, Str by char_traits, an object
  # with a CompareTo method by it.
  def self.elem_compare(a, b)
    return b.nil? ? 0 : -1 if a.nil?
    return 1 if b.nil?
    case a
    when Float
      return -1 if a < b
      return 1 if a > b
      return 0 if a == b
      return b != b ? 0 : -1 if a != a
      1
    when Integer, String
      a < b ? -1 : (a > b ? 1 : 0)
    when true, false
      a == b ? 0 : (a ? 1 : -1)
    else
      raise TypeError, "Cpp.elem_compare: no ordering for #{a.class}" unless a.respond_to?(:CompareTo)
      c = a.CompareTo(b)
      c < 0 ? -1 : (c > 0 ? 1 : 0)
    end
  end

  def Elem_Compare(a, b) = Cpp.elem_compare(a, b)

  # std::less as the C# runtime's Less<T>.Fn computes it
  def self.elem_less(a, b)
    case a
    when Float then a < b || (a != a && b == b)
    when Integer then a < b
    when true, false then !a && b
    else Cpp.elem_compare(a, b) < 0
    end
  end

  def Elem_Less(a, b) = Cpp.elem_less(a, b)

  # ---- element makers: objects whose call returns a new default element
  MK_I = -> { 0 }
  MK_D = -> { 0.0 }
  MK_Z = -> { false }
  MK_N = -> { nil }

  # Makers whose result is immutable, so a container may fill with Array.new(n, mk.call). The struct makers
  # (MK_CPtr, MK_PtrD, ...) are added by the files that define them.
  IMMUTABLE_MAKERS = {}.compare_by_identity
  [MK_I, MK_D, MK_Z, MK_N].each { |m| IMMUTABLE_MAKERS[m] = true }

  def self.made(mk, n)
    return Array.new(n) if mk.nil?
    return Array.new(n, mk.call) if IMMUTABLE_MAKERS[mk]
    Array.new(n) { mk.call }
  end

  # ------------------------------------------------------------------------------------------------- C# text

  NET_INF = 'Infinity'   # NumberFormatInfo.InvariantInfo.PositiveInfinitySymbol of .NET 8

  # .NET Core's double.ToString(): the shortest round-trip digits in the "G" layout, scientific when the decimal
  # exponent is 17 or more or below -4, "-0" for -0.0, "NaN" for every NaN.
  def self.net_double(x)
    return 'NaN' if x != x
    return NET_INF if x == INF
    return '-' + NET_INF if x == -INF
    return Cpp.signbit(x) ? '-0' : '0' if x == 0.0
    r = x.to_s                        # Ruby's shortest round-trip digits: "1.5", "1.0e+20", "1.0e-05"
    neg = r.start_with?('-')
    r = r[1..] if neg
    mant, ex = r.split('e')
    ip, fp = mant.split('.')
    fp = '' if fp.nil? || fp == '0'
    digs = ip + fp
    scale = (ex ? ex.to_i : 0) + ip.length
    k = digs.length - digs.sub(/\A0+/, '').length
    digs = digs[k..].sub(/0+\z/, '')
    scale -= k
    t = if scale > 17 || scale < -3
          e = scale - 1
          digs[0] + (digs.length > 1 ? '.' + digs[1..] : '') + (e >= 0 ? 'E+' : 'E-') + format('%02d', e.abs)
        elsif scale <= 0
          '0.' + '0' * -scale + digs
        elsif scale >= digs.length
          digs + '0' * (scale - digs.length)
        else
          digs[0, scale] + '.' + digs[scale..]
        end
    neg ? '-' + t : t
  end

  # C#'s ToString() / string concatenation of a value: an Integer in decimal, True/False, a String itself, nil as
  # '', a double as .NET Core writes it, another object by its ToString().
  def cs_tostring(v)
    case v
    when String then v
    when true then 'True'
    when false then 'False'
    when Integer then v.to_s
    when Float then Cpp.net_double(v)
    when nil then ''
    else v.ToString()
    end
  end

  # C#'s char as a one-character string: a byte (Latin-1) below 256, '?' above (as .NET's Latin1 encoding writes it)
  def cs_chr(v) = v < 256 ? v.chr : '?'

  def cs_equals(a, b) = Cpp.elem_eq(a, b)

  # ------------------------------------------------------------------------------------------------- control flow

  # Raised for a goto that leaves a loop inside a dispatch loop (k: the label); the engine has none.
  class GotoSignal < StandardError
    attr_reader :k

    def initialize(k)
      super(k.to_s)
      @k = k
    end
  end
end
