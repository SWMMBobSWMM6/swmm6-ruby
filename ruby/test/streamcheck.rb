# encoding: binary
# frozen_string_literal: false
# streamcheck.rb - the cases of tests/stdcheck/streamcheck.cpp / streamcheck.cs through the Ruby runtime's streams and
# file system (ruby/cpp/streams.rb, fs.rb, rfs.rb), statement for statement as tests/stdcheck/streamcheck_py/
# streamcheck.py. Section a must equal the C# output (and the C++ output but for the one glibc %#g quirk line);
# section b the C# output (the C# port's own behaviour); section c the C++ and C# outputs.
# Run from a folder that has a build/ subfolder (paths are relative to it): ruby streamcheck.rb a|b|c
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
require_relative '../cpp/cpp'

$sb = +''
def bits(u) = [u].pack('Q<').unpack1('E')
def st(s) = (s.good ? 'g' : '-') + (s.eof ? 'e' : '-') + (s.fail_ ? 'f' : '-') + (s.bad ? 'b' : '-')

def g(v)
  o = NewOStringStream()
  o.Put_d(v)
  o.str_.ToString
end

def s(x) = Cpp.str_of(x)
def b(x) = x ? '1' : '0'
def w(x) = $sb << x.b
def t(x) = x.ToString.b
def c(ch) = ch.ord
def ec(e) = "#{e.v} (#{t(e.message)})"
def cell(v) = Cpp::Cell.new(v)

def sec_c
  f = NewIFStream_Str_i(s('build/streamcheck.bin'), Ios_in | Ios_binary)
  bb = [0]
  f.read_PtrT_l__I(NewPtrI_TA_l(bb, 0), 4)
  f.seekg(4, Ios_cur)
  f.read_PtrT_l__I(NewPtrI_TA_l(bb, 0), 4)
  w("cur at8 #{bb[0]} tellg #{f.tellg} #{st(f)}\n")
end

def sec_a
  vals = [0.0, bits(0x8000000000000000), 1.0, -1.0, 0.1, 0.5, 1.5, 2.5, 123.456, 1e-5, 1.23456789e-7, 1e21,
          1.7976931348623157e308, bits(1), 2.2250738585072014e-308, 1.0 / 3.0, 2.0 / 3.0, 100.0, 1e15,
          123_456_789_012_345_678.0, 0.000123456, 9.999999, 99.995, 0.125, bits(0x7ff8000000000000),
          bits(0x7ff0000000000000), bits(0xfff0000000000000), 1e100, 5e-310, 3.14159265358979, -0.0004567, 1_234_567.0,
          0.95, 0.05, 1e-300, 6.02214076e23]
  precs = [0, 1, 2, 3, 4, 6, 8, 10, 15, 16, 17, 20, -1]
  vals.each do |v|
    4.times do |mode|
      2.times do |sp|
        precs.each do |p|
          next if mode == 3 && p != 6
          o = NewOStringStream()
          o.Manip_fixed if mode == 1
          o.Manip_scientific if mode == 2
          o.setf_i_i(Ios_fixed | Ios_scientific, Ios_floatfield) if mode == 3
          o.Manip_showpoint if sp == 1
          o.precision_l(p)
          o.Put_d(v)
          w("d #{mode}#{sp} #{p} [#{t(o.str_)}]\n")
        end
      end
    end
    f = NewOStringStream()
    f.Put_f(f32(v))
    w("f [#{t(f.str_)}]\n")
  end
  o = NewOStringStream()
  o.Put_c(c('[')).Manip_setw(10).Put_d(3.5).Put_CPtr(R_Lit('][')).Manip_left.Manip_setw(8).Manip_setfill(c('*')).Put_i(-42).Put_c(c(']'))
  o.Put_c(c('[')).Manip_right.Manip_setw(6).Put_CPtr(R_Lit('ab')).Put_CPtr(R_Lit('][')).Manip_setw(2).Put_CPtr(R_Lit('abcdef')).Put_c(c(']'))
  o.Put_c(c('[')).Manip_setw(5).Manip_setfill(c('0')).Put_u(7).Put_CPtr(R_Lit('][')).Put_i(123).Put_c(c(']'))
  o.Manip_boolalpha.Put_c(c('[')).Put_b(true).Put_c(c(' ')).Put_b(false).Put_c(c(']')).Manip_noboolalpha.Put_c(c('[')).Put_b(true).Put_b(false).Put_c(c(']'))
  o.Put_c(c('[')).Manip_setw(12).Manip_setfill(c(' ')).Manip_quoted_Str(s('a"b\\c')).Put_c(c(']'))
  o.Put_c(c('[')).Manip_quoted_CPtr(R_Lit('plain')).Put_c(c(']'))
  o.Put_c(c('[')).Manip_fixed.Manip_setprecision(3).Manip_setw(9).Put_d(2.0 / 3.0).Put_c(c(']'))
  o.Put_c(c('[')).Manip_defaultfloat.Manip_setprecision(4).Put_d(2.0 / 3.0).Put_c(c(']'))
  o.Put_c(c('[')).Put_l(-9_223_372_036_854_775_808).Put_c(c(' ')).Put_ul(18_446_744_073_709_551_615).Put_c(c(' ')).Put_s(-5).Put_c(c(']'))
  o.Put_c(c('[')).Put_c(c('x')).Put_c(65).Put_c(c(']'))
  w("w #{t(o.str_)}\n")

  o = NewOStringStream_Str(s('abcdef'))
  o.Put_CPtr(R_Lit('XY'))
  w("init [#{t(o.str_)}] tellp #{o.tellp}\n")
  q = NewOStringStream()
  q.Put_CPtr(R_Lit('hello world'))
  q.seekp(6)
  q.Put_CPtr(R_Lit('W'))
  q.seekp(-1, Ios_end)
  q.Put_CPtr(R_Lit('D'))
  q.seekp(2, Ios_beg)
  q.seekp(1, Ios_cur)
  q.Put_CPtr(R_Lit('L'))
  w("seekp [#{t(q.str_)}] tellp #{q.tellp}\n")

  is = NewIStringStream_Str(s("  3.25 -7 abc\nline two\n\nlast"))
  d = cell(-1.0)
  i = cell(-1)
  sv = NewStr()
  is.Get_dr(d)
  w("x d #{g(d.v)} #{st(is)}\n")
  is.Get_ir(i)
  w("x i #{i.v} #{st(is)}\n")
  is.Get_Str(sv)
  w("x s #{t(sv)} #{st(is)}\n")
  line = NewStr()
  4.times do
    Streams_getline_IStream_Str(is, line)
    w("x line [#{t(line)}] #{st(is)}\n")
  end

  is = NewIStringStream_Str(s('12 4294967296 -2147483648 2147483648 -9223372036854775808 9000000000000000000 4294967295 7'))
  a = cell(-1)
  bb = cell(-1)
  cc = cell(-1)
  e = cell(-1)
  is.Get_ir(a).Get_ir(bb)
  w("x ints #{a.v} #{bb.v} #{st(is)}\n")
  is.clear
  is.Get_ir(cc).Get_ir(e)
  w("x ints #{cc.v} #{e.v} #{st(is)}\n")
  is.clear
  l = cell(-1)
  is.Get_lr(l)
  w("x long #{l.v} #{st(is)}\n")
  is.clear
  u8 = cell(0)
  u4 = cell(0)
  is.Get_ulr(u8)
  w("x ulong #{u8.v} #{st(is)}\n")
  is.clear
  is.Get_ur(u4)
  w("x uint #{u4.v} #{st(is)}\n")

  is = NewIStringStream_Str(s('a,b,,c'))
  f = NewStr()
  w("x field [#{t(f)}] #{st(is)}\n") while Streams_getline_IStream_Str_c(is, f, c(',')).ok
  w("x field end #{st(is)}\n")

  is = NewIStringStream_Str(s("   \t\n  tail"))
  is.Manip_ws
  rest = NewStr()
  Streams_getline_IStream_Str(is, rest)
  w("x ws [#{t(rest)}] #{st(is)}\n")
  e2 = NewIStringStream_Str(s('   '))
  e2.Manip_ws
  w("x ws-end #{st(e2)}\n")

  is = NewIStringStream_Str(s('0123456789'))
  buf = Array.new(16, 0)
  is.read_CPtr_l(Cpp::CPtr.new(buf, 0), 4)
  w("r [#{buf[0, 4].pack('C*')}] gc #{is.gcount} #{st(is)} tellg #{is.tellg}\n")
  w("r peek #{is.peek}")
  w(" get #{is.get_}")
  w(" get #{is.get_} #{st(is)}\n")
  is.ignore(3, c('8'))
  w("r ignore tellg #{is.tellg} #{st(is)}\n")
  is.seekg(-2, Ios_cur)
  w("r seekg cur tellg #{is.tellg} get #{is.get_}\n")
  is.seekg(-3, Ios_end)
  w("r seekg end tellg #{is.tellg} get #{is.get_}\n")
  is.read_CPtr_l(Cpp::CPtr.new(buf, 0), 10)
  w("r short gc #{is.gcount} #{st(is)}\n")
  is.clear
  is.seekg(0, Ios_beg)
  w("r rewind tellg #{is.tellg} get #{is.get_} #{st(is)}\n")
  is.ignore(100, -1)
  w("r ignore-all #{st(is)}\n")
  w("r get-end #{is.get_}")
  w(" #{st(is)}\n")
  w("r str [#{t(is.str_)}]\n")

  f = NewOFStream_Str_i(s('build/streamcheck.bin'), Ios_trunc | Ios_binary)
  w("f open #{b(f.is_open)} #{st(f)}\n")
  ai = [1, -2, 300_000]
  ad = [1.5, -0.25]
  f.write_PtrT_l__I(NewPtrI_TA_l(ai, 0), 12)
  f.write_PtrT_l__D(NewPtrD_TA_l(ad, 0), 16)
  f.write_CPtr_l(R_Lit('MAGIC'), 5)
  w("f tellp #{f.tellp}\n")
  f.Put_d(3.25).Put_c(c(' ')).Put_i(42).Put_c(c("\n"))
  w("f tellp #{f.tellp}\n")
  f.close
  w("f closed #{b(f.is_open)}\n")

  f = NewOFStream_Str_i(s('build/streamcheck.bin'), Ios_app)
  f.Put_CPtr(R_Lit("tail\n"))
  f.Dispose

  f = NewIFStream_Str_i(s('build/streamcheck.bin'), Ios_in | Ios_binary)
  w("f in open #{b(f.is_open)} #{st(f)}\n")
  ai = [0, 0, 0]
  f.read_PtrT_l__I(NewPtrI_TA_l(ai, 0), 12)
  w("f ints #{ai[0]} #{ai[1]} #{ai[2]} gc #{f.gcount} tellg #{f.tellg}\n")
  ad = [0.0, 0.0]
  f.read_PtrT_l__D(NewPtrD_TA_l(ad, 0), 16)
  w("f dbl #{g(ad[0])} #{g(ad[1])} tellg #{f.tellg}\n")
  m = Array.new(6, 0)
  f.read_CPtr_l(Cpp::CPtr.new(m, 0), 5)
  w("f magic #{m[0, m.index(0)].pack('C*')}\n")
  x = cell(0.0)
  n = cell(0)
  tt = NewStr()
  f.Get_dr(x).Get_ir(n).Get_Str(tt)
  w("f text #{g(x.v)} #{n.v} #{t(tt)} #{st(f)}\n")
  f.seekg(-5, Ios_end)
  Streams_getline_IStream_Str(f, tt)
  w("f end-5 [#{t(tt)}] #{st(f)}\n")
  Streams_getline_IStream_Str(f, tt)
  w("f after #{st(f)}\n")
  f.clear
  f.seekg(0, Ios_end)
  w("f size #{f.tellg}\n")
  f.seekg(4, Ios_beg)
  bb = [0]
  f.read_PtrT_l__I(NewPtrI_TA_l(bb, 0), 4)
  w("f at4 #{bb[0]} tellg #{f.tellg}\n")
  f.seekg(1000, Ios_beg)
  f.read_PtrT_l__I(NewPtrI_TA_l(bb, 0), 4)
  w("f past-end gc #{f.gcount} #{st(f)}\n")
  f.close

  f = NewIFStream_Str_i(s('build/no-such-file.bin'), Ios_in)
  w("f missing open #{b(f.is_open)} #{st(f)}\n")
end

def sec_b
  is = NewIStringStream_Str(s("x\nlast"))
  line = NewStr()
  3.times do
    Streams_getline_IStream_Str(is, line)
    w("b line [#{t(line)}] #{st(is)}\n")
  end

  is = NewIStringStream_Str(s('12abc 99999999999999999999 18446744073709551615 -1 1e400 inf 0x1p3 -.5 1e 5'))
  i = cell(-1)
  l = cell(0)
  u8 = cell(0)
  u4 = cell(0)
  d = cell(0.0)
  is.Get_ir(i)
  w("b 12abc #{i.v} #{st(is)}\n")
  is.clear
  is.Get_lr(l)
  w("b long-over #{l.v} #{st(is)}\n")
  is.clear
  is.Get_ulr(u8)
  w("b ulong-max #{u8.v} #{st(is)}\n")
  is.clear
  is.Get_ur(u4)
  w("b uint-neg #{u4.v} #{st(is)}\n")
  is.clear
  5.times do
    is.Get_dr(d)
    w("b dbl #{g(d.v)} #{st(is)}\n")
    is.clear
  end
  is.Get_ir(i)
  w("b last #{i.v} #{st(is)}\n")
  i.v = 77
  is.Get_ir(i)
  w("b after-eof #{i.v} #{st(is)}\n")
  fl = cell(0.0)
  is.clear
  is.str_Str(s(' 0.1 '))
  is.Get_fr(fl)
  w("b float #{g(fl.v)} #{st(is)}\n")
  ch = cell(0)
  is.str_Str(s('  q'))
  is.Get_cr(ch)
  w("b char #{ch.v} #{st(is)}\n")

  f = NewOFStream_Str_i(s('build/streamcheck.bin'), Ios_app)
  w("b app tellp #{f.tellp}\n")
  f.close
  gg = NewOFStream_CPtr_i(R_Lit('build/no-dir/x.txt'), Ios_out)
  w("b bad-open #{b(gg.is_open)} #{st(gg)}\n")
  gg.Put_CPtr(R_Lit('dropped'))
  h = NewOFStream()
  w("b unopened #{b(h.is_open)} #{st(h)}\n")
  h.open_Str_i(s('build/streamcheck.txt'))
  h.Put_d(1.25).Manip_endl
  w("b reopened #{b(h.is_open)} #{st(h)} tellp #{h.tellp}\n")
  h.seekp(0, Ios_beg)
  h.Put_CPtr(R_Lit('9'))
  h.seekp(0, Ios_end)
  h.Put_CPtr(R_Lit('z'))
  h.Dispose
  r = NewIFStream_FsPath_i(NewFsPath_Str(s('build/streamcheck.txt')), Ios_in)
  tt = NewStr()
  Streams_getline_IStream_Str(r, tt)
  w("b reread [#{t(tt)}] ")
  Streams_getline_IStream_Str(r, tt)
  w("[#{t(tt)}] #{st(r)}\n")
  r.close
  dr = NewIFStream_Str_i(s('build'), Ios_in)
  w("b dir-open #{b(dr.is_open)} #{st(dr)}\n")

  o = NewOStringStream()
  o.str_Str(s('abc'))
  o.Put_CPtr(R_Lit('XY'))
  w("b str-set [#{t(o.str_)}] tellp #{o.tellp}\n")
  o.precision_l(3)
  o2 = NewOStringStream()
  o2.MoveFrom(o)
  o2.Put_d(1.0 / 3.0)
  o.Put_CPtr(R_Lit('q'))
  w("b moved [#{t(o2.str_)}] [#{t(o.str_)}]\n")
  i1 = NewIStringStream_Str(s('one two'))
  wd = NewStr()
  i1.Get_Str(wd)
  i2 = NewIStringStream()
  i2.MoveFrom(i1)
  i2.Get_Str(wd)
  w("b imoved [#{t(wd)}] #{st(i2)} str [#{t(i2.str_)}]\n")
  p = NewOStringStream()
  p.Put_d(1.5).Manip_scientific.Put_d(1.5).Manip_fixed.Put_d(1.5).Manip_defaultfloat.Put_d(1.5).Manip_showpoint.Put_d(1.5).Manip_noshowpoint.Put_d(1.5)
  p.Put_SetW(NewSetW(6)).Put_SetFill(NewSetFill(c('.'))).Put_SetPrec(NewSetPrec(2)).Put_d(3.14159).Put_SetW(Streams_setw(4)).Put_SetFill(Streams_setfill(c('#'))).Put_i(1)
  p.setf_i_i(Ios_left, Ios_adjustfield)
  p.width_l(5)
  p.Put_CPtr(R_Lit('ab'))
  p.unsetf(Ios_left)
  p.width_l(5)
  p.Put_CPtr(R_Lit('cd'))
  p.Put_f(f32(f32(1.0) / f32(3.0))).Put_uc(66).Put_u((2_147_483_647 * 2) & 0xFFFFFFFF)
  w("b manip [#{t(p.str_)}] w #{p.width_} f #{p.fill_} p #{p.precision_}\n")

  fs = NewFStream(s('build/streamcheck.fs'), Ios_in | Ios_out)
  fs.Put_CPtr(R_Lit('fstream'))
  w("b fstream #{b(fs.is_open)} tellp #{fs.tellp}\n")
  fs.close

  paths = ['', '/', 'a', 'a/', '/a/b.c', 'a/b.tar.gz', '.hidden', 'dir/.hidden', 'a/..', '..', '.', 'a/./b/../c',
           '/../x', '//a//b//', 'a/b/', 'x.', 'dir.d/file', '/a/b/../../..', '../a/../..', './', 'a//b', '/a']
  paths.each do |ps|
    p = NewFsPath_Str(s(ps))
    w("p [#{ps}] fn [#{t(p.filename)}] par [#{t(p.parent_path)}] stem [#{t(p.stem)}] ext [#{t(p.extension)}" \
      "] abs #{b(p.is_absolute)}#{b(p.is_relative)} has #{b(p.has_filename)}#{b(p.has_parent_path)}#{b(p.has_extension)}" \
      " norm [#{t(p.lexically_normal)}] empty #{b(p.empty)}\n")
    w("  join [#{t(p.Join_FsPath(NewFsPath_Str(s('x'))))}] [#{t(p.Join_Str(s('/abs')))}] [#{t(p.Join_FsPath(NewFsPath()))}] [#{t(p.Join_CPtr(R_Lit('y/z')))}]")
    q = p.Clone
    q.replace_extension_FsPath(NewFsPath_Str(s('.out')))
    q2 = p.Clone
    q2.replace_extension_Str(s('txt'))
    q3 = p.Clone
    q3.replace_extension_FsPath
    q4 = p.Clone
    q4.replace_filename(NewFsPath_Str(s('new.inp')))
    q5 = p.Clone
    q5.remove_filename
    cs = p.c_str
    cb = cs.B[cs.O, cs.B[cs.O..].index(0)].pack('C*')
    cmpv = p.compare(NewFsPath_Str(s('a')))
    w(" rext [#{t(q)}] [#{t(q2)}] [#{t(q3)}] rfn [#{t(q4)}] rmfn [#{t(q5)}] str [#{t(p.string)}] gs [#{t(p.generic_string)}" \
      "] cs [#{cb}] cmp #{cmpv <=> 0}\n")
  end
  a = NewFsPath_Str(s('x'))
  bp = NewFsPath_CPtr(R_Lit('y'))
  a.Assign_FsPath(bp)
  bp.Assign_Str(s('w'))
  cc = NewFsPath()
  cc.MoveFrom(a)
  w("p assign [#{t(a)}] [#{t(bp)}] [#{t(cc)}] ")
  cc.clear
  w("[#{t(cc)}] #{b(cc.empty)}\n")

  dirp = NewFsPath_Str(s('build/fsdir'))
  e = NewErrorCode()
  Fs_remove_FsPath(NewFsPath_Str(s('build/fsdir/x/y/f.txt')))
  Fs_remove_FsPath(NewFsPath_Str(s('build/fsdir/x/y/g.txt')))
  Fs_remove_FsPath(NewFsPath_Str(s('build/fsdir/x/y/h.txt')))
  Fs_remove_FsPath_ErrorCode(NewFsPath_Str(s('build/fsdir/x/y')), e)
  w("fs mkdir #{b(Fs_create_directories_FsPath(NewFsPath_Str(s('build/fsdir/x/y'))))} again " \
    "#{b(Fs_create_directories_FsPath_ErrorCode(NewFsPath_Str(s('build/fsdir/x/y')), e))} #{ec(e)}\n")
  file = NewFsPath_Str(s('build/fsdir/x/y/f.txt'))
  o = NewOFStream_FsPath_i(file, Ios_out)
  o.Put_CPtr(R_Lit('0123456789'))
  o.close
  w("fs exists #{b(Fs_exists_FsPath(file))}#{b(Fs_exists_FsPath(dirp))}#{b(Fs_exists_FsPath(NewFsPath_Str(s('build/fsdir/none'))))}#{b(Fs_exists_FsPath_ErrorCode(file, e))}" \
    " reg #{b(Fs_is_regular_file_FsPath(file))}#{b(Fs_is_regular_file_FsPath(dirp))} dir #{b(Fs_is_directory_FsPath(file))}#{b(Fs_is_directory_FsPath(dirp))}\n")
  w("fs size #{Fs_file_size_FsPath(file)} ec #{Fs_file_size_FsPath_ErrorCode(file, e)} #{ec(e)}")
  w(" missing #{Fs_file_size_FsPath_ErrorCode(NewFsPath_Str(s('build/fsdir/none')), e)} #{ec(e)}")
  w(" dir #{Fs_file_size_FsPath_ErrorCode(dirp, e)} #{ec(e)}\n")
  ['build/fsdir/x/y/f.txt', 'build/fsdir', 'build/fsdir/none', '/dev/null'].each do |sp|
    s1 = Fs_status_FsPath(NewFsPath_Str(s(sp)))
    s2 = Fs_symlink_status_FsPath_ErrorCode(NewFsPath_Str(s(sp)), e)
    s3 = Fs_symlink_status_FsPath(NewFsPath_Str(s(sp)))
    w("fs status #{sp} #{s1.type} #{s2.type} #{s3.Clone.type} #{b(Fs_exists_FileStatus(s1))}#{b(Fs_is_regular_file_FileStatus(s1))}" \
      "#{b(Fs_is_directory_FileStatus(s1))}#{b(Fs_is_symlink(s1))}\n")
  end
  gp = NewFsPath_Str(s('build/fsdir/x/y/g.txt'))
  Fs_create_hard_link(file, gp, e)
  w("fs link #{ec(e)}")
  Fs_create_hard_link(file, gp, e)
  w(" again #{ec(e)}")
  Fs_create_hard_link(NewFsPath_Str(s('build/fsdir/none')), NewFsPath_Str(s('build/fsdir/x/y/n.txt')), e)
  w(" missing #{ec(e)} size #{Fs_file_size_FsPath(gp)}\n")
  hp = NewFsPath_Str(s('build/fsdir/x/y/h.txt'))
  Fs_rename_FsPath_FsPath_ErrorCode(gp, hp, e)
  w("fs rename #{ec(e)} #{b(Fs_exists_FsPath(gp))}#{b(Fs_exists_FsPath(hp))}")
  Fs_rename_FsPath_FsPath_ErrorCode(gp, hp, e)
  w(" missing #{ec(e)}")
  Fs_rename_FsPath_FsPath(hp, gp)
  w(" plain #{b(Fs_exists_FsPath(gp))}#{b(Fs_exists_FsPath(hp))}")
  Fs_rename_FsPath_FsPath_ErrorCode(gp, file, e)
  w(" over #{ec(e)} #{b(Fs_exists_FsPath(gp))}#{b(Fs_exists_FsPath(file))}\n")
  e1 = b(Fs_equivalent_FsPath_FsPath(file, NewFsPath_Str(s('./build/fsdir/x/../x/y//f.txt')))) + b(Fs_equivalent_FsPath_FsPath(file, dirp))
  e1 += "#{b(Fs_equivalent_FsPath_FsPath_ErrorCode(file, NewFsPath_Str(s('build/fsdir/none')), e))} #{ec(e)}"
  e1 += " #{b(Fs_equivalent_FsPath_FsPath_ErrorCode(file, file, e))} #{ec(e)}"
  w("fs equiv #{e1}\n")
  k1 = "#{t(Fs_canonical_FsPath_ErrorCode(NewFsPath_Str(s('build/fsdir/none')), e))}] #{ec(e)}"
  k2 = t(Fs_weakly_canonical_FsPath(NewFsPath_Str(s('build/../build/fsdir/./x/'))))
  k3 = "#{t(Fs_weakly_canonical_FsPath_ErrorCode(NewFsPath_Str(s('/a/b/../c/.')), e))}] #{ec(e)}"
  k4 = "#{t(Fs_canonical_FsPath_ErrorCode(NewFsPath_Str(s('/x/../y')), e))}] #{ec(e)}"
  k5 = t(Fs_canonical_FsPath(dirp))
  w("fs canon [#{k1} [#{k2}] [#{k3} [#{k4} [#{k5}]\n")
  w("fs abs [#{t(Fs_absolute(NewFsPath_Str(s('rel/p'))))}] [#{t(Fs_absolute(NewFsPath_Str(s('/abs/p'))))}] cwd [#{t(Fs_current_path())}" \
    "] tmp [#{t(Fs_temp_directory_path())}]\n")
  w("fs remove #{b(Fs_remove_FsPath(file))}#{b(Fs_remove_FsPath(file))}#{b(Fs_remove_FsPath(dirp))}")
  w(" ec #{b(Fs_remove_FsPath_ErrorCode(NewFsPath_Str(s('build/fsdir/x')), e))} #{ec(e)}")
  w(" #{b(Fs_remove_FsPath_ErrorCode(NewFsPath_Str(s('build/fsdir/x/y')), e))} #{ec(e)}")
  w(" #{b(Fs_remove_FsPath_ErrorCode(NewFsPath_Str(s('build/fsdir/x/y')), e))} #{ec(e)}\n")
  e2 = NewErrorCode()
  w("ec #{b(e2.Bool)} #{e2.value}")
  [13, 17, 20, 21, 95, 5].each do |v|
    e2.v = v
    w(" #{ec(e2)}")
  end
  e2.clear
  w(" #{b(e2.Bool)}\n")
end

case ARGV[0] || 'a'
when 'a' then sec_a
when 'b' then sec_b
else sec_c
end
Streams_cout.write_CPtr_l(Cpp::CPtr.new($sb.bytes, 0), $sb.bytesize)
