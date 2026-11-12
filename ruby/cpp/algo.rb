# encoding: binary
# frozen_string_literal: true
# algo.rb - <algorithm> and <numeric> over vector / array iterators and pointers: the Ruby form of the Algo class of
# cs/runtime/Misc.cs (Cpp.Algo), which is the specification, by way of py/cpp/algo.py.
#
# Iterators and pointers are immutable values: an Iter has .a (the backing Array) and .i (the index), a Ptr .a and
# .o (the offset); the functions read and write a[...] directly, as the C# does.
# Names: Algo_<name><overload suffix><specialisation>; a generic member used with a primitive type argument has
# the suffix __ and the codes (Algo_fill_IterT_IterT_T__D); with a reference type none. What depends on the element
# type: copying an element (Elem<T>.Copy: a reference type's copy is a clone), equality (EqualityComparer<T>:
# double.Equals makes NaN equal to NaN) and std::less (Less<T>.Fn: numbers with the primitive <).
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.

module Cpp
  ACODES = %w[O D F I L B S C Z].freeze

  def self.algo_name(base, codes) = codes.all?('O') ? base : base + '__' + codes.join
  def self.copier(c) = c == 'O' ? ECOPY : nil

  def self.eqf(c)
    return STD_EQ if c == 'O'
    return ->(a, b) { a == b || (a != a && b != b) } if c == 'D' || c == 'F'
    ->(a, b) { a == b }
  end

  PLT = ->(a, b) { a < b }
  def self.ltf(c) = c == 'O' ? Less_Fn : PLT

  def self.iadd(b, n) = b.v.nil? ? Iter.new(nil, b.a, b.i + n) : Iter.new(b.v, b.v.a, b.i + n)
  def self.padd(p, n) = p.add(n)

  def self.fill_into(a, i0, n, v, cp)
    return if n <= 0
    if cp.nil?
      a.fill(v, i0, n)
    else
      k = 0
      while k < n
        a[i0 + k] = cp.call(v)
        k += 1
      end
    end
  end

  def self.copy_into(src, s0, n, dst, d0, cp)
    return if n <= 0
    seg = src[s0, n]
    seg = seg.map { |x| cp.call(x) } unless cp.nil?
    dst[d0, n] = seg
  end

  # the base names, one function per element code
  ACODES.each do |c|
    cp = Cpp.copier(c)
    eq = Cpp.eqf(c)
    lt0 = Cpp.ltf(c)
    nm = ->(base) { Cpp.algo_name(base, [c]) }

    define_method(nm.('Algo_fill_IterT_IterT_T')) { |b, e, v| Cpp.fill_into(b.a, b.i, e.i - b.i, v, cp) }
    define_method(nm.('Algo_fill_PtrT_PtrT_T')) { |b, e, v| Cpp.fill_into(b.a, b.o, e.o - b.o, v, cp) }
    define_method(nm.('Algo_fill_n_IterT_ul_T')) do |b, n, v|
      Cpp.fill_into(b.a, b.i, n, v, cp)
      Cpp.iadd(b, n)
    end
    define_method(nm.('Algo_fill_n_PtrT_ul_T')) do |b, n, v|
      Cpp.fill_into(b.a, b.o, n, v, cp)
      Cpp.padd(b, n)
    end
    define_method(nm.('Algo_any_of')) do |b, e, f|
      a = b.a
      i = b.i
      r = false
      while i < e.i
        if f.call(a[i])
          r = true
          break
        end
        i += 1
      end
      r
    end
    define_method(nm.('Algo_all_of')) do |b, e, f|
      a = b.a
      i = b.i
      r = true
      while i < e.i
        unless f.call(a[i])
          r = false
          break
        end
        i += 1
      end
      r
    end
    define_method(nm.('Algo_none_of')) do |b, e, f|
      a = b.a
      i = b.i
      r = true
      while i < e.i
        if f.call(a[i])
          r = false
          break
        end
        i += 1
      end
      r
    end
    define_method(nm.('Algo_find')) do |b, e, v|
      a = b.a
      i = b.i
      r = e
      while i < e.i
        if eq.call(a[i], v)
          r = Cpp.iadd(b, i - b.i)
          break
        end
        i += 1
      end
      r
    end
    [['Algo_find_if', true], ['Algo_find_if_not', false]].each do |base, want|
      define_method(nm.(base)) do |b, e, f|
        a = b.a
        i = b.i
        r = e
        while i < e.i
          if (f.call(a[i]) ? true : false) == want
            r = Cpp.iadd(b, i - b.i)
            break
          end
          i += 1
        end
        r
      end
    end
    define_method(nm.('Algo_count')) do |b, e, v|
      a = b.a
      n = 0
      (b.i...e.i).each { |i| n += 1 if eq.call(a[i], v) }
      n
    end
    define_method(nm.('Algo_count_if')) do |b, e, f|
      a = b.a
      n = 0
      (b.i...e.i).each { |i| n += 1 if f.call(a[i]) }
      n
    end
    define_method(nm.('Algo_lower_bound_IterT_IterT_T')) { |b, e, v| Cpp.lower_bound(b, e, v, lt0) }
    define_method(nm.('Algo_lower_bound_IterT_IterT_T_FuncTTb')) { |b, e, v, lt| Cpp.lower_bound(b, e, v, lt) }
    define_method(nm.('Algo_upper_bound_IterT_IterT_T')) { |b, e, v| Cpp.upper_bound(b, e, v, lt0) }
    define_method(nm.('Algo_upper_bound_IterT_IterT_T_FuncTTb')) { |b, e, v, lt| Cpp.upper_bound(b, e, v, lt) }
    define_method(nm.('Algo_binary_search')) do |b, e, v|
      f = Cpp.lower_bound(b, e, v, lt0).i
      f != e.i && !lt0.call(v, b.a[f])
    end
    define_method(nm.('Algo_is_sorted_IterT_IterT')) { |b, e| Cpp.is_sorted(b, e, lt0) }
    define_method(nm.('Algo_is_sorted_IterT_IterT_FuncTTb')) { |b, e, lt| Cpp.is_sorted(b, e, lt) }
    define_method(nm.('Algo_adjacent_find_IterT_IterT')) { |b, e| Cpp.adjacent_find(b, e, eq) }
    define_method(nm.('Algo_adjacent_find_IterT_IterT_FuncTTb')) { |b, e, q| Cpp.adjacent_find(b, e, q) }
    define_method(nm.('Algo_unique_IterT_IterT')) { |b, e| Cpp.unique(b, e, eq) }
    define_method(nm.('Algo_unique_IterT_IterT_FuncTTb')) { |b, e, q| Cpp.unique(b, e, q) }
    define_method(nm.('Algo_remove_if')) { |b, e, f| Cpp.remove_if(b, e, f) }
    define_method(nm.('Algo_remove')) { |b, e, v| Cpp.remove_if(b, e, ->(x) { eq.call(x, v) }) }
    define_method(nm.('Algo_max_element_IterT_IterT')) { |b, e| Cpp.max_element(b, e, lt0) }
    define_method(nm.('Algo_max_element_IterT_IterT_FuncTTb')) { |b, e, lt| Cpp.max_element(b, e, lt) }
    define_method(nm.('Algo_min_element_IterT_IterT')) { |b, e| Cpp.min_element(b, e, lt0) }
    define_method(nm.('Algo_min_element_IterT_IterT_FuncTTb')) { |b, e, lt| Cpp.min_element(b, e, lt) }
    define_method(nm.('Algo_copy_IterT_IterT_IterT')) do |b, e, o|
      n = e.i - b.i
      Cpp.copy_into(b.a, b.i, n, o.a, o.i, cp)
      Cpp.iadd(o, n)
    end
    define_method(nm.('Algo_copy_IterT_IterT_PtrT')) do |b, e, o|
      n = e.i - b.i
      Cpp.copy_into(b.a, b.i, n, o.a, o.o, cp)
      Cpp.padd(o, n)
    end
    define_method(nm.('Algo_copy_PtrT_PtrT_PtrT')) do |b, e, o|
      n = e.o - b.o
      Cpp.copy_into(b.a, b.o, n, o.a, o.o, cp)
      Cpp.padd(o, n)
    end
    define_method(nm.('Algo_copy_PtrT_PtrT_IterT')) do |b, e, o|
      n = e.o - b.o
      Cpp.copy_into(b.a, b.o, n, o.a, o.i, cp)
      Cpp.iadd(o, n)
    end
    define_method(nm.('Algo_copy_n_IterT_ul_IterT')) do |b, n, o|
      Cpp.copy_into(b.a, b.i, n, o.a, o.i, cp)
      Cpp.iadd(o, n)
    end
    define_method(nm.('Algo_copy_n_PtrT_ul_PtrT')) do |b, n, o|
      Cpp.copy_into(b.a, b.o, n, o.a, o.o, cp)
      Cpp.padd(o, n)
    end
    define_method(nm.('Algo_replace')) do |b, e, old, nw|
      a = b.a
      (b.i...e.i).each { |i| a[i] = nw if eq.call(a[i], old) }
      nil
    end
    define_method(nm.('Algo_reverse')) do |b, e|
      a = b.a
      a[b.i, e.i - b.i] = a[b.i, e.i - b.i].reverse if e.i - b.i > 1
      nil
    end
    define_method(nm.('Algo_equal')) do |b, e, b2|
      a = b.a
      a2 = b2.a
      d = b2.i - b.i
      (b.i...e.i).all? { |i| eq.call(a[i], a2[i + d]) }
    end
    define_method(nm.('Algo_distance_IterT_IterT')) { |x, y| y.i - x.i }
    define_method(nm.('Algo_distance_PtrT_PtrT')) { |x, y| y.o - x.o }
    define_method(nm.('Algo_next')) { |x, n = 1| Cpp.iadd(x, n) }
    define_method(nm.('Algo_prev')) { |x, n = 1| Cpp.iadd(x, -n) }
    define_method(nm.('Algo_VecFrom')) do |b, e|
      seg = b.a[b.i, e.i - b.i]
      Cpp.vec_of(c, b, cp.nil? ? seg : seg.map { |x| cp.call(x) })
    end
    define_method(nm.('Algo_VecFromPtr')) do |b, e|
      seg = b.a[b.o, e.o - b.o]
      Cpp.vec_of(c, b, cp.nil? ? seg : seg.map { |x| cp.call(x) })
    end
    define_method(nm.('Algo_begin_VecT')) { |v| v.begin }
    define_method(nm.('Algo_end_VecT')) { |v| v.end }
    define_method(nm.('Algo_begin_TA')) { |a| Iter.new(nil, a, 0) }
    define_method(nm.('Algo_end_TA')) { |a| Iter.new(nil, a, a.length) }
    define_method(nm.('Algo_size_VecT')) { |v| v.n }
    define_method(nm.('Algo_size_TA')) { |a| a.length }
    ACODES.each do |c2|
      n2 = ->(base) { Cpp.algo_name(base, [c, c2]) }
      define_method(n2.('Algo_accumulate_IterT_IterT_A_FuncATA')) do |b, e, init, op|
        a = b.a
        (b.i...e.i).each { |i| init = op.call(init, a[i]) }
        init
      end
      define_method(n2.('Algo_lower_bound_IterT_IterT_V_FuncTVb')) { |b, e, v, lt| Cpp.lower_bound(b, e, v, lt) }
      define_method(n2.('Algo_upper_bound_IterT_IterT_V_FuncVTb')) { |b, e, v, lt| Cpp.upper_bound(b, e, v, lt) }
      define_method(n2.('Algo_transform_IterT_IterT_IterU_FuncTU')) do |b, e, o, f|
        a = b.a
        oa = o.a
        d = o.i - b.i
        (b.i...e.i).each { |i| oa[i + d] = f.call(a[i]) }
        Cpp.iadd(o, e.i - b.i)
      end
    end
  end

  def self.lower_bound(b, e, v, lt)
    a = b.a
    first = b.i
    ln = e.i - first
    while ln > 0
      half = ln >> 1
      mid = first + half
      if lt.call(a[mid], v)
        first = mid + 1
        ln = ln - half - 1
      else
        ln = half
      end
    end
    Cpp.iadd(b, first - b.i)
  end

  def self.upper_bound(b, e, v, lt)
    a = b.a
    first = b.i
    ln = e.i - first
    while ln > 0
      half = ln >> 1
      mid = first + half
      if lt.call(v, a[mid])
        ln = half
      else
        first = mid + 1
        ln = ln - half - 1
      end
    end
    Cpp.iadd(b, first - b.i)
  end

  # std::is_sorted: no element is less than the one before it
  def self.is_sorted(b, e, lt)
    a = b.a
    ((b.i + 1)...e.i).none? { |i| lt.call(a[i], a[i - 1]) }
  end

  def self.adjacent_find(b, e, eq)
    a = b.a
    i = b.i
    while i < e.i - 1
      return Cpp.iadd(b, i - b.i) if eq.call(a[i], a[i + 1])
      i += 1
    end
    e
  end

  # std::unique: keeps the first of each run of equal elements (libstdc++'s order of moves)
  def self.unique(b, e, eq)
    return e if b.i == e.i
    a = b.a
    first = b.i
    last = e.i
    nxt = first + 1
    while nxt != last
      break if eq.call(a[first], a[nxt])
      first = nxt
      nxt += 1
    end
    return e if nxt == last
    dest = first
    first = nxt + 1
    while first != last
      unless eq.call(a[dest], a[first])
        dest += 1
        a[dest] = a[first]
      end
      first += 1
    end
    Cpp.iadd(b, dest + 1 - b.i)
  end

  def self.remove_if(b, e, f)
    a = b.a
    first = b.i
    last = e.i
    first += 1 while first != last && !f.call(a[first])
    return e if first == last
    res = first
    ((first + 1)...last).each do |i|
      x = a[i]
      unless f.call(x)
        a[res] = x
        res += 1
      end
    end
    Cpp.iadd(b, res - b.i)
  end

  def self.max_element(b, e, lt)
    i0 = b.i
    return e if i0 == e.i
    a = b.a
    best = i0
    ((i0 + 1)...e.i).each { |i| best = i if lt.call(a[best], a[i]) }
    Cpp.iadd(b, best - i0)
  end

  def self.min_element(b, e, lt)
    i0 = b.i
    return e if i0 == e.i
    a = b.a
    best = i0
    ((i0 + 1)...e.i).each { |i| best = i if lt.call(a[i], a[best]) }
    Cpp.iadd(b, best - i0)
  end

  # new Vec<T>() holding items (Algo.VecFrom sets the array and the count, as the C# does). A vector of a reference
  # type takes the maker of the vector the source iterator belongs to.
  def self.vec_of(c, src, items)
    if c == 'O'
      mk = src.respond_to?(:v) && src.v.respond_to?(:mk) ? src.v.mk : nil
      v = Vec.new(mk.nil? ? MK_N : mk)
    else
      v = Cpp.const_get("Vec#{c}").new
    end
    v.a = items
    v.n = items.length
    v
  end

  # ------------------------------------------------------------------------------------------------- accumulate, iota

  # double: the sums made one by one, left to right
  def Algo_accumulate_Iterd_Iterd_d(b, e, init)
    a = b.a
    i = b.i
    while i < e.i
      init += a[i]
      i += 1
    end
    init
  end

  def Algo_accumulate_Iteri_Iteri_i(b, e, init) = Cpp.i32(b.a[b.i, e.i - b.i].sum(init))
  def Algo_accumulate_Iterl_Iterl_l(b, e, init) = Cpp.i64(b.a[b.i, e.i - b.i].sum(init))

  def Algo_accumulate_Iteri_Iteri_d(b, e, init)
    a = b.a
    (b.i...e.i).each { |i| init += a[i] }
    init.to_f
  end

  def Algo_accumulate_Iterul_Iterul_ul(b, e, init) = b.a[b.i, e.i - b.i].sum(init) & M64

  # transform over a string's bytes with a function returning int or sbyte: each result stored as a char
  def Algo_transform_Iteruc_Iteruc_Iteruc_Funcucc(b, e, o, f)
    a = b.a
    oa = o.a
    d = o.i - b.i
    (b.i...e.i).each { |i| oa[i + d] = f.call(a[i]) & 0xFF }
    Cpp.iadd(o, e.i - b.i)
  end
  alias Algo_transform_Iteruc_Iteruc_Iteruc_Funcuci Algo_transform_Iteruc_Iteruc_Iteruc_Funcucc

  def Algo_iota_Iteri_Iteri_i(b, e, v)
    a = b.a
    (b.i...e.i).each do |i|
      a[i] = v
      v = Cpp.i32(v + 1)
    end
  end

  def Algo_iota_Iterul_Iterul_ul(b, e, v)
    a = b.a
    (b.i...e.i).each do |i|
      a[i] = v
      v = (v + 1) & M64
    end
  end
end
