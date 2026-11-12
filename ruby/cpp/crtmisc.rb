# encoding: binary
# frozen_string_literal: true
# crtmisc.rb - the rest of cs/runtime/Misc.cs and Std.cs that core_*.rb and algo.rb do not have: atomics (Atomic<T>),
# std::variant (Variant), std::tuple of more elements (TupN, with Ident_Of), chrono (TimePoint, Duration), the
# one-thread stand-ins Mutex / CondVar / Thread / Lock / OnceFlag, Std (call_once, rethrow, get<i>, swap,
# from_chars, QNaN), ErrorCode, FromCharsResult, Dbg (exception trace when SWMM6_CS_TRACE is set), Sys
# (hardware_concurrency), SysException (a .NET exception), and raw memory on typed arrays (Mem, Bytes). A port of
# py/cpp/crtmisc.py.
#
# Typed arrays are Ruby Arrays without a run-time element type, so the Mem / Bytes functions take it from their
# specialisation suffix (D double, F float, I int/uint, L long/ulong, S short, B byte/sbyte, Z bool) and see the
# Array as its little-endian bytes (x86's layout, C#'s MemoryMarshal.AsBytes). Bytes read into an I or L Array are
# decoded signed (int, long), into a B Array unsigned (byte), except where the engine's only uses are unsigned
# (memcpy__IB is the hot-start file's uint CRC, memcpy__LD the ulong bits of a double).
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.

require 'etc'

module Cpp
  # ------------------------------------------------------------------------------------------------ atomics
  def self.wrap64(r)
    return r & M64 if r > M64
    return ((r + 0x8000000000000000) & M64) - 0x8000000000000000 if r < -0x8000000000000000
    r
  end

  def self.wrap32(r)
    return r & 0xFFFFFFFF if r > 0xFFFFFFFF
    return ((r + 0x80000000) & 0xFFFFFFFF) - 0x80000000 if r < -0x80000000
    r
  end

  # std::atomic<T> on one thread (C# Cpp.Atomic<T>): v is the value (an attribute, and so the atomic is a Ref)
  class Atomic
    include ICopy
    attr_accessor :v

    def initialize(x)
      @v = x
    end

    def exchange(x, _order = 0)
      o = @v
      @v = x
      o
    end

    def load(_order = 0) = @v

    def store(x, _order = 0)
      @v = x
    end

    # compare_exchange_weak / _strong on one thread: never fails spuriously; expected is a Ref
    def compare_exchange(expected, desired, *_orders)
      v = @v
      e = expected.v
      if v == e || (v != v && e != e)
        @v = desired
        return true
      end
      expected.v = v
      false
    end
    alias compare_exchange_weak compare_exchange
    alias compare_exchange_strong compare_exchange

    def Clone = self.class.new(@v)

    def Assign(o)
      @v = o.v
    end

    def ref_v = self
    def ToString = @v.to_s
    def fetch_add(d, _order = 0) = (o = @v; @v = _add(o, d); o)
    def fetch_sub(d, _order = 0) = (o = @v; @v = _add(o, -d); o)
  end

  class AtomicD < Atomic
    def _add(a, b) = a + b
  end

  class AtomicF < Atomic
    def _add(a, b) = Cpp.f32_double(a + b)
  end

  class AtomicI < Atomic
    def _add(a, b) = Cpp.wrap32(a + b)
  end

  class AtomicL < Atomic
    def _add(a, b) = Cpp.wrap64(a + b)
  end

  class AtomicZ < Atomic; end

  def NewAtomicD = AtomicD.new(0.0)
  def NewAtomicD_T(x) = AtomicD.new(x)
  def NewAtomicF = AtomicF.new(0.0)
  def NewAtomicF_T(x) = AtomicF.new(x)
  def NewAtomicI = AtomicI.new(0)
  def NewAtomicI_T(x) = AtomicI.new(x)
  def NewAtomicL = AtomicL.new(0)
  def NewAtomicL_T(x) = AtomicL.new(x)
  def NewAtomicZ = AtomicZ.new(false)
  def NewAtomicZ_T(x) = AtomicZ.new(x)

  # ------------------------------------------------------------------------------------------------ std::variant
  # std::variant<bool, int, double, std::string> (the engine's user-flag value): the alternative held (v) and its
  # index in the declared list (idx)
  class Variant
    include ICopy
    attr_accessor :v, :idx

    def initialize
      @v = false
      @idx = 0
    end

    def Set_b(x) = (@v = x; @idx = 0)
    def Set_i(x) = (@v = x; @idx = 1)
    def Set_d(x) = (@v = x; @idx = 2)
    def Set_Str(x) = (@v = x.Clone; @idx = 3)
    def index = @idx
    def Holds(i) = @idx == i

    def Get(i)
      raise NewBadVariantAccess() if @idx != i
      @v
    end

    def Clone
      c = Variant.new
      c.Assign(self)
      c
    end

    def Assign(o)
      @idx = o.idx
      @v = o.idx == 3 ? o.v.Clone : o.v
    end

    def MoveFrom(o)
      @idx = o.idx
      @v = o.v
    end
  end

  def NewVariant = Variant.new
  def NewVariant_b(x) = Variant.new.tap { |r| r.Set_b(x) }
  def NewVariant_i(x) = Variant.new.tap { |r| r.Set_i(x) }
  def NewVariant_d(x) = Variant.new.tap { |r| r.Set_d(x) }
  def NewVariant_Str(x) = Variant.new.tap { |r| r.Set_Str(x) }

  # ------------------------------------------------------------------------------------------------ tuples
  IDS = {}.compare_by_identity

  # a unique number per object for this run (C# Cpp.Ident.Of): orders pointers where only identity matters
  def self.ident_of(o)
    return 0 if o.nil?
    IDS[o] ||= IDS.size + 1
  end

  def Ident_Of(o) = Cpp.ident_of(o)

  # one element of std::tuple's operator< (C# TupN.Cmp)
  def self.tcmp(a, b)
    return b.nil? ? 0 : -1 if a.nil?
    case a
    when Float, Integer then a < b ? -1 : (b < a ? 1 : 0)
    when true, false then (a ? 1 : 0) <=> (b ? 1 : 0)
    when TBox then a.v < b.v ? -1 : (b.v < a.v ? 1 : 0)
    when Ptr
      x = Cpp.ident_of(a.a)
      y = Cpp.ident_of(b.a)
      return x < y ? -1 : 1 if x != y
      a.o < b.o ? -1 : (b.o < a.o ? 1 : 0)
    else
      return a.CompareTo(b) if a.respond_to?(:CompareTo)
      raise SysException.new('NotSupportedException', "tuple element #{a.class}")
    end
  end

  # std::tuple of more than three elements (a map key compared element by element, as std::tuple's operator<
  # does); v is the Array of elements
  class TupN
    include ICopy
    include Comparable
    attr_accessor :v

    def initialize(*items)
      @v = items
    end

    def Clone = TupN.new(*@v)

    def Assign(o)
      @v = o.v.dup
    end

    def MoveFrom(o)
      @v = o.v
    end

    def CompareTo(o)
      @v.each_with_index do |x, i|
        c = Cpp.tcmp(x, o.v[i])
        return c if c != 0
      end
      0
    end

    def <=>(other) = other.is_a?(TupN) ? CompareTo(other) : nil
    def Equals(o) = !o.nil? && CompareTo(o) == 0
    def eql?(o) = o.is_a?(TupN) && CompareTo(o) == 0
    def GetHashCode = @v.length
    def hash = @v.length
  end

  def NewTupN = TupN.new
  def NewTupN_oA(*items) = TupN.new(*items)

  # ------------------------------------------------------------------------------------------------ chrono
  # a std::chrono time point (an immutable struct): ns, nanoseconds of a monotonic clock. Used only for timing
  # (profiling counters, the run's elapsed time); none of it reaches the results.
  class TimePoint
    attr_reader :ns

    def initialize(ns = 0)
      @ns = ns
    end

    def Clone = self
    def time_since_epoch = Duration.new(@ns)
  end

  # a duration in nanoseconds; count() gives seconds (the engine counts durations as std::chrono::duration<double>)
  class Duration
    attr_reader :ns

    def initialize(ns = 0)
      @ns = ns
    end

    def Clone = self
    def count = @ns * 1e-9
  end

  TimePoint_ZERO = TimePoint.new(0)
  Duration_ZERO = Duration.new(0)
  MK_TimePoint = -> { TimePoint_ZERO }
  IMMUTABLE_MAKERS[MK_TimePoint] = true

  def TimePoint_now = TimePoint.new(Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond))
  def TimePoint_op_Sub(a, b) = Duration.new(a.ns - b.ns)
  def NewDuration_l(n) = Duration.new(n)
  def NewDuration_Duration(d) = Duration.new(d.ns)
  def Duration_op_Add(a, b) = Duration.new(a.ns + b.ns)
  def Duration_op_Sub(a, b) = Duration.new(a.ns - b.ns)

  # ------------------------------------------------------------------------------------------------ one thread
  # The ports run single-threaded (the engine's one worker thread, the output writer, is replaced by a synchronous
  # call): these never block.
  class Mutex
    def lock; end
    def unlock; end
    def try_lock = true
  end

  class CondVar
    def notify_one; end
    def notify_all; end
  end

  class Thread
    def joinable = false
    def join; end
  end

  class Lock; end

  # std::once_flag: whether call_once has run its function
  class OnceFlag
    attr_accessor :done

    def initialize
      @done = false
    end
  end

  def NewMutex = Mutex.new
  def NewCondVar = CondVar.new
  def NewThread = Thread.new
  def NewLock = Lock.new
  def NewOnceFlag = OnceFlag.new

  # ------------------------------------------------------------------------------------------------ Std
  Std_QNaN = [0x7FF8000000000000].pack('Q<').unpack1('E')     # C++'s quiet NaN
  Std_SNaN = [0x7FF4000000000000].pack('Q<').unpack1('E')

  # std::rethrow_exception: raise the stored exception again
  def Std_Rethrow(e) = raise(e)

  # std::call_once: run f the first time only (single-threaded; an exception leaves the flag unset)
  def Std_call_once(flag, f)
    return if flag.done
    f.call
    flag.done = true
  end

  def Std_Nop(_x) = 0
  def Std_iabs_i(x) = x.abs
  def Std_iabs_l(x) = x.abs
  def Std_get0_PairAB(p) = p.first
  def Std_get1_PairAB(p) = p.second

  %w[ID II IO LO OD OI OL OS OZ DD DI LL LD IL OO ZO BO OB IZ IB LI DO IF OF].each do |s|
    alias_method "Std_get0_PairAB__#{s}", :Std_get0_PairAB
    alias_method "Std_get1_PairAB__#{s}", :Std_get1_PairAB
  end

  # std::swap through two Refs
  def Std_swap(a, b)
    t = a.v
    a.v = b.v
    b.v = t
  end
  %w[D F I L B S C Z].each { |s| alias_method "Std_swap__#{s}", :Std_swap }

  def Std_exchange(a, v)
    old = a.v
    a.v = v
    old
  end

  def Std_release(a)
    r = a.v
    a.v = nil
    r
  end

  # std::from_chars_result (an immutable struct): ptr, the CPtr after the characters read, and ec, the errc (0, 22
  # invalid_argument, 34 result_out_of_range)
  class FromCharsResult
    attr_reader :ptr, :ec

    def initialize(ptr = nil, ec = 0)
      @ptr = ptr
      @ec = ec
    end

    def Clone = self
  end

  # the bytes of [first, last) of one buffer, as a binary String
  def self.range_bytes(first, last) = first.B[first.O, last.O - first.O].map { |x| x & 255 }.pack('C*')

  # std::from_chars for double (chars_format::general), as libstdc++ has it: the value strtod reads from the same
  # characters (both are correctly rounded), except that a sign other than '-', leading white space and a
  # hexadecimal prefix are not read ("0x10" is 0 and stops at the x), and a value too large or too small for a
  # double is result_out_of_range (34) with the value left unchanged (libstdc++ followed, as in the Python port)
  def Std_from_chars_CPtr_CPtr_dr(first, last, v)
    t = Cpp.range_bytes(first, last)
    k = t.getbyte(0) == 45 ? 1 : 0
    c = t.getbyte(k) || 0
    lc = c >= 65 && c <= 90 ? c | 0x20 : c
    return FromCharsResult.new(first, 22) unless (c >= 48 && c <= 57) || c == 46 || lc == 105 || lc == 110
    t = t.byteslice(0, k + 1) if c == 48 && k + 1 < t.bytesize && (t.getbyte(k + 1) | 0x20) == 120
    r, e, = Cpp.scan_double(t, 0, false)
    return FromCharsResult.new(first, 22) if e <= 0
    ptr = CPtr.new(first.B, first.O + e)
    return FromCharsResult.new(ptr, 34) if r.infinite? && lc != 105
    if r == 0.0
      (k...e).each do |j|
        d = t.getbyte(j)
        break if d == 101 || d == 69
        return FromCharsResult.new(ptr, 34) if d >= 49 && d <= 57
      end
    end
    v.v = r
    FromCharsResult.new(ptr, 0)
  end

  # std::from_chars for integers, base 10: an optional '-' (signed types only), digits; an empty match is
  # invalid_argument (22) with ptr = first; a value out of the type's range is result_out_of_range (34), all the
  # digits consumed, the value left unchanged
  def self.int_chars(first, last, signed, lo, hi, v)
    t = Cpp.range_bytes(first, last)
    i = 0
    neg = false
    if signed && t.getbyte(0) == 45
      neg = true
      i = 1
    end
    j = i
    n = t.bytesize
    j += 1 while j < n && (c = t.getbyte(j)) >= 48 && c <= 57
    return FromCharsResult.new(first, 22) if j == i
    r = t.byteslice(i, j - i).to_i
    r = -r if neg
    ptr = CPtr.new(first.B, first.O + j)
    return FromCharsResult.new(ptr, 34) unless r >= lo && r <= hi
    v.v = r
    FromCharsResult.new(ptr, 0)
  end

  def Std_from_chars_CPtr_CPtr_ir(f, l, v) = Cpp.int_chars(f, l, true, -2147483648, 2147483647, v)
  def Std_from_chars_CPtr_CPtr_lr(f, l, v) = Cpp.int_chars(f, l, true, -9223372036854775808, 9223372036854775807, v)
  def Std_from_chars_CPtr_CPtr_ur(f, l, v) = Cpp.int_chars(f, l, false, 0, 0xFFFFFFFF, v)
  def Std_from_chars_CPtr_CPtr_ulr(f, l, v) = Cpp.int_chars(f, l, false, 0, M64, v)

  # std::error_code: v, the errno value (a class: shared, not copied)
  class ErrorCode
    attr_accessor :v

    TEXT = { 0 => 'Success', 2 => 'No such file or directory', 13 => 'Permission denied', 17 => 'File exists',
             20 => 'Not a directory', 21 => 'Is a directory', 95 => 'Operation not supported' }.freeze

    def initialize
      @v = 0
    end

    def Bool = @v != 0
    def value = @v
    def clear = (@v = 0)

    # glibc's strerror text for the errno values the filesystem calls set (a Str)
    def message = Cpp.str_of(TEXT.fetch(@v) { "Unknown error #{@v}" })
  end

  def NewErrorCode = ErrorCode.new

  # ------------------------------------------------------------------------------------------------ Dbg, Sys, exceptions
  TRACE = !ENV['SWMM6_CS_TRACE'].nil?

  # with the environment variable SWMM6_CS_TRACE set, each exception a translated catch handler catches is printed
  # to stderr (the engine itself turns most of them into error codes)
  def Dbg_Caught(e)
    return unless TRACE
    $stderr.write("[caught] #{e.class}: #{e.message}\n  #{(e.backtrace || []).first(12).join("\n  ")}\n")
  end

  # std::thread::hardware_concurrency: libstdc++ on Linux asks glibc's get_nprocs, the processors online
  # (sysconf(_SC_NPROCESSORS_ONLN)), not the affinity limit; 0 when unknown. The engine prints it in THREADS warnings.
  def Sys_hardware_concurrency
    n = Etc.sysconf(Etc::SC_NPROCESSORS_ONLN)
    n.nil? || n <= 0 ? 0 : n
  rescue StandardError
    0
  end

  # a .NET exception the C# engine throws itself (new XxxException(msg)): kind, the C# class name, and the message.
  # It is not a CppException; rescue StandardError (C#'s catch (System.Exception)) takes it.
  class SysException < StandardError
    attr_reader :kind, :Message

    def initialize(kind = 'Exception', message = '')
      super(message)
      @kind = kind
      @Message = message
    end

    def ToString = "System.#{@kind}: #{@Message}"
  end

  # ------------------------------------------------------------------------------------------------ Mem, Bytes
  # element codes: [size, unpack directive, pack directive, mask]
  EL = {
    'D' => [8, 'E', 'E', nil], 'F' => [4, 'e', 'e', nil], 'I' => [4, 'l<', 'L<', 0xFFFFFFFF],
    'U' => [4, 'L<', 'L<', 0xFFFFFFFF], 'L' => [8, 'q<', 'Q<', M64], 'UL' => [8, 'Q<', 'Q<', M64],
    'S' => [2, 's<', 'S<', 0xFFFF], 'C' => [2, 'S<', 'S<', 0xFFFF], 'B' => [1, 'C', 'C', 0xFF], 'Z' => [1, 'C', 'C', nil]
  }.freeze

  # the first n bytes of the Array a from element o, as the little-endian bytes of its elements (a binary String).
  # No bytes are no bytes even at a null pointer (libstdc++ passes the data() of an empty vector, nullptr, with 0).
  def self.elem_bytes(code, a, o, n)
    return ''.b if n == 0
    size, _, wc, mask = EL[code]
    k = (n + size - 1) / size
    els = a[o, k]
    raise IndexError, 'memory read past the array' if els.nil? || els.length < k
    b = case code
        when 'Z' then els.map { |x| x ? 1 : 0 }.pack('C*')
        when 'F' then Cpp.floats_bytes(els)
        when 'D' then els.pack('E*')
        else els.map { |x| x & mask }.pack("#{wc}*")
        end
    b.bytesize == n ? b : b.byteslice(0, n)
  end

  def self.all_bytes(code, a, o) = Cpp.elem_bytes(code, a, o, (a.length - o) * EL[code][0])

  # the bytes data into the Array a from element o (a partial last element keeps its other bytes)
  def self.elem_write(code, a, o, data)
    n = data.bytesize
    return if n == 0
    size, rc, = EL[code]
    k = (n + size - 1) / size
    raise IndexError, 'memory write past the array' if o + k > a.length
    data = data + Cpp.elem_bytes(code, a, o + k - 1, size).byteslice(n - (k - 1) * size, size) if n != k * size
    a[o, k] = code == 'Z' ? data.bytes.map { |x| x != 0 } : data.unpack("#{rc}*")
  end

  # n bytes of a CPtr's buffer from its offset (none at a null pointer when n is 0)
  def self.cp_bytes(p, n)
    return ''.b if n == 0
    s = p.B[p.O, n]
    raise IndexError, 'memory read past the buffer' if s.nil? || s.length < n
    s.pack('C*')
  end

  def self.cp_write(p, data)
    n = data.bytesize
    return if n == 0
    raise IndexError, 'memory write past the buffer' if p.O + n > p.B.length
    p.B[p.O, n] = data.bytes
  end

  CALLOC = { 'D' => [0.0, 8], 'F' => [0.0, 4], 'I' => [0, 4], 'L' => [0, 8], 'B' => [0, 1] }.freeze
  CALLOC.each do |c, (z, size)|
    # calloc(n, size) cast to T*: n*size bytes of zeroed T. Zero bytes give an empty Array, which, like glibc's
    # unique pointer for a zero-size request, is never dereferenced. free() is the collector's.
    define_method("Mem_Calloc__#{c}") { |n, sz| Ptr.new(Array.new(n * sz / size, z), 0) }
  end

  def Mem_Free(_p); end

  def self.index_of(a, obj)
    i = a.index { |x| x.equal?(obj) }
    i = a.index(obj) if i.nil?
    i.nil? ? -1 : i
  end

  # &obj - p: the index of an object in an array of objects (pointers to objects are references)
  def Mem_Diff_T_PtrT(obj, p) = Cpp.index_of(p.a, obj) - p.o
  def Mem_Diff_PtrT_T(p, obj) = p.o - Cpp.index_of(p.a, obj)

  %w[B D F I L S Z C].each do |c|
    # memcpy(T* d, const char* s, n): n bytes of s into the elements of d
    define_method("Mem_memcpy_PtrT_CPtr_ul__#{c}") do |d, s, n|
      Cpp.elem_write(c, d.a, d.o, Cpp.cp_bytes(s, n))
      d
    end
    define_method("Mem_memcpy_CPtr_PtrU_ul__#{c}") do |d, s, n|
      Cpp.cp_write(d, Cpp.elem_bytes(c, s.a, s.o, n))
      d
    end
    define_method("Mem_memset_PtrT_i_ul__#{c}") do |d, v, n|
      Cpp.elem_write(c, d.a, d.o, (v & 255).chr * n)
      d
    end
  end

  # memcpy<T, U>: the destination's code first; through the bytes, so overlapping arrays behave as memmove. The
  # engine's only uses are unsigned: a uint CRC from a byte vector (IB) and the ulong bits of a double (LD).
  { 'IB' => %w[U B], 'LD' => %w[UL D], 'DL' => %w[D L], 'BI' => %w[B I], 'IF' => %w[I F], 'FI' => %w[F I] }.each do |s, (dc, sc)|
    define_method("Mem_memcpy_PtrT_PtrU_ul__#{s}") do |d, src, n|
      Cpp.elem_write(dc, d.a, d.o, Cpp.elem_bytes(sc, src.a, src.o, n)) if n != 0
      d
    end
  end

  def Mem_memcpy_CPtr_CPtr_ul(d, s, n)
    Cpp.cp_write(d, Cpp.cp_bytes(s, n)) if n != 0     # memcpy(d, s, 0) reads and writes nothing, even at null pointers
    d
  end

  def Mem_memset_CPtr_i_ul(d, c, n)
    Cpp.cp_write(d, (c & 255).chr * n)
    d
  end

  # fwrite of size*count bytes of a char buffer (none, even at a null pointer, when that is 0); returns count
  def Mem_fwrite_CPtr_ul_ul_CFile(p, size, count, f)
    f.S.write(Cpp.cp_bytes(p, size * count)) if size * count != 0
    count
  end

  # fread of size*count bytes into a char buffer: the number of whole items read; a short read sets the end-of-file
  # flag (the error flag for a directory: CFile.ReadFailed)
  def Mem_fread_CPtr_ul_ul_CFile(p, size, count, f)
    want = size * count
    b = want != 0 ? (f.S.read(want) || ''.b) : ''.b
    f.ReadFailed if b.bytesize < want
    Cpp.cp_write(p, b)
    size != 0 ? b.bytesize / size : 0
  end

  %w[D F I L B].each do |c|
    define_method("Mem_fwrite_PtrT_ul_ul_CFile__#{c}") do |p, size, count, f|
      f.S.write(Cpp.elem_bytes(c, p.a, p.o, size * count))
      count
    end
    define_method("Mem_fread_PtrT_ul_ul_CFile__#{c}") do |p, size, count, f|
      want = size * count
      b = want != 0 ? (f.S.read(want) || ''.b) : ''.b
      f.ReadFailed if b.bytesize < want
      Cpp.elem_write(c, p.a, p.o, b)
      size != 0 ? b.bytesize / size : 0
    end
  end

  def Bytes_View_CPtr(p) = p

  # the bytes of the numbers p points at, to the end of its array, as a char* for reading (a copy); a null pointer
  # gives the null char*
  %w[B D F I L S Z C].each do |c|
    define_method("Bytes_View_PtrT__#{c}") do |p|
      next CPtr_ZERO if p.a.nil? && p.at.nil?
      CPtr.new(Cpp.all_bytes(c, p.a, p.o).bytes, 0)
    end
  end
end
