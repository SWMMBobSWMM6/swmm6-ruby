# encoding: binary
# frozen_string_literal: true
# core_ptr.rb - the runtime structs that point into storage: CPtr (C's char*, the struct at the top of
# cs/runtime/CRuntime.cs), Ptr<T> (a raw pointer into an array, or to one field of an object), Iter<T> and
# RevIter<T> (vector iterators), CSpan<T> (std::span) and Box<T> (a reference member), from cs/runtime/Std.cs and
# Misc.cs. Every struct is an immutable object shared freely: arithmetic makes a new one. One Ruby class serves
# every element type (Ptr<double>, Ptr<int>, ...): the specialised names the engine uses are aliases.
# Byte buffers (a Str's storage, a C buffer, a literal, a byte[] or sbyte[] the engine made) are Arrays of Integers.
# A port of py/cpp/core_ptr.py. Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.

module Cpp
  CODES = ['', 'D', 'F', 'I', 'L', 'B', 'Z', 'S', 'C'].freeze

  # The offset of the first NUL in byte buffer b at or after o (C# R.strlen runs off the array without one: here
  # an IndexError).
  def self.zfind(b, o)
    i = o
    while (c = b[i]) != 0
      raise IndexError, 'cpp: no NUL in a C string buffer' if c.nil?
      i += 1
    end
    i
  end

  # m bytes of buffer b from offset o as an Array of 0..255. IndexError when the buffer is shorter, as C#'s
  # Array.Copy throws.
  def self.buf_bytes(b, o, m)
    r = o >= 0 ? b[o, m] : nil
    raise IndexError, "cpp: byte range #{o}+#{m} outside a buffer of #{b.length}" if r.nil? || r.length != m
    r.map { |x| x & 0xFF }
  end

  # The bytes of the C string at p (up to its NUL), values 0..255
  def self.cstr_bytes(p)
    b = p.B
    o = p.O
    e = Cpp.zfind(b, o)
    b[o, e - o].map { |x| x & 0xFF }
  end

  # C#'s R.Str(p): the C string at p as a binary Ruby String (Latin-1 bytes); to the end of the buffer if no NUL
  def self.cstr_text(p)
    b = p.B
    o = p.O
    e = o
    e += 1 while (c = b[e]) && c != 0
    b[o, e - o].pack('C*')
  end

  def self.cstr_len(p) = Cpp.zfind(p.B, p.O) - p.O

  # ------------------------------------------------------------------------------------------------- CPtr
  # C char*: a byte buffer B (an Array) and an offset O; a nil B is the null pointer. Element reads give the signed
  # char (x86 C's char), writes store the low byte.
  class CPtr
    attr_reader :B, :O

    def initialize(b, o)
      @B = b
      @O = o
    end

    def Clone = self
    def get_IsNull = @B.nil?

    def get(i)
      x = @B[@O + i]
      x > 127 ? x - 256 : x
    end

    def set(i, v)
      @B[@O + i] = v & 0xFF
    end

    def assign(i, v)
      @B[@O + i] = v & 0xFF
      v
    end

    def ref(i) = ByteRef.new(@B, @O + i)

    def preInc(i)
      k = @O + i
      x = @B[k]
      v = (x > 127 ? x - 256 : x) + 1
      @B[k] = v & 0xFF
      v
    end

    def preDec(i)
      k = @O + i
      x = @B[k]
      v = (x > 127 ? x - 256 : x) - 1
      @B[k] = v & 0xFF
      v
    end

    def postInc(i)
      k = @O + i
      x = @B[k]
      v = x > 127 ? x - 256 : x
      @B[k] = (v + 1) & 0xFF
      v
    end

    def postDec(i)
      k = @O + i
      x = @B[k]
      v = x > 127 ? x - 256 : x
      @B[k] = (v - 1) & 0xFF
      v
    end

    alias get_Item get
    alias get_Item_i get
    alias set_Item set
    alias set_Item_i set
    alias ref_Item ref
    alias ref_Item_i ref

    # C#'s Equals / GetHashCode: the same buffer and, unless null, the same offset
    def Equals(o) = o.is_a?(CPtr) && o.B.equal?(@B) && (@B.nil? || o.O == @O)
    alias Equals_CPtr Equals
    alias Equals_o Equals
    alias == Equals
    alias eql? Equals

    def hash = (@B.nil? ? 0 : @B.object_id) ^ @O
    def GetHashCode = ((@B.nil? ? 0 : @B.object_id) ^ @O) & 0x7FFFFFFF

    # the NUL-terminated bytes as text, "(null)" for the null pointer
    def ToString = @B.nil? ? '(null)' : Cpp.cstr_text(self)
    alias to_s ToString

    def inspect = "CPtr(#{@B.nil? ? 'nil' : 'Array'}, #{@O})"
  end

  CPtr_ZERO = CPtr.new(nil, 0)     # default(CPtr): the null pointer
  CPtr_Null = CPtr_ZERO
  MK_CPtr = -> { CPtr_ZERO }
  IMMUTABLE_MAKERS[MK_CPtr] = true

  # a char* made from a std::vector<char> / std::array<char, N> or unsigned char storage: the same Array
  def CPtr_from_Ptrc(p) = CPtr.new(p.a, p.o)
  def CPtr_from_Ptruc(p) = CPtr.new(p.a, p.o)
  def CPtr_op_Add_CPtr_i(p, n) = CPtr.new(p.B, p.O + n)
  alias CPtr_op_Add_CPtr_l CPtr_op_Add_CPtr_i
  alias CPtr_op_Add_CPtr_ul CPtr_op_Add_CPtr_i
  alias CPtr_op_Add CPtr_op_Add_CPtr_i
  def CPtr_op_Sub(p, n) = CPtr.new(p.B, p.O - n)
  alias CPtr_op_Sub_CPtr_i CPtr_op_Sub
  def CPtr_op_Increment(p) = CPtr.new(p.B, p.O + 1)
  def CPtr_op_Decrement(p) = CPtr.new(p.B, p.O - 1)
  def CPtr_op_Eq(a, b) = a.B.equal?(b.B) && (a.B.nil? || a.O == b.O)
  def CPtr_op_Ne(a, b) = !(a.B.equal?(b.B) && (a.B.nil? || a.O == b.O))
  def CPtr_op_Lt(a, b) = a.O < b.O
  def CPtr_op_Gt(a, b) = a.O > b.O
  def CPtr_op_Le(a, b) = a.O <= b.O
  def CPtr_op_Ge(a, b) = a.O >= b.O
  def CPtr_Diff(a, b) = a.O - b.O

  # ------------------------------------------------------------------------------------------------- Ptr
  # A raw pointer to T inside an array (C# Cpp.Ptr<T>): the Array a and the offset o; null has a nil Array. A
  # pointer made by &obj.field is a FieldPtr, which keeps the object ob and a RefAt callable at (at.call(ob) gives a
  # Ref to the field); for an array pointer ob and at are nil.
  class Ptr
    attr_reader :a, :o

    def initialize(a, o)
      @a = a
      @o = o
    end

    def ob = nil
    def at = nil
    def Clone = self
    def get_IsNull = @a.nil?
    def add(k) = Ptr.new(@a, @o + k)

    def get_Item_i(i) = @a[@o + i]
    alias get_Item_l get_Item_i
    alias get_Item_ul get_Item_i
    alias get_Item get_Item_i

    def set_Item_i(i, v)
      @a[@o + i] = v
    end
    alias set_Item_l set_Item_i
    alias set_Item_ul set_Item_i
    alias set_Item set_Item_i

    def ref_Item_i(i) = ArrRef.new(@a, @o + i)
    alias ref_Item_l ref_Item_i
    alias ref_Item_ul ref_Item_i
    alias ref_Item ref_Item_i

    def get_Deref = @a[@o]

    def set_Deref(v)
      @a[@o] = v
    end

    def ref_Deref = ArrRef.new(@a, @o)

    def Equals(q) = q.is_a?(Ptr) && Cpp.ptr_eq(self, q)
    alias Equals_PtrT Equals
    alias Equals_o Equals
    alias == Equals
    alias eql? Equals
    def hash = @o.hash
    def GetHashCode = Cpp.i32(@o)

    def inspect = "Ptr(#{@a.nil? ? 'nil' : 'Array'}, #{@o})"
  end

  # &obj.field: every element access is the field (the offset only counts for pointer arithmetic and comparison)
  class FieldPtr < Ptr
    attr_reader :ob, :at

    def initialize(o, ob, at)
      super(nil, o)
      @ob = ob
      @at = at
    end

    def get_IsNull = false
    def add(k) = FieldPtr.new(@o + k, @ob, @at)
    def get_Item_i(_i) = @at.call(@ob).v
    alias get_Item_l get_Item_i
    alias get_Item_ul get_Item_i
    alias get_Item get_Item_i

    def set_Item_i(_i, v)
      @at.call(@ob).v = v
    end
    alias set_Item_l set_Item_i
    alias set_Item_ul set_Item_i
    alias set_Item set_Item_i

    def ref_Item_i(_i) = @at.call(@ob)
    alias ref_Item_l ref_Item_i
    alias ref_Item_ul ref_Item_i
    alias ref_Item ref_Item_i
    def get_Deref = @at.call(@ob).v

    def set_Deref(v)
      @at.call(@ob).v = v
    end

    def ref_Deref = @at.call(@ob)
    def inspect = "Ptr(field of #{@ob.class})"
  end

  # two field pointers are equal when they reach the same object through lambdas from the same place in the source
  # (C# compares the delegates' methods); two array pointers when the Arrays are the same and, unless null, the
  # offsets too
  def self.ptr_eq(p, q)
    pa = p.at
    qa = q.at
    if pa || qa
      return !pa.nil? && !qa.nil? && p.ob.equal?(q.ob) && (pa.equal?(qa) || pa.source_location == qa.source_location) && p.o == q.o
    end
    p.a.equal?(q.a) && (p.a.nil? || p.o == q.o)
  end

  Ptr_ZERO = Ptr.new(nil, 0)       # default(Ptr<T>): the null pointer (one object serves every T)
  MK_Ptr = -> { Ptr_ZERO }
  IMMUTABLE_MAKERS[MK_Ptr] = true

  def NewPtr_TA_l(a, o) = Ptr.new(a, o)
  def NewPtr_o_RefAtT(ob, at) = FieldPtr.new(0, ob, at)
  def Ptr_op_Add_PtrT_l(p, k) = p.add(k)
  alias Ptr_op_Add_PtrT_ul Ptr_op_Add_PtrT_l
  def Ptr_op_Sub_PtrT_l(p, k) = p.add(-k)
  def Ptr_op_Sub_PtrT_PtrT(p, q) = p.o - q.o
  def Ptr_op_Increment(p) = p.add(1)
  def Ptr_op_Decrement(p) = p.add(-1)
  def Ptr_op_Eq(p, q) = Cpp.ptr_eq(p, q)
  def Ptr_op_Ne(p, q) = !Cpp.ptr_eq(p, q)
  def Ptr_op_Lt(p, q) = p.o < q.o
  def Ptr_op_Gt(p, q) = p.o > q.o
  def Ptr_op_Le(p, q) = p.o <= q.o
  def Ptr_op_Ge(p, q) = p.o >= q.o
  def Ptr_from_IterT(it) = Ptr.new(it.a, it.i)

  # ------------------------------------------------------------------------------------------------- Iter
  # A vector iterator (C# Cpp.Iter<T>): the vector v (nil when made from a bare array or a Str's buffer), the
  # storage a when made, and an index i. Arithmetic re-reads the vector's current storage, as the C# does.
  class Iter
    attr_reader :v, :a, :i

    def initialize(v, a, i)
      @v = v
      @a = a
      @i = i
    end

    def Clone = self
    def get_Deref = @a[@i]

    def set_Deref(x)
      @a[@i] = x
    end

    def ref_Deref = ArrRef.new(@a, @i)
    def get_Item(k) = @a[@i + k]

    def set_Item(k, x)
      @a[@i + k] = x
    end

    def ref_Item(k) = ArrRef.new(@a, @i + k)
    alias get_Item_l get_Item
    alias set_Item_l set_Item
    alias ref_Item_l ref_Item

    def Equals(o) = o.is_a?(Iter) && o.i == @i
    alias Equals_IterT Equals
    alias Equals_o Equals
    alias == Equals
    alias eql? Equals
    def hash = @i.hash
    def GetHashCode = Cpp.i32(@i)
    def inspect = "Iter(#{@v ? 'vec' : 'array'}, #{@i})"
  end

  Iter_ZERO = Iter.new(nil, nil, 0)
  MK_Iter = -> { Iter_ZERO }
  IMMUTABLE_MAKERS[MK_Iter] = true

  def NewIter_TA_l(a, i) = Iter.new(nil, a, i)
  def NewIter_VecT_l(v, i) = Iter.new(v, v.a, i)

  def Iter_op_Add(x, k)
    v = x.v
    v.nil? ? Iter.new(nil, x.a, x.i + k) : Iter.new(v, v.a, x.i + k)
  end

  def Iter_op_Sub_IterT_l(x, k) = Iter_op_Add(x, -k)
  def Iter_op_Sub_IterT_IterT(x, y) = x.i - y.i

  def Iter_op_Increment(x)
    v = x.v
    v.nil? ? Iter.new(nil, x.a, x.i + 1) : Iter.new(v, v.a, x.i + 1)
  end

  def Iter_op_Decrement(x) = Iter_op_Add(x, -1)
  def Iter_op_Eq(x, y) = x.i == y.i
  def Iter_op_Ne(x, y) = x.i != y.i
  def Iter_op_Lt(x, y) = x.i < y.i
  def Iter_op_Gt(x, y) = x.i > y.i
  def Iter_op_Le(x, y) = x.i <= y.i
  def Iter_op_Ge(x, y) = x.i >= y.i

  # ------------------------------------------------------------------------------------------------- RevIter
  # std::reverse_iterator over a vector: the vector and one past the element it designates.
  class RevIter
    attr_reader :v, :i

    def initialize(v, i)
      @v = v
      @i = i
    end

    def Clone = self
    def get_Deref = @v.a[@i - 1]

    def set_Deref(x)
      @v.a[@i - 1] = x
    end

    def ref_Deref = ArrRef.new(@v.a, @i - 1)
    def Equals(o) = o.is_a?(RevIter) && o.i == @i
    alias Equals_o Equals
    alias == Equals
    alias eql? Equals
    def hash = @i.hash
    def GetHashCode = Cpp.i32(@i)
  end

  RevIter_ZERO = RevIter.new(nil, 0)
  MK_RevIter = -> { RevIter_ZERO }
  IMMUTABLE_MAKERS[MK_RevIter] = true
  def NewRevIter_VecT_l(v, i) = RevIter.new(v, i)
  def RevIter_op_Increment(x) = RevIter.new(x.v, x.i - 1)
  def RevIter_op_Eq(x, y) = x.i == y.i
  def RevIter_op_Ne(x, y) = x.i != y.i

  # ------------------------------------------------------------------------------------------------- CSpan
  # std::span<T>: n elements of the Array a starting at o. The engine reads a, o and n.
  class CSpan
    attr_reader :a, :o, :n

    def initialize(a, o, n)
      @a = a
      @o = o
      @n = n
    end

    def Clone = self
    def get_Item(i) = @a[@o + i]

    def set_Item(i, x)
      @a[@o + i] = x
    end

    def ref_Item(i) = ArrRef.new(@a, @o + i)
    alias get_Item_l get_Item
    alias set_Item_l set_Item
    alias ref_Item_l ref_Item
    def size = @n
    def empty = @n == 0
    def data = Ptr.new(@a.nil? ? [] : @a, @o)
    def front = @a[@o]
    def back = @a[@o + @n - 1]
    def ref_front = ArrRef.new(@a, @o)
    def ref_back = ArrRef.new(@a, @o + @n - 1)
    def subspan(off, cnt = 0xFFFFFFFFFFFFFFFF) = CSpan.new(@a, @o + off, cnt == 0xFFFFFFFFFFFFFFFF ? @n - off : cnt)
    alias subspan_ul_ul subspan
    def first(cnt) = CSpan.new(@a, @o, cnt)
    def last(cnt) = CSpan.new(@a, @o + @n - cnt, cnt)
    def Equals(x) = x.is_a?(CSpan) && x.a.equal?(@a) && x.o == @o && x.n == @n
    alias == Equals
    alias eql? Equals
    def hash = [@a.object_id, @o, @n].hash
  end

  CSpan_ZERO = CSpan.new(nil, 0, 0)
  MK_CSpan = -> { CSpan_ZERO }
  IMMUTABLE_MAKERS[MK_CSpan] = true
  def NewCSpan_TA_l_l(a, o, n) = CSpan.new(a, o, n)

  # ------------------------------------------------------------------------------------------------- Box
  # A reference member of a class (T& held by an object, C# Cpp.Box<T>): an array cell a[o], or the place a RefGet
  # callable g reaches (g.call gives a Ref).
  class Box
    attr_reader :a, :o, :g

    def initialize(a, o, g = nil)
      @a = a
      @o = o
      @g = g
    end

    def get_V = @g.nil? ? @a[@o] : @g.call.v

    def set_V(x)
      if @g.nil?
        @a[@o] = x
      else
        @g.call.v = x
      end
    end

    def ref_V = @g.nil? ? ArrRef.new(@a, @o) : @g.call
  end

  def NewBox_TA_l(a, o) = Box.new(a, o)
  def NewBox_RefGetT(g) = Box.new(nil, 0, g)
  def Box_Of(g) = Box.new(nil, 0, g)

  # ------------------------------------------------------------------------------------------------- aliases
  # The specialised names: one function serves every element type.
  [['Ptr@_ZERO', Ptr_ZERO], ['Iter@_ZERO', Iter_ZERO], ['RevIter@_ZERO', RevIter_ZERO], ['CSpan@_ZERO', CSpan_ZERO],
   ['MK_Ptr@', MK_Ptr], ['MK_Iter@', MK_Iter], ['MK_RevIter@', MK_RevIter], ['MK_CSpan@', MK_CSpan]].each do |n, v|
    CODES[1..].each { |c| const_set(n.sub('@', c), v) }
  end
  CODES[1..].each do |c|
    %w[Ptr Iter RevIter CSpan Box].each { |k| const_set(k + c, const_get(k)) }
  end
  %w[NewPtr@_TA_l NewPtr@_o_RefAtT Ptr@_op_Add_PtrT_l Ptr@_op_Add_PtrT_ul Ptr@_op_Sub_PtrT_l Ptr@_op_Sub_PtrT_PtrT
     Ptr@_op_Increment Ptr@_op_Decrement Ptr@_op_Eq Ptr@_op_Ne Ptr@_op_Lt Ptr@_op_Gt Ptr@_op_Le Ptr@_op_Ge
     Ptr@_from_IterT NewIter@_TA_l NewIter@_VecT_l Iter@_op_Add Iter@_op_Sub_IterT_l Iter@_op_Sub_IterT_IterT
     Iter@_op_Increment Iter@_op_Decrement Iter@_op_Eq Iter@_op_Ne Iter@_op_Lt Iter@_op_Gt Iter@_op_Le Iter@_op_Ge
     NewRevIter@_VecT_l RevIter@_op_Increment RevIter@_op_Eq RevIter@_op_Ne NewCSpan@_TA_l_l Box@_Of NewBox@_TA_l
     NewBox@_RefGetT].each do |n|
    base = n.sub('@', '')
    CODES[1..].each { |c| alias_method n.sub('@', c), base }
  end
  CODES[1..].each { |c| alias_method "Box_Of__#{c}", :Box_Of }
end
