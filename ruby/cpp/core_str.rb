# encoding: binary
# frozen_string_literal: true
# core_str.rb - std::string (cs/runtime/Str.cs: Str, a mutable byte sequence, so lengths, comparisons and printf
# padding count bytes as libstdc++ does) and the C++ standard exception classes (std::exception and its library
# subclasses, from cs/runtime/Std.cs). The engine reads s.b[i] (the backing Array, bytes 0..n-1) and s.n (the
# length) directly; b's length is the capacity plus one, as the C#'s byte[] is (Str() starts with 16 bytes, growth
# doubles), and c_str() hands out a NUL-terminated CPtr over b.
# A port of py/cpp/core_str.py. Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.

module Cpp
  NPOS = 0xFFFFFFFFFFFFFFFF
  Str_npos = NPOS

  # The bytes of the C string at CPtr p (to its NUL), 0..255
  def self.cb(p) = Cpp.cstr_bytes(p)

  # an Array of bytes as a binary String (for searching)
  def self.bs(a) = a.pack('C*')

  class Str
    include ICopy
    attr_accessor :b, :n

    def initialize
      @b = Array.new(16, 0)
      @n = 0
    end

    # a Str over buffer b (an Array of at least n + 1 bytes) holding n bytes
    def self.over(b, n)
      s = allocate
      s.b = b
      s.n = n
      s
    end

    # a fresh buffer of m + 1 bytes holding src (m bytes) and a zero
    def self.own(src)
      t = src.dup
      t << 0
      t
    end

    # Str.Reserve: room for need bytes plus the NUL; growth doubles the buffer (a new one, like Array.Resize)
    def _reserve(need)
      b = @b
      lb = b.length
      return b if need + 1 <= lb
      cap = lb * 2
      cap = need + 1 if cap < need + 1
      @b = b + Array.new(cap - lb, 0)
    end

    def size = @n
    def length = @n
    def empty = @n == 0

    def clear
      @n = 0
    end

    def c_str
      n = @n
      b = @b
      b = _reserve(n) if n + 1 > b.length
      b[n] = 0
      CPtr.new(b, 0)
    end
    alias data c_str

    def at(i)
      raise OutOfRange.new("basic_string::at: __n (which is #{i}) >= this->size() (which is #{@n})") if i >= @n
      @b[i]
    end

    def front = @b[0]
    def back = @b[@n - 1]
    def ref_front = ArrRef.new(@b, 0)
    def ref_back = ArrRef.new(@b, @n - 1)
    def get_Item(i) = @b[i]

    def set_Item(i, v)
      @b[i] = v & 0xFF
    end

    def ref_Item(i) = ArrRef.new(@b, i)
    alias get_Item_ul get_Item
    alias get_Item_l get_Item
    alias get_Item_i get_Item
    alias set_Item_ul set_Item
    alias set_Item_l set_Item
    alias set_Item_i set_Item
    alias ref_Item_ul ref_Item
    alias ref_Item_l ref_Item
    alias ref_Item_i ref_Item

    def Char(i)
      x = @b[i]
      x > 127 ? x - 256 : x
    end

    # ---- copy and move
    def Clone
      t = @b[0, @n]
      t << 0
      Str.over(t, @n)
    end

    def Assign_Str(o)
      return if o.equal?(self)
      m = o.n
      b = @b
      b = _reserve(m) if m + 1 > b.length
      b[0, m] = o.b[0, m]
      @n = m
    end
    alias Assign Assign_Str

    def Assign_CPtr(p)
      src = Cpp.cb(p)
      @b = Str.own(src)
      @n = src.length
    end

    def Assign_i(ch)
      b = @b
      b = _reserve(1) if b.length < 2
      b[0] = ch & 0xFF
      @n = 1
    end

    def MoveFrom(o)
      return if o.equal?(self)
      @b = o.b
      @n = o.n
      o.b = Array.new(16, 0)
      o.n = 0
    end
    alias MoveFrom_Str MoveFrom

    def assign_Str(o)
      Assign_Str(o)
      self
    end

    def assign_CPtr(p)
      Assign_CPtr(p)
      self
    end

    def assign_CPtr_ul(p, ln)
      # (no bytes are read for a length of 0: the pointer may be null, as libstdc++ allows)
      @b = Str.own(ln != 0 ? Cpp.buf_bytes(p.B, p.O, ln) : [])
      @n = ln
      self
    end

    def assign_CPtr_CPtr(b0, e0) = assign_CPtr_ul(b0, e0.O - b0.O)
    def assign_Ptrc_Ptrc(b0, e0) = assign_CPtr_ul(CPtr.new(b0.a, b0.o), e0.o - b0.o)

    def assign_ul_i(count, ch)
      b = _reserve(count)
      b.fill(ch & 0xFF, 0, count)
      @n = count
      self
    end

    # ---- append and edit
    def append_Str(o)
      n = @n
      m = o.n
      b = @b
      b = _reserve(n + m) if n + m + 1 > b.length
      b[n, m] = o.b[0, m]
      @n = n + m
      self
    end

    def append_Str_ul_ul(o, pos, ln)
      n = @n
      m = o.n - pos
      raise IndexError, 'basic_string::append: position beyond the string' if m < 0
      m = ln if ln < m
      b = _reserve(n + m)
      b[n, m] = o.b[pos, m]
      @n = n + m
      self
    end

    def append_CPtr(p)
      src = Cpp.cb(p)
      n = @n
      m = src.length
      b = @b
      b = _reserve(n + m) if n + m + 1 > b.length
      b[n, m] = src
      @n = n + m
      self
    end

    def append_CPtr_ul(p, ln)
      return self if ln == 0
      src = Cpp.buf_bytes(p.B, p.O, ln)
      n = @n
      b = @b
      b = _reserve(n + ln) if n + ln + 1 > b.length
      b[n, ln] = src
      @n = n + ln
      self
    end

    # the bytes of a binary Ruby String appended (the runtime's streams: getline)
    def append_bytes(data)
      ln = data.bytesize
      return self if ln == 0
      n = @n
      b = @b
      b = _reserve(n + ln) if n + ln + 1 > b.length
      b[n, ln] = data.bytes
      @n = n + ln
      self
    end

    def append_ul_i(count, ch)
      n = @n
      b = _reserve(n + count)
      b.fill(ch & 0xFF, n, count)
      @n = n + count
      self
    end

    def append_i(ch)
      n = @n
      b = @b
      b = _reserve(n + 1) if n + 2 > b.length
      b[n] = ch & 0xFF
      @n = n + 1
      self
    end

    def push_back(ch)
      n = @n
      b = @b
      b = _reserve(n + 1) if n + 2 > b.length
      b[n] = ch & 0xFF
      @n = n + 1
    end

    def pop_back
      @n -= 1
    end

    def resize(m, ch = 0)
      n = @n
      b = _reserve(m)
      b.fill(ch & 0xFF, n, m - n) if m > n
      @n = m
    end
    alias resize_ul_i resize
    alias resize_ul resize

    def reserve(m)
      _reserve(m)
    end

    def shrink_to_fit; end

    def remove_prefix(k)
      n = @n
      b = @b
      b[0, n - k] = b[k, n - k]
      n -= k
      b[n] = 0
      @n = n
    end

    def remove_suffix(k)
      n = @n - k
      @b[n] = 0
      @n = n
    end

    def substr(pos = 0, ln = NPOS)
      n = @n
      raise OutOfRange.new("basic_string::substr: __pos (which is #{pos}) > this->size() (which is #{n})") if pos > n
      m = n - pos
      m = ln if ln < m
      t = @b[pos, m]
      t << 0
      Str.over(t, m)
    end

    def erase(pos = 0, ln = NPOS)
      n = @n
      m = n - pos
      m = ln if ln < m
      b = @b
      b[pos, n - m - pos] = b[pos + m, n - m - pos]
      @n = n - m
      self
    end

    def insert_ul_Str(pos, s)
      n = @n
      sn = s.n
      b = _reserve(n + sn)
      b[pos + sn, n - pos] = b[pos, n - pos]
      b[pos, sn] = s.b[0, sn]
      @n = n + sn
      self
    end

    def insert_ul_CPtr(pos, p) = insert_ul_Str(pos, Cpp.str_cptr(p))
    def insert_ul_ul_i(pos, count, ch) = insert_ul_Str(pos, Cpp.str_fill(count, ch))

    def replace_ul_ul_Str(pos, ln, s)
      n = @n
      m = n - pos
      m = ln if ln < m
      b = @b
      t = b[0, pos] + s.b[0, s.n] + b[pos + m, n - pos - m]
      t << 0
      @b = t
      @n = n - m + s.n
      self
    end

    def replace_ul_ul_CPtr(pos, ln, p) = replace_ul_ul_Str(pos, ln, Cpp.str_cptr(p))

    # ---- search (npos is 2^64 - 1)
    def _find(sub, pos)
      n = @n
      return pos <= n ? pos : NPOS if sub.empty?
      return NPOS if pos > n
      r = Cpp.bs(@b[0, n]).index(Cpp.bs(sub), pos)
      r.nil? ? NPOS : r
    end

    def find_Str_ul(s, pos = 0) = _find(s.b[0, s.n], pos)
    def find_CPtr_ul(p, pos = 0) = _find(Cpp.cb(p), pos)

    def find_i_ul(ch, pos = 0)
      n = @n
      return NPOS if pos >= n
      c = ch & 0xFF
      b = @b
      i = pos
      while i < n
        return i if b[i] == c
        i += 1
      end
      NPOS
    end

    def _rfind(sub, pos)
      n = @n
      m = sub.length
      return NPOS if m > n
      start = n - m
      start = pos if pos < start
      r = Cpp.bs(@b[0, start + m]).rindex(Cpp.bs(sub), start)
      r.nil? ? NPOS : r
    end

    def rfind_Str_ul(s, pos = NPOS) = _rfind(s.b[0, s.n], pos)
    def rfind_CPtr_ul(p, pos = NPOS) = _rfind(Cpp.cb(p), pos)

    def rfind_i_ul(ch, pos = NPOS)
      n = @n
      return NPOS if n == 0
      i = n - 1
      i = pos if pos < i
      c = ch & 0xFF
      while i >= 0
        return i if @b[i] == c
        i -= 1
      end
      NPOS
    end

    def _first_of(st, pos)
      b = @b
      i = pos
      while i < @n
        return i if st.include?(b[i])
        i += 1
      end
      NPOS
    end

    def _first_not_of(st, pos)
      b = @b
      i = pos
      while i < @n
        return i unless st.include?(b[i])
        i += 1
      end
      NPOS
    end

    def _last_of(st, pos)
      n = @n
      return NPOS if n == 0
      i = n - 1
      i = pos if pos < i
      while i >= 0
        return i if st.include?(@b[i])
        i -= 1
      end
      NPOS
    end

    def _last_not_of(st, pos)
      n = @n
      return NPOS if n == 0
      i = n - 1
      i = pos if pos < i
      while i >= 0
        return i unless st.include?(@b[i])
        i -= 1
      end
      NPOS
    end

    def find_first_of_Str_ul(s, pos = 0) = _first_of(s.b[0, s.n], pos)
    def find_first_of_CPtr_ul(p, pos = 0) = _first_of(Cpp.cb(p), pos)
    def find_first_of_i_ul(ch, pos = 0) = find_i_ul(ch, pos)
    def find_first_not_of_Str_ul(s, pos = 0) = _first_not_of(s.b[0, s.n], pos)
    def find_first_not_of_CPtr_ul(p, pos = 0) = _first_not_of(Cpp.cb(p), pos)
    def find_first_not_of_i_ul(ch, pos = 0) = _first_not_of([ch & 0xFF], pos)
    def find_last_of_Str_ul(s, pos = NPOS) = _last_of(s.b[0, s.n], pos)
    def find_last_of_CPtr_ul(p, pos = NPOS) = _last_of(Cpp.cb(p), pos)
    def find_last_of_i_ul(ch, pos = NPOS) = rfind_i_ul(ch, pos)
    def find_last_not_of_Str_ul(s, pos = NPOS) = _last_not_of(s.b[0, s.n], pos)
    def find_last_not_of_CPtr_ul(p, pos = NPOS) = _last_not_of(Cpp.cb(p), pos)
    def find_last_not_of_i_ul(ch, pos = NPOS) = _last_not_of([ch & 0xFF], pos)

    def starts_with_Str(s) = s.n <= @n && @b[0, s.n] == s.b[0, s.n]

    def starts_with_CPtr(p)
      sub = Cpp.cb(p)
      sub.length <= @n && @b[0, sub.length] == sub
    end

    def starts_with_i(ch) = @n > 0 && @b[0] == (ch & 0xFF)
    def ends_with_Str(s) = s.n <= @n && @b[@n - s.n, s.n] == s.b[0, s.n]

    def ends_with_CPtr(p)
      sub = Cpp.cb(p)
      sub.length <= @n && @b[@n - sub.length, sub.length] == sub
    end

    def ends_with_i(ch) = @n > 0 && @b[@n - 1] == (ch & 0xFF)
    def contains_Str(s) = find_Str_ul(s, 0) != NPOS
    def contains_i(ch) = find_i_ul(ch, 0) != NPOS

    # ---- comparison (char_traits<char>::compare is memcmp: unsigned bytes, then the length difference)
    def self.cmp(x, n, y, on)
      m = n < on ? n : on
      c = x[0, m] <=> y[0, m]
      return c if c != 0
      d = n - on
      d > 2147483647 ? 2147483647 : (d < -2147483648 ? -2147483648 : d)
    end

    def compare_Str(o) = Str.cmp(@b, @n, o.b, o.n)

    def compare_CPtr(p)
      y = Cpp.cb(p)
      Str.cmp(@b, @n, y, y.length)
    end

    def compare_ul_ul_Str(pos, ln, o) = substr(pos, ln).compare_Str(o)
    def CompareTo(o) = compare_Str(o)

    def Equals_Str(o)
      return true if o.equal?(self)
      return false if o.nil?
      n = @n
      o.n == n && @b[0, n] == o.b[0, n]
    end

    def Equals(o) = o.is_a?(Str) && Equals_Str(o)
    alias Equals_o Equals
    alias == Equals
    alias eql? Equals
    def hash = @b[0, @n].hash

    # C#'s GetHashCode (h = h * 31 + byte, wrapping at 32 bits); std::hash is StdHash's, not this
    def GetHashCode
      h = @n
      i = 0
      while i < @n
        h = (h * 31 + @b[i]) & 0xFFFFFFFF
        i += 1
      end
      h > 0x7FFFFFFF ? h - 0x100000000 : h
    end

    def EqLit(p)
      sub = Cpp.cb(p)
      sub.length == @n && @b[0, @n] == sub
    end

    # ---- conversions
    def Bytes = @b[0, @n]
    def ToString = @b[0, @n].pack('C*')
    alias to_s ToString
    def inspect = "Str(#{ToString().inspect})"
    def begin = Iter.new(nil, @b, 0)
    def end = Iter.new(nil, @b, @n)
    alias cbegin begin
    alias cend end
  end

  # ------------------------------------------------------------------------------------------------- constructors

  def NewStr = Str.new

  def NewStr_Str(s)
    t = s.b[0, s.n]
    t << 0
    Str.over(t, s.n)
  end

  # const char* -> std::string: the bytes to the NUL (the buffer is exactly length + 1, as the C#'s)
  def self.str_cptr(p)
    b = p.B
    o = p.O
    e = Cpp.zfind(b, o)
    t = b[o, e - o + 1]
    t.map! { |x| x & 0xFF } if t.any?(&:negative?)
    Str.over(t, e - o)
  end

  def NewStr_CPtr(p) = Cpp.str_cptr(p)
  def Str_from_CPtr(p) = Cpp.str_cptr(p)

  def NewStr_CPtr_ul(p, ln) = Str.over(Str.own(ln != 0 ? Cpp.buf_bytes(p.B, p.O, ln) : []), ln)

  def self.str_fill(count, ch)
    t = Array.new(count, ch & 0xFF)
    t << 0
    Str.over(t, count)
  end

  def NewStr_ul_i(count, ch) = Cpp.str_fill(count, ch)

  def NewStr_Str_ul_ul(s, pos, ln = NPOS)
    m = s.n - pos
    m = ln if ln < m
    t = s.b[pos, m]
    t << 0
    Str.over(t, m)
  end

  def NewStr_ucA_i_i(src, off, ln) = Str.over(Str.own(ln != 0 ? Cpp.buf_bytes(src, off, ln) : []), ln)

  # new Str(string): the bytes of a binary Ruby String (the Latin-1 bytes of the C# string)
  def self.str_of(text)
    t = text.bytes
    n = t.length
    t << 0
    Str.over(t, n)
  end

  def NewStr_str(text) = Cpp.str_of(text)
  def Str_of(text) = Cpp.str_of(text)

  def Str_FromBytes(x)
    m = x.length
    Str.over(Str.own(Cpp.buf_bytes(x, 0, m)), m)
  end

  # ------------------------------------------------------------------------------------------------- statics

  def Str_Cat_Str_Str(x, y)
    t = x.b[0, x.n] + y.b[0, y.n]
    t << 0
    Str.over(t, x.n + y.n)
  end

  def Str_Cat_Str_CPtr(x, y)
    src = Cpp.cb(y)
    t = x.b[0, x.n] + src
    t << 0
    Str.over(t, x.n + src.length)
  end

  def Str_Cat_CPtr_Str(x, y)
    src = Cpp.cb(x)
    t = src + y.b[0, y.n]
    t << 0
    Str.over(t, src.length + y.n)
  end

  def Str_Cat_Str_i(x, ch)
    t = x.b[0, x.n]
    t << (ch & 0xFF) << 0
    Str.over(t, x.n + 1)
  end

  def Str_Cat_i_Str(ch, y)
    t = [ch & 0xFF] + y.b[0, y.n]
    t << 0
    Str.over(t, y.n + 1)
  end

  def Str_to_string_i(v) = Cpp.str_of(v.to_s)
  alias Str_to_string_l Str_to_string_i
  alias Str_to_string_ul Str_to_string_i
  alias Str_to_string_u Str_to_string_i

  # std::to_string(double): libstdc++ formats it with "%f" (the runtime's exact printf)
  def Str_to_string_d(v) = Cpp.str_of(Cpp.fmt_float(v, '', -1, 6, 'f'))
  alias Str_to_string_f Str_to_string_d

  # std::stod (libstdc++'s __stoa over strtod): invalid_argument("stod") when nothing converts, out_of_range("stod")
  # when strtod sets ERANGE; idx, unless null, receives the number of bytes used.
  def Str_stod(s, idx = Ptr_ZERO)
    p = s.c_str
    e = Cell.new(p)
    v = R_strtod_CPtr_CPtrr(p, e)
    raise InvalidArgument.new('stod') if e.v.O == p.O
    raise OutOfRange.new('stod') if R_get_ERange()
    idx.set_Deref(e.v.O - p.O) unless idx.get_IsNull
    v
  end

  # C#'s R.strtol (base 10 whatever base is asked): spaces, a sign, digits; [value clamped to long, end offset],
  # end nil when no digit follows
  def self.strtol(p)
    b = p.B
    i = p.O
    i += 1 while [32, 9, 10, 11, 12, 13].include?(b[i])
    neg = false
    if b[i] == 43 || b[i] == 45
      neg = b[i] == 45
      i += 1
    end
    st = i
    v = 0
    while (c = b[i]) && c >= 48 && c <= 57
      v = v * 10 + (c - 48)
      i += 1
    end
    return [0, nil] if i == st
    v = -v if neg
    v = 9223372036854775807 if v > 9223372036854775807
    v = -9223372036854775808 if v < -9223372036854775808
    [v, i]
  end

  def Str_stoi(s, idx = Ptr_ZERO, bas = 10)
    p = s.c_str
    v, e = Cpp.strtol(p)
    raise InvalidArgument.new('stoi') if e.nil?
    raise OutOfRange.new('stoi') if v < -2147483648 || v > 2147483647
    idx.set_Deref(e - p.O) unless idx.get_IsNull
    v
  end

  def Str_stol(s, idx = Ptr_ZERO, bas = 10)
    p = s.c_str
    v, e = Cpp.strtol(p)
    raise InvalidArgument.new('stol') if e.nil?
    idx.set_Deref(e - p.O) unless idx.get_IsNull
    v
  end

  # ------------------------------------------------------------------------------------------------- exceptions
  # std::exception and the library's subclasses. An engine class deriving from one calls super() with no arguments
  # (the message is then "std::exception", as new CppException() gives). catch (System.Exception) is
  # rescue StandardError. RuntimeError and RangeError here are the C++ classes (Cpp::RuntimeError), not Ruby's.
  class CppException < StandardError
    attr_accessor :msg

    DEFAULT = 'std::exception'

    def initialize(m = nil)
      s = if m.nil? then Cpp.str_of(self.class::DEFAULT)
          elsif m.is_a?(String) then Cpp.str_of(m)
          else m.Clone
          end
      super(s.ToString)
      @msg = s
    end

    # the C# constructor CppException(Str) run on an allocated object of an engine class derived from it
    def _ctor_Str(m)
      @msg = m.Clone
    end

    def what = @msg.c_str
    def Message = message
  end

  class LogicError < CppException; end
  class RuntimeError < CppException; end
  class InvalidArgument < LogicError; end
  class OutOfRange < LogicError; end
  class LengthError < LogicError; end
  class DomainError < LogicError; end
  class RangeError < RuntimeError; end
  class OverflowError < RuntimeError; end
  class BadAlloc < CppException; DEFAULT = 'std::bad_alloc'; end
  class BadOptionalAccess < CppException; DEFAULT = 'bad optional access'; end
  class BadFunctionCall < CppException; DEFAULT = 'bad_function_call'; end
  class BadVariantAccess < CppException; DEFAULT = 'std::get: wrong index for variant'; end

  def NewCppException(m = nil) = CppException.new(m)
  alias NewCppException_Str NewCppException
  {
    'LogicError' => LogicError, 'RuntimeError' => RuntimeError, 'InvalidArgument' => InvalidArgument,
    'OutOfRange' => OutOfRange, 'LengthError' => LengthError, 'DomainError' => DomainError,
    'RangeError' => RangeError, 'OverflowError' => OverflowError
  }.each do |n, k|
    define_method("New#{n}_Str") { |m| k.new(m) }
    define_method("New#{n}_str") { |m| k.new(m) }
  end
  def NewBadAlloc(m = nil) = BadAlloc.new(m)
  def NewBadOptionalAccess(m = nil) = BadOptionalAccess.new(m)
  def NewBadFunctionCall(m = nil) = BadFunctionCall.new(m)
  def NewBadVariantAccess(m = nil) = BadVariantAccess.new(m)
end
