# encoding: binary
# frozen_string_literal: true
# containers.rb - std::unordered_map / unordered_set with libstdc++'s exact node order (GCC 13 bits/hashtable.h: one
# singly linked list, a bucket array pointing at the node before each bucket's first node, new nodes at the front of
# their bucket, the prime rehash policy with growth factor 2), std::hash as libstdc++ computes it (identity for
# integers, _Hash_bytes for strings), std::map / std::set (sorted), std::stack, std::queue and their iterators: the
# Ruby form of cs/runtime/Containers.cs (C# namespace Cpp), which is the specification, by way of
# py/cpp/containers.py.
#
# The engine iterates hashed containers, so their node order reaches its output; ruby/test (hashcheck.rb) compares
# this file's order with libstdc++'s. Lookups do not walk the buckets: each table also keeps a Ruby Hash from the
# key's value (a string's bytes, an integer, a float, an object's identity) to its node, which finds the node the
# bucket walk would find, because the keys are unique. A table with a hasher and key-equal of the engine's own
# (UMapC, USetC: CiHash, CiEqual) keys that Hash by the hash code instead and remembers which strings it has already
# looked up. The bucket array and the node list are kept exactly as libstdc++ keeps them, for the order.
#
# Element types are not known in Ruby, so what C# decides from typeof(K) is decided here from the key's run-time
# class: std::hash<K>, std::equal_to<K> and std::less<K> (Less_Fn) by the value's class.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.

module Cpp
  M64 = 0xFFFFFFFFFFFFFFFF

  def self.out_of_range(text) = OutOfRange.new(text)

  # ------------------------------------------------------------------------------------------------- std::hash
  HB_MUL = ((0xc6a4a793 << 32) + 0x5bd1e995) & M64
  HB_SEED = 0xc70f6907

  # libstdc++'s std::_Hash_bytes (libsupc++/hash_bytes.cc, the 64-bit branch) over the binary String s; a size_t
  def self.hash_bytes(s, seed)
    mul = HB_MUL
    ln = s.bytesize
    h = (seed ^ (ln * mul)) & M64
    words = ln >> 3
    if words > 0
      s.unpack("Q<#{words}").each do |w|
        d = (w * mul) & M64
        d = ((d ^ (d >> 47)) * mul) & M64
        h = ((h ^ d) * mul) & M64
      end
    end
    r = ln & 7
    if r != 0
      t = 0
      p = words << 3
      (r - 1).downto(0) { |k| t = (t << 8) | s.getbyte(p + k) }
      h = ((h ^ t) * mul) & M64
    end
    h = ((h ^ (h >> 47)) * mul) & M64
    h ^ (h >> 47)
  end

  # Cpp.StdHash.HashBytes over b (an Array of bytes) [off, off + ln)
  def StdHash_HashBytes(b, off, ln, seed) = Cpp.hash_bytes(b[off, ln].pack('C*'), seed)

  HBC = {}     # string bytes -> _Hash_bytes, so a name hashed once is not hashed again

  def self.hash_content(cb)
    h = HBC[cb]
    if h.nil?
      h = Cpp.hash_bytes(cb, HB_SEED)
      HBC.clear if HBC.size >= 262_144
      HBC[cb.frozen? ? cb : cb.dup.freeze] = h
    end
    h
  end

  # std::hash<double>: 0 for both zeros, otherwise _Hash_bytes of the eight bytes
  def self.hash_double(d) = d == 0.0 ? 0 : Cpp.hash_bytes([d].pack('E'), HB_SEED)

  def self.str_key(s) = s.b[0, s.n].pack('C*')

  def StdHash_Of_Str(s) = Cpp.hash_content(Cpp.str_key(s))
  def StdHash_Of_i(v) = v & M64
  alias StdHash_Of_l StdHash_Of_i
  alias StdHash_Of_u StdHash_Of_i
  alias StdHash_Of_ul StdHash_Of_i

  # std::hash<K>(k), K being k's run-time class: an integer its value modulo 2^64, a string _Hash_bytes, a double as
  # std::hash<double>, a bool 1 or 0, any other object its identity (libstdc++ hashes the address, which no other
  # program reproduces: such tables are looked up, not iterated into the output)
  def self.std_hash(k)
    case k
    when Integer then k & M64
    when Str then Cpp.hash_content(Cpp.str_key(k))
    when Float then Cpp.hash_double(k)
    when true then 1
    when false then 0
    else k.object_id & M64
    end
  end

  STD_HASH = ->(k) { Cpp.std_hash(k) }
  def StdHash_For = STD_HASH

  # The Hash key of a table's node: the key's value where C# compares values (a string's bytes, an integer, a double;
  # a NaN by its bits), else the object's identity (C# hashes such keys by identity: for a library value, the
  # container's copy).
  def self.dk(k)
    case k
    when Integer, true, false then k
    when Str then Cpp.str_key(k)
    when Float then k == k ? k : [:nan, [k].pack('E')]
    else [:id, k.object_id]
    end
  end

  def self.code_of_dk(dk)
    case dk
    when Integer then dk & M64
    when String then Cpp.hash_content(dk)
    when Float then Cpp.hash_double(dk)
    when true then 1
    when false then 0
    else dk[0] == :id ? dk[1] & M64 : Cpp.hash_bytes(dk[1], HB_SEED)
    end
  end

  # EqualityComparer<T>.Default.Equals(a, b), T being a's run-time class
  def self.deq(a, b)
    case a
    when Integer, true, false then a == b
    when Float then a == b || (a != a && b != b)
    when Str then b.is_a?(Str) && a.n == b.n && a.b[0, a.n] == b.b[0, b.n]
    when nil then b.nil?
    when Pair then a.equal?(b)
    else
      return a.equal?(b) if b.nil?
      a.respond_to?(:Equals) ? (a.Equals(b) ? true : false) : a.equal?(b)
    end
  end

  STD_EQ = ->(a, b) { Cpp.deq(a, b) }

  class Hash_
    include ICopy
    def op_Call(x) = Cpp.std_hash(x)
    def Clone = Hash_.new
    def Assign(o); end
  end

  def NewHash = Hash_.new
  def Hash_Of(x) = Cpp.std_hash(x)

  class EqualTo
    include ICopy
    def op_Call(a, b) = Cpp.deq(a, b)
    def Clone = EqualTo.new
    def Assign(o); end
  end

  def NewEqualTo = EqualTo.new

  # ------------------------------------------------------------------------------------------------- std::less

  # Cpp.Less<T>.Fn, std::less<T>, T being a's run-time class: numbers with the primitive a < b, strings as
  # char_traits compares them (unsigned bytes, then length), pairs first then second, other objects by their
  # CompareTo, objects without one by identity (std::set<const Column*> orders by address).
  def self.less_fn(a, b)
    case a
    when Integer, Float then a < b
    when Str then (a.b[0, a.n] <=> b.b[0, b.n]) < 0
    when Pair
      x = a.first
      y = b.first
      return true if Cpp.less_fn(x, y)
      return false if Cpp.less_fn(y, x)
      Cpp.less_fn(a.second, b.second)
    when true, false then !a && b ? true : false
    when nil then !b.nil?
    else
      return false if b.nil?
      return a.CompareTo(b) < 0 if a.respond_to?(:CompareTo)
      a.object_id < b.object_id
    end
  end

  # the comparator object std::less is (the engine passes it as a function: Cpp.Less<T>.Fn)
  Less_Fn = ->(a, b) { Cpp.less_fn(a, b) }

  class Less
    include ICopy
    def op_Call(a, b) = Cpp.less_fn(a, b)
    def Clone = Less.new
    def Assign(o); end
  end

  def NewLess = Less.new

  class NoKey < StandardError; end

  # A sorted container's key as a Ruby value whose <=> is Less_Fn's order of k: a string's bytes, a number, a pair as
  # an Array of those. Raises NoKey for anything else (and a NaN).
  def self.sk(k)
    case k
    when Integer then k
    when Str then Cpp.str_key(k)
    when Float
      raise NoKey if k != k
      k
    when Pair then [Cpp.sk(k.first), Cpp.sk(k.second)]
    when true then 1
    when false then 0
    else raise NoKey
    end
  end

  # ------------------------------------------------------------------------------------------------- rehash policy
  FAST_BKT = [2, 2, 2, 3, 5, 5, 7, 7, 11, 11, 11, 11, 13, 13].freeze
  PLAST = PRIMES.length - 1      # __prime_list + __n_primes - 1 (the sentinel is excluded)

  # the first index in PRIMES[lo, hi) whose prime is not less than n (bisect_left)
  def self.prime_at_least(n, lo, hi)
    while lo < hi
      mid = (lo + hi) >> 1
      if PRIMES[mid] < n
        lo = mid + 1
      else
        hi = mid
      end
    end
    lo
  end

  # The prime rehash policy (libstdc++ src/c++11/hashtable_c++0x.cc), Cpp.RehashPolicy. The hash tables keep its
  # NextResize in their own field and do the same arithmetic inline (max load 1.0).
  class RehashPolicy
    include ICopy
    attr_accessor :MaxLoad, :NextResize

    def initialize
      @MaxLoad = 1.0
      @NextResize = 0
    end

    def NextBkt(n)
      if n < 14
        return 1 if n == 0
        @NextResize = (FAST_BKT[n] * @MaxLoad).floor
        return FAST_BKT[n]
      end
      lo = Cpp.prime_at_least(n, 6, PLAST)
      @NextResize = lo == PLAST ? M64 : (PRIMES[lo] * @MaxLoad).floor
      PRIMES[lo]
    end

    def BktForElements(n) = (n / @MaxLoad).ceil

    def NeedRehash(nBkt, nElt, nIns)
      if nElt + nIns > @NextResize
        min_bkts = [nElt + nIns, @NextResize != 0 ? 0 : 11].max / @MaxLoad
        return [true, NextBkt([min_bkts.floor + 1, nBkt * 2].max)] if min_bkts >= nBkt
        @NextResize = (nBkt * @MaxLoad).floor
      end
      [false, 0]
    end

    def Clone
      r = RehashPolicy.new
      r.MaxLoad = @MaxLoad
      r.NextResize = @NextResize
      r
    end

    def Assign(o)
      @MaxLoad = o.MaxLoad
      @NextResize = o.NextResize
    end
  end

  def NewRehashPolicy = RehashPolicy.new

  # ------------------------------------------------------------------------------------------------- the hash table

  # A hash table node (Cpp.HNode<E>); the before-begin sentinel is a node too. dk (the table's Hash key) and same (the
  # next node with the same hash code, in a table keyed by codes) are this port's own.
  class HNode
    attr_accessor :next, :val, :code, :dk, :same

    def initialize
      @next = nil
      @val = nil
      @code = 0
      @dk = nil
      @same = nil
    end
  end

  def NewHNode = HNode.new

  KC = {}.compare_by_identity

  # Cpp.KeyCopy<T>.Of: the container's own copy of a key that is a library value (an ICopy class of the runtime: a
  # string, a vector, a pair); an engine object as it is.
  def self.key_copy(x)
    case x
    when Integer, Float, true, false, nil then x
    when Str then x.Clone
    else
      c = KC[x.class]
      c = KC[x.class] = x.is_a?(ICopy) && x.class.name.to_s.start_with?('Cpp::') if c.nil?
      c ? x.Clone : x
    end
  end

  def KeyCopy_Of(x) = Cpp.key_copy(x)

  # Elem<T>.Copy, by the value's run-time class: an ICopy object cloned, an Array deeply, anything else shared
  def self.ecopy(x)
    case x
    when Integer, Float, true, false, nil then x
    when Array then x.map { |e| Cpp.ecopy(e) }
    else x.is_a?(ICopy) ? x.Clone : x
    end
  end

  KF_FIRST = ->(p) { p.first }
  KF_IDENT = ->(x) { x }
  PAIR_CLONE = ->(p) { p.Clone }
  ECOPY = ->(x) { Cpp.ecopy(x) }

  # libstdc++'s _Hashtable for unique keys (Cpp.HashTable<K, E>). E is the stored element (a Pair for UMap, the key
  # for USet). b is the bucket array (each entry the node before the bucket's first node, or nil), bb the
  # before-begin sentinel, cnt the element count, nr the policy's NextResize.
  # d finds nodes. With std::hash and std::equal_to (cm true) it maps each key's value (Cpp.dk) to its node. With a
  # hasher or key-equal given (cm false) it maps hash codes to nodes, chained through HNode.same, the key-equal
  # deciding; pc / nc then remember the strings found (to their node) and not found.
  class HashTable
    attr_accessor :hash, :eq, :kf, :cm, :b, :bb, :cnt, :nr, :d, :pc, :nc

    def initialize(key, hash = nil, eq = nil, cache = false)
      _init(key, hash, eq, cache)
    end

    def _init(key, hash, eq, cache)
      @kf = key
      @cm = hash.nil? && eq.nil?
      @hash = hash.nil? ? STD_HASH : hash
      @eq = eq.nil? ? STD_EQ : eq
      @b = [nil]
      @bb = HNode.new
      @cnt = 0
      @nr = 0
      @d = {}
      if cache && !@cm
        @pc = {}
        @nc = {}
      else
        @pc = nil
        @nc = nil
      end
      @lck = nil
      @lcode = nil
      @lk = nil
    end

    # lookup: the node holding k, or nil (then @lck / @lcode / @lk say what _add needs)
    def _lookup(k)
      if @cm
        ck = k.is_a?(Integer) ? k : (k.is_a?(Str) ? k.b[0, k.n].pack('C*') : Cpp.dk(k))
        n = @d[ck]
        @lck = ck if n.nil?
        return n
      end
      pc = @pc
      ck = nil
      if !pc.nil? && k.is_a?(Str)
        ck = k.b[0, k.n].pack('C*')
        n = pc[ck]
        return n unless n.nil?
        if @nc.key?(ck)
          @lck = ck
          @lcode = nil
          @lk = k
          return nil
        end
      end
      code = @hash.call(k)
      n = @d[code]
      unless n.nil?
        eq = @eq
        kf = @kf
        n = n.same while !n.nil? && !eq.call(k, kf.call(n.val))
      end
      unless ck.nil?
        if n.nil?
          @nc.clear if @nc.size >= 65_536
          @nc[ck] = true
        else
          pc[ck] = n
        end
      end
      if n.nil?
        @lck = ck
        @lcode = code
        @lk = k
      end
      n
    end

    # links e, whose key the last _lookup did not find, at the front of its bucket (after the rehash check)
    def _add(e)
      if @cm
        dk = @lck
        code = case dk
               when Integer then dk & M64
               when String then Cpp.hash_content(dk)
               when Array
                 if dk[0] == :id
                   dk = [:id, @kf.call(e).object_id]      # the stored key's identity
                   dk[1] & M64
                 else
                   Cpp.code_of_dk(dk)
                 end
               else Cpp.code_of_dk(dk)
               end
      else
        code = @lcode
        code = @hash.call(@lk) if code.nil?
        dk = code
        @lk = nil
      end
      n1 = @cnt + 1
      _grow(n1) if n1 > @nr
      node = HNode.new
      node.val = e
      node.code = code
      node.dk = dk
      b = @b
      nb = b.length
      i = code % nb
      before = b[i]
      if before.nil?
        bb = @bb
        nx = bb.next
        node.next = nx
        bb.next = node
        b[nx.code % nb] = node unless nx.nil?
        b[i] = bb
      else
        node.next = before.next
        before.next = node
      end
      @cnt = n1
      if @cm
        @d[dk] = node
      else
        node.same = @d[code]
        @d[code] = node
        pc = @pc
        unless pc.nil?
          @nc.clear unless @nc.empty?
          ck = @lck
          pc[ck] = node unless ck.nil?
        end
      end
      node
    end

    def _next_bkt(n)
      if n < 14
        return 1 if n == 0
        @nr = FAST_BKT[n]
        return FAST_BKT[n]
      end
      lo = Cpp.prime_at_least(n, 6, PLAST)
      @nr = lo == PLAST ? M64 : PRIMES[lo]
      PRIMES[lo]
    end

    # _M_need_rehash(bucket_count, size, 1) when size + 1 > NextResize; rehashes if it says so
    def _grow(need)
      nr = @nr
      nbk = @b.length
      min_bkts = (need > (nr != 0 ? 0 : 11) ? need : (nr != 0 ? 0 : 11)).to_f
      if min_bkts >= nbk
        m = min_bkts.floor + 1
        m = nbk * 2 if m < nbk * 2
        _rehash_to(_next_bkt(m))
      else
        @nr = nbk
      end
    end

    # _M_rehash_aux for unique keys: relink every node into n buckets, keeping each bucket's order
    def _rehash_to(n)
      nb = Array.new(n)
      bb = @bb
      p = bb.next
      bb.next = nil
      bbeg = 0
      until p.nil?
        nxt = p.next
        i = p.code % n
        q = nb[i]
        if q.nil?
          p.next = bb.next
          bb.next = p
          nb[i] = bb
          nb[bbeg] = p unless p.next.nil?
          bbeg = i
        else
          p.next = q.next
          q.next = p
        end
        p = nxt
      end
      @b = nb
    end

    def _erase_node(i, prev, n)
      b = @b
      nb = b.length
      if prev.equal?(b[i])
        # removing the bucket's first node (_M_remove_bucket_begin)
        nx = n.next
        nbk = nx.nil? ? 0 : nx.code % nb
        if nx.nil? || nbk != i
          b[nbk] = b[i] unless nx.nil?
          @bb.next = nx if b[i].equal?(@bb)
          b[i] = nil
        end
      elsif !n.next.nil?
        nbk = n.next.code % nb
        b[nbk] = prev if nbk != i
      end
      prev.next = n.next
      @cnt -= 1
      if @cm
        @d.delete(n.dk)
      else
        code = n.code
        f = @d[code]
        if f.equal?(n)
          if n.same.nil?
            @d.delete(code)
          else
            @d[code] = n.same
          end
        else
          f = f.same until f.same.equal?(n)
          f.same = n.same
        end
        @pc&.clear
      end
    end

    def EraseAt(n)
      i = n.code % @b.length
      prev = @b[i]
      prev = prev.next until prev.next.equal?(n)
      _erase_node(i, prev, n)
    end

    def _erase_key(k)
      n = _lookup(k)
      return false if n.nil?
      EraseAt(n)
      true
    end

    def size = @cnt
    def empty = @cnt == 0

    # keeps the bucket count, as libstdc++'s clear does
    def clear
      @b = Array.new(@b.length)
      @bb.next = nil
      @cnt = 0
      @d.clear
      unless @pc.nil?
        @pc.clear
        @nc.clear
      end
    end

    def bucket_count = @b.length
    def reserve(n) = rehash(n.ceil)

    def rehash(n)
      m = @cnt + 1
      m = n if n > m
      want = _next_bkt(m)
      _rehash_to(want) if want != @b.length
    end

    # the elements in node order; like the C# iterator, each step reads the next link when the loop asks
    def Items
      Enumerator.new do |y|
        p = @bb.next
        until p.nil?
          y << p.val
          p = p.next
        end
      end
    end

    def each
      p = @bb.next
      until p.nil?
        yield p.val
        p = p.next
      end
    end

    def begin = MIt.node(@bb.next)
    def end = MIT_END

    def find(k)
      n = _lookup(k)
      n.nil? ? MIT_END : MIt.node(n)
    end

    def count_(k) = _lookup(k).nil? ? 0 : 1
    def count(k) = _lookup(k).nil? ? 0 : 1
    def contains(k) = !_lookup(k).nil?
    def erase_K(k) = _erase_key(k) ? 1 : 0

    def erase_MItE(it)
      n = it.node
      nx = n.next
      EraseAt(n)
      MIt.node(nx)
    end

    # _M_assign: the same bucket count, the same node order, each element copied by copy (nil: shared)
    def _copy_from(o, copy)
      nbk = o.b.length
      b = Array.new(nbk)
      bb = @bb
      bb.next = nil
      @nr = o.nr
      cm = @cm
      kf = @kf
      d = {}
      prev = bb
      c = 0
      p = o.bb.next
      until p.nil?
        q = HNode.new
        v = copy.nil? ? p.val : copy.call(p.val)
        q.val = v
        code = p.code
        q.code = code
        prev.next = q
        i = code % nbk
        b[i] = prev if b[i].nil?
        if cm
          dk = Cpp.dk(kf.call(v))
          q.dk = dk
          d[dk] = q
        else
          q.dk = code
          q.same = d[code]
          d[code] = q
        end
        prev = q
        c += 1
        p = p.next
      end
      @b = b
      @cnt = c
      @d = d
      unless @pc.nil?
        @pc = {}
        @nc = {}
      end
    end
  end

  def NewHashTable(key, hash = nil, eq = nil) = HashTable.new(key, hash, eq)

  # ------------------------------------------------------------------------------------------------- iterators

  # An iterator over a hashed or sorted container (C# struct Cpp.MIt<E>): a node (nil at end) or a position in a
  # sorted container's list. A struct, so an immutable value: ++ and -- make new iterators.
  class MIt
    attr_reader :node, :list, :pos

    def initialize(node = nil, lst = nil, pos = 0)
      @node = node
      @list = lst
      @pos = pos
    end

    def self.node(n) = MIt.new(n, nil, 0)
    def self.at(lst, p) = MIt.new(nil, lst, p)

    def Clone = self
    def get_Deref = @list.nil? ? @node.val : @list[@pos]
    def Equals(o) = o.is_a?(MIt) && Cpp.mit_eq(self, o)
    alias == Equals
    def GetHashCode = @pos
  end

  MIT_END = MIt.new
  MIt_ZERO = MIT_END
  MK_MIt = -> { MIT_END }
  IMMUTABLE_MAKERS[MK_MIt] = true

  # a list position compares by position (a hashed container's end counts as no position); two nodes by identity
  def self.mit_eq(a, b)
    al = a.list
    bl = b.list
    if !al.nil? || !bl.nil?
      pa = al.nil? ? 0x7FFFFFFF : a.pos
      pb = bl.nil? ? 0x7FFFFFFF : b.pos
      return pa == pb
    end
    a.node.equal?(b.node)
  end

  def NewMIt_HNodeE(n) = MIt.node(n)
  def NewMIt_ListE_i(lst, p) = MIt.at(lst, p)
  def MIt_op_Increment(x) = x.list.nil? ? MIt.node(x.node.next) : MIt.at(x.list, x.pos + 1)
  def MIt_op_Decrement(x) = MIt.at(x.list, x.pos - 1)
  def MIt_op_Eq(a, b) = Cpp.mit_eq(a, b)
  def MIt_op_Ne(a, b) = !Cpp.mit_eq(a, b)

  # ------------------------------------------------------------------------------------------------- unordered_map / _set

  # std::unordered_map<K, V> (Cpp.UMap<K, V>) on HashTable's node order. mk makes a mapped value for operator[] and
  # try_emplace (the translator's maker; C#: an explicit maker or Elem<V>.Make).
  class UMap < HashTable
    include ICopy
    attr_accessor :mk

    def initialize(h = nil, eq = nil, mk = nil, cache = false)
      _init(KF_FIRST, h, eq, cache)
      @mk = mk
    end

    def _makev = @mk.nil? ? nil : @mk.call

    def _node(k)
      n = _lookup(k)
      n = _add(Pair.new(Cpp.key_copy(k), _makev)) if n.nil?
      n
    end

    def Index(k) = _node(k).val.second
    def ref_Index(k) = SecondRef.new(_node(k).val)

    def _at(k)
      n = _lookup(k)
      raise Cpp.out_of_range('_Map_base::at') if n.nil?
      n
    end

    def at(k) = _at(k).val.second
    def ref_at(k) = SecondRef.new(_at(k).val)

    def _insert_kv(k, v)
      n = _lookup(k)
      return Pair.new(MIt.node(n), false) unless n.nil?
      Pair.new(MIt.node(_add(Pair.new(Cpp.key_copy(k), v))), true)
    end

    def insert(p) = _insert_kv(p.first, p.second)
    def emplace_K_V(k, v) = _insert_kv(k, v)
    def emplace_PairKV(p) = _insert_kv(p.first, p.second)
    def try_emplace_K_V(k, v) = _insert_kv(k, v)

    def try_emplace_K(k)
      n = _lookup(k)
      return Pair.new(MIt.node(n), false) unless n.nil?
      Pair.new(MIt.node(_add(Pair.new(Cpp.key_copy(k), _makev))), true)
    end

    def insert_or_assign(k, v)
      n = _lookup(k)
      unless n.nil?
        n.val.second = v
        return Pair.new(MIt.node(n), false)
      end
      Pair.new(MIt.node(_add(Pair.new(Cpp.key_copy(k), v))), true)
    end

    def _init_list(il)
      il.each { |p| _add(p.Clone) if _lookup(p.first).nil? }
    end

    def Clone
      m = UMap.new(@cm ? nil : @hash, @cm ? nil : @eq, @mk)
      m._copy_from(self, PAIR_CLONE)
      m
    end

    def Assign(o)
      _copy_from(o, PAIR_CLONE) unless equal?(o)
    end

    def MoveFrom(o)
      return if equal?(o)
      _copy_from(o, nil)
      o.clear
    end
  end

  def NewUMap_FuncKul_FuncKKb_FuncV(h = nil, eq = nil, mk = nil, *makers)
    mk = makers[0] if mk.nil? && !makers.empty?
    UMap.new(h, eq, mk)
  end

  def NewUMap_PairKVA_FuncKul_FuncKKb(il, h = nil, eq = nil, mk = nil)
    m = UMap.new(h, eq, mk)
    m._init_list(il)
    m
  end

  # std::unordered_set<T> (Cpp.USet<T>) on HashTable's node order.
  class USet < HashTable
    include ICopy

    def initialize(h = nil, eq = nil, cache = false)
      _init(KF_IDENT, h, eq, cache)
    end

    def insert(x)
      n = _lookup(x)
      return Pair.new(MIt.node(n), false) unless n.nil?
      Pair.new(MIt.node(_add(Cpp.key_copy(x))), true)
    end

    def emplace(x) = insert(x)

    def _init_list(il)
      il.each { |x| _add(x) if _lookup(x).nil? }
    end

    def Clone
      m = USet.new(@cm ? nil : @hash, @cm ? nil : @eq)
      m._copy_from(self, ECOPY)
      m
    end

    def Assign(o)
      _copy_from(o, ECOPY) unless equal?(o)
    end

    def MoveFrom(o)
      return if equal?(o)
      _copy_from(o, nil)
      o.clear
    end
  end

  def NewUSet_FuncTul_FuncTTb(h = nil, eq = nil) = USet.new(h, eq)

  def NewUSet_TA_FuncTul_FuncTTb(il, h = nil, eq = nil)
    m = USet.new(h, eq)
    m._init_list(il)
    m
  end

  # ------------------------------------------------------------------------------------------------- engine hashers
  # A hasher of the engine's own (struct CiHash { size_t operator()(...) }): the generated class implements HashOf.
  # A two-argument predicate of the engine's own (a key-equal such as CiEqual): Call2(a, b). The classes that include
  # these modules register themselves, for UMapC / USetC.
  HASHFNS = []
  BINFNS = []

  module IHashFn
    def self.included(base)
      HASHFNS << base
    end
  end

  module IBinFn
    def self.included(base)
      BINFNS << base unless base.name.to_s.start_with?('Cpp::')
    end
  end

  # std::equal_to, for a container whose hasher is the engine's but whose key-equal is the default
  class StdEq
    include IBinFn
    include ICopy
    def Call2(a, b) = Cpp.deq(a, b)
    def Clone = StdEq.new
    def Assign(o); end
  end

  def NewStdEq = StdEq.new

  def self.pick(classes, name, what)
    return classes[0] if classes.length == 1
    named = classes.select { |c| c.name.to_s.end_with?(name) }
    return named[0] if named.length == 1
    raise "Cpp.UMapC/USetC: the translator passes no #{what}, and the engine defines #{classes.length} #{what} classes " \
          "(#{classes.map(&:name).join(', ')}); cannot tell which one is meant"
  end

  # C#'s new H() and new E() for UMapC<K, V, H, E>: the engine instantiates one pair only (CiHash, CiEqual), so the
  # classes come from the IHashFn / IBinFn classes the engine defined. [hash function, key-equal function]
  def self.engine_fns
    @engine_fns ||= begin
      h = Cpp.pick(HASHFNS, 'CiHash', 'IHashFn').new
      e = Cpp.pick(BINFNS, 'CiEqual', 'IBinFn').new
      [h.method(:HashOf), e.method(:Call2)]
    end
  end

  # std::unordered_map<K, V, H, E> with the engine's hasher H and key-equal E (Cpp.UMapC)
  class UMapC < UMap
    def initialize(mk = nil, fns = nil)
      h, e = fns.nil? ? Cpp.engine_fns : fns
      super(h, e, mk, true)
    end

    def Clone
      m = UMapC.new(@mk, [@hash, @eq])
      m._copy_from(self, PAIR_CLONE)
      m
    end
  end

  def NewUMapC_FuncV(mk = nil, *makers)
    mk = makers[0] if mk.nil? && !makers.empty?
    UMapC.new(mk)
  end

  def NewUMapC_PairKVA(il, mk = nil)
    m = UMapC.new(mk)
    m._init_list(il)
    m
  end

  class USetC < USet
    def initialize(fns = nil)
      h, e = fns.nil? ? Cpp.engine_fns : fns
      super(h, e, true)
    end

    def Clone
      m = USetC.new([@hash, @eq])
      m._copy_from(self, ECOPY)
      m
    end
  end

  def NewUSetC = USetC.new

  def NewUSetC_TA(il)
    m = USetC.new
    m._init_list(il)
    m
  end

  # ------------------------------------------------------------------------------------------------- std::map / set

  # the first index of a sorted Array of keys whose key is not less than ck (bisect_left)
  def self.bisect(keys, ck)
    lo = 0
    hi = keys.length
    while lo < hi
      mid = (lo + hi) >> 1
      if (keys[mid] <=> ck) < 0
        lo = mid + 1
      else
        hi = mid
      end
    end
    lo
  end

  # std::map (Cpp.Map<K, V>): the pairs kept sorted by the comparator in an Array (a red-black tree's order is the
  # sorted order). With std::less (the default) a parallel Array of the keys as Ruby values (Cpp.sk) is searched by
  # bisection; with another comparator, or a key sk cannot express, the search calls the comparator.
  class Map
    include ICopy
    attr_accessor :lt, :items, :keys, :mk

    def initialize(less = nil, mk = nil)
      less = Less_Fn if less.nil?
      @lt = less
      @items = []
      @keys = less.equal?(Less_Fn) ? [] : nil
      @mk = mk
    end

    def std? = @lt.equal?(Less_Fn)

    # [index of the first pair whose key is not less than k, k's sorted key or nil]
    def _lower(k)
      keys = @keys
      unless keys.nil?
        begin
          ck = Cpp.sk(k)
          return [Cpp.bisect(keys, ck), ck]
        rescue NoKey
          @keys = nil
        end
      end
      lt = @lt
      items = @items
      lo = 0
      hi = items.length
      while lo < hi
        mid = (lo + hi) >> 1
        if lt.call(items[mid].first, k)
          lo = mid + 1
        else
          hi = mid
        end
      end
      [lo, nil]
    end

    def _at_key(i, k, ck)
      return false if i >= @items.length
      return (ck <=> @keys[i]) >= 0 unless ck.nil?
      !@lt.call(k, @items[i].first)
    end

    def _put(i, ck, p)
      @items.insert(i, p)
      @keys&.insert(i, ck)
    end

    def _find(k)
      i, ck = _lower(k)
      _at_key(i, k, ck) ? i : -1
    end

    def _index(k)
      i, ck = _lower(k)
      _put(i, ck, Pair.new(Cpp.key_copy(k), @mk.nil? ? nil : @mk.call)) unless _at_key(i, k, ck)
      @items[i]
    end

    def Index(k) = _index(k).second
    def ref_Index(k) = SecondRef.new(_index(k))

    def at(k)
      i = _find(k)
      raise Cpp.out_of_range('map::at') if i < 0
      @items[i].second
    end

    def ref_at(k)
      i = _find(k)
      raise Cpp.out_of_range('map::at') if i < 0
      SecondRef.new(@items[i])
    end

    def insert(p)
      i, ck = _lower(p.first)
      return Pair.new(MIt.at(@items, i), false) if _at_key(i, p.first, ck)
      _put(i, ck, Pair.new(Cpp.key_copy(p.first), p.second))
      Pair.new(MIt.at(@items, i), true)
    end

    def emplace_K_V(k, v) = insert(Pair.new(k, v))
    def emplace_PairKV(p) = insert(p)
    def try_emplace_K_V(k, v) = insert(Pair.new(k, v))

    def insert_or_assign(k, v)
      i = _find(k)
      if i >= 0
        @items[i].second = v
        return Pair.new(MIt.at(@items, i), false)
      end
      insert(Pair.new(k, v))
    end

    def find(k)
      i = _find(k)
      MIt.at(@items, i < 0 ? @items.length : i)
    end

    def lower_bound(k) = MIt.at(@items, _lower(k)[0])

    def upper_bound(k)
      i, ck = _lower(k)
      i += 1 while _at_key(i, k, ck)
      MIt.at(@items, i)
    end

    def count(k) = _find(k) >= 0 ? 1 : 0
    def contains(k) = _find(k) >= 0

    def erase_K(k)
      i = _find(k)
      return 0 if i < 0
      @items.delete_at(i)
      @keys&.delete_at(i)
      1
    end

    def erase_MItPairKV(it)
      @items.delete_at(it.pos)
      @keys&.delete_at(it.pos)
      MIt.at(@items, it.pos)
    end

    def size = @items.length
    def empty = @items.empty?

    def clear
      @items.clear
      @keys = [] if std?
    end

    def begin = MIt.at(@items, 0)
    def end = MIt.at(@items, @items.length)
    def Items = @items
    def _keys_of(o) = !o.keys.nil? && std? ? o.keys.dup : nil

    def Clone
      m = Map.new(@lt, @mk)
      m.items = @items.map(&:Clone)
      m.keys = m._keys_of(self)
      m
    end

    def Assign(o)
      return if equal?(o)
      @items = o.items.map(&:Clone)
      @keys = _keys_of(o)
    end

    def MoveFrom(o)
      return if equal?(o)
      @items = o.items
      @keys = _keys_of(o)
      o.items = []
      o.keys = o.std? ? [] : nil
    end
  end

  def NewMap_FuncKKb_FuncV(less = nil, mk = nil, *makers)
    mk = makers[0] if mk.nil? && !makers.empty?
    Map.new(less, mk)
  end

  def NewMap_PairKVA_FuncKKb(il, less = nil, mk = nil)
    m = Map.new(less, mk)
    il.each { |p| m.insert(p.Clone) }
    m
  end

  # std::set (Cpp.Set<T>): the elements kept sorted in an Array, searched as Map searches its keys.
  class Set_
    include ICopy
    attr_accessor :lt, :items, :keys

    def initialize(less = nil)
      less = Less_Fn if less.nil?
      @lt = less
      @items = []
      @keys = less.equal?(Less_Fn) ? [] : nil
    end

    def std? = @lt.equal?(Less_Fn)

    def _lower(k)
      keys = @keys
      unless keys.nil?
        begin
          ck = Cpp.sk(k)
          return [Cpp.bisect(keys, ck), ck]
        rescue NoKey
          @keys = nil
        end
      end
      lt = @lt
      items = @items
      lo = 0
      hi = items.length
      while lo < hi
        mid = (lo + hi) >> 1
        if lt.call(items[mid], k)
          lo = mid + 1
        else
          hi = mid
        end
      end
      [lo, nil]
    end

    def _at_key(i, k, ck)
      return false if i >= @items.length
      return (ck <=> @keys[i]) >= 0 unless ck.nil?
      !@lt.call(k, @items[i])
    end

    def insert(x)
      i, ck = _lower(x)
      return Pair.new(MIt.at(@items, i), false) if _at_key(i, x, ck)
      @items.insert(i, Cpp.key_copy(x))
      @keys&.insert(i, ck)
      Pair.new(MIt.at(@items, i), true)
    end

    def emplace(x) = insert(x)

    def find(k)
      i, ck = _lower(k)
      MIt.at(@items, _at_key(i, k, ck) ? i : @items.length)
    end

    def count(k)
      i, ck = _lower(k)
      _at_key(i, k, ck) ? 1 : 0
    end

    def contains(k) = count(k) > 0

    def erase_T(k)
      i, ck = _lower(k)
      return 0 unless _at_key(i, k, ck)
      @items.delete_at(i)
      @keys&.delete_at(i)
      1
    end

    def erase_MItT(it)
      @items.delete_at(it.pos)
      @keys&.delete_at(it.pos)
      MIt.at(@items, it.pos)
    end

    def size = @items.length
    def empty = @items.empty?

    def clear
      @items.clear
      @keys = [] if std?
    end

    def begin = MIt.at(@items, 0)
    def end = MIt.at(@items, @items.length)
    def Items = @items
    def _keys_of(o) = !o.keys.nil? && std? ? o.keys.dup : nil

    def Clone
      m = Set_.new(@lt)
      m.items = @items.map { |x| Cpp.ecopy(x) }
      m.keys = m._keys_of(self)
      m
    end

    def Assign(o)
      return if equal?(o)
      @items = o.items.map { |x| Cpp.ecopy(x) }
      @keys = _keys_of(o)
    end

    def MoveFrom(o)
      return if equal?(o)
      @items = o.items
      @keys = _keys_of(o)
      o.items = []
      o.keys = o.std? ? [] : nil
    end
  end

  def NewSet_FuncTTb(less = nil) = Set_.new(less)

  def NewSet_TA_FuncTTb(il, less = nil)
    m = Set_.new(less)
    il.each { |x| m.insert(x) }
    m
  end

  # ------------------------------------------------------------------------------------------------- stack / queue

  # std::stack over std::deque (Cpp.Stk<T>): push (the element as given, no copy, as the C# does), pop, top.
  class Stk
    include ICopy
    attr_accessor :items

    def initialize
      @items = []
    end

    def push(x)
      @items << x
    end

    def pop
      @items.pop
    end

    def top = @items[-1]
    def ref_top = ArrRef.new(@items, @items.length - 1)
    def empty = @items.empty?
    def size = @items.length

    def Clone
      s = Stk.new
      s.items = @items.map { |x| Cpp.ecopy(x) }
      s
    end

    def Assign(o)
      @items.replace(o.items.map { |x| Cpp.ecopy(x) }) unless equal?(o)
    end

    def MoveFrom(o)
      return if equal?(o)
      @items.replace(o.items)
      o.items.clear
    end
  end

  def NewStk = Stk.new

  # std::queue over std::deque (Cpp.Que<T>): first in, first out; the Array is compacted as the C# does.
  class Que
    include ICopy
    attr_accessor :items, :head

    def initialize
      @items = []
      @head = 0
    end

    def push(x)
      @items << x
    end

    def pop
      @items[@head] = nil
      @head += 1
      return unless @head > 64 && @head * 2 > @items.length
      @items.shift(@head)
      @head = 0
    end

    def front = @items[@head]
    def ref_front = ArrRef.new(@items, @head)
    def back = @items[-1]
    def ref_back = ArrRef.new(@items, @items.length - 1)
    def empty = @items.length == @head
    def size = @items.length - @head

    def Clone
      q = Que.new
      q.items = @items[@head..].map { |x| Cpp.ecopy(x) }
      q
    end

    def Assign(o)
      return if equal?(o)
      @items.replace(o.items[o.head..].map { |x| Cpp.ecopy(x) })
      @head = 0
    end

    def MoveFrom(o)
      return if equal?(o)
      @items.replace(o.items[o.head..])
      @head = 0
      o.items.clear
      o.head = 0
    end
  end

  def NewQue = Que.new
end
