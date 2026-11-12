# encoding: binary
# frozen_string_literal: true
# streams.rb - cs/runtime/Streams.cs, the iostreams the engine uses, with libstdc++'s formatting; a port of
# py/cpp/streams.py. A double is written with the printf format libstdc++'s num_put builds from the stream flags
# (%.*g by default, %.*f for fixed, %.*e for scientific, %a for fixed|scientific, '#' for showpoint) through crt.rb's
# glibc-exact formatter; width and fill are applied afterwards and width resets. A double is read as libstdc++'s
# num_get reads it (the characters a number can have, converted by strtod; an overflow fails and stores +-DBL_MAX);
# an integer is a token converted by strtol (a token that does not convert whole sets failbit and stores 0; an int
# out of range stores the nearest limit). getline consumes the delimiter; at the end of the input it sets eof, and
# fail too when nothing at all was read. seekg clears eof; on a file, ios::cur is relative to the logical read
# position. An ifstream on a directory opens, and its first read sets badbit and failbit.
# What the C# streams write to and read from (FileStream, MemoryStream, the console) is fs.rb's .NET behaviour.
# cout and cerr write through to file descriptors 1 and 2 at once, after flushing the C stdio file of the same
# descriptor, so stream and printf output keep their order.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.

module Cpp
  # the libstdc++ values of ios_base::openmode, seekdir, fmtflags and iostate
  Ios_in = 8
  Ios_out = 16
  Ios_binary = 4
  Ios_app = 1
  Ios_trunc = 32
  Ios_ate = 2
  Ios_beg = 0
  Ios_cur = 1
  Ios_end = 2
  Ios_fixed = 4
  Ios_scientific = 256
  Ios_left = 32
  Ios_right = 128
  Ios_showpoint = 1024
  Ios_boolalpha = 1
  Ios_adjustfield = 176
  Ios_basefield = 74
  Ios_floatfield = 260
  Ios_goodbit = 0
  Ios_badbit = 1
  Ios_eofbit = 2
  Ios_failbit = 4
  DBL_MAX = 1.7976931348623157e308

  # libstdc++'s __num_base::_S_format_float: [showpoint][g, f, e, a]
  SFMTS = [%w[%.*g %.*f %.*e %a], %w[%#.*g %#.*f %#.*e %#a]].map { |r| r.map { |f| CPtr.new(Cpp.lit_bytes(f), 0) } }

  def self.arg_exc
    SysException.new('ArgumentException', 'Offset and length were out of bounds for the array or count is greater ' \
                                          'than the number of elements from index to the end of the source collection.')
  end

  def self.dest_exc
    SysException.new('ArgumentException', 'Destination array was not long enough. Check the destination index, ' \
                                          "length, and the array's lower bounds. (Parameter 'destinationArray')")
  end

  def self.aoor_exc = SysException.new('ArgumentOutOfRangeException', 'Specified argument was out of the range of valid values.')

  # ---- the bytes of the numbers a Ptr<T> points at (C# Mem.BytesOf / Mem.BytesInto: MemoryMarshal.AsBytes of the
  # span from the pointer to the end of its array, sliced to n bytes): ArgumentOutOfRangeException when n bytes do
  # not fit, and a write of a partial element changes only its low bytes
  POD_SIZE = { 'B' => 1, 'Z' => 1, 'S' => 2, 'I' => 4, 'L' => 8, 'F' => 4, 'D' => 8 }.freeze

  def self.pod_check(p, size, n)
    a = p.a
    raise SysException.new('NullReferenceException', 'Object reference not set to an instance of an object.') if a.nil?
    o = p.o
    raise Cpp.aoor_exc if o < 0 || o > a.length || n < 0 || n > (a.length - o) * size
  end

  # Mem.BytesOf(p, n); a null p with no bytes is no bytes
  def self.pod_of(code, p, n)
    return ''.b if n == 0 && p.a.nil?
    Cpp.pod_check(p, POD_SIZE[code], n)
    Cpp.elem_bytes(code, p.a, p.o, n)
  end

  # Mem.BytesInto(p, src, 0, n): the first n bytes of the numbers p points at replaced by src's first n bytes
  def self.pod_into(code, p, src, n)
    if n <= 0
      return if n == 0 && p.a.nil?
      Cpp.pod_check(p, POD_SIZE[code], 0)
      return
    end
    Cpp.pod_check(p, POD_SIZE[code], n)
    if code == 'B'
      p.a[p.o, n] = src.byteslice(0, n).bytes
    else
      Cpp.elem_write(code, p.a, p.o, src.byteslice(0, n))
    end
  end

  # ------------------------------------------------------------------------------------------------- manipulators
  SetPrec = Struct.new(:n)
  SetW = Struct.new(:n)
  SetFill = Struct.new(:c)
  def NewSetPrec(n) = SetPrec.new(n)
  def NewSetW(n) = SetW.new(n)
  def NewSetFill(c) = SetFill.new(c)
  def Streams_setprecision(n) = SetPrec.new(n)
  def Streams_setw(n) = SetW.new(n)
  def Streams_setfill(c) = SetFill.new(c)

  # ------------------------------------------------------------------------------------------------- IosBase
  # the state and format part of std::ios_base (Cpp.IosBase)
  class IosBase
    attr_accessor :failbit, :eofbit, :badbit, :prec, :flagsv, :widthv, :fillc

    def initialize
      @failbit = false
      @eofbit = false
      @badbit = false
      @prec = 6
      @flagsv = 0
      @widthv = 0
      @fillc = 32
    end

    def good = !(@failbit || @eofbit || @badbit)
    def fail_ = @failbit || @badbit
    def bad = @badbit
    def eof = @eofbit
    def ok = !(@failbit || @badbit)
    def notok = @failbit || @badbit
    def Bool = ok

    # clear(state): as in the C# port, every flag is reset whatever the argument
    def clear(_s = 0)
      @failbit = @eofbit = @badbit = false
    end

    def precision_ = @prec
    def precision_l(p) = (o = @prec; @prec = p; o)
    def width_ = @widthv
    def width_l(w) = (o = @widthv; @widthv = w; o)
    def fill_ = @fillc
    def fill_i(c) = (o = @fillc; @fillc = c; o)
    def setf_i(f) = (o = @flagsv; @flagsv = Cpp.i32(o | f); o)
    def setf_i_i(f, m) = (o = @flagsv; @flagsv = Cpp.i32((o & ~m) | (f & m)); o)
    def unsetf(f) = (@flagsv = Cpp.i32(@flagsv & ~f))
    def rdbuf = nil
    def imbue(_l) = nil
    def exceptions(_m) = nil
  end

  # ------------------------------------------------------------------------------------------------- OStream
  # std::ostream (Cpp.OStream). It writes to a FileStream (s: an ofstream or fstream), a MemoryStream (mem: an
  # ostringstream) or a console stream (std: 1 for cout, 2 for cerr).
  class OStream < IosBase
    attr_accessor :s, :mem, :std

    def initialize
      super
      @s = nil
      @mem = nil
      @std = 0
    end

    def Raw(data)
      if !@s.nil?
        @s.write(data)
      elsif @std != 0
        return if data.empty?
        R_fflush(@std == 1 ? R_stdout_ : R_stderr_)
        (@std == 1 ? R_stdout_ : R_stderr_).S.write(data)
      elsif !@mem.nil?
        @mem.write(data)
      end
    end

    # a formatted field: the fill before it (after it when left-adjusted) up to the width, which resets
    def Pad(body)
      w = @widthv
      @widthv = 0
      n = body.bytesize
      if n >= w
        Raw(body)
        return
      end
      pad = (@fillc & 255).chr * (w - n)
      if @flagsv & 32 != 0
        Raw(body)
        Raw(pad)
      else
        Raw(pad)
        Raw(body)
      end
    end

    def Put_Str(x) = (Pad(x.b[0, x.n].pack('C*')); self)
    def Put_CPtr(x) = (Pad(Cpp.cbs(x)); self)
    def Put_c(c) = (Pad((c & 255).chr); self)
    def Put_uc(c) = (Pad((c & 255).chr); self)
    def Put_i(v) = (Pad(v.to_s); self)
    alias Put_l Put_i
    alias Put_u Put_i
    alias Put_ul Put_i
    alias Put_s Put_i
    def Put_b(v) = (Pad(@flagsv & 1 != 0 ? (v ? 'true' : 'false') : (v ? '1' : '0')); self)

    # operator<<(double): the conversion letter from the floatfield, '#' for showpoint, the precision
    def Put_d(v)
      fm = SFMTS[@flagsv & 1024 != 0 ? 1 : 0]
      fx = @flagsv & 4 != 0
      sci = @flagsv & 256 != 0
      body = if fx && sci then Cpp.format_c(fm[3], [v])
             else Cpp.format_c(fx ? fm[1] : (sci ? fm[2] : fm[0]), [Cpp.i32(@prec), v])
             end
      Pad(body)
      self
    end
    alias Put_f Put_d

    def Put_SetPrec(p) = (@prec = p.n; self)
    def Put_SetW(w) = (@widthv = w.n; self)
    def Put_SetFill(f) = (@fillc = f.c; self)
    def Put_OStream(_o) = self
    def Manip_endl = (Raw("\n"); flush; self)
    def Manip_flush = (flush; self)
    def Manip_setprecision(n) = (@prec = n; self)
    def Manip_setw(n) = (@widthv = n; self)
    def Manip_setfill(c) = (@fillc = c; self)

    # std::quoted(s): s between double quotes, with every '"' and '\' escaped by a backslash; the width applies to
    # the whole quoted string, as in libstdc++
    def self.quote(body) = "\"#{body.gsub(/["\\]/) { |m| "\\#{m}" }}\""
    def Manip_quoted_Str(x) = (Pad(OStream.quote(x.b[0, x.n].pack('C*'))); self)
    def Manip_quoted_CPtr(x) = (Pad(OStream.quote(Cpp.cbs(x))); self)
    def Manip_fixed = (@flagsv = (@flagsv & ~(4 | 256)) | 4; self)
    def Manip_scientific = (@flagsv = (@flagsv & ~(4 | 256)) | 256; self)
    def Manip_defaultfloat = (@flagsv &= ~(4 | 256); self)
    def Manip_left = (@flagsv = (@flagsv & ~(32 | 128)) | 32; self)
    def Manip_right = (@flagsv = (@flagsv & ~(32 | 128)) | 128; self)
    def Manip_boolalpha = (@flagsv |= 1; self)
    def Manip_noboolalpha = (@flagsv &= ~1; self)
    def Manip_showpoint = (@flagsv |= 1024; self)
    def Manip_noshowpoint = (@flagsv &= ~1024; self)

    # write(p, n): n raw bytes (none, even at a null pointer, when n is 0)
    def write_CPtr_l(p, n)
      return self if n == 0
      k = Cpp.i32(n)
      raise Cpp.arg_exc if p.O + k > p.B.length || k < 0
      Raw(p.B[p.O, k].pack('C*'))
      self
    end

    # write((const char*)p, n) of an array of numbers: its first n bytes (Mem.BytesOf)
    %w[B Z S I L F D].each do |c|
      define_method("write_PtrT_l__#{c}") { |p, n| Raw(Cpp.pod_of(c, p, Cpp.i32(n))); self }
    end

    # s?.Flush(): a file's buffer reaches the file; the console streams write through at once
    def flush
      @s&.flush
      self
    end

    def tellp
      return @s.position unless @s.nil?
      raise SysException.new('NotSupportedException', 'Stream does not support seeking.') if @std != 0
      @mem.nil? ? 0 : @mem.instance_variable_get(:@pos)
    end

    def seekp(pos, d = 0)
      if !@s.nil? then @s.seek(pos, d)
      elsif @std != 0 then raise SysException.new('NotSupportedException', 'Stream does not support seeking.')
      elsif !@mem.nil? then @mem.seek(pos, d)
      end
      self
    end
  end

  # ------------------------------------------------------------------------------------------------- OStringStream
  # std::ostringstream over a MemoryStream: str() is every byte written
  class OStringStream < OStream
    def initialize
      super
      @mem = MemStream.new
    end

    def str_ = Cpp.str_of(@mem.b)

    # str(x): the contents replaced by x, the put position at its end
    def str_Str(x)
      m = MemStream.new
      m.write(x.b[0, x.n].pack('C*'))
      @mem = m
    end

    # the move assignment: the bytes, the precision and the flags (the source is left empty)
    def MoveFrom(o)
      @mem = o.mem
      @prec = o.prec
      @flagsv = o.flagsv
      o.mem = MemStream.new
    end
  end

  def NewOStringStream = OStringStream.new
  def NewOStringStream_i(_mode) = OStringStream.new

  def NewOStringStream_Str(init)
    o = OStringStream.new
    o.mem.write(init.b[0, init.n].pack('C*'))
    o.mem.seek(0, 0)
    o
  end

  # ------------------------------------------------------------------------------------------------- OFStream
  # std::ofstream over a FileStream with a 64 KiB buffer: ios::app appends (FileMode.Append), any other mode creates
  # or truncates (FileMode.Create); a file that cannot be opened leaves the stream closed with failbit set. Dispose
  # is the destructor, which closes the file; a stream that is never closed keeps its buffered bytes, as the C#
  # FileStream does at exit.
  class OFStream < OStream
    include IDisposable

    def open_bytes(path, mode)
      unless @s.nil?
        old = @s
        @s = nil
        old.close
      end
      app = mode & 1 != 0
      f = Cpp.open_fd(Cpp.latin1_str(path), app ? O_APPEND : O_CREATE)
      begin
        @s = FileOut.new(f, 1 << 16, app)
      rescue StandardError
        f.close
        raise
      end
      @failbit = false
    rescue StandardError
      @s = nil
      @failbit = true
    end

    def open_Str_i(path, mode = 16) = open_bytes(path.b[0, path.n].pack('C*'), mode)
    def open_FsPath_i(path, mode = 16) = open_Str_i(path.p, mode)
    def open_CPtr_i(path, mode = 16) = open_bytes(Cpp.cbs(path), mode)
    def is_open = !@s.nil?

    def close
      s = @s
      return if s.nil?
      @s = nil
      s.close
    end

    def Dispose = close

    def MoveFrom(o)
      @s = o.s
      o.s = nil
    end
  end

  def NewOFStream = OFStream.new
  def NewOFStream_Str_i(path, mode = 16) = OFStream.new.tap { |o| o.open_Str_i(path, mode) }
  def NewOFStream_CPtr_i(path, mode = 16) = OFStream.new.tap { |o| o.open_CPtr_i(path, mode) }
  def NewOFStream_FsPath_i(path, mode = 16) = OFStream.new.tap { |o| o.open_Str_i(path.p, mode) }

  # ------------------------------------------------------------------------------------------------- FStream
  # std::fstream as the C# port has it: the file opened, or created, for reading and writing (FileMode.OpenOrCreate,
  # not truncated) and written from its start through a FileStream with the default 4 KiB buffer
  class FStream < OStream
    include IDisposable

    def initialize(path = nil, _mode = 0)
      super()
      return if path.nil?
      f = Cpp.open_fd(Cpp.latin1_str(path.b[0, path.n].pack('C*')), O_RW)
      begin
        @s = FileOut.new(f, 4096, false)
      rescue StandardError
        f.close
        raise
      end
    rescue StandardError
      @failbit = true
    end

    def is_open = !@s.nil?

    def close
      s = @s
      return if s.nil?
      @s = nil
      s.close
    end

    def Dispose = close
  end

  def NewFStream(path, mode) = FStream.new(path, mode)

  # ------------------------------------------------------------------------------------------------- IStream
  WS_B = [32, 9, 10, 13, 11, 12].freeze
  WS_RX = /[ \t\n\r\v\f]/n
  NWS_RX = /[^ \t\n\r\v\f]/n

  # std::istream as the C# port has it: a buffer of bytes (the whole string of an istringstream, or the last block
  # of up to 64 KiB read from an ifstream's file) and the read position in it. dir: an ifstream opened on a
  # directory: the first read fails with EISDIR, badbit and failbit, not eofbit (C# Cpp.IStream.dir).
  class IStream < IosBase
    attr_accessor :buf, :pos, :len, :src, :gcountv, :dir

    def initialize
      super
      @buf = ''.b
      @pos = 0
      @len = 0
      @src = nil
      @gcountv = 0
      @dir = false
    end

    def Fill
      if @pos < @len
        raise IndexError, 'Index was outside the bounds of the array.' if @pos < 0
        return true
      end
      if @dir
        @badbit = true
        @failbit = true
        return false
      end
      return false if @src.nil?
      @buf = @src.read(1 << 16)
      @len = @buf.bytesize
      @pos = 0
      @len > 0
    end

    # a read found no more input: the end of the input sets eofbit; a failed read (dir) set badbit instead
    def AtEnd
      @eofbit = true unless @dir
    end

    def peek
      unless Fill()
        AtEnd()
        return -1
      end
      @buf.getbyte(@pos)
    end

    def get_
      unless Fill()
        AtEnd()
        @failbit = true
        return -1
      end
      @gcountv = 1
      @pos += 1
      @buf.getbyte(@pos - 1)
    end

    def get_cr(c)
      x = get_
      c.v = x > 127 ? x - 256 : x if x >= 0
      self
    end

    def ignore(n = 1, delim = -1)
      i = 0
      while i < n
        c = get_
        break if c < 0 || c == delim
        i += 1
      end
      @failbit = @failbit && !@eofbit
      self
    end

    def gcount = @gcountv

    # read(p, n): up to n bytes; fewer set eof and fail. gcount is the number read.
    def read_CPtr_l(p, n)
      got = 0
      b = p.B
      o = p.O
      while got < n
        break unless Fill()
        k = n - got
        k = @len - @pos if @len - @pos < k
        raise Cpp.dest_exc if o + got + k > b.length
        b[o + got, k] = @buf.byteslice(@pos, k).bytes
        @pos += k
        got += k
      end
      @gcountv = got
      if got < n
        AtEnd()
        @failbit = true
      end
      self
    end

    # read((char*)p, n) into an array of numbers: its first gcount bytes are replaced (Mem.BytesInto)
    %w[B Z S I L F D].each do |c|
      define_method("read_PtrT_l__#{c}") do |p, n|
        tmp = CPtr.new(Array.new(Cpp.i32(n), 0), 0)
        read_CPtr_l(tmp, n)
        Cpp.pod_into(c, p, tmp.B.pack('C*'), @gcountv)
        self
      end
    end

    # getline(s, line, delim): the bytes up to the delimiter (consumed, not stored)
    def ReadLine(s, delim)
      s.clear
      anyb = false
      d = delim >= 0 && delim <= 255 ? delim.chr : nil
      loop do
        unless Fill()
          AtEnd()
          @failbit = true unless anyb
          return anyb
        end
        anyb = true
        k = d.nil? ? nil : @buf.index(d, @pos)
        k = @len if k.nil? || k >= @len
        s.append_bytes(@buf.byteslice(@pos, k - @pos)) if k > @pos
        if k < @len
          @pos = k + 1
          return true
        end
        @pos = @len
      end
    end

    def SkipWs
      while Fill()
        k = @buf.index(NWS_RX, @pos)
        if k.nil? || k >= @len
          @pos = @len
          next
        end
        @pos = k
        return
      end
    end

    # the next whitespace-delimited token (a binary String); failbit when there is none, eof when the input ends
    def token
      SkipWs()
      tok = ''.b
      while Fill()
        e = @buf.index(WS_RX, @pos)
        e = @len if e.nil? || e > @len
        tok << @buf.byteslice(@pos, e - @pos)
        @pos = e
        break if e < @len
      end
      if tok.empty?
        @failbit = true
        AtEnd() unless Fill()
      elsif !Fill()
        AtEnd()
      end
      tok
    end

    def Get_Str(s)
      t = token
      s.Assign_Str(Cpp.str_of(t)) unless t.empty?
      self
    end

    # is >> std::ws: skip whitespace (eof is set if the input ends there, failbit is not)
    def Manip_ws
      loop do
        unless Fill()
          AtEnd()
          break
        end
        k = @buf.index(NWS_RX, @pos)
        if k.nil? || k >= @len
          @pos = @len
          next
        end
        @pos = k
        break
      end
      self
    end

    # past the current character: the next one, or -1 at the end of the input
    def next_c
      @pos += 1
      Fill() ? @buf.getbyte(@pos) : -1
    end

    # is >> v for a double, as libstdc++ does it: the sentry (a stream not good extracts nothing; white space
    # skipped; at the end of the input eof and fail, v unchanged); num_get's _M_extract_float takes the characters a
    # C-locale number can have (a sign, one of any leading zeros, digits, one '.', and an 'e' after a digit with its
    # sign), stopping at the first other one, which stays in the stream; the gnu __convert_to_v converts them with
    # strtod: not all of them converted is failbit with v = 0, an overflow is failbit with v = +-DBL_MAX, an
    # underflow is no error. eofbit when the number ends the input.
    def Get_dr(v)
      if @failbit || @eofbit || @badbit
        @failbit = true
        return self
      end
      SkipWs()
      unless Fill()
        AtEnd()
        @failbit = true
        return self
      end
      acc = +''.b
      c = @buf.getbyte(@pos)
      if c == 43 || c == 45
        acc << c
        c = next_c
      end
      mantissa = dec = sci = false
      while c == 48
        unless mantissa
          acc << 48
          mantissa = true
        end
        c = next_c
      end
      while c >= 0
        if c >= 48 && c <= 57
          acc << c
          mantissa = true
        elsif c == 46 && !dec && !sci
          acc << 46
          dec = true
        elsif (c == 101 || c == 69) && !sci && mantissa
          acc << 101
          sci = true
          c = next_c
          break if c < 0
          if c == 43 || c == 45
            acc << c
          else
            next
          end
        else
          break
        end
        c = next_c
      end
      AtEnd() if c < 0
      r, n, = Cpp.scan_double(acc, 0, false)
      if n <= 0 || n != acc.bytesize
        v.v = 0.0
        @failbit = true
      elsif r == INF
        v.v = DBL_MAX
        @failbit = true
      elsif r == -INF
        v.v = -DBL_MAX
        @failbit = true
      else
        v.v = r
      end
      self
    end

    def Get_fr(v)
      d = Cell.new(0.0)
      Get_dr(d)
      v.v = Cpp.f32_double(d.v)
      self
    end

    def Get_ir(v)
      t = token
      if t.empty?
        v.v = 0
        return self
      end
      r, e = Cpp.strtol_bytes(t, 0)
      if e != t.bytesize || r < -2147483648 || r > 2147483647
        @failbit = true
        v.v = r < -2147483648 ? -2147483648 : (r > 2147483647 ? 2147483647 : 0)
        return self
      end
      v.v = r
      self
    end

    def Get_lr(v)
      t = token
      if t.empty?
        v.v = 0
        return self
      end
      r, e = Cpp.strtol_bytes(t, 0)
      if e != t.bytesize
        @failbit = true
        v.v = 0
        return self
      end
      v.v = r
      self
    end

    def Get_ulr(v)
      x = Cell.new(0)
      Get_lr(x)
      v.v = x.v & M64
      self
    end

    def Get_ur(v)
      x = Cell.new(0)
      Get_lr(x)
      v.v = x.v & 0xFFFFFFFF
      self
    end

    def Get_cr(c)
      SkipWs()
      x = get_
      c.v = x > 127 ? x - 256 : x if x >= 0
      self
    end

    # the read position: the file offset of the next byte, or the index in the string
    def tellg = @src.nil? ? @pos : @src.pos - (@len - @pos)

    def seekg(off, d = 0)
      @eofbit = false
      if !@src.nil?
        # ios::cur is relative to the read position, not to the file's, which is past the buffered block
        np = case d
             when 0 then off
             when 1 then tellg + off
             else @src.length + off
             end
        if np < 0
          @failbit = true
          return self
        end
        @src.seek(np)
        @pos = @len = 0
      else
        @pos = Cpp.i32(case d
                       when 0 then off
                       when 1 then @pos + off
                       else @len + off
                       end)
      end
      self
    end
  end

  # C#'s R.strtol(s, ref end, base) on a binary String from index i: leading space skipped, an optional sign,
  # decimal digits, the value clamped to the long range. Returns [value, end index]; the end is i itself when there
  # are no digits.
  def self.strtol_bytes(b, i)
    m = /\G[ \t\n\r\v\f]*([+-]?)([0-9]+)/n.match(b, i)
    return [0, i] if m.nil?
    v = m[2].to_i
    v = -v if m[1] == '-'
    [v.clamp(-9223372036854775808, 9223372036854775807), m.end(0)]
  end

  # ------------------------------------------------------------------------------------------------- IStringStream
  # std::istringstream: a copy of the string to read from
  class IStringStream < IStream
    # str(x): a copy of x to read from the start; fail and eof are cleared
    def str_Str(s)
      @buf = s.b[0, s.n].pack('C*')
      @pos = 0
      @len = @buf.bytesize
      @failbit = @eofbit = false
    end

    def str_ = Cpp.str_of(@buf.byteslice(0, @len))

    def MoveFrom(o)
      @buf = o.buf
      @pos = o.pos
      @len = o.len
    end
  end

  def NewIStringStream = IStringStream.new
  def NewIStringStream_Str(s) = IStringStream.new.tap { |i| i.str_Str(s) }
  def NewIStringStream_Str_i(s, _mode) = IStringStream.new.tap { |i| i.str_Str(s) }

  # ------------------------------------------------------------------------------------------------- IFStream
  # std::ifstream over a FileStream: a missing file leaves the stream closed with failbit set; a directory opens, as
  # libstdc++ opens it, and every read then fails (IStream.dir). Dispose is the destructor, which closes the file.
  class IFStream < IStream
    include IDisposable

    def open_bytes(path)
      unless @src.nil?
        @src.close
        @src = nil
      end
      @dir = false
      name = Cpp.latin1_str(path)
      if Cpp.dir_exists(name)
        @dir = true
        @failbit = false
        @pos = @len = 0
        return
      end
      @src = FileIn.new(Cpp.open_fd(name, O_READ))
      @failbit = false
      @pos = @len = 0
    rescue StandardError
      @src = nil
      @failbit = true
    end

    def open_Str_i(path, _mode = 8) = open_bytes(path.b[0, path.n].pack('C*'))
    def open_FsPath_i(path, mode = 8) = open_Str_i(path.p, mode)
    def open_CPtr_i(path, _mode = 8) = open_bytes(Cpp.cbs(path))
    def is_open = !@src.nil? || @dir

    def close
      s = @src
      unless s.nil?
        @src = nil
        s.close
      end
      @dir = false
    end

    def Dispose = close

    def MoveFrom(o)
      @src = o.src
      @buf = o.buf
      @pos = o.pos
      @len = o.len
      @dir = o.dir
      o.src = nil
      o.dir = false
    end
  end

  def NewIFStream = IFStream.new
  def NewIFStream_Str_i(path, mode = 8) = IFStream.new.tap { |f| f.open_Str_i(path, mode) }
  def NewIFStream_CPtr_i(path, mode = 8) = IFStream.new.tap { |f| f.open_CPtr_i(path, mode) }
  def NewIFStream_FsPath_i(path, mode = 8) = IFStream.new.tap { |f| f.open_Str_i(path.p, mode) }

  # ------------------------------------------------------------------------------------------------- Cpp.Streams
  Streams_cout = OStream.new.tap { |o| o.std = 1 }
  Streams_cerr = OStream.new.tap { |o| o.std = 2 }
  Streams_clog = Streams_cerr

  def Streams_getline_IStream_Str(s, line) = (s.ReadLine(line, 10); s)
  def Streams_getline_IStream_Str_c(s, line, delim) = (s.ReadLine(line, delim & 255); s)
  def Streams_getline_IStream_Str_i(s, line, delim) = (s.ReadLine(line, delim & 255); s)
end
