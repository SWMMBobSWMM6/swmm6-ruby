# encoding: binary
# frozen_string_literal: true
# core_vec.rb - std::vector (Vec and its specialisations VecD, VecI, ...), std::optional (Opt), std::pair (Pair),
# std::min/max/clamp (M), the array helpers (Arr, System.Array.Fill), moves and out-parameter copy-back (Mv),
# destructors (Dtor, Defer). From cs/runtime/Std.cs and Misc.cs, by way of py/cpp/core_vec.py.
# A vector is the Array a, whose length is the capacity (libstdc++'s growth: a full vector grows to
# size + max(size, 1), into a new Array, as the C#'s Array.Resize makes a new array), and the count n; the engine
# reads and writes v.a[i] and v.n directly. Slots past n always hold the element type's default value.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.

module Cpp
  ZEROS = { 'D' => 0.0, 'F' => 0.0, 'I' => 0, 'L' => 0, 'B' => 0, 'Z' => false, 'S' => 0, 'C' => 0 }.freeze

  # ------------------------------------------------------------------------------------------------- Vec
  class VecBase
    include ICopy
    include IDestroyElems
    attr_accessor :a, :n

    def _z = nil

    def size = @n
    def empty = @n == 0
    def capacity = @a.length

    def at(i)
      raise OutOfRange.new("vector::_M_range_check: __n (which is #{i}) >= this->size() (which is #{@n})") if i >= @n
      @a[i]
    end

    def ref_at(i)
      raise OutOfRange.new("vector::_M_range_check: __n (which is #{i}) >= this->size() (which is #{@n})") if i >= @n
      ArrRef.new(@a, i)
    end

    def front = @a[0]
    def back = @a[@n - 1]
    def ref_front = ArrRef.new(@a, 0)
    def ref_back = ArrRef.new(@a, @n - 1)

    # libstdc++'s data() is nullptr until the vector first allocates (capacity 0); the engine tests it for null
    def data = @a.empty? ? Ptr_ZERO : Ptr.new(@a, 0)

    def get_Item(i) = @a[i]

    def set_Item(i, v)
      @a[i] = v
    end

    def ref_Item(i) = ArrRef.new(@a, i)
    alias get_Item_ul get_Item
    alias get_Item_l get_Item
    alias get_Item_i get_Item
    alias set_Item_ul set_Item
    alias set_Item_l set_Item
    alias set_Item_i set_Item
    alias ref_Item_ul ref_Item
    alias ref_Item_l ref_Item
    alias ref_Item_i ref_Item

    # Vec.Grow: libstdc++'s new capacity, size + max(size, 1), at least need; a new Array holding the old one
    def _grow(need)
      a = @a
      la = a.length
      return a if need <= la
      n = @n
      cap = n + (n > 1 ? n : 1)
      cap = need if cap < need
      @a = a + Array.new(cap - la, _z)
    end

    def reserve(c)
      a = @a
      @a = a + Array.new(c - a.length, _z) if c > a.length
    end

    def shrink_to_fit
      @a = @a[0, @n] if @a.length != @n
    end

    def push_back(v)
      a = @a
      n = @n
      a = _grow(n + 1) if n == a.length
      a[n] = v
      @n = n + 1
    end

    def emplace_back(v)
      push_back(v)
      v
    end

    def ref_emplace_back(v)
      push_back(v)
      ArrRef.new(@a, @n - 1)
    end

    def pop_back
      n = @n - 1
      @n = n
      @a[n] = _z
    end

    def clear
      n = @n
      @a.fill(_z, 0, n) if n > 0
      @n = 0
    end

    def swap(o)
      @a, o.a = o.a, @a
      @n, o.n = o.n, @n
    end

    def begin = Iter.new(self, @a, 0)
    def end = Iter.new(self, @a, @n)
    alias cbegin begin
    alias cend end
    def rbegin = RevIter.new(self, @n)
    def rend = RevIter.new(self, 0)

    def each(&blk)
      @a[0, @n].each(&blk)
    end

    def insert_IterT_T(pos, v)
      p = pos.i
      n = @n
      a = @a
      a = _grow(n + 1) if n == a.length
      a[p + 1, n - p] = a[p, n - p]
      a[p] = v
      @n = n + 1
      Iter.new(self, a, p)
    end

    def _insert(p, tmp)
      m = tmp.length
      n = @n
      a = _grow(n + m)
      a[p + m, n - p] = a[p, n - p]
      a[p, m] = tmp
      @n = n + m
      Iter.new(self, a, p)
    end

    def insert_IterT_IterT_IterT(pos, b, e) = _insert(pos.i, _copy_range(b.a, b.i, e.i - b.i))
    def insert_IterT_TA(pos, il) = _insert(pos.i, _copy_range(il, 0, il.length))
    def insert_IterT_PtrT_PtrT(pos, b, e) = _insert(pos.i, _copy_range(b.a, b.o, e.o - b.o))

    def insert_IterT_ul_T(pos, cnt, v)
      p = pos.i
      n = @n
      a = _grow(n + cnt)
      a[p + cnt, n - p] = a[p, n - p]
      a[p, cnt] = _fill_copies(v, cnt)
      @n = n + cnt
      Iter.new(self, a, p)
    end

    def erase_IterT(pos)
      p = pos.i
      n = @n - 1
      a = @a
      a[p, n - p] = a[p + 1, n - p]
      a[n] = _z
      @n = n
      Iter.new(self, a, p)
    end

    def erase_IterT_IterT(b, e)
      p = b.i
      q = e.i
      n = @n
      a = @a
      m = q - p
      a[p, n - m - p] = a[q, n - q]
      a.fill(_z, n - m, m)
      @n = n - m
      Iter.new(self, a, p)
    end

    def assign_ul_T(c, v)
      a = @a
      la = a.length
      if c > la
        a = Array.new(c, _z)
        @a = a
      else
        a.fill(_z)
      end
      a[0, c] = _fill_copies(v, c)
      @n = c
    end

    def assign_IterT_IterT(b, e)
      m = e.i - b.i
      @a = _copy_range(b.a, b.i, m)
      @n = m
    end

    def assign_TA(il)
      @a = _copy_range(il, 0, il.length)
      @n = il.length
    end
    alias Assign_TA assign_TA
    alias MoveFrom_TA assign_TA

    def resize_ul_T(c, v)
      n = @n
      if c > n
        a = _grow(c)
        a[n, c - n] = _fill_copies(v, c - n)
      else
        @a.fill(_z, c, n - c)
      end
      @n = c
    end

    def inspect = "#{self.class.name.split('::').last}(#{@a[0, @n].inspect})"
  end

  # std::vector of a primitive (double, int, bool, ...): elements copy by value.
  class VecP < VecBase
    def initialize
      @a = []
      @n = 0
    end

    def _copy_range(src, o, m)
      r = src[o, m]
      raise IndexError, 'cpp.Vec: range outside its array' if r.nil? || r.length != m
      r
    end

    def _fill_copies(v, m) = Array.new(m, v)

    def resize_ul(c)
      n = @n
      if c > n
        _grow(c)
      else
        @a.fill(_z, c, n - c)
      end
      @n = c
    end
    alias resize resize_ul

    def DestroyElems; end

    def Clone
      v = self.class.allocate
      v.a = @a[0, @n]
      v.n = @n
      v
    end

    def Assign_VecT(o)
      return if o.equal?(self)
      @a = o.a[0, o.n]
      @n = o.n
    end

    # move-assign: take o's storage and leave o empty, as libstdc++ does
    def MoveFrom_VecT(o)
      return if o.equal?(self)
      @a = o.a
      @n = o.n
      o.a = []
      o.n = 0
    end

    def Assign(o)
      o.instance_of?(Array) ? assign_TA(o) : Assign_VecT(o)
    end

    def MoveFrom(o)
      o.instance_of?(Array) ? assign_TA(o) : MoveFrom_VecT(o)
    end
  end

  def self.vec_eq_plain(x, y)
    n = x.n
    n == y.n && x.a[0, n] == y.a[0, n]
  end

  # Vec<double>.Eq: EqualityComparer<double> (NaN equals NaN)
  def self.vec_eq_double(x, y)
    n = x.n
    return false if n != y.n
    xa = x.a
    ya = y.a
    i = 0
    while i < n
      p = xa[i]
      q = ya[i]
      return false if p != q && (p == p || q == q)
      i += 1
    end
    true
  end

  # std::vector<T> of a reference or struct type T: mk makes a new element (the maker the translator passes, or the
  # Func<T> the C# constructor takes); mkx tells whether C# would hold it as its mk field (a Func<T> given to the
  # constructor) rather than use Elem<T>.Make, which matters for Assign and MoveFrom (C#'s mk ??= o.mk).
  class Vec < VecBase
    attr_accessor :mk, :mkx

    def initialize(mk = nil)
      @a = []
      @n = 0
      @mk = mk
      @mkx = false
    end

    def _copy_range(src, o, m)
      r = src[o, m]
      raise IndexError, 'cpp.Vec: range outside its array' if r.nil? || r.length != m
      Cpp.copies(r)
    end

    def _fill_copies(v, m)
      return Array.new(m) { v.Clone() } if v.is_a?(ICopy)
      return Array.new(m) { Cpp.deep(v) } if v.instance_of?(Array)
      Array.new(m, v)
    end

    def _made(m) = Cpp.made(@mk, m)

    def resize_ul(c)
      n = @n
      if c > n
        a = _grow(c)
        a[n, c - n] = _made(c - n)
      else
        @a.fill(nil, c, n - c)
      end
      @n = c
    end
    alias resize resize_ul

    # ~vector: each element's destructor in order, first to last (libstdc++ _Destroy)
    def DestroyElems
      a = @a
      i = 0
      while i < @n
        Cpp.dtor(a[i])
        i += 1
      end
    end

    def Clone
      v = Vec.allocate
      v.mk = @mk
      v.mkx = @mkx
      v.a = Cpp.copies(@a[0, @n])
      v.n = @n
      v
    end

    def _adopt(o)
      return unless !@mkx && o.mkx
      @mk = o.mk
      @mkx = true
    end

    def Assign_VecT(o)
      return if o.equal?(self)
      @a = Cpp.copies(o.a[0, o.n])
      @n = o.n
      _adopt(o)
    end

    def MoveFrom_VecT(o)
      return if o.equal?(self)
      @a = o.a
      @n = o.n
      _adopt(o)
      o.a = []
      o.n = 0
    end

    def Assign(o)
      o.instance_of?(Array) ? assign_TA(o) : Assign_VecT(o)
    end

    def MoveFrom(o)
      o.instance_of?(Array) ? assign_TA(o) : MoveFrom_VecT(o)
    end
  end

  ZEROS.each do |c, z|
    k = Class.new(VecP)
    k.class_eval("def _z = #{z.inspect}", __FILE__, __LINE__)
    const_set("Vec#{c}", k)
    define_method("NewVec#{c}") { k.new }
    define_method("NewVec#{c}_ul") do |count|
      v = k.allocate
      v.a = Array.new(count, z)
      v.n = count
      v
    end
    define_method("NewVec#{c}_ul_T") do |count, x|
      v = k.allocate
      v.a = Array.new(count, x)
      v.n = count
      v
    end
    define_method("NewVec#{c}_TA") do |init|
      v = k.allocate
      v.a = init.dup
      v.n = init.length
      v
    end
    define_method("Vec#{c}_Adopt") do |arr|
      v = k.allocate
      v.a = arr
      v.n = arr.length
      v
    end
    if c == 'D' || c == 'F'
      define_method("Vec#{c}_Eq") { |x, y| Cpp.vec_eq_double(x, y) }
    else
      define_method("Vec#{c}_Eq") { |x, y| Cpp.vec_eq_plain(x, y) }
    end
  end

  def NewVec(mk = nil) = Vec.new(mk)

  def NewVec_FuncT(mk)
    v = Vec.new(mk)
    v.mkx = true
    v
  end

  def NewVec_ul(count, mk)
    v = Vec.new(mk)
    v.a = v._made(count)
    v.n = count
    v
  end

  def NewVec_ul_FuncT(count, mk)
    v = NewVec_ul(count, mk)
    v.mkx = true
    v
  end

  def NewVec_ul_T(count, x, mk)
    v = Vec.new(mk)
    v.a = v._fill_copies(x, count)
    v.n = count
    v
  end

  def NewVec_TA(init, mk)
    v = Vec.new(mk)
    v.a = Cpp.copies(init)
    v.n = init.length
    v
  end

  def Vec_Adopt(arr, mk = nil)
    v = Vec.new(mk)
    v.a = arr
    v.n = arr.length
    v
  end

  def Vec_Eq(x, y)
    n = x.n
    return false if n != y.n
    xa = x.a
    ya = y.a
    i = 0
    while i < n
      return false unless Cpp.elem_eq(xa[i], ya[i])
      i += 1
    end
    true
  end

  # ------------------------------------------------------------------------------------------------- Opt
  class OptValRef < Ref
    def initialize(o)
      @o = o
    end

    def v = @o.val

    def v=(x)
      @o.val = x
    end
  end

  # std::optional<T>: has, and val (the default value of T when empty).
  class Opt
    include ICopy
    include IDestroyElems
    attr_accessor :has, :val

    def _z = nil

    def initialize
      @has = false
      @val = _z
    end

    def DestroyElems
      Cpp.dtor(@val) if @has
    end

    def has_value = @has

    def value
      raise BadOptionalAccess.new unless @has
      @val
    end

    def ref_value
      raise BadOptionalAccess.new unless @has
      OptValRef.new(self)
    end

    def get_Deref = @val

    def set_Deref(x)
      @val = x
    end

    def ref_Deref = OptValRef.new(self)
    def value_or(d) = @has ? @val : d

    def reset
      @has = false
      @val = _z
    end

    def MoveFrom(o)
      return if o.equal?(self)
      @has = o.has
      @val = o.val
    end

    def emplace(v)
      @has = true
      @val = v
    end

    def ref_emplace(v)
      @has = true
      @val = v
      OptValRef.new(self)
    end

    def Clone
      c = self.class.allocate
      if @has
        c.has = true
        c.val = Cpp.copy(@val)
      else
        c.has = false
        c.val = _z
      end
      c
    end

    def Assign(o)
      @has = o.has
      @val = o.has ? Cpp.copy(o.val) : _z
    end

    def Set(v)
      @has = true
      @val = v
    end

    def inspect = @has ? "Opt(#{@val.inspect})" : 'Opt()'
  end

  def NewOpt = Opt.new

  def NewOpt_T(v)
    o = Opt.allocate
    o.has = true
    o.val = v
    o
  end

  ZEROS.each do |c, z|
    k = Class.new(Opt)
    k.class_eval("def _z = #{z.inspect}", __FILE__, __LINE__)
    const_set("Opt#{c}", k)
    define_method("NewOpt#{c}") { k.new }
    define_method("NewOpt#{c}_T") do |v|
      o = k.allocate
      o.has = true
      o.val = v
      o
    end
  end

  # ------------------------------------------------------------------------------------------------- Pair
  class FirstRef < Ref
    def initialize(p)
      @p = p
    end

    def v = @p.first

    def v=(x)
      @p.first = x
    end
  end

  class SecondRef < Ref
    def initialize(p)
      @p = p
    end

    def v = @p.second

    def v=(x)
      @p.second = x
    end
  end

  # std::pair: a mutable class, so p.first = x works through references.
  class Pair
    include ICopy
    attr_accessor :first, :second

    def initialize(a, b)
      @first = a
      @second = b
    end

    def Clone = Pair.new(Cpp.copy(@first), Cpp.copy(@second))

    def Assign(o)
      @first = Cpp.copy(o.first)
      @second = Cpp.copy(o.second)
    end

    def ref_first = FirstRef.new(self)
    def ref_second = SecondRef.new(self)

    # std::pair's operator<: first, then second (each by Less<T>.Fn)
    def CompareTo(o)
      return -1 if Cpp.elem_less(@first, o.first)
      return 1 if Cpp.elem_less(o.first, @first)
      return -1 if Cpp.elem_less(@second, o.second)
      return 1 if Cpp.elem_less(o.second, @second)
      0
    end

    def inspect = "Pair(#{@first.inspect}, #{@second.inspect})"
  end

  def NewPair(ma, mb) = Pair.new(ma.call, mb.call)
  def NewPair_A_B(a, b) = Pair.new(a, b)
  def Pair_Eq(x, y) = Cpp.elem_eq(x.first, y.first) && Cpp.elem_eq(x.second, y.second)
  def Pair_op_Lt(x, y) = x.CompareTo(y) < 0
  def Pair_op_Gt(x, y) = x.CompareTo(y) > 0
  def Pair_op_Le(x, y) = x.CompareTo(y) <= 0
  def Pair_op_Ge(x, y) = x.CompareTo(y) >= 0

  # ------------------------------------------------------------------------------------------------- M
  # std::min / max / clamp exactly as libstdc++ writes them (the comparisons decide which argument comes back, which
  # matters for -0.0 and NaN). The engine writes the two-argument forms inline.
  def M_min(a, b) = b < a ? b : a
  def M_max(a, b) = a < b ? b : a
  def M_min_T_T_FuncTTb(a, b, lt) = lt.call(b, a) ? b : a
  def M_max_T_T_FuncTTb(a, b, lt) = lt.call(a, b) ? b : a
  def M_clamp(v, lo, hi) = v < lo ? lo : (hi < v ? hi : v)

  # min(initializer_list): the first smallest (NaN never replaces, a NaN first stays)
  def M_min_dA(il)
    r = il[0]
    i = 1
    while i < il.length
      x = il[i]
      r = x if x < r
      i += 1
    end
    r
  end

  def M_max_dA(il)
    r = il[0]
    i = 1
    while i < il.length
      x = il[i]
      r = x if r < x
      i += 1
    end
    r
  end

  alias M_min_iA M_min_dA
  alias M_max_iA M_max_dA
  %w[d_d f_f i_i l_l ul_ul u_u uc_uc c_c s_s us_us].each do |t|
    alias_method "M_min_#{t}", :M_min
    alias_method "M_max_#{t}", :M_max
  end
  %w[d_d_d i_i_i l_l_l].each { |t| alias_method "M_clamp_#{t}", :M_clamp }
  CODES[1..].each do |c|
    alias_method "M_min_T_T_FuncTTb__#{c}", :M_min_T_T_FuncTTb
    alias_method "M_max_T_T_FuncTTb__#{c}", :M_max_T_T_FuncTTb
  end

  # ------------------------------------------------------------------------------------------------- Arr

  def Arr_Make(n, mk) = Cpp.made(mk, n)
  def Arr_MakeWith(n, mk) = Array.new(n) { mk.call }
  def Arr_Make2(n, m, mk) = Array.new(n) { Cpp.made(mk, m) }

  # Arr.Clone<T>: a new array; an element of a class (ICopy) type cloned, any other element shared
  def Arr_Clone(a) = a.nil? ? nil : a.map { |x| x.is_a?(ICopy) ? x.Clone() : x }

  def Arr_Assign(dst, src)
    i = 0
    while i < src.length
      d = dst[i]
      if d.is_a?(ICopy)
        d.Assign(src[i])
      else
        dst[i] = src[i]
      end
      i += 1
    end
  end

  def Arr_Fill(a, b, e, v)
    i = b
    while i < e
      a[i] = Cpp.copy(v)
      i += 1
    end
  end

  def Arr_Eq(x, y)
    return false if x.length != y.length
    i = 0
    while i < x.length
      return false unless Cpp.elem_eq(x[i], y[i])
      i += 1
    end
    true
  end

  # System.Array.Fill(T[] a, T v): every element the same value (the same reference for a class)
  def Array_Fill(lst, v)
    lst.fill(v)
  end

  ZEROS.each do |c, z|
    define_method("Arr_Make__#{c}") { |n| Array.new(n, z) }
    define_method("Arr_Make2__#{c}") { |n, m| Array.new(n) { Array.new(m, z) } }
    define_method("Arr_Clone__#{c}") { |a| a&.dup }
    define_method("Arr_Assign__#{c}") { |dst, src| dst[0, src.length] = src }
    define_method("Arr_Fill__#{c}") { |a, b, e, v| a.fill(v, b, e - b) }
    if c == 'D' || c == 'F'
      define_method("Arr_Eq__#{c}") do |x, y|
        next false if x.length != y.length
        x.each_index.all? { |i| (p = x[i]) == (q = y[i]) || (p != p && q != q) }
      end
    else
      define_method("Arr_Eq__#{c}") { |x, y| x == y }
    end
  end

  # ------------------------------------------------------------------------------------------------- Dtor, Defer

  # Cpp.Dtor.Run: a C++ destructor: an IDisposable's Dispose, a container's elements (IDestroyElems), each element
  # of an array.
  def self.dtor(o)
    return if o.nil?
    if o.is_a?(IDisposable)
      o.Dispose()
    elsif o.is_a?(IDestroyElems)
      o.DestroyElems()
    elsif o.instance_of?(Array)
      o.each { |x| Cpp.dtor(x) unless x.nil? || x.is_a?(Numeric) }
    end
  end

  def Dtor_Run(o) = Cpp.dtor(o)

  # A destructor deferred to the end of the enclosing block (a using declaration), unless cancelled.
  class Defer
    include IDisposable

    def initialize(a)
      @a = a
    end

    def Cancel
      @a = nil
    end

    def Dispose
      x = @a
      @a = nil
      x&.call
    end
  end

  def NewDefer(a) = Defer.new(a)

  # ------------------------------------------------------------------------------------------------- Mv

  # unique_ptr::reset(q) and unique_ptr assignment: store the new pointer, then delete the old one (p a Ref)
  def Mv_Reset(p, q)
    old = p.v
    p.v = q
    Cpp.dtor(old) if !old.nil? && !old.equal?(q)
  end

  # copy a boxed out-parameter back into its variable (x a Ref) after the call produced value v
  def Mv_Back(v, x, box)
    x.v = box[0]
    v
  end

  def Mv_Back_U(v, x, box)
    x.v = box[0] & 0xFFFFFFFF
    v
  end

  def Mv_Back_Q(v, x, box)
    x.v = box[0] & 0xFFFFFFFFFFFFFFFF
    v
  end

  # std::move of a container or class into a new owner: the source (a Ref) is left a new default object
  def Mv_Take(x, mk)
    r = x.v
    x.v = mk.call
    r
  end

  def Mv_TakeRef(x)
    r = x.v
    x.v = nil
    r
  end

  def Mv_PostStep_PtrTr_i(p, d)
    r = p.v
    p.v = r.add(d)
    r
  end

  def Mv_PostStep_IterTr_i(p, d)
    r = p.v
    v = r.v
    p.v = v.nil? ? Iter.new(nil, r.a, r.i + d) : Iter.new(v, v.a, r.i + d)
    r
  end

  def Mv_PostStep_CPtrr_i(p, d)
    r = p.v
    p.v = CPtr.new(r.B, r.O + d)
    r
  end

  def Mv_PostStep_RevIterTr_i(p, d)
    r = p.v
    p.v = RevIter.new(r.v, r.i - 1)
    r
  end

  def Mv_PostStep_MItEr_i(p, d)
    r = p.v
    p.v = d > 0 ? MIt_op_Increment(r) : MIt_op_Decrement(r)
    r
  end

  def Mv_Delete(o)
    o.Dispose() if o.is_a?(IDisposable)
  end

  CODES.each do |c|
    s = c.empty? ? '' : "__#{c}"
    unless c.empty?
      %w[Mv_PostStep_PtrTr_i Mv_PostStep_IterTr_i Mv_PostStep_RevIterTr_i Mv_Reset Mv_TakeRef].each { |n| alias_method n + s, n }
      z = ZEROS[c]
      define_method("Mv_Take__#{c}") do |x|
        r = x.v
        x.v = z
        r
      end
    end
    (['O'] + CODES[1..]).each do |c2|
      n = "Mv_Back__#{c.empty? ? 'O' : c}#{c2}"
      alias_method n, :Mv_Back unless method_defined?(n)
    end
  end
  (['O'] + CODES[1..]).each do |c|
    alias_method "Mv_Back__#{c}U", :Mv_Back_U
    alias_method "Mv_Back__#{c}Q", :Mv_Back_Q
  end
end
