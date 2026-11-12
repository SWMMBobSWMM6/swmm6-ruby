# encoding: binary
# frozen_string_literal: false
# crtcheck.rb - the Ruby side of tests/crtcheck (as pycheck/crtcheck.py is the Python side):
#   ruby --disable-gems crtcheck.rb libm N | printf | scanf | misc | units
# reads what the C program of the same name (tests/crtcheck: libm.c, printf.c, scanf.c, misc.cpp, and
# tests/crtcheck/pycheck/specs.c for every printf conversion the engine's format strings use) wrote on stdin and
# reports where the Ruby runtime (ruby/cpp: crt.rb, crtmath.rb, crtmisc.rb, rfs.rb) differs from glibc. The case
# lines and their checks are crtcheck.py's, one for one; units are its unit checks in Ruby's terms.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
require 'tmpdir'
require_relative '../cpp/cpp'

def bits(x) = [x].pack('E').unpack1('Q<')
def frombits(b) = [b].pack('Q<').unpack1('E')
def unhex(s) = s == '-' ? ''.b : [s].pack('H*')
def lit(b) = Cpp::CPtr.new(b.bytes + [0], 0)
def hexs(b) = b.unpack1('H*')

def lines(what)
  n = bad = 0
  $stdin.binmode
  $stdin.each_line do |raw|
    f = raw.chomp("\n").split("\t", -1)
    n += 1
    want, got = yield(f)
    next if want == got
    bad += 1
    puts "MISMATCH #{unhex(f[0]).inspect}\n  glibc:  #{want}\n  Ruby:   #{got}" if bad <= 15
  end
  puts "#{what} cases: #{n}, mismatches: #{bad}"
end

# ------------------------------------------------------------------------------------------------ printf
# hex(format) types args size ret hex(output)
def printf_case(f)
  fmt = lit(unhex(f[0]))
  vals = f[2].split(',')
  args = []
  f[1].each_char.with_index do |t, i|
    v = vals[i]
    case t
    when 'd' then args << frombits(v.to_i(16))
    when 'i'
      x = v.to_i(16)
      args << (x >= 1 << 31 ? x - (1 << 32) : x)
    when 'l'
      x = v.to_i(16)
      args << I64(x >= 1 << 63 ? x - (1 << 64) : x)
    when 's' then args << lit(unhex(v))
    when 'S' then args << Cpp::CPtr_ZERO
    end
  end
  size = f[3].to_i
  buf = R_Buf_i(1024)
  buf.B.fill(0x55)
  buf.B[0] = 0
  r = R_snprintf_CPtr_ul_CPtr_oA(buf, size, fmt, *args)
  out = '-'
  if size > 0
    k = buf.B.index(0)
    out = hexs(buf.B[0, k].pack('C*')) if k > 0
  end
  ["#{f[4]}\t#{f[5]}", "#{r}\t#{out}"]
end

# ------------------------------------------------------------------------------------------------ scanf
# hex(format) hex(input) types ret values; the targets are the kinds the engine passes
def scanf_case(f)
  fmt = lit(unhex(f[0]))
  inp = lit(unhex(f[1]))
  types = f[2]
  m = types.length
  ints = Array.new(m, 0x55555555)
  longs = Array.new(m, 0x5555555555555555)
  floats = Array.new(m, ("\x55" * 4).unpack1('e'))
  doubles = Array.new(m, frombits(0x5555555555555555))
  bufs = Array.new(m)
  args = []
  types.each_char.with_index do |t, k|
    case t
    when 'i', 'n' then args << R_RefI(->(v) { ints[k] = v })
    when 'u' then args << R_RefL(->(v) { ints[k] = Cpp.i32(v) })   # a long setter, kept as unsigned int bits read as int
    when 'l' then args << R_RefL(->(v) { longs[k] = v })
    when 'f' then args << R_RefF(->(v) { floats[k] = v })
    when 'd' then args << R_RefD(->(v) { doubles[k] = v })
    when 'k'
      ints[k] = 0x55
      args << R_RefI(->(v) { ints[k] = ((v + 0x80) & 0xFF) - 0x80 })
    when 's', 'c'
      bufs[k] = R_Buf_i(64)
      bufs[k].B.fill(0x55)
      args << bufs[k]
    end
  end
  r = R_sscanf(inp, fmt, *args)
  parts = +''
  types.each_char.with_index do |t, k|
    parts << case t
             when 'i', 'n', 'u', 'k' then ints[k].to_s
             when 'l' then longs[k].to_s
             when 'f' then format('%08x', Cpp.float_bytes(floats[k]).unpack1('L<'))   # pack('e') would drop a NaN's sign
             when 'd' then format('%016x', bits(doubles[k]))
             else hexs(bufs[k].B[0, 12].pack('C*'))
             end
    parts << ' '
  end
  want = "#{f[3]}\t#{f[4] || ''}"
  [want, "#{r}\t#{parts}"]
end

# ------------------------------------------------------------------------------------------------ misc
# kind hex(input) result
def misc_case(f)
  raw = unhex(f[1])
  s = lit(raw)
  e = CPtr_op_Add_CPtr_i(s, raw.bytesize)
  k = f[0]
  got = case k
        when 'fci', 'fcu', 'fcl'
          v = Cpp::Cell.new(k == 'fcl' ? 0x5555555555555555 : 0x55555555)
          r = send(k == 'fci' ? :Std_from_chars_CPtr_CPtr_ir : (k == 'fcu' ? :Std_from_chars_CPtr_CPtr_ur : :Std_from_chars_CPtr_CPtr_lr), s, e, v)
          "#{r.ec} #{CPtr_Diff(r.ptr, s)} #{v.v}"
        when 'fcd'
          v = Cpp::Cell.new(0.25)
          r = Std_from_chars_CPtr_CPtr_dr(s, e, v)
          format('%d %d %016x', r.ec, CPtr_Diff(r.ptr, s), bits(v.v))
        when 'strtol'
          en = Cpp::Cell.new(s)
          v = R_strtol(s, en, 10)
          "#{v} #{CPtr_Diff(en.v, s)}"
        when 'atoi' then R_atoi(s).to_s
        when 'atol' then R_atol(s).to_s
        when 'strtod'
          en = Cpp::Cell.new(s)
          v = R_strtod_CPtr_CPtrr(s, en)
          format('%016x %d', bits(v), CPtr_Diff(en.v, s))
        when 'ctime'
          p = R_ctime_Ptrl(NewPtrL_TA_l([raw.to_i], 0))
          hexs(p.B[p.O, R_strlen(p)].pack('C*'))
        when 'nprocs' then Sys_hardware_concurrency().to_s
        when 'ctype'
          c = raw.to_i
          format('%d%d%d%d%d%d%d%d%d %d %d', R_isdigit(c), R_isalpha(c), R_isalnum(c), R_isspace(c), R_isupper(c),
                 R_islower(c), R_ispunct(c), R_isprint(c), R_isxdigit(c), R_toupper(c), R_tolower(c))
        else raise ArgumentError, k
        end
  got += "  (#{k} #{raw.inspect})" if got != f[2]
  [f[2], got]
end

# ------------------------------------------------------------------------------------------------ libm
FN = %w[atan2 cbrt cosh sinh tanh log2 expm1 log1p hypot fmod remainder round nextafter exp log pow sin cos tan asin
        acos atan log10 floor ceil trunc sqrt].freeze
F = [->(x, y) { Math_Atan2_d(x, y) }, ->(x, _) { Math_Cbrt_d(x) }, ->(x, _) { Math_Cosh_d(x) },
     ->(x, _) { Math_Sinh_d(x) }, ->(x, _) { Math_Tanh_d(x) }, ->(x, _) { Math_Log2_d(x) }, ->(x, _) { LibM_expm1(x) },
     ->(x, _) { LibM_log1p(x) }, ->(x, y) { LibM_hypot(x, y) }, ->(x, y) { LibM_fmod(x, y) },
     ->(x, y) { LibM_remainder(x, y) }, ->(x, _) { LibM_round(x) }, ->(x, y) { LibM_nextafter(x, y) },
     ->(x, _) { Math_Exp_d(x) }, ->(x, _) { Math_Log_d(x) }, ->(x, y) { Math_Pow_d(x, y) },
     ->(x, _) { Math_Sin_d(x) }, ->(x, _) { Math_Cos_d(x) }, ->(x, _) { Math_Tan_d(x) }, ->(x, _) { Math_Asin_d(x) },
     ->(x, _) { Math_Acos_d(x) }, ->(x, _) { Math_Atan_d(x) }, ->(x, _) { Math_Log10_d(x) },
     ->(x, _) { Math_Floor_d(x) }, ->(x, _) { Math_Ceiling_d(x) }, ->(x, _) { Math_Truncate_d(x) },
     ->(x, _) { x > 0.0 ? Math.sqrt(x) : Math_Sqrt_d(x) }].freeze
NSPEC = 24

def show(x)
  b = bits(x)
  return (b >> 63 == 1 ? '-nan' : 'nan') + (b & 0x7FFFFFFFFFFFFFFF == 0x7FF8000000000000 ? '' : format('(0x%x)', b & 0xFFFFFFFFFFFFF)) if x.nan?
  return b >> 63 == 1 ? '-0' : '0' if x == 0.0
  x.inspect
end

def ulps(a, b)
  ia = [a].pack('E').unpack1('q<')
  ib = [b].pack('E').unpack1('q<')
  ia = -(1 << 63) - ia if ia < 0
  ib = -(1 << 63) - ib if ib < 0
  (ia - ib).abs
end

def libm(n)
  $stdin.binmode
  per = n + NSPEC * NSPEC
  puts format('%-10s %8s %10s %9s %8s %10s  %s', 'function', 'cases', 'mismatch', 'NaN-sign', 'max ulp', 'special',
              'first mismatch (x, y: glibc vs Ruby)')
  total = 0
  FN.each_with_index do |name, fi|
    data = $stdin.read(per * 24)
    abort 'short input' if data.nil? || data.bytesize < per * 24
    fn = F[fi]
    bad = nan_sign = maxu = sbad = 0
    nan_num = false
    first = ''
    vals = data.unpack('EEQ<' * per)
    per.times do |k|
      x = vals[3 * k]
      y = vals[3 * k + 1]
      want = vals[3 * k + 2]
      got = bits(fn.call(x, y))
      next if got == want
      bad += 1
      sbad += 1 if k >= n
      w = frombits(want)
      g = frombits(got)
      if w.nan? && g.nan? then nan_sign += 1
      elsif !w.nan? && !g.nan? then maxu = [maxu, ulps(w, g)].max
      else nan_num = true
      end
      first = "#{show(x)}, #{show(y)}: #{show(w)} vs #{show(g)}" if first.empty?
    end
    total += bad
    puts format('%-10s %8d %10d %9d %8s %10d  %s', name, per, bad, nan_sign, nan_num ? 'NaN/num' : maxu.to_s, sbad, first)
  end
  puts "total mismatches: #{total}"
end

# ------------------------------------------------------------------------------------------------ units
$un = 0
$ubad = 0

def check(name, ok, *detail)
  $un += 1
  return if ok
  $ubad += 1
  puts "FAIL #{name} #{detail.inspect}"
end

def units
  # sscanf into pointer parameters: the stash and R_Back, as the engine's parsers use them
  v = Cpp::Cell.new(-9)
  flag = Cpp::Cell.new('q'.ord)
  r = R_Back_i_T1r_T2r__LB(R_sscanf(R_Lit('123 Y'), R_Lit('%ld %c'), Cpp::R_Slot, Cpp::R_Slot), v, flag)
  check('slot %ld %c', r == 2 && v.v == 123 && flag.v == 'Y'.ord, r, v.v, flag.v)
  v.v = -9
  flag.v = 'q'.ord
  r = R_Back_i_T1r_T2r__LB(R_sscanf(R_Lit('77'), R_Lit('%ld %c'), Cpp::R_Slot, Cpp::R_Slot), v, flag)
  check('slot partial', r == 1 && v.v == 77 && flag.v == 'q'.ord, r, v.v, flag.v)
  x = Cpp::Cell.new(99.99)
  r = R_Back_i_T1r__B(R_sscanf(R_Lit('1.5 X'), R_Lit('%f %c'), R_RefF(->(s) { x.v = s }), Cpp::R_Slot), flag)
  check('RefF + slot', r == 2 && x.v == 1.5 && flag.v == 'X'.ord, r, x.v, flag.v)
  h = Cpp::Cell.new(0)
  r = R_Back_i_T1r__S(R_sscanf(R_Lit('-12'), R_Lit('%d'), Cpp::R_Slot), h)
  check('slot converted', r == 1 && h.v == -12, r, h.v)
  d = Cpp::Cell.new(0.0)
  r = R_Back_i_T1r__D(R_sscanf(R_Lit('2.5'), R_Lit('%lf'), Cpp::R_Slot), d)
  check('slot double', r == 1 && d.v == 2.5, r, d.v)
  s1 = R_Buf_i(80)
  r = R_sscanf(R_Lit('  SWMM5 x'), R_Lit('%s'), s1)
  check('%s CPtr', r == 1 && R_strcmp(s1, R_Lit('SWMM5')) == 0, r)
  ci = Cpp::Cell.new(0)
  cd = Cpp::Cell.new(0.0)
  r = R_sscanf(R_Lit('7 0.5'), R_Lit('%d %lf'), ci, cd)
  check('Ref cells as targets', r == 2 && ci.v == 7 && cd.v == 0.5, r, ci.v, cd.v)
  pb = NewPtrB_TA_l([0] * 16, 2)
  r = R_sscanf(R_Lit('abc'), R_Lit('%s'), pb)
  check('%s into a char array pointer', r == 1 && pb.a[2] == 'a'.ord && pb.a[4] == 'c'.ord && pb.a[5] == 0, r)
  lb = Cpp::CPtr.new([0] * 8, 0)
  r = R_sscanf(R_Lit("xy\xE9"), R_Lit('%s'), lb)
  check('%s into a byte buffer', r == 1 && lb.B[0, 4] == [120, 121, 0xE9, 0], lb.B)

  # strtod details: hex floats, NaN payloads, the end pointer, ERANGE
  en = Cpp::Cell.new(Cpp::CPtr_ZERO)
  s = R_Lit('  0x1.8p1rest')
  check('strtod hex', R_strtod_CPtr_CPtrr(s, en) == 3.0 && CPtr_Diff(en.v, s) == 9)
  check('strtod nan payload', bits(R_strtod_CPtr(R_Lit('nan(0x5)'))) == 0x7ff8000000000005)
  check('strtod -nan', bits(R_strtod_CPtr(R_Lit('-nan'))) == 0xfff8000000000000)
  s = R_Lit('abc')
  check('strtod no number', R_strtod_CPtr_CPtrr(s, en) == 0.0 && CPtr_op_Eq(en.v, s))
  check('strtod huge exponent', R_strtod_CPtr(R_Lit('1e99999999999')) == Float::INFINITY &&
        R_strtod_CPtr(R_Lit('1e-99999999999')) == 0.0)
  er = []
  [['1e999', 1], ['-1e999', 1], ['1e-400', 1], ['2.2250738585072011e-308', 1], ['2.22507385850720138e-308', 0],
   ['2.2250738585072014e-308', 0], ['4.9e-324', 1], ['1.5', 0], ['0', 0], ['0e-999', 0], ['0x1p-1080', 1],
   ['0x1p99999', 1], ['inf', 0], ['abc', 0], ['4.940656458412465441765687928682213723651e-324', 1],
   ['4.940656458412465441248710587739e-324', 1], ['0x3p-1074', 0], ["#{3 * 5**1074}e-1074", 0]].each do |t, w|
    R_strtod_CPtr(R_Lit(t))
    er << t if (R_get_ERange() ? 1 : 0) != w
  end
  check('strtod ERANGE', er.empty?, er)
  check('atof', R_atof(R_Lit(' -2.5e1x')) == -25.0)

  # raw memory
  b = [0]
  Mem_memcpy_PtrT_PtrU_ul__LD(NewPtrL_TA_l(b, 0), NewPtrD_TA_l([-2.75], 0), 8)
  check('memcpy double->u64 (unsigned)', b[0] == bits(-2.75), b[0])
  view = Bytes_View_PtrT__L(NewPtrL_TA_l([0x0102030405060708], 0))
  check('bytes view', view.B.length == 8 && view.B[0] == 8 && view.B[7] == 1)
  f = [0.0]
  Mem_memcpy_PtrT_CPtr_ul__D(NewPtrD_TA_l(f, 0), view, 8)
  check('memcpy CPtr->double', bits(f[0]) == 0x0102030405060708)
  c = Mem_Calloc__D(5, 8)
  check('calloc', c.a.length == 5 && c.o == 0 && c.a[4] == 0.0)
  arr = [Object.new, Object.new, Object.new]
  check('diff', Mem_Diff_T_PtrT(arr[2], NewPtr_TA_l(arr, 1)) == 1)
  u = [0, 0]
  Mem_memcpy_PtrT_PtrU_ul__IB(NewPtrI_TA_l(u, 1), NewPtrB_TA_l([1, 2, 3, 4, 5], 1), 4)
  check('memcpy bytes->u32 offset', u[0] == 0 && u[1] == 0x05040302, u)
  crc = [0]
  Mem_memcpy_PtrT_PtrU_ul__IB(NewPtrI_TA_l(crc, 0), NewPtrB_TA_l([0x01, 0x02, 0x03, 0xF4], 0), 4)
  check('memcpy uint crc (unsigned)', crc[0] == 0xF4030201, crc)
  w = [0x11111111, 0x22222222]
  Mem_memcpy_PtrT_CPtr_ul__I(NewPtrI_TA_l(w, 0), Cpp::CPtr.new([1, 2, 3, 4, 5, 6], 0), 6)
  check('memcpy partial element', w[0] == 0x04030201 && w[1] == 0x22220605, w)
  neg = [0]
  Mem_memcpy_PtrT_CPtr_ul__I(NewPtrI_TA_l(neg, 0), Cpp::CPtr.new([255, 255, 255, 255], 0), 4)
  check('memcpy int (signed)', neg[0] == -1, neg)
  zv = Bytes_View_PtrT__Z(NewPtrZ_TA_l([true, false, true], 1))
  check('bool view', zv.B.length == 2 && zv.B[0] == 0 && zv.B[1] == 1)
  dv = Bytes_View_PtrT__D(NewPtrD_TA_l([1.0, 2.0], 1))
  check('double view offset', dv.B.length == 8 && dv.B[7] == 0x40 && dv.B[6] == 0)
  sh = [0, 0]
  Mem_memcpy_PtrT_CPtr_ul__S(NewPtrS_TA_l(sh, 0), Cpp::CPtr.new([0xff, 0x7f, 0x01, 0x80], 0), 4)
  check('memcpy shorts', sh[0] == 0x7FFF && sh[1] == -0x7FFF, sh)
  fl = [0.0]
  Mem_memcpy_PtrT_CPtr_ul__F(NewPtrF_TA_l(fl, 0), Bytes_View_PtrT__F(NewPtrF_TA_l([f32(0.1)], 0)), 4)
  check('memcpy float', fl[0] == f32(0.1), fl)
  nanf = [Cpp.f32_double(frombits(0xFFF8000000000123))]
  check('float NaN bytes', Bytes_View_PtrT__F(NewPtrF_TA_l(nanf, 0)).B == [0, 0, 0xC0, 0xFF], nanf)

  # binary files
  Dir.mktmpdir('crtcheck') do |dr|
    name = R_Lit(File.join(dr, 't.bin'))
    fp = R_fopen(name, R_Lit('w+b'))
    Mem_fwrite_CPtr_ul_ul_CFile(R_Lit('STAMP'), 1, 5, fp)
    R_fwriteI1(42, fp)
    pos = R_ftell(fp)
    R_fwriteD1(3.5, fp)
    R_fwriteF1(0.25, fp)
    Mem_fwrite_PtrT_ul_ul_CFile__I(NewPtrI_TA_l([7, -8, 9], 0), 4, 3, fp)
    R_fseek_CFile_l_i(fp, pos, 0)
    R_fwriteD1(4.5, fp)
    R_rewind(fp)
    stamp = R_BufOf(16, [])
    got = Mem_fread_CPtr_ul_ul_CFile(stamp, 1, 5, fp)
    i = Cpp::Cell.new(0)
    d = Cpp::Cell.new(0.0)
    fl = Cpp::Cell.new(0.0)
    ok = got == 5 && R_strncmp(stamp, R_Lit('STAMP'), 5) == 0 && R_freadI1(i, fp) == 1 && i.v == 42 &&
         R_freadD1(d, fp) == 1 && d.v == 4.5 && R_freadF1(fl, fp) == 1 && fl.v == 0.25
    check('binary round trip', ok, got, i.v, d.v, fl.v)
    ints = [0] * 4
    k = Mem_fread_PtrT_ul_ul_CFile__I(NewPtrI_TA_l(ints, 0), 4, 4, fp)
    check('short fread', k == 3 && ints[0, 3] == [7, -8, 9] && R_feof(fp) == 1, k, ints)
    check('fgetc at end', R_fgetc(fp) == -1)
    check('ftell at end', R_ftell(fp) == 5 + 4 + 8 + 4 + 12)
    check('fseek negative', R_fseek_CFile_l_i(fp, -1, 0) == -1)
    check('fseek end', R_fseek_CFile_l_i(fp, -4, 2) == 0 && R_ftell(fp) == 29 && R_feof(fp) == 0)
    last = Cpp::Cell.new(0)
    check('fread after seek', R_freadI1(last, fp) == 1 && last.v == 9)
    check('fclose', R_fclose(fp) == 0)
    fp = R_fopen(name, R_Lit('r'))
    line = R_Buf_i(8)
    check('fgets', !R_fgets(line, 4, fp).get_IsNull && R_strcmp(line, R_Lit('STA')) == 0)
    part = [0x11111111, 0x22222222]
    R_fseek_CFile_l_i(fp, -6, 2)
    pk = Mem_fread_PtrT_ul_ul_CFile__I(NewPtrI_TA_l(part, 0), 4, 2, fp)
    check('fread partial element', pk == 1 && part[0] == 0x0009FFFF && part[1] == 0x22220000 && R_feof(fp) == 1, pk, part)
    R_fclose(fp)
    check('fopen missing', R_fopen(R_Lit(File.join(dr, 'none')), R_Lit('r')).nil?)
    dfp = R_fopen(R_Lit(dr), R_Lit('r'))
    dline = R_Buf_i(8)
    check('fopen directory', !dfp.nil? && R_fgets(dline, 8, dfp).get_IsNull && R_feof(dfp) == 0 && R_ferror(dfp) == 1 &&
          R_fgetc(dfp) == -1 && R_feof(dfp) == 0 && R_fclose(dfp) == 0 && R_fopen(R_Lit(dr), R_Lit('r+')).nil? &&
          R_fopen(R_Lit(dr), R_Lit('w')).nil?)
    check('ferror of a file', R_ferror(R_fopen(name, R_Lit('r'))) == 0)
    check('fopen bad mode', R_fopen(name, R_Lit('x')).nil?)
    an = R_Lit(File.join(dr, 'a.txt'))
    fp = R_fopen(an, R_Lit('w'))
    R_fprintf(fp, R_Lit("one\n"))
    R_fclose(fp)
    fp = R_fopen(an, R_Lit('a'))
    check('append position', R_ftell(fp) == 4)
    check('append no seek back', R_fseek_CFile_l_i(fp, 0, 0) == -1)
    R_fprintf(fp, R_Lit("two\n"))
    R_fclose(fp)
    check('append content', File.binread(File.join(dr, 'a.txt')) == "one\ntwo\n")
    tn = File.join(dr, 'l.txt')
    File.binwrite(tn, "ab\ncdef\ng")
    fp = R_fopen(R_Lit(tn), R_Lit('r'))
    lb = R_Buf_i(16)
    got = []
    got << [R_Str(lb), R_feof(fp)] until R_fgets(lb, 4, fp).get_IsNull
    check('fgets lines', got == [["ab\n", 0], ['cde', 0], ["f\n", 0], ['g', 1]] && R_feof(fp) == 1, got)
    R_fclose(fp)
    fp = R_fopen(R_Lit(File.join(dr, 't.txt')), R_Lit('w'))
    R_fprintf(fp, R_Lit("%-6s|%3d|%5.2f|%c|%zu|%s|%d|%hu|%u|%c|%d|%s|%x|%ld|%lld|%.3f\n"), R_Lit('ab'), I8(-5),
              F32(1.25), U8('Z'.ord), U64((1 << 64) - 1), NewStr_CPtr(R_Lit('str')), 7, U16(65535), U32(0xFFFFFFFF),
              Ch('q'.ord), true, 'rbstr', I16(-1), I64(-(1 << 63)), U64(1 << 63), 2)
    R_FlushAll()
    R_fclose(fp)
    txt = File.binread(File.join(dr, 't.txt'))
    check('fprintf argument kinds', txt == 'ab    | -5| 1.25|Z|18446744073709551615|str|7|65535|4294967295|q|1' \
                                          "|rbstr|ffffffff|-9223372036854775808|-9223372036854775808|2.000\n", txt)
    check('fprintf null file', R_fprintf(nil, R_Lit('x')) == -1)
    sb = R_Buf_i(8)
    check('snprintf truncation', R_snprintf_CPtr_ul_CPtr_oA(sb, 4, R_Lit('%d'), 123_456) == 6 && R_strcmp(sb, R_Lit('123')) == 0)
    check('snprintf size 0', R_snprintf_CPtr_ul_CPtr_oA(sb, 0, R_Lit('%s'), R_Lit('abc')) == 3 && R_strcmp(sb, R_Lit('123')) == 0)
    check('remove', R_remove(an) == 0 && R_remove(an) == -1)
    check('File.Exists', File_Exists(File.join(dr, 't.txt')) && !File_Exists(dr) && !File_Exists(''))
    check('printf nan/inf', R_Format(R_Lit('%f %+.2e %5.1f %G %a'), [Cpp::DNAN, Float::INFINITY, -Float::INFINITY, Cpp::QNAN, -0.0]) ==
          '-nan +inf  -inf NAN -0x0p+0')
  end

  # tuples, atomics, variants, once
  t1 = [1.0, 2.0]
  t2 = [1.0, 2.0]
  a = NewTupN_oA(1, 2.5, NewPtrD_TA_l(t1, 0), true, 3)
  b = NewTupN_oA(1, 2.5, NewPtrD_TA_l(t1, 0), true, 3)
  c = NewTupN_oA(1, 2.5, NewPtrD_TA_l(t2, 0), true, 3)
  d = NewTupN_oA(1, 2.5, NewPtrD_TA_l(t1, 0), true, 4)
  check('tuple equal', a.CompareTo(b) == 0 && a.Equals(b) && a.eql?(b) && a.hash == b.hash)
  check('tuple identity', a.CompareTo(c) != 0 && a.CompareTo(c) == -c.CompareTo(a))
  check('tuple order', a.CompareTo(d) < 0 && d.CompareTo(a) > 0 && a < d && a.is_a?(Cpp::ICopy))
  m = NewAtomicL()
  check('fetch_add', m.fetch_add(5, 0) == 0 && m.fetch_add(2, 0) == 5 && m.v == 7)
  fa = NewAtomicD_T(1.5)
  old = Cpp::Cell.new(1.0)
  ok1 = fa.compare_exchange(old, 3.0)
  ok2 = fa.compare_exchange(old, 3.0)
  check('compare_exchange', !ok1 && old.v == 1.5 && ok2 && fa.v == 3.0)
  z = NewAtomicZ_T(true)
  z.v = false
  check('atomic bool', !z.v && !z.Clone.v && z.is_a?(Cpp::ICopy))
  ul = NewAtomicL_T((1 << 64) - 1)
  ul.fetch_add(1, 0)
  check('atomic ulong wraps', ul.v == 0, ul.v)
  sl = NewAtomicL_T(-1)
  sl.fetch_add(1, 0)
  check('atomic long', sl.v == 0)
  v = NewVariant()
  check('variant default', v.v == false && v.idx == 0)
  s = NewStr_CPtr(R_Lit('abc'))
  v.Set_Str(s)
  s.append_i('d'.ord)
  w = v.Clone
  check('variant string', v.idx == 3 && v.v.ToString == 'abc' && !w.v.equal?(v.v) && w.v.ToString == 'abc')
  v.Set_d(2.5)
  check('variant double', v.idx == 2 && v.v == 2.5 && v.index == 2)
  once = NewOnceFlag()
  calls = [0]
  inc = -> { calls[0] += 1 }
  Std_call_once(once, inc)
  Std_call_once(once, inc)
  check('call_once', calls[0] == 1)
  x = Cpp::Cell.new(1)
  y = Cpp::Cell.new(2)
  Std_swap__I(x, y)
  check('swap', x.v == 2 && y.v == 1)
  da = [1.0, 2.0]
  Std_swap__D(Cpp::ArrRef.new(da, 0), Cpp::ArrRef.new(da, 1))
  check('swap array elements', da == [2.0, 1.0])
  t0 = TimePoint_now()
  check('duration', TimePoint_op_Sub(TimePoint_now(), t0).Clone.count >= 0 && Cpp::TimePoint_ZERO.ns == 0)
  check('qnan', bits(Cpp::Std_QNaN) == 0x7FF8000000000000)
  check('nop', Std_Nop(3) == 0)
  pr = NewPair_A_B(4, 0.5)
  check('get0/get1', Std_get0_PairAB__ID(pr) == 4 && Std_get1_PairAB__ID(pr) == 0.5)
  thrown = begin
    Std_Rethrow(IOError.new('x'))
    false
  rescue IOError
    true
  end
  check('Rethrow', thrown)
  ec = NewErrorCode()
  ec.v = 2
  check('error_code', ec.Bool && ec.message.ToString == 'No such file or directory')
  se = Cpp::SysException.new('NotImplementedException', 'm')
  check('SysException', se.message == 'm' && se.kind == 'NotImplementedException' && !se.is_a?(Cpp::CppException) &&
        se.is_a?(StandardError))
  check('locks', NewThread().joinable == false && !NewMutex().nil? && !NewCondVar().nil? && !NewLock().nil?)
  check('hardware_concurrency', Sys_hardware_concurrency() == Etc.sysconf(Etc::SC_NPROCESSORS_ONLN))

  # math corners
  inf = Float::INFINITY
  check('CopySign NaN sign', Math_CopySign_d(1.0, Cpp::DNAN) == -1.0)
  check('Truncate', Math_Truncate_d(-2.7) == -2.0 && bits(Math_Truncate_d(-0.5)) == 0x8000000000000000)
  check('Ceiling -0', bits(Math_Ceiling_d(-0.5)) == 0x8000000000000000 && Math_Ceiling_d(0.2) == 1.0)
  check('Floor', bits(Math_Floor_d(-0.0)) == 0x8000000000000000 && Math_Floor_d(-0.5) == -1.0 &&
        Math_Floor_d(inf) == inf && Math_Floor_d(1e300) == 1e300)
  check('round', LibM_round(2.5) == 3.0 && LibM_round(-2.5) == -3.0 && LibM_round(0.49999999999999994) == 0.0 &&
        bits(LibM_round(-0.4)) == 0x8000000000000000 && LibM_lround(-2.5) == -3)
  check('pow errors', Math_Pow_d(0.0, -1.0) == inf && Math_Pow_d(-0.0, -3.0) == -inf &&
        bits(Math_Pow_d(-8.0, 1.0 / 3)) == 0xFFF8000000000000 && Math_Pow_d(10.0, 400.0) == inf &&
        Math_Pow_d(-10.0, 401.0) == -inf)
  check('log errors', Math_Log_d(0.0) == -inf && Math_Log_d(-1.0).nan? && Math_Log10_d(-0.0) == -inf)
  check('exp overflow', Math_Exp_d(1000.0) == inf && Math_Cosh_d(1000.0) == inf && Math_Sinh_d(-1000.0) == -inf)
  check('sqrt', bits(Math_Sqrt_d(-1.0)) == 0xFFF8000000000000 && Math_Sqrt_d(4.0) == 2.0 &&
        bits(Math_Sqrt_d(Cpp::QNAN)) == 0x7FF8000000000000 && bits(Math_Sqrt_d(-0.0)) == 0x8000000000000000)
  check('Log2 powers', Math_Log2_d(1024.0) == 10.0 && Math_Log2_d(5e-324) == -1074.0 && Math_Log2_d(1.0) == 0.0)
  check('Max/Min', bits(Math_Max_d_d(-0.0, 0.0)) == 0 && bits(Math_Min_d_d(0.0, -0.0)) == 0x8000000000000000 &&
        Math_Max_d_d(Cpp::QNAN, 1.0).nan? && Math_Min_d_d(1.0, Cpp::QNAN).nan?)

  # char arrays and strings
  p = R_LitN('OPENSWMM_HS_V1', 16)
  check('LitN', p.B.length == 16 && p.B[14] == 0 && p.B[15] == 0)
  q = R_CopyBuf(p)
  q.B[0] = 'X'.ord
  check('CopyBuf', p.B[0] == 'O'.ord && q.O == p.O)
  dst = R_BufOf(6, ['a'.ord, 'b'.ord])
  check('BufOf', dst.B == [97, 98, 0, 0, 0, 0])
  check('bufs', R_Bufs(5, 24).length == 5 && R_Bufs(5, 24)[4].B.length == 24)
  tp = NewPtrL_TA_l([0], 0)
  t = R_time_Ptrl(tp)
  check('time', t > 1_700_000_000 && tp.a[0] == t && R_difftime(t + 3, t) == 3.0 && R_time_Ptrl(Cpp::PtrL_ZERO) >= t)
  check('strcmp unsigned', R_strcmp(Cpp::CPtr.new([0xE9, 0], 0), R_Lit('e')) > 0 &&
        R_strcmp(R_Lit('ab'), R_Lit('abc')) == -'c'.ord && R_strcmp(Cpp::CPtr.new([97, 0], 0), R_Lit('a')) == 0)
  hay = R_Lit('a,b,,c')
  check('strchr', CPtr_Diff(R_strchr(hay, ','.ord), hay) == 1 && CPtr_Diff(R_strchr(hay, 0), hay) == 6 &&
        R_strchr(hay, 'z'.ord).get_IsNull)
  check('strrchr', CPtr_Diff(R_strrchr(hay, ','.ord), hay) == 4 && R_strrchr(hay, 'z'.ord).get_IsNull)
  check('strstr', CPtr_Diff(R_strstr(hay, R_Lit(',,')), hay) == 3 && R_strstr(hay, R_Lit('x')).get_IsNull &&
        CPtr_op_Eq(R_strstr(hay, R_Lit('')), hay))
  check('strcspn', R_strcspn(hay, R_Lit(',')) == 1 && R_strcspn(R_Lit('abc'), R_Lit('x')) == 3)
  toks = []
  tk = R_strtok(hay, R_Lit(','))
  until tk.get_IsNull
    toks << R_Str(tk)
    tk = R_strtok(Cpp::CPtr_ZERO, R_Lit(','))
  end
  check('strtok', toks == %w[a b c], toks)
  cat = R_Buf_i(16)
  R_strcpy(cat, R_Lit('ab'))
  R_strcat(cat, R_Lit('cd'))
  check('strcpy/strcat', R_Str(cat) == 'abcd' && R_strlen(cat) == 4)
  R_strcpy(CPtr_op_Add_CPtr_i(cat, 1), cat)
  check('strcpy overlap', R_Str(cat) == 'aabcd')
  check('toupper', R_toupper('a'.ord) == 'A'.ord && R_toupper('{'.ord) == '{'.ord)
  check('atoi wrap', R_atoi(R_Lit('4294967297')) == 1 && R_atoi(R_Lit('99999999999999999999')) == -1)
  check('to_string(double)', Str_to_string_d(1.0 / 3).ToString == '0.333333' && Str_to_string_d(-2.5e-7).ToString == '-0.000000')
  puts "units cases: #{$un}, failures: #{$ubad}"
end

case ARGV[0]
when 'libm' then libm(ARGV[1].to_i)
when 'printf' then lines('printf') { |f| printf_case(f) }
when 'scanf' then lines('scanf') { |f| scanf_case(f) }
when 'misc' then lines('misc') { |f| misc_case(f) }
when 'units' then units
else abort 'crtcheck.rb: libm N | printf | scanf | misc | units'
end
R_FlushAll()
