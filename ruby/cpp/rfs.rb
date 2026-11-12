# encoding: binary
# frozen_string_literal: true
# rfs.rb - the C library functions of cs/runtime/Fs.cs (the part of the C# partial class Cpp.R in that file): errno,
# getenv, ctype in the C locale, atol / strtol0, ferror / fileno / setvbuf (no-ops as in the C# port), rename, fgetc,
# time(object), strncpy, strncmp, memcmp, sprintf and memcpyBuf. A port of py/cpp/rfs.py (stderr and stdin are
# crt.rb's, BufOf too).
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.

module Cpp
  R_errno_ = 0

  # .NET's string of OS bytes: UTF-8, an invalid sequence replaced by U+FFFD
  REPL = "\xEF\xBF\xBD".dup.force_encoding('UTF-8').freeze
  def self.net_str(b) = b.dup.force_encoding('UTF-8').scrub(REPL)

  # R.Lit of a .NET string: each UTF-16 unit's low byte, as (byte)s[i] takes it, and a NUL
  def self.net_lit(s)
    u = s.encode('UTF-16LE').bytes
    b = Array.new(u.length / 2) { |i| u[2 * i] }
    b << 0
    CPtr.new(b, 0)
  end

  NET_ENV = [nil]

  # the environment as .NET reads it (names and values decoded from UTF-8), the first of a repeated name kept
  def self.net_environ
    e = NET_ENV[0]
    if e.nil?
      e = {}
      ENV.each_pair do |k, v|
        nk = Cpp.net_str(k.b)
        e[nk] = Cpp.net_str(v.b) unless e.key?(nk)
      end
      NET_ENV[0] = e
    end
    e
  end

  # Environment.GetEnvironmentVariable: a fresh copy of the value, or a null pointer
  def R_getenv(name)
    v = Cpp.net_environ[Cpp.net_str(Cpp.cbs(name))]
    v.nil? ? CPtr_ZERO : Cpp.net_lit(v)
  end

  # ctype in the C locale
  def R_isdigit(c) = c >= 48 && c <= 57 ? 1 : 0
  def R_isalpha(c) = (c >= 97 && c <= 122) || (c >= 65 && c <= 90) ? 1 : 0
  def R_isalnum(c) = (c >= 48 && c <= 57) || (c >= 97 && c <= 122) || (c >= 65 && c <= 90) ? 1 : 0
  def R_isspace(c) = c == 32 || (c >= 9 && c <= 13) ? 1 : 0
  def R_isupper(c) = c >= 65 && c <= 90 ? 1 : 0
  def R_islower(c) = c >= 97 && c <= 122 ? 1 : 0
  def R_isprint(c) = c >= 32 && c < 127 ? 1 : 0
  def R_isxdigit(c) = (c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70) ? 1 : 0
  def R_ispunct(c) = c > 32 && c < 127 && R_isalnum(c) == 0 ? 1 : 0
  def R_tolower(c) = c >= 65 && c <= 90 ? c + 32 : c

  # C#'s R.strtol(s, ref end, b) on a C string (base 10 whatever b is, the value clamped to the long range)
  def R_atol(s) = R_strtol(s, nil, 10)
  def R_strtol0(s, _b = 10) = R_strtol(s, nil, 10)

  # ferror: the error flag, set by a read of a directory opened with fopen (CFile.Err; C# Fs.cs ferror)
  def R_ferror(f) = !f.nil? && f.Err ? 1 : 0
  def R_fileno(_f) = 3
  def R_setvbuf(_f, _b, _mode, _size) = 0

  # File.Move(a, b, overwrite: true): 0, or -1 when it fails
  def R_rename(a, b)
    Cpp.move_file(Cpp.net_str(Cpp.cbs(a)), Cpp.net_str(Cpp.cbs(b)))
    0
  rescue StandardError
    -1
  end

  # f.S.ReadByte(), the end of the file setting its eof flag, or for a directory its error flag
  def R_fgetc(f)
    b = f.S.read(1)
    if b.nil? || b.empty?
      f.ReadFailed
      return -1
    end
    b.getbyte(0)
  end

  # time(p) for a pointer argument the engine passes as an object (C#'s time(object?)); p is not written
  def R_time_o(_p) = Time.now.to_i

  def R_strncpy(d, s, n)
    m = Cpp.i32(n)
    return d if m <= 0
    db = d.B
    dO = d.O
    sb = s.B
    sO = s.O
    i = 0
    while i < m && (c = sb[sO + i] & 255) != 0
      db[dO + i] = c
      i += 1
    end
    while i < m
      db[dO + i] = 0
      i += 1
    end
    d
  end

  def R_strncmp(a, b, n)
    m = Cpp.i32(n)
    ab = a.B
    aO = a.O
    bb = b.B
    bO = b.O
    i = 0
    while i < m
      x = ab[aO + i] & 255
      y = bb[bO + i] & 255
      return x - y if x != y
      return 0 if x == 0
      i += 1
    end
    0
  end

  def R_memcmp(a, b, n)
    m = Cpp.i32(n)
    return 0 if m <= 0
    x = a.B[a.O, m]
    y = b.B[b.O, m]
    raise IndexError, 'memcmp past the buffer' if x.nil? || y.nil? || x.length < m || y.length < m
    return 0 if x == y
    m.times do |i|
      p = x[i] & 255
      q = y[i] & 255
      return p - q if p != q
    end
    0
  end

  # copy-assigning a char array member: all its bytes
  def R_memcpyBuf(d, s)
    k = [d.B.length - d.O, s.B.length - s.O].min
    return if k <= 0
    d.B[d.O, k] = s.B[s.O, k]
  end

  def R_sprintf(buf, fmt, *args)
    b = Cpp.format_c(fmt, args)
    k = b.bytesize
    if buf.O + k + 1 > buf.B.length
      raise SysException.new('ArgumentException', 'Destination array was not long enough. Check the destination ' \
                                                  "index, length, and the array's lower bounds. (Parameter 'destinationArray')")
    end
    Cpp.put(buf, 0, b + "\0")
    k
  end
end
