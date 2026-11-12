# encoding: binary
# frozen_string_literal: true
# crt.rb - the C library layer of cs/runtime/CRuntime.cs and Stash.cs (C# class Cpp.R except CPtr): NUL-terminated
# byte strings, strtod / strtol / atoi, sscanf, the printf family (glibc-exact), stdio files (Cpp.CFile and the
# registry FlushAll flushes), stdout, time / ctime, the char-array helpers Lit / LitN / Buf / Bufs / BufOf / CopyBuf,
# and the sscanf targets RefI / RefL / RefD / RefF and Slot / Back. A port of py/cpp/crt.py, with the exact decimal
# conversions of the SWMM5 Ruby port (swmm5-ports/ruby/swmm5/crt.rb, lessons 26 and 27 there): MRI's Kernel#format
# is not correctly rounded for %f %e %g, and String#to_f is not glibc's strtod, so neither is used for a double.
# Where the C# runtime departs from glibc in a case the gate does not exercise, this follows glibc, as the Python,
# Go and Java runtimes do (printf takes integer arguments at the size their length modifier says; sscanf has %n,
# scan sets and glibc's float scanner; strtod reads NaN payloads and hexadecimal floats exactly).
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.

module Cpp
  SPACE_B = [32, 9, 10, 11, 12, 13].freeze
  PNAN = [0x7FF8000000000000].pack('Q<').unpack1('E')    # glibc's strtod("nan")
  DBL_MIN = 2.2250738585072014e-308

  # ------------------------------------------------------------------------------------------------- byte strings

  # The bytes of the C string at p (to its NUL; to the buffer's end when it has none) as a binary String
  def self.cbs(p)
    b = p.B
    o = p.O
    e = o
    n = b.length
    e += 1 while e < n && (b[e] & 255) != 0
    b[o, e - o].pack('C*')
  end

  # store the bytes of the binary String data at p + off (values 0..255)
  def self.put(p, off, data)
    p.B[p.O + off, data.bytesize] = data.bytes
  end

  LITS = {}

  def self.lit_bytes(s)
    b = LITS[s]
    if b.nil?
      b = s.bytes
      b << 0
      b.freeze
      LITS[s] = b if LITS.size < 200_000
    end
    b
  end

  # a string literal as a fresh NUL-terminated byte array
  def R_Lit(s) = CPtr.new(Cpp.lit_bytes(s).dup, 0)

  # char a[n] = "literal": n bytes (at least the literal and its NUL), the literal's first, the rest zero
  def R_LitN(s, n)
    b = Cpp.lit_bytes(s)
    m = b.length
    buf = b.dup
    buf.fill(0, m, n - m) if n > m
    CPtr.new(buf, 0)
  end

  # char a[n]: n zero bytes (at least one)
  def R_Buf_i(n) = CPtr.new(Array.new(n > 1 ? n : 1, 0), 0)
  alias R_Buf_l R_Buf_i
  alias R_Buf_ul R_Buf_i

  def R_BufFrom(lit, n)
    p = R_Buf_i(n)
    s = Cpp.cbs(lit).byteslice(0, n)
    p.B[0, s.bytesize] = s.bytes
    p
  end

  # char a[n][m]: n zeroed rows of m bytes
  def R_Bufs(n, m) = Array.new(n) { R_Buf_i(m) }
  alias R_NewBufs R_Bufs

  # char buf[n] = { ... }: n bytes (at least one), the given ones first, the rest zero
  def R_BufOf(n, vals)
    b = Array.new(n > 1 ? n : 1, 0)
    k = [vals.length, b.length].min
    (0...k).each { |i| b[i] = vals[i] & 255 }
    CPtr.new(b, 0)
  end

  # the copy of a char array member: the whole buffer, the same offset (a null pointer stays null)
  def R_CopyBuf(p) = p.B.nil? ? p : CPtr.new(p.B.dup, p.O)

  def R_Str(p) = Cpp.cbs(p)
  def R_Bytes(p) = Cpp.cbs(p)

  def R_strlen(p)
    b = p.B
    i = p.O
    while (c = b[i]) & 255 != 0
      i += 1
    end
    i - p.O
  rescue NoMethodError
    raise IndexError, 'strlen: no terminating NUL in the buffer'
  end

  def R_strcpy(d, s)
    Cpp.put(d, 0, Cpp.cbs(s) + "\0")          # a copy first: an overlapping copy behaves as memmove
    d
  end

  def R_strcat(d, s)
    Cpp.put(d, R_strlen(d), Cpp.cbs(s) + "\0")
    d
  end

  # strcmp: the difference of the first unsigned bytes that differ (0 when equal)
  def R_strcmp(a, b)
    x = Cpp.cbs(a)
    y = Cpp.cbs(b)
    return 0 if x == y
    n = [x.bytesize, y.bytesize].min
    (0...n).each do |i|
      d = x.getbyte(i) - y.getbyte(i)
      return d if d != 0
    end
    (x.getbyte(n) || 0) - (y.getbyte(n) || 0)
  end

  # the first c in the C string s (c == 0: its terminator), or a null pointer
  def R_strchr(s, c)
    ch = c & 255
    b = s.B
    i = s.O
    loop do
      x = b[i] & 255
      return CPtr.new(b, i) if x == ch
      return CPtr_ZERO if x == 0
      i += 1
    end
  end

  def R_strrchr(s, c)
    ch = c & 255
    b = s.B
    r = nil
    i = s.O
    loop do
      x = b[i] & 255
      r = i if x == ch
      return r.nil? ? CPtr_ZERO : CPtr.new(b, r) if x == 0
      i += 1
    end
  end

  def R_strstr(h, n)
    nb = Cpp.cbs(n)
    return h if nb.empty?
    i = Cpp.cbs(h).index(nb)
    i.nil? ? CPtr_ZERO : CPtr.new(h.B, h.O + i)
  end

  def R_strcspn(s, reject)
    sb = Cpp.cbs(s)
    rb = Cpp.cbs(reject)
    sb.each_byte.with_index { |c, i| return i if rb.include?(c.chr) }
    sb.bytesize
  end

  TOK = [nil]    # strtok's saved position: [buffer, index] or nil

  # strtok: the next token of s (s null: of the string the last call was given), the delimiter after it set to NUL
  def R_strtok(s, delim)
    TOK[0] = [s.B, s.O] unless s.B.nil?
    st = TOK[0]
    return CPtr_ZERO if st.nil?
    b, p = st
    ds = Cpp.cbs(delim).bytes
    n = b.length
    p += 1 while p < n && (b[p] & 255) != 0 && ds.include?(b[p] & 255)
    if p >= n || (b[p] & 255) == 0
      TOK[0] = nil
      return CPtr_ZERO
    end
    start = p
    p += 1 while p < n && (b[p] & 255) != 0 && !ds.include?(b[p] & 255)
    if p < n && (b[p] & 255) != 0
      b[p] = 0
      TOK[0] = [b, p + 1]
    else
      TOK[0] = nil
    end
    CPtr.new(b, start)
  end

  def R_toupper(c) = c >= 97 && c <= 122 ? c - 32 : c

  # ------------------------------------------------------------------------------------------------- strtod
  # Decimal text to the nearest double, ties to even, by exact integer arithmetic (Clinger's fast path when the
  # digits and the power of ten are both exact doubles). An exact value is [num, den] (positive Integers).
  P10F = (0..22).map { |k| Float("1e#{k}") }.freeze
  P10I = (0..400).map { |k| 10**k }.freeze
  def self.pow10i(k) = k <= 400 ? P10I[k] : 10**k

  # the nearest IEEE value with mbits significant bits and minimum normal exponent emin to num/den (positive),
  # ties to even, with gradual underflow; as a Float (inf beyond emax)
  def self.ratio_round(num, den, mbits, emin, emax)
    e = num.bit_length - den.bit_length
    e -= 1 unless e >= 0 ? num >= (den << e) : (num << -e) >= den
    # now 2**e <= num/den < 2**(e+1)
    e = emin if e < emin
    sh = mbits - 1 - e
    if sh >= 0
      q, r = (num << sh).divmod(den)
    else
      d2 = den << -sh
      q, r = num.divmod(d2)
      den = d2
    end
    r2 = r << 1
    q += 1 if r2 > den || (r2 == den && q.odd?)
    return INF if q.bit_length + (-sh) > emax + 1
    Math.ldexp(q.to_f, -sh)
  end

  def self.ratio_to_double(num, den) = Cpp.ratio_round(num, den, 53, -1022, 1023)
  def self.ratio_to_single(num, den) = Cpp.ratio_round(num, den, 24, -126, 127)

  # the double nearest digits * 10**exp10 (digits a non-negative Integer)
  def self.to_double(digits, exp10)
    return 0.0 if digits == 0
    if digits < 9007199254740992 && exp10.abs <= 22
      return exp10 >= 0 ? digits.to_f * P10F[exp10] : digits.to_f / P10F[-exp10]
    end
    nd = digits.to_s.length
    return INF if nd + exp10 > 310
    return 0.0 if nd + exp10 < -330
    exp10 >= 0 ? Cpp.ratio_to_double(digits * Cpp.pow10i(exp10), 1) : Cpp.ratio_to_double(digits, Cpp.pow10i(-exp10))
  end

  ERANGE = [false]
  def R_get_ERange = ERANGE[0]

  DEC_RX = /\G[ \t\n\v\f\r]*([+-]?)((?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)/n
  DEC_NS_RX = /\G([+-]?)((?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)/n
  HEXF_RX = /\G0[xX]((?:[0-9A-Fa-f]+(?:\.[0-9A-Fa-f]*)?|\.[0-9A-Fa-f]+))(?:[pP]([+-]?[0-9]+))?/n

  # [digits Integer, exp10] of decimal number text (digits, '.', exponent; no sign)
  def self.dec_parts(txt)
    m, ex = txt.split(/[eE]/, 2)
    ip, fp = m.split('.', 2)
    fp ||= ''
    ds = (ip + fp).sub(/\A0+/, '')
    e10 = -fp.length
    if ex
      ev = ex.to_i
      ev = 1_000_000_000 if ev > 1_000_000_000
      ev = -1_000_000_000 if ev < -1_000_000_000
      e10 += ev
    end
    [ds.empty? ? 0 : ds.to_i, e10, ds.length]
  end

  # glibc strtod's ERANGE for a decimal whose correctly rounded value is av: overflow, or underflow (tiny after
  # rounding and inexact, decided exactly)
  def self.dec_range(d, e10, nd, av)
    return true if av == INF
    return false if av > DBL_MIN || d == 0
    return true if nd + e10 < -340
    return false if e10 >= 0
    p10 = Cpp.pow10i(-e10)
    return false if (d << 1076) >= ((1 << 54) - 1) * p10
    m = [av].pack('E').unpack1('q<')
    (d << 1074) != m * p10
  end

  # glibc's strtod on the binary String b from index i (the end of b or a NUL ends the input): [value, end, exact],
  # end -1 when there is no number; exact is [neg, digits, exp10] for a decimal (the value digits * 10**exp10) or
  # [neg, num, den] for a hexadecimal number, for strtof; nil for inf / nan. Sets ERANGE as glibc's strtod sets errno.
  def self.scan_double(b, i, skip = true)
    m = (skip ? DEC_RX : DEC_NS_RX).match(b, i)
    if m && !(m[2] == '0' && (m.end(0) < b.bytesize) && (b.getbyte(m.end(0)) | 0x20) == 120)
      neg = m[1] == '-'
      d, e10, nd = Cpp.dec_parts(m[2])
      v = Cpp.to_double(d, e10)
      ERANGE[0] = v > DBL_MIN && v < INF ? false : Cpp.dec_range(d, e10, nd, v)
      return [neg ? -v : v, m.end(0), [neg, d, e10, nd]]
    end
    ERANGE[0] = false
    n = b.bytesize
    i += 1 while skip && i < n && SPACE_B.include?(b.getbyte(i))
    neg = false
    if i < n && (b.getbyte(i) == 43 || b.getbyte(i) == 45)
      neg = b.getbyte(i) == 45
      i += 1
    end
    c0 = i < n ? b.getbyte(i) | 0x20 : 0
    if c0 == 105 && b.byteslice(i, 3).downcase == 'inf'
      i += 3
      i += 5 if b.byteslice(i, 5).to_s.downcase == 'inity'
      return [neg ? -INF : INF, i, nil]
    end
    if c0 == 110 && b.byteslice(i, 3).downcase == 'nan'
      i += 3
      if i < n && b.getbyte(i) == 40
        k = i + 1
        k += 1 while k < n && (c = b.getbyte(k)) && ((c >= 48 && c <= 57) || ((c | 0x20) >= 97 && (c | 0x20) <= 122) || c == 95)
        if k < n && b.getbyte(k) == 41
          pl = k == i + 1 ? 0 : Cpp.c_unsigned(b.byteslice(i + 1, k - i - 1))
          unless pl.nil?
            v = [0x7FF8000000000000 | (pl & ((1 << 51) - 1))].pack('Q<').unpack1('E')
            return [neg ? -v : v, k + 1, nil]
          end
          i = k + 1
        end
      end
      return [neg ? DNAN : PNAN, i, nil]
    end
    if c0 == 48 && i + 1 < n && (b.getbyte(i + 1) | 0x20) == 120
      h = HEXF_RX.match(b, i)
      if h
        mant = h[1]
        ip, fp = mant.split('.', 2)
        fp ||= ''
        mv = (ip + fp).empty? ? 0 : (ip + fp).to_i(16)
        e2 = (h[2] || '0').to_i - 4 * fp.length
        num = mv
        den = 1
        if e2 >= 0 then num <<= e2 else den <<= -e2 end
        hv = mv == 0 ? 0.0 : (e2 > 5000 ? INF : (e2 < -5000 ? 0.0 : Cpp.ratio_to_double(num, den)))
        ERANGE[0] = (hv == 0.0 && mv != 0) || hv.infinite?
        return [neg ? -hv : hv, h.end(0), [neg, num, den]]
      end
      return [neg ? -0.0 : 0.0, i + 1, [neg, 0, 1]]      # the "0" alone
    end
    [0.0, -1, nil]
  end

  # strtoull(s, 0, 0) of a whole n-char-sequence; nil if it is not one
  def self.c_unsigned(s)
    v = if s =~ /\A0[xX][0-9a-fA-F]+\z/ then s[2..].to_i(16)
        elsif s =~ /\A0[0-7]*\z/ then s.to_i(8)
        elsif s =~ /\A[0-9]+\z/ then s.to_i(10)
        end
    return nil if v.nil?
    v > M64 ? M64 : v
  end

  def R_ScanDouble(b, i, skip = true) = Cpp.scan_double(b, i, skip)

  def R_strtod_CPtr(s)
    v, e, = Cpp.scan_double(Cpp.cbs(s), 0)
    e >= 0 ? v : 0.0
  end

  # strtod(s, &end): end (a Ref) is set to the character after the number, or to s when there is none
  def R_strtod_CPtr_CPtrr(s, endr)
    v, e, = Cpp.scan_double(Cpp.cbs(s), 0)
    if e < 0
      endr.v = s
      return 0.0
    end
    endr.v = CPtr.new(s.B, s.O + e)
    v
  end

  def R_atof(s) = R_strtod_CPtr(s)

  INT_RX = /\A[ \t\n\v\f\r]*([+-]?)([0-9]+)/n

  # the C# runtime's strtol: optional space and sign, decimal digits, clamped to long; end (a Ref, or nil) is set to
  # the character after the digits, or to s when there are none
  def R_strtol(s, endr, base = 10)
    m = INT_RX.match(Cpp.cbs(s))
    if m.nil?
      endr.v = s unless endr.nil?
      return 0
    end
    endr.v = CPtr.new(s.B, s.O + m.end(0)) unless endr.nil?
    v = m[2].to_i
    v = -v if m[1] == '-'
    v.clamp(-9223372036854775808, 9223372036854775807)
  end

  # atoi: strtol's long, then (int): its low 32 bits
  def R_atoi(s) = Cpp.i32(R_strtol(s, nil, 10))

  # strtof of a number whose exact value is ex: [neg, digits, exp10, ndigits] for a decimal, [neg, num, den] for a
  # hexadecimal number (or a double v when there is none: inf, nan)
  def self.text_f32(ex, v)
    return Cpp.f32_double(v) if ex.nil? || v != v || v.infinite?
    neg = ex[0]
    if ex.length == 4
      d = ex[1]
      e10 = ex[2]
      return neg ? -0.0 : 0.0 if d == 0 || ex[3] + e10 < -60
      return neg ? -INF : INF if ex[3] + e10 > 60
      num, den = e10 >= 0 ? [d * Cpp.pow10i(e10), 1] : [d, Cpp.pow10i(-e10)]
    else
      num = ex[1]
      den = ex[2]
    end
    return neg ? -0.0 : 0.0 if num == 0
    r = Cpp.ratio_to_single(num, den)
    neg ? -r : r
  end

  # ------------------------------------------------------------------------------------------------- sscanf targets
  class SetI
    def initialize(f)
      @f = f
    end

    def Set(v) = @f.call(v)
  end

  class SetL < SetI; end
  class SetD < SetI; end
  class SetF < SetI; end

  def R_RefI(a) = SetI.new(a)
  def R_RefL(a) = SetL.new(a)
  def R_RefD(a) = SetD.new(a)
  def R_RefF(a) = SetF.new(a)

  # the sscanf target that is a C pointer parameter (ref in C#): the value is stashed, then R.Back copies it
  class ScanSlot; end
  R_Slot = ScanSlot.new
  STASH = []

  def self.overflow_exc = SysException.new('OverflowException', 'Value was either too large or too small.')

  # Convert.ChangeType of a stashed number to an integer type whose values are [lo, hi] (checked as C#'s Convert is)
  def self.conv_int(v, lo, hi)
    if v.is_a?(Float)
      r = v.round(half: :even)
      raise Cpp.overflow_exc unless r >= lo && r <= hi
      return r
    end
    raise Cpp.overflow_exc unless v >= lo && v <= hi
    v
  end

  def R_Back_i_T1r__B(n, a)
    v = STASH[0]
    a.v = Cpp.conv_int(v, -128, 255) unless v.nil?
    n
  end

  def R_Back_i_T1r__S(n, a)
    v = STASH[0]
    a.v = Cpp.conv_int(v, -32768, 65535) unless v.nil?
    n
  end

  def R_Back_i_T1r__I(n, a)
    v = STASH[0]
    a.v = Cpp.conv_int(v, -2147483648, 0xFFFFFFFF) unless v.nil?
    n
  end

  def R_Back_i_T1r__L(n, a)
    v = STASH[0]
    a.v = Cpp.conv_int(v, -9223372036854775808, 9223372036854775807) unless v.nil?
    n
  end

  def R_Back_i_T1r__D(n, a)
    v = STASH[0]
    a.v = v.to_f unless v.nil?
    n
  end

  def R_Back_i_T1r__F(n, a)
    v = STASH[0]
    a.v = Cpp.f32_double(v.to_f) unless v.nil?
    n
  end

  def R_Back_i_T1r__Z(n, a)
    v = STASH[0]
    a.v = v != 0 && v != false unless v.nil?
    n
  end

  def R_Back_i_T1r_T2r__LB(n, a, b)
    v = STASH[0]
    a.v = Cpp.conv_int(v, -9223372036854775808, 9223372036854775807) unless v.nil?
    v = STASH[1]
    b.v = Cpp.conv_int(v, -128, 255) unless v.nil?
    n
  end

  # ------------------------------------------------------------------------------------------------- sscanf
  SCF = {}

  # the directives of a scanf format: [:w] white space, [:l, c] a literal byte, or
  # [:p, suppress, width, lmod, conv, set] a conversion (set: the bytes a scan set accepts, as an Array of 256 bools)
  def self.scan_compile(f)
    out = []
    k = 0
    n = f.bytesize
    while k < n
      c = f.getbyte(k)
      if SPACE_B.include?(c)
        k += 1 while k < n && SPACE_B.include?(f.getbyte(k))
        out << [:w]
        next
      end
      if c != 37
        out << [:l, c]
        k += 1
        next
      end
      k += 1
      suppress = false
      if k < n && f.getbyte(k) == 42
        suppress = true
        k += 1
      end
      width = 0
      while k < n && (d = f.getbyte(k)) >= 48 && d <= 57
        width = width * 10 + d - 48
        k += 1
      end
      lmod = 0
      while k < n && 'lhLzjtq'.include?(f.getbyte(k).chr)
        lmod += 1 if f.getbyte(k) != 104
        k += 1
      end
      conv = k < n ? f.getbyte(k) : 0
      k += 1
      cset = nil
      if conv == 91
        s = Array.new(256, false)
        negate = false
        if k < n && f.getbyte(k) == 94
          negate = true
          k += 1
        end
        first = true
        while k < n && (first || f.getbyte(k) != 93)
          ch = f.getbyte(k)
          if ch == 45 && !first && k + 1 < n && f.getbyte(k + 1) != 93 && f.getbyte(k - 1) <= f.getbyte(k + 1)
            (f.getbyte(k - 1)..f.getbyte(k + 1)).each { |x| s[x] = true }
            k += 2
            first = false
            next
          end
          s[ch] = true
          k += 1
          first = false
        end
        k += 1 if k < n && f.getbyte(k) == 93
        if negate
          s.map!(&:!)
          s[0] = false
        end
        cset = s
      end
      out << [:p, suppress, width, lmod, conv, cset]
    end
    out
  end

  def self.wrap_lmod(v, lmod) = lmod != 0 ? Cpp.i64(v) : Cpp.i32(v)

  # an integer conversion's value into its target (an int unless the l modifier was given)
  def self.store_int(a, v, lmod)
    case a
    when SetL then a.Set(Cpp.i64(v))
    when SetI then a.Set(Cpp.i32(v))
    when ScanSlot then STASH << Cpp.wrap_lmod(v, lmod)
    else
      raise ArgumentError, "sscanf integer target #{a.inspect}" unless a.respond_to?(:v=)
      a.v = Cpp.wrap_lmod(v, lmod)
    end
  end

  # a %s / %[ / %c string into a char* target: a CPtr, or a char array pointer (Ptr<sbyte>)
  def self.store_buf(a, data)
    if a.is_a?(CPtr)
      Cpp.put(a, 0, data)
    elsif a.is_a?(Ptr)
      a.a[a.o, data.bytesize] = data.bytes.map { |c| c > 127 ? c - 256 : c }
    else
      raise ArgumentError, "sscanf string target #{a.inspect}"
    end
  end

  def self.store_float(a, v, ex, lmod)
    case a
    when SetD then a.Set(v)
    when SetF then a.Set(Cpp.text_f32(ex, v))
    when ScanSlot then STASH << (lmod != 0 ? v : Cpp.text_f32(ex, v))
    else
      raise ArgumentError, "sscanf float target #{a.inspect}" unless a.respond_to?(:v=)
      a.v = lmod != 0 ? v : Cpp.text_f32(ex, v)
    end
  end

  # glibc's sscanf for the directives the engine uses: %d %i %u (decimal), %f %e %g %a (and capitals), %s, %c, %[...],
  # %n and %%, with * and widths and the h/l/L/z/j/t/q modifiers. Targets: the R_RefI / RefL / RefD / RefF setters,
  # R_Slot (the value is stashed for R_Back), char buffers (CPtr, Ptr<sbyte>) and Refs (Cell, ArrRef). It returns the
  # number of assignments, or EOF (-1) when the input ends before the first assignment.
  def R_sscanf(s, fmt, *args)
    STASH.clear
    b = Cpp.cbs(s)
    fb = Cpp.cbs(fmt)
    dirs = SCF[fb]
    if dirs.nil?
      dirs = Cpp.scan_compile(fb)
      SCF[fb.freeze] = dirs if SCF.size < 10_000
    end
    n = b.bytesize
    i = 0
    ai = 0
    count = 0
    dirs.each do |d|
      op = d[0]
      if op == :w
        i += 1 while i < n && SPACE_B.include?(b.getbyte(i))
        next
      end
      if op == :l
        return count == 0 ? -1 : count if i >= n
        return count if b.getbyte(i) != d[1]
        i += 1
        next
      end
      _, suppress, width, lmod, conv, cset = d
      if conv != 99 && conv != 91 && conv != 110
        i += 1 while i < n && SPACE_B.include?(b.getbyte(i))
      end
      if conv == 110
        unless suppress
          Cpp.store_int(args[ai], i, lmod)
          ai += 1
        end
        next
      end
      return count == 0 ? -1 : count if i >= n
      w = width > 0 ? width : 1 << 30
      case conv
      when 100, 105, 117                         # d i u
        j = i
        lim = i + w
        neg = false
        if j < lim && (b.getbyte(j) == 43 || b.getbyte(j) == 45)
          neg = b.getbyte(j) == 45
          j += 1
        end
        ds = j
        e = lim < n ? lim : n
        j += 1 while j < e && (c = b.getbyte(j)) >= 48 && c <= 57
        return count if j == ds
        u = b.byteslice(ds, j - ds).to_i
        i = j
        if conv == 117
          if u > M64
            u = M64
          elsif neg
            u = (-u) & M64
          end
          v = lmod == 0 ? u & 0xFFFFFFFF : u
        else
          v = neg ? -u : u
          v = v.clamp(-9223372036854775808, 9223372036854775807)
        end
        unless suppress
          Cpp.store_int(args[ai], v, lmod)
          ai += 1
          count += 1
        end
      when 102, 101, 69, 103, 71, 97, 65, 70    # f e E g G a A F
        e, num = Cpp.scan_float(b, i, width)
        return count if e < 0
        i = e
        v, ne, ex = Cpp.scan_double(num, 0, false)
        return count if ne <= 0
        unless suppress
          Cpp.store_float(args[ai], v, ex, lmod)
          ai += 1
          count += 1
        end
      when 115, 91                              # s [
        j = i
        e = i + w < n ? i + w : n
        if conv == 115
          j += 1 while j < e && !SPACE_B.include?(b.getbyte(j))
        else
          j += 1 while j < e && cset[b.getbyte(j)]
        end
        return count if j == i
        unless suppress
          Cpp.store_buf(args[ai], b.byteslice(i, j - i) + "\0")
          ai += 1
          count += 1
        end
        i = j
      when 99                                   # c
        m = width > 0 ? width : 1
        j = i + m < n ? i + m : n
        unless suppress
          a = args[ai]
          ai += 1
          c = b.getbyte(i)
          sc = c > 127 ? c - 256 : c
          case a
          when SetI then a.Set(sc)
          when ScanSlot then (i...j).each { |k| x = b.getbyte(k); STASH << (x > 127 ? x - 256 : x) }
          when CPtr, Ptr then Cpp.store_buf(a, b.byteslice(i, j - i))
          else
            raise ArgumentError, "sscanf %c target #{a.inspect}" unless a.respond_to?(:v=)
            a.v = sc
          end
          count += 1
        end
        i = j
      when 37
        return count if b.getbyte(i) != 37
        i += 1
      else
        raise ArgumentError, "sscanf %#{conv.chr}"
      end
    end
    count
  end

  # The scanner of glibc's vfscanf for a floating conversion at b[i]: [index after, the characters taken] or
  # [-1, nil] for a matching failure. Like glibc, it reads one character ahead and pushes back only that one.
  def self.scan_float(b, i, width)
    n = b.bytesize
    left = width > 0 ? width : -1
    p = i
    buf = +''
    inchar = lambda do
      if p < n
        p += 1
        b.getbyte(p - 1)
      else
        -1
      end
    end
    dec = -> { left -= 1 if left > 0 }
    low = ->(c) { c >= 65 && c <= 90 ? c | 0x20 : c }
    expect = lambda do |ch|
      return false if left == 0
      c = inchar.call
      return false if c < 0 || low.call(c) != ch
      dec.call
      buf << c
      true
    end
    c = inchar.call
    dec.call
    got_sign = 0
    if c == 45 || c == 43
      got_sign = 1
      buf << c
      return [-1, nil] if left == 0
      c = inchar.call
      return [-1, nil] if c < 0
      dec.call
    end
    if low.call(c) == 110
      buf << c
      return [-1, nil] unless expect.call(97) && expect.call(110)
      return [p, buf]
    end
    if low.call(c) == 105
      buf << c
      return [-1, nil] unless expect.call(110) && expect.call(102)
      if left != 0
        c = inchar.call
        if c >= 0
          if low.call(c) == 105
            dec.call
            buf << c
            return [-1, nil] unless expect.call(110) && expect.call(105) && expect.call(116) && expect.call(121)
          else
            p -= 1
          end
        end
      end
      return [p, buf]
    end
    exp_char = 101
    hexa = got_digit = got_dot = got_e = false
    if left != 0 && c == 48
      buf << c
      c = inchar.call
      dec.call
      if left != 0 && low.call(c) == 120
        buf << c
        hexa = true
        exp_char = 112
        c = inchar.call
        dec.call
      else
        got_digit = true
      end
    end
    loop do
      if c >= 48 && c <= 57
        buf << c
        got_digit = true
      elsif !got_e && hexa && c >= 0 && low.call(c) >= 97 && low.call(c) <= 102
        buf << c
        got_digit = true
      elsif got_e && buf.getbyte(-1) == exp_char && (c == 45 || c == 43)
        buf << c
      elsif got_digit && !got_e && c >= 0 && low.call(c) == exp_char
        buf << exp_char
        got_e = got_dot = true
      elsif !got_dot && c == 46
        buf << c
        got_dot = true
      else
        p -= 1 if c >= 0
        break
      end
      break if left == 0
      c = inchar.call
      break if c < 0
      dec.call
    end
    return [-1, nil] if buf.bytesize == got_sign || (hexa && buf.bytesize == 2 + got_sign)
    [p, buf]
  end

  # ------------------------------------------------------------------------------------------------- printf
  FC = {}

  # [literal String | [left, plus, space, alt, zero, width, prec, size, conv]]: width -1 and prec -2 for '*', prec -1
  # for none, size the integer width in bits
  def self.fmt_compile(fb)
    segs = []
    i = 0
    n = fb.bytesize
    lit = 0
    while i < n
      if fb.getbyte(i) != 37
        i += 1
        next
      end
      segs << fb.byteslice(lit, i - lit) if i > lit
      i += 1
      if i < n && fb.getbyte(i) == 37
        segs << '%'
        i += 1
        lit = i
        next
      end
      left = plus = space = alt = zero = false
      while i < n
        case fb.getbyte(i)
        when 45 then left = true
        when 43 then plus = true
        when 32 then space = true
        when 35 then alt = true
        when 48 then zero = true
        else break
        end
        i += 1
      end
      width = 0
      if i < n && fb.getbyte(i) == 42
        width = -1
        i += 1
      else
        while i < n && (c = fb.getbyte(i)) >= 48 && c <= 57
          width = width * 10 + c - 48
          i += 1
        end
      end
      prec = -1
      if i < n && fb.getbyte(i) == 46
        i += 1
        prec = 0
        if i < n && fb.getbyte(i) == 42
          prec = -2
          i += 1
        else
          while i < n && (c = fb.getbyte(i)) >= 48 && c <= 57
            prec = prec * 10 + c - 48
            i += 1
          end
        end
      end
      size = 32
      while i < n
        c = fb.getbyte(i)
        if c == 104
          size = size == 16 ? 8 : 16
        elsif 'lLqjzt'.include?(c.chr)
          size = 64
        else
          break
        end
        i += 1
      end
      conv = i < n ? fb.getbyte(i) : 0
      i += 1
      lit = i
      segs << [left, plus, space, alt, zero, width, prec, size, conv].freeze
    end
    segs << fb.byteslice(lit, n - lit) if lit < n
    segs.freeze
  end

  SIGNED = { 8 => ->(v) { ((v + 0x80) & 0xFF) - 0x80 }, 16 => ->(v) { ((v + 0x8000) & 0xFFFF) - 0x8000 },
             32 => ->(v) { ((v + 0x80000000) & 0xFFFFFFFF) - 0x80000000 },
             64 => ->(v) { ((v + 0x8000000000000000) & M64) - 0x8000000000000000 } }.freeze
  MASK = { 8 => 0xFF, 16 => 0xFFFF, 32 => 0xFFFFFFFF, 64 => M64 }.freeze

  # an integer argument as its C# value (x86's truncation from a floating one)
  def self.argint(a)
    case a
    when Integer then a
    when true then 1
    when false then 0
    when Float then a != a || a >= 9223372036854775808.0 || a < -9223372036854775808.0 ? -9223372036854775808 : a.to_i
    when F32 then Cpp.argint(a.v)
    when TBox then a.v
    else raise TypeError, "printf: integer argument #{a.inspect}"
    end
  end

  def self.argf(a)
    case a
    when Float then a
    when Integer then a.to_f
    when TBox then a.v.to_f
    else raise TypeError, "printf: floating argument #{a.inspect}"
    end
  end

  # a %s argument's bytes (a binary String), or nil for a null pointer
  def self.argstr(a)
    case a
    when CPtr then a.B.nil? ? nil : Cpp.cbs(a)
    when Str then a.b[0, a.n].pack('C*')
    when String then a
    when nil then nil
    when Ptr then a.a.nil? ? nil : Cpp.cbs(CPtr.new(a.a, a.o))
    else raise TypeError, "printf: string argument #{a.inspect}"
    end
  end

  # The bytes printf writes for fmt (a CPtr) and args (a binary String): glibc's formatting, with the flags - + space
  # # 0, width and precision (* too), the length modifiers hh h l ll L q j z t, and the conversions d i u o x X c s f F
  # e E g G a A %. An integer argument is taken at the size its length modifier says.
  def self.format_c(fmt, args)
    fb = Cpp.cbs(fmt)
    segs = FC[fb]
    if segs.nil?
      segs = Cpp.fmt_compile(fb)
      FC[fb.freeze] = segs if FC.size < 20_000
    end
    o = +''
    ai = 0
    segs.each do |seg|
      if seg.is_a?(String)
        o << seg
        next
      end
      left, plus, space, alt, zero, width, prec, size, conv = seg
      if width == -1
        width = Cpp.i32(Cpp.argint(args[ai]))
        ai += 1
        if width < 0
          left = true
          width = -width
        end
      end
      if prec == -2
        prec = Cpp.i32(Cpp.argint(args[ai]))
        ai += 1
        prec = -1 if prec < 0
      end
      sign = ''
      prefix = ''
      numeric = true
      raise IndexError, 'printf: too few arguments' if ai >= args.length && conv != 0
      case conv
      when 100, 105                              # d i
        v = SIGNED[size].call(Cpp.argint(args[ai]))
        ai += 1
        if v < 0 then sign = '-'
        elsif plus then sign = '+'
        elsif space then sign = ' '
        end
        body = v.abs.to_s
        if prec >= 0
          zero = false
          body = '' if prec == 0 && v == 0
          body = body.rjust(prec, '0')
        end
      when 117, 120, 88, 111                     # u x X o
        u = Cpp.argint(args[ai]) & MASK[size]
        ai += 1
        body = case conv
               when 117 then u.to_s
               when 111 then u.to_s(8)
               when 120 then u.to_s(16)
               else u.to_s(16).upcase
               end
        if prec >= 0
          zero = false
          body = '' if prec == 0 && u == 0
          body = body.rjust(prec, '0')
        end
        if alt
          if conv == 111 && (body.empty? || body.getbyte(0) != 48)
            body = '0' + body
          elsif conv == 120 && u != 0
            prefix = '0x'
          elsif conv == 88 && u != 0
            prefix = '0X'
          end
        end
      when 99                                    # c
        numeric = false
        body = (Cpp.argint(args[ai]) & 255).chr
        ai += 1
      when 115                                   # s
        numeric = false
        p = Cpp.argstr(args[ai])
        ai += 1
        body = if p.nil? then prec < 0 || prec >= 6 ? '(null)' : ''
               elsif prec >= 0 then p.byteslice(0, prec)
               else p
               end
      when 102, 70, 101, 69, 103, 71, 97, 65    # f F e E g G a A
        v = Cpp.argf(args[ai])
        ai += 1
        if Cpp.signbit(v) then sign = '-'
        elsif plus then sign = '+'
        elsif space then sign = ' '
        end
        upper = conv == 70 || conv == 69 || conv == 71 || conv == 65
        if !v.finite?
          body = v.nan? ? 'nan' : 'inf'
          body = body.upcase if upper
          zero = false
        elsif conv == 97 || conv == 65
          body = Cpp.hexfloat(v.abs, prec, alt)
          prefix = '0x'
          if upper
            body = body.upcase
            prefix = '0X'
          end
        else
          body = Cpp.format_float(v.abs, conv, prec < 0 ? 6 : prec, alt)
        end
      else
        raise ArgumentError, "printf %#{conv.chr}"
      end
      m = sign.bytesize + prefix.bytesize + body.bytesize
      if m >= width
        o << sign << prefix << body
      elsif left
        o << sign << prefix << body << ' ' * (width - m)
      elsif zero && numeric
        o << sign << prefix << '0' * (width - m) << body
      else
        o << ' ' * (width - m) << sign << prefix << body
      end
    end
    o
  end

  def R_Format(fmt, args) = Cpp.format_c(fmt, args)

  # ---- exact %f %e %g: x = m * 2**e, and round(x * 10**s) with ties to even, as glibc prints the exact binary value

  # [m, e] with |x| = m * 2**e (x finite, nonzero)
  def self.decompose(x)
    b = [x].pack('E').unpack1('Q<')
    be = (b >> 52) & 0x7FF
    m = b & 0xFFFFFFFFFFFFF
    be == 0 ? [m, -1074] : [m | 0x10000000000000, be - 1075]
  end

  # round(m * 2**e * 10**s), ties to even
  def self.scaled_round(m, e, s)
    num = m
    den = 1
    if s >= 0 then num *= Cpp.pow10i(s) else den = Cpp.pow10i(-s) end
    if e >= 0 then num <<= e else den <<= -e end
    q, r = num.divmod(den)
    r2 = r << 1
    q += 1 if r2 > den || (r2 == den && q.odd?)
    q
  end

  def self.cmp_pow10(m, e, k)
    a = m
    b = 1
    if e >= 0 then a <<= e else b <<= -e end
    if k >= 0 then b *= Cpp.pow10i(k) else a *= Cpp.pow10i(-k) end
    a <=> b
  end

  # the decimal exponent E with 10**E <= x < 10**(E+1), exactly
  def self.dec_exp(x, m, e)
    k = Math.log10(x).floor
    k -= 1 while Cpp.cmp_pow10(m, e, k) < 0
    k += 1 while Cpp.cmp_pow10(m, e, k + 1) >= 0
    k
  end

  # digits of x (finite, >= 0) for %f with precision p: [integer part, fraction]
  def self.f_digits(x, p)
    return ['0', '0' * p] if x == 0.0
    m, e = Cpp.decompose(x)
    if e >= 0 && p == 0
      s = (m << e).to_s
      return [s, '']
    end
    s = Cpp.scaled_round(m, e, p).to_s
    s = '0' * (p + 1 - s.length) + s if s.length < p + 1
    [s[0, s.length - p], s[s.length - p, p]]
  end

  # digits of x (finite, >= 0) for %e with precision p: [p+1 digits, decimal exponent]
  def self.e_digits(x, p)
    return ['0' * (p + 1), 0] if x == 0.0
    m, e = Cpp.decompose(x)
    k = Cpp.dec_exp(x, m, e)
    q = Cpp.scaled_round(m, e, p - k)
    if q >= Cpp.pow10i(p + 1)
      k += 1
      q = Cpp.pow10i(p)
    end
    [q.to_s, k]
  end

  def self.exp_str(k, upper) = (upper ? 'E' : 'e') + (k < 0 ? '-' : '+') + (k.abs < 10 ? '0' : '') + k.abs.to_s

  # %f %e %g (and capitals) of a finite non-negative double, glibc's rounding and layout
  def self.format_float(a, conv, prec, alt)
    upper = conv == 69 || conv == 71
    case conv
    when 102, 70
      ip, fp = Cpp.f_digits(a, prec)
      prec > 0 ? ip + '.' + fp : (alt ? ip + '.' : ip)
    when 101, 69
      d, k = Cpp.e_digits(a, prec)
      d[0] + (prec > 0 || alt ? '.' : '') + d[1..] + Cpp.exp_str(k, upper)
    else
      pp = prec == 0 ? 1 : prec
      d, k = Cpp.e_digits(a, pp - 1)
      if alt && a != 0.0 && k == pp && pp > 1
        # glibc's quirk: when rounding to P digits carries up to 10^P from an exponent of P - 1, the exponential form
        # keeps the fixed form's count of fraction digits (none): %#g of 999999.5 is "1.e+06"
        m, e = Cpp.decompose(a)
        return Cpp.format_float(a, upper ? 69 : 101, 0, true) if Cpp.dec_exp(a, m, e) == pp - 1
      end
      if pp > k && k >= -4
        ip, fp = Cpp.f_digits(a, pp - 1 - k)
        fp = fp.sub(/0+\z/, '') unless alt
        fp.empty? && !alt ? ip : ip + '.' + fp
      else
        fr = d[1..]
        fr = fr.sub(/0+\z/, '') unless alt
        d[0] + (fr.empty? && !alt ? '' : '.') + fr + Cpp.exp_str(k, upper)
      end
    end
  end

  # glibc's %a of a non-negative finite double without the 0x prefix
  def self.hexfloat(a, prec, alt)
    bits = [a].pack('E').unpack1('Q<')
    ex = (bits >> 52) & 0x7FF
    man = bits & 0xFFFFFFFFFFFFF
    lead = 1
    if ex == 0
      lead = 0
      e = man != 0 ? -1022 : 0
    else
      e = ex - 1023
    end
    if prec < 0
      digits = format('%013x', man).sub(/0+\z/, '')
    elsif prec < 13
      drop = (13 - prec) * 4
      full = (lead << 52) | man
      keep = full >> drop
      rem = full & ((1 << drop) - 1)
      half = 1 << (drop - 1)
      keep += 1 if rem > half || (rem == half && keep.odd?)
      lead = keep >> (prec * 4)
      digits = prec > 0 ? format('%0*x', prec, keep & ((1 << (prec * 4)) - 1)) : ''
    else
      digits = format('%013x', man) + '0' * (prec - 13)
    end
    s = lead.to_s
    s += '.' + digits if !digits.empty? || alt
    s + (e >= 0 ? "p+#{e}" : "p-#{-e}")
  end

  # as glibc's %f: libstdc++'s std::to_string(double)
  def self.fmt_float(v, _flags, _width, prec, _conv)
    return (Cpp.signbit(v) ? '-' : '') + (v.nan? ? 'nan' : 'inf') unless v.finite?
    (Cpp.signbit(v) ? '-' : '') + Cpp.format_float(v.abs, 102, prec, false)
  end

  def R_fprintf(f, fmt, *args)
    b = Cpp.format_c(fmt, args)
    return -1 if f.nil?
    f.S.write(b)
    b.bytesize
  end

  # snprintf with an unsigned size n: at most n - 1 bytes and the terminator; the length of the whole output
  def R_snprintf_CPtr_ul_CPtr_oA(buf, n, fmt, *args)
    b = Cpp.format_c(fmt, args)
    if n != 0
      m = b.bytesize < n - 1 ? b.bytesize : n - 1
      Cpp.put(buf, 0, b.byteslice(0, m) + "\0")
    end
    b.bytesize
  end

  def R_snprintf_CPtr_l_CPtr_oA(buf, n, fmt, *args) = R_snprintf_CPtr_ul_CPtr_oA(buf, n & M64, fmt, *args)
  def R_snprintf_CPtr_i_CPtr_oA(buf, n, fmt, *args) = R_snprintf_CPtr_ul_CPtr_oA(buf, n & M64, fmt, *args)

  # ------------------------------------------------------------------------------------------------- files
  CFILE_OPEN = {}.compare_by_identity     # the files fopen opened and fclose has not closed: exit() flushes them

  # C's FILE* (C# Cpp.CFile): S, the stream (a Ruby File in binary mode, or a CStdStream for a standard stream), the
  # end-of-file flag Eof and IsStd. Dir: a directory opened with fopen(dir, "r"): every read fails with EISDIR, which
  # sets the error indicator Err, not end-of-file.
  class CFile
    attr_accessor :S, :Eof, :IsStd, :floor, :Dir, :Err

    def initialize(s, std = false)
      @S = s
      @Eof = false
      @IsStd = std
      @floor = 0
      @Dir = false
      @Err = false
      CFILE_OPEN[self] = true unless std
    end

    def ReadFailed
      if @Dir then @Err = true else @Eof = true end
    end
  end

  # .NET's Stream.Null (the stream of a directory opened for reading)
  class NullStream
    def write(b) = b.bytesize
    def read(_n = nil) = nil
    def gets(*) = nil
    def seek(*) = 0
    def pos = 0
    def flush; end
    def close; end
  end

  # a standard stream for a CFile: written through to its file descriptor at once, read unbuffered; no seeking
  class CStdStream
    def initialize(io)
      @io = io
      @pos = 0
    end

    def write(b)
      n = b.bytesize
      k = 0
      k += @io.syswrite(k == 0 ? b : b.byteslice(k, n - k)) while k < n
      @pos += n
      n
    rescue Errno::EPIPE
      n
    end

    def read(n = nil)
      r = n.nil? ? @io.read : @io.read(n)
      @pos += r.bytesize unless r.nil?
      r
    end

    def gets(sep, limit)
      r = @io.gets(sep, limit)
      @pos += r.bytesize unless r.nil?
      r
    end

    def seek(*) = raise(Errno::ESPIPE)
    def pos = @pos
    def flush; end
    def close; end
  end

  R_stdout_ = CFile.new(CStdStream.new(IO.new(1, 'wb', autoclose: false)), true)
  R_stderr_ = CFile.new(CStdStream.new(IO.new(2, 'wb', autoclose: false)), true)
  R_stdin_ = CFile.new(CStdStream.new(IO.new(0, 'rb', autoclose: false)), true)

  # fopen as the C# runtime does it: r (r+) an existing file, w (w+) a new or truncated file, a an append-only file
  # that cannot seek before its old end; b and t ignored; nil when the file cannot be opened. A directory opened with
  # "r" opens, as glibc opens it, and its reads fail.
  def R_fopen(name, mode)
    fn = Cpp.cbs(name)
    m = Cpp.cbs(mode)
    return nil if m.empty?
    plus = m.include?('+')
    c = m.getbyte(0)
    if c == 114 && !plus && File.directory?(fn)
      d = CFile.new(NullStream.new)
      d.Dir = true
      return d
    end
    case c
    when 114 then CFile.new(File.open(fn, plus ? 'r+b' : 'rb'))
    when 119 then CFile.new(File.open(fn, plus ? 'w+b' : 'wb'))
    when 97
      return nil if File.directory?(fn)
      f = File.open(fn, File::WRONLY | File::CREAT | File::BINARY, 0o666)
      f.seek(0, IO::SEEK_END)
      cf = CFile.new(f)
      cf.floor = f.pos
      cf
    end
  rescue SystemCallError, IOError, ArgumentError
    nil
  end

  def R_fclose(f)
    return -1 if f.nil?
    if f.IsStd
      f.S.flush
    else
      f.S.close
      CFILE_OPEN.delete(f)
    end
    0
  end

  # what C's exit() does to open streams: flush every one (stdout and stderr too)
  def R_FlushAll
    CFILE_OPEN.keys.each do |f|
      f.S.flush
    rescue StandardError
      nil
    end
  end

  # fflush; fflush(NULL) flushes every stream, as glibc does
  def R_fflush(f)
    if f.nil? then R_FlushAll() else f.S.flush end
    0
  end

  def R_feof(f) = f.Eof ? 1 : 0

  def R_rewind(f)
    f.S.seek(0)
    f.Eof = false
  end

  # fseek: 0, or -1 when the position would be negative (or before the start of an append) or the stream cannot seek
  def R_fseek_CFile_l_i(f, off, whence)
    s = f.S
    p = case whence
        when 0 then off
        when 1 then s.pos + off
        else
          s.seek(0, IO::SEEK_END)
          s.pos + off
        end
    return -1 if p < f.floor
    s.seek(p, IO::SEEK_SET)
    f.Eof = false
    0
  rescue SystemCallError, IOError, ArgumentError
    -1
  end
  alias R_fseek_CFile_i_i R_fseek_CFile_l_i

  def R_ftell(f) = f.S.pos

  # fgets: up to n - 1 bytes, to and including a newline; a null pointer when nothing was read (end of file)
  def R_fgets(buf, n, f)
    return CPtr_ZERO if n <= 1
    line = f.S.gets("\n", n - 1)
    f.ReadFailed if line.nil? || (line.bytesize < n - 1 && !line.end_with?("\n"))
    return CPtr_ZERO if line.nil? || line.empty?
    Cpp.put(buf, 0, line + "\0")
    buf
  end

  def R_remove(name)
    File.delete(Cpp.cbs(name))
    0
  rescue SystemCallError
    -1
  end

  def R_mkstemp(template)
    n = R_strlen(template)
    chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    rnd = Random.new
    1000.times do
      Cpp.put(template, n - 6, Array.new(6) { chars[rnd.rand(62)] }.join)
      begin
        File.open(Cpp.cbs(template), File::CREAT | File::EXCL | File::RDWR, 0o600).close
        return 3
      rescue Errno::EEXIST
        next
      rescue SystemCallError
        return -1
      end
    end
    -1
  end

  # the 4 bytes C's (float)x stores (x already single-rounded): MRI's pack('e') turns every NaN into +NaN, where
  # cvtsd2ss keeps the sign and the top of the payload
  def self.float_bytes(x)
    return [x].pack('e') if x == x
    b = [x].pack('E').unpack1('Q<')
    [((b >> 32) & 0x80000000) | 0x7FC00000 | ((b >> 29) & 0x3FFFFF)].pack('L<')
  end

  # a whole Array of single-rounded values as little-endian floats
  def self.floats_bytes(arr)
    s = arr.sum(0.0)
    return arr.pack('e*') if s == s
    arr.map { |x| Cpp.float_bytes(x) }.join
  end

  def R_fwriteF1(v, f)
    f.S.write(Cpp.float_bytes(v))
    1
  end

  def R_fwriteD1(v, f)
    f.S.write([v].pack('E'))
    1
  end

  def R_fwriteI1(v, f)
    f.S.write([v & 0xFFFFFFFF].pack('L<'))
    1
  end

  def R_fwriteL1(v, f)
    f.S.write([v & M64].pack('Q<'))
    1
  end

  def self.read_exact(f, n)
    b = f.S.read(n)
    if b.nil? || b.bytesize < n
      f.ReadFailed
      return nil
    end
    b
  end

  def R_freadF1(r, f)
    b = Cpp.read_exact(f, 4)
    return 0 if b.nil?
    r.v = b.unpack1('e')
    1
  end

  def R_freadD1(r, f)
    b = Cpp.read_exact(f, 8)
    return 0 if b.nil?
    r.v = b.unpack1('E')
    1
  end

  def R_freadI1(r, f)
    b = Cpp.read_exact(f, 4)
    return 0 if b.nil?
    r.v = b.unpack1('l<')
    1
  end

  def R_freadL1(r, f)
    b = Cpp.read_exact(f, 8)
    return 0 if b.nil?
    r.v = b.unpack1('q<')
    1
  end

  # ------------------------------------------------------------------------------------------------- time
  def R_time = Time.now.to_i

  # time(p): the seconds since the epoch, also stored at p unless p is null
  def R_time_Ptrl(p)
    t = Time.now.to_i
    p.set_Item_i(0, t) unless p.get_IsNull
    t
  end

  def R_difftime(e, s) = (e - s).to_f

  # ctime: "Www Mmm dd hh:mm:ss yyyy\n" in the local time zone (asctime's format), as a fresh C string
  def R_ctime_l(t) = R_Lit(Time.at(t).strftime("%a %b %e %H:%M:%S %Y\n"))
  def R_ctime_Ptrl(p) = R_ctime_l(p.get_Item_i(0))
end
