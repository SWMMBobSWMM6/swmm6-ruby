# encoding: binary
# frozen_string_literal: true
# crtmath.rb - C#'s System.Math as the generated engine calls it (Math_<Name>_d) and the libm functions of
# cs/runtime/Misc.cs's Cpp.LibM (LibM_<name>); the Ruby form of py/cpp/crtmath.py.
#
# The C++ engine calls glibc's libm, and MRI's Math module calls the same glibc functions at the same symbol
# versions (libruby.so binds exp, log, log2 and pow at GLIBC_2.29, hypot at 2.35, fmod at 2.38, the rest at 2.2.5,
# as libopenswmm.engine.so does), so on the common path the result is glibc's bit for bit. Where MRI's own code
# decides the result instead, the function goes to glibc itself through Fiddle (dlsym gives the default version,
# the one the C++ engine linked):
#   - Math.acos / asin / log / log10 / log2 raise Math::DomainError outside the domain (glibc returns a NaN);
#   - Float#** returns a Complex for a negative base and a non-integral exponent (glibc returns a NaN);
#   - Math.cbrt adds a Newton step after glibc's cbrt on glibc systems (it differs from cbrt on more than half of
#     all arguments), so cbrt is always Fiddle;
#   - Math.sqrt(-0.0) is +0.0 and raises for a negative argument; the engine's sqrt is inlined for x > 0 and comes
#     here only for zero, a negative or a NaN argument;
#   - Math.atan2 answers a zero pair itself (the same values as glibc's, checked);
#   - expm1, log1p, remainder and nextafter are not in the Math module.
# floor / ceiling / truncate / round are exact operations computed here, keeping -0.0, and a NaN quieted as roundsd
# and glibc quiet it (x + 0.0 for every argument of 2^52 or more in magnitude, an infinity or a NaN).
# tests/rb (run_rb_checks.sh) compares every function with the system libm, tools/libm/test's way.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.

require 'fiddle'

module Cpp
  LIBM = Fiddle.dlopen('libm.so.6')
  TD = Fiddle::TYPE_DOUBLE

  def self.c1(name) = Fiddle::Function.new(LIBM[name], [TD], TD)
  def self.c2(name) = Fiddle::Function.new(LIBM[name], [TD, TD], TD)

  C_ACOS = c1('acos')
  C_ASIN = c1('asin')
  C_LOG = c1('log')
  C_LOG10 = c1('log10')
  C_LOG2 = c1('log2')
  C_POW = c2('pow')
  C_CBRT = c1('cbrt')
  C_EXPM1 = c1('expm1')
  C_LOG1P = c1('log1p')
  C_REMAINDER = c2('remainder')
  C_NEXTAFTER = c2('nextafter')
  C_HYPOT = c2('hypot')
  C_FMOD = c2('fmod')
  C_ATAN2 = c2('atan2')
  TWO52 = 4503599627370496.0
  LONG_MIN = -9223372036854775808

  # ------------------------------------------------------------------------------------------------ System.Math
  def Math_Acos_d(x) = x >= -1.0 && x <= 1.0 ? Math.acos(x) : C_ACOS.call(x)
  def Math_Asin_d(x) = x >= -1.0 && x <= 1.0 ? Math.asin(x) : C_ASIN.call(x)
  def Math_Atan_d(x) = Math.atan(x)
  def Math_Atan2_d(y, x) = Math.atan2(y, x)
  def Math_Cbrt_d(x) = C_CBRT.call(x)
  def Math_Cos_d(x) = Math.cos(x)
  def Math_Cosh_d(x) = Math.cosh(x)
  def Math_Exp_d(x) = Math.exp(x)
  def Math_Log_d(x) = x > 0.0 ? Math.log(x) : C_LOG.call(x)
  def Math_Log10_d(x) = x > 0.0 ? Math.log10(x) : C_LOG10.call(x)
  def Math_Log2_d(x) = x > 0.0 ? Math.log2(x) : C_LOG2.call(x)
  def Math_Pow_d(x, y) = x < 0.0 ? C_POW.call(x, y) : x**y
  def Math_Sin_d(x) = Math.sin(x)
  def Math_Sinh_d(x) = Math.sinh(x)
  def Math_Tan_d(x) = Math.tan(x)
  def Math_Tanh_d(x) = Math.tanh(x)

  # sqrt for an argument that is not > 0: a zero itself (its sign kept), x86's default NaN for a negative one, a NaN
  # itself, quieted (x + 0.0 is sqrtsd's NaN: the payload kept, a signaling NaN made quiet)
  def Math_Sqrt_d(x)
    return Math.sqrt(x) if x > 0.0
    return x if x == 0.0
    return x + 0.0 if x != x
    DNAN
  end

  def Math_CopySign_d(x, y) = Cpp.signbit(x) == Cpp.signbit(y) ? x : -x

  def Math_Floor_d(x)
    return x + 0.0 unless x > -TWO52 && x < TWO52
    r = x.floor.to_f
    r == 0.0 ? x * 0.0 : r          # floor(-0.0) is -0.0; floor(0.5) is +0.0 (x * 0.0 keeps x's sign)
  end

  def Math_Ceiling_d(x)
    return x + 0.0 unless x > -TWO52 && x < TWO52
    r = x.ceil.to_f
    r == 0.0 ? (Cpp.signbit(x) ? -0.0 : 0.0) : r
  end

  def Math_Truncate_d(x)
    return x + 0.0 unless x > -TWO52 && x < TWO52
    r = x.truncate.to_f
    r == 0.0 ? (Cpp.signbit(x) ? -0.0 : 0.0) : r
  end

  def Math_Abs_d(x) = x.abs

  # System.Math.Max (.NET Core 3.0+): NaN if either is NaN; +0.0 over -0.0
  def Math_Max_d_d(a, b)
    return a if a != a
    return b if b != b
    return Cpp.signbit(a) ? b : a if a == b
    a > b ? a : b
  end

  def Math_Min_d_d(a, b)
    return a if a != a
    return b if b != b
    return Cpp.signbit(a) ? a : b if a == b
    a < b ? a : b
  end

  # System.Math.Round(double): to the nearest integer, ties to even (the sign of a zero kept)
  def Math_Round_d(x)
    return x + 0.0 unless x > -TWO52 && x < TWO52
    r = x.round(half: :even).to_f
    r == 0.0 ? (Cpp.signbit(x) ? -0.0 : 0.0) : r
  end

  # ------------------------------------------------------------------------------------------------ Cpp.LibM
  def LibM_nextafter(x, y) = C_NEXTAFTER.call(x, y)
  def LibM_hypot(x, y) = Math.hypot(x, y)
  def LibM_fmod(x, y) = C_FMOD.call(x, y)

  # C round: to the nearest integer, halfway cases away from zero (round(-0.4) is -0.0)
  def LibM_round(x)
    return x + 0.0 unless x > -TWO52 && x < TWO52
    t = x.truncate.to_f
    d = x - t                       # exact below 2^52
    if d >= 0.5 then t += 1.0
    elsif d <= -0.5 then t -= 1.0
    end
    t == 0.0 ? (Cpp.signbit(x) ? -0.0 : 0.0) : t
  end

  # C lround: round's value as a long (LONG_MIN, x86's invalid result, for NaN or out of range)
  def LibM_lround(x)
    r = LibM_round(x)
    return LONG_MIN if r != r || r >= 9223372036854775808.0 || r < -9223372036854775808.0
    r.to_i
  end

  def LibM_expm1(x) = C_EXPM1.call(x)
  def LibM_log1p(x) = C_LOG1P.call(x)
  def LibM_remainder(x, y) = C_REMAINDER.call(x, y)
  def LibM_log(x) = Math_Log_d(x)
end
