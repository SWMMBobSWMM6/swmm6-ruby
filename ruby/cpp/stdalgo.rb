# encoding: binary
# frozen_string_literal: true
# stdalgo.rb - libstdc++'s sorting algorithms, step for step (GCC 13 bits/stl_algo.h and bits/stl_heap.h), the Ruby
# form of cs/runtime/StdAlgo.cs (Cpp.StdAlgo), which is the specification, by way of py/cpp/stdalgo.py. std::sort is
# an introsort and is not stable: with equal keys the order it leaves depends on every swap it makes, so this port
# makes the same ones. std::stable_sort's result is fixed by stability alone.
# StdAlgo_Sort(a, first, last, comp) sorts the Array a over [first, last) with comp.call(x, y) -> bool. Fast path,
# taken only where every correct sort leaves the same values in the same places: std::less on integers, and on
# doubles with no NaN and no zero of both signs (equal keys are equal values), uses Ruby's own sort.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.

module Cpp
  THRESHOLD = 16

  def self.sort(a, first, last, comp)
    return if first == last
    Cpp.introsort_loop(a, first, last, ((last - first).bit_length - 1) * 2, comp)
    Cpp.final_insertion_sort(a, first, last, comp)
  end

  def self.introsort_loop(a, first, last, depth, comp)
    while last - first > THRESHOLD
      if depth == 0
        Cpp.partial_sort(a, first, last, last, comp)
        return
      end
      depth -= 1
      # __unguarded_partition_pivot: __move_median_to_first(first, first + 1, mid, last - 1), then
      # __unguarded_partition(first + 1, last, first)
      mid = first + (last - first) / 2
      ia = first + 1
      ic = last - 1
      xa = a[ia]
      xb = a[mid]
      xc = a[ic]
      j = if comp.call(xa, xb)
            if comp.call(xb, xc) then mid
            elsif comp.call(xa, xc) then ic
            else ia
            end
          elsif comp.call(xa, xc) then ia
          elsif comp.call(xb, xc) then ic
          else mid
          end
      pv = a[j]
      a[j] = a[first]
      a[first] = pv
      lo = ia
      hi = last
      loop do
        lo += 1 while comp.call(a[lo], pv)
        hi -= 1
        hi -= 1 while comp.call(pv, a[hi])
        break unless lo < hi
        t = a[lo]
        a[lo] = a[hi]
        a[hi] = t
        lo += 1
      end
      Cpp.introsort_loop(a, lo, last, depth, comp)
      last = lo
    end
  end

  def self.final_insertion_sort(a, first, last, comp)
    if last - first > THRESHOLD
      Cpp.insertion_sort(a, first, first + THRESHOLD, comp)
      i = first + THRESHOLD
      while i < last
        val = a[i]
        nxt = i - 1
        while comp.call(val, a[nxt])
          a[nxt + 1] = a[nxt]
          nxt -= 1
        end
        a[nxt + 1] = val
        i += 1
      end
    else
      Cpp.insertion_sort(a, first, last, comp)
    end
  end

  def self.insertion_sort(a, first, last, comp)
    return if first == last
    i = first + 1
    while i < last
      val = a[i]
      if comp.call(val, a[first])
        a[first + 1, i - first] = a[first, i - first]          # move_backward(first, i, i + 1)
        a[first] = val
      else
        nxt = i - 1
        while comp.call(val, a[nxt])
          a[nxt + 1] = a[nxt]
          nxt -= 1
        end
        a[nxt + 1] = val
      end
      i += 1
    end
  end

  def self.partial_sort(a, first, middle, last, comp)
    Cpp.heap_select(a, first, middle, last, comp)
    Cpp.sort_heap(a, first, middle, comp)
  end

  def self.heap_select(a, first, middle, last, comp)
    Cpp.make_heap(a, first, middle, comp)
    (middle...last).each do |i|
      next unless comp.call(a[i], a[first])
      value = a[i]
      a[i] = a[first]
      Cpp.adjust_heap(a, first, 0, middle - first, value, comp)
    end
  end

  def self.make_heap(a, first, last, comp)
    return if last - first < 2
    ln = last - first
    parent = (ln - 2) / 2
    loop do
      Cpp.adjust_heap(a, first, parent, ln, a[first + parent], comp)
      return if parent == 0
      parent -= 1
    end
  end

  def self.sort_heap(a, first, last, comp)
    while last - first > 1
      last -= 1
      value = a[last]
      a[last] = a[first]
      Cpp.adjust_heap(a, first, 0, last - first, value, comp)
    end
  end

  def self.adjust_heap(a, first, hole, ln, value, comp)
    top = hole
    second = hole
    lim = ln >= 1 ? (ln - 1) / 2 : 0
    while second < lim
      second = 2 * (second + 1)
      second -= 1 if comp.call(a[first + second], a[first + (second - 1)])
      a[first + hole] = a[first + second]
      hole = second
    end
    if ln.even? && second == (ln - 2) / 2
      second = 2 * (second + 1)
      a[first + hole] = a[first + (second - 1)]
      hole = second - 1
    end
    parent = (hole - 1) / 2
    while hole > top && comp.call(a[first + parent], value)
      a[first + hole] = a[first + parent]
      hole = parent
      parent = (hole - 1) / 2
    end
    a[first + hole] = value
  end

  # std::stable_sort: any stable sort gives libstdc++'s result; this is the C# merge sort, step for step
  def self.stable_sort(a, first, last, comp)
    n = last - first
    return if n < 2
    Cpp.merge_sort(a, first, last, Array.new(n), comp)
  end

  def self.merge_sort(a, lo, hi, buf, comp)
    return if hi - lo < 2
    mid = lo + (hi - lo) / 2
    Cpp.merge_sort(a, lo, mid, buf, comp)
    Cpp.merge_sort(a, mid, hi, buf, comp)
    i = lo
    j = mid
    k = 0
    while i < mid && j < hi
      y = a[j]
      x = a[i]
      if comp.call(y, x)
        buf[k] = y
        j += 1
      else
        buf[k] = x
        i += 1
      end
      k += 1
    end
    while i < mid
      buf[k] = a[i]
      i += 1
      k += 1
    end
    while j < hi
      buf[k] = a[j]
      j += 1
      k += 1
    end
    a[lo, k] = buf[0, k]
  end

  # whether equal doubles in seg are equal values: no NaN, and not both +0.0 and -0.0
  def self.plain_doubles(seg)
    zs = 0
    seg.each do |x|
      return false if x != x
      zs |= Cpp.signbit(x) ? 2 : 1 if x == 0.0
    end
    zs != 3
  end

  def StdAlgo_Sort(a, first, last, comp)
    return if last - first < 2
    Cpp.sort(a, first, last, comp)
  end

  def StdAlgo_StableSort(a, first, last, comp)
    return if last - first < 2
    Cpp.stable_sort(a, first, last, comp)
  end

  def StdAlgo_PartialSort(a, first, middle, last, comp) = Cpp.partial_sort(a, first, middle, last, comp)

  def self.int_sort(a, first, last, comp, stable)
    return if last - first < 2
    if comp.equal?(Less_Fn)
      a[first, last - first] = a[first, last - first].sort
    elsif stable
      Cpp.stable_sort(a, first, last, comp)
    else
      Cpp.sort(a, first, last, comp)
    end
  end

  def self.dbl_sort(a, first, last, comp, stable)
    return if last - first < 2
    if comp.equal?(Less_Fn)
      seg = a[first, last - first]
      if Cpp.plain_doubles(seg)
        a[first, last - first] = seg.sort
        return
      end
      comp = PLT
    end
    stable ? Cpp.stable_sort(a, first, last, comp) : Cpp.sort(a, first, last, comp)
  end

  %w[D F].each do |c|
    define_method("StdAlgo_Sort__#{c}") { |a, f, l, comp| Cpp.dbl_sort(a, f, l, comp, false) }
    define_method("StdAlgo_StableSort__#{c}") { |a, f, l, comp| Cpp.dbl_sort(a, f, l, comp, true) }
  end
  %w[I L B S C].each do |c|
    define_method("StdAlgo_Sort__#{c}") { |a, f, l, comp| Cpp.int_sort(a, f, l, comp, false) }
    define_method("StdAlgo_StableSort__#{c}") { |a, f, l, comp| Cpp.int_sort(a, f, l, comp, true) }
  end
  def StdAlgo_Sort__Z(a, f, l, comp) = StdAlgo_Sort(a, f, l, comp)
  def StdAlgo_StableSort__Z(a, f, l, comp) = StdAlgo_StableSort(a, f, l, comp)
  %w[D F I L B S C Z].each do |c|
    define_method("StdAlgo_PartialSort__#{c}") { |a, f, m, l, comp| Cpp.partial_sort(a, f, m, l, comp.equal?(Less_Fn) ? PLT : comp) }
  end
end
