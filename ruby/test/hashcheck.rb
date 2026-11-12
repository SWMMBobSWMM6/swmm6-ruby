# encoding: binary
# frozen_string_literal: true
# hashcheck.rb - the operations of tests/stdcheck/hashcheck.cpp through the Ruby runtime's hash tables
# (ruby/cpp/containers.rb: UMap, USet, HashTable, the rehash policy, std::hash); output must equal hashcheck.cpp's:
# bucket counts and iteration order after inserts, operator[], erases, reserve and copies, and std::hash of strings.
# After tests/stdcheck/hashcheck.py. Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
require_relative '../cpp/cpp'

M = 0xFFFFFFFFFFFFFFFF
PRE = %w[J C N OF P RG SUB_ Link- node. W].freeze
$s = 52_024
def rnd
  s = $s
  s ^= (s << 13) & M
  s ^= s >> 7
  s ^= (s << 17) & M
  $s = s
end

def mkstr(x) = Cpp.str_of(x)
def text(s) = s.b[0, s.n].pack('C*')

def name(r)
  x = PRE[r % 10] + ((r >> 8) % 5000).to_s
  x += "_#{(r >> 24) % 97}" if ((r >> 20) % 3).zero?
  mkstr(x)
end

out = +''
40.times do |rd|
  m = NewUMap_FuncKul_FuncKKb_FuncV(nil, nil, Cpp::MK_I)
  mi = NewUMap_FuncKul_FuncKKb_FuncV(nil, nil, Cpp::MK_I)
  st = NewUSet_FuncTul_FuncTTb(nil, nil)
  n = 1 + rnd % (rd < 20 ? 60 : 3000)
  m.reserve(n) if rd % 7 == 3
  n.times do |i|
    r = rnd
    k = name(r)
    if (r % 5).zero?
      v = m.ref_Index(k)
      v.v = v.v + i
    else
      m.emplace_K_V(k, i)
    end
    mi.emplace_K_V(r % 20_000 - 10_000, i)
    st.insert(k)
    m.erase_K(name(rnd)) if (r % 11).zero? && !m.empty
    mi.erase_K(rnd % 20_000 - 10_000) if (r % 13).zero?
    m.erase_MItE(m.begin) if (r % 17).zero? && !m.empty
  end
  c = m.Clone
  out << "map #{rd}: #{m.bucket_count} buckets #{m.size}:"
  m.Items.each { |kv| out << " #{text(kv.first)}=#{kv.second}" }
  out << "\ncopy:"
  c.Items.each { |kv| out << " #{text(kv.first)}" }
  out << "\nimap #{mi.bucket_count} #{mi.size}:"
  mi.Items.each { |kv| out << " #{kv.first}=#{kv.second}" }
  out << "\nset #{st.bucket_count}:"
  st.Items.each { |k| out << " #{text(k)}" }
  out << "\n"
end
['', 'a', 'abcdefg', 'abcdefgh', 'abcdefghi', 'Junction_17', 'OUTFALL-1'].each do |w|
  out << "hash #{w} #{StdHash_Of_Str(mkstr(w))}\n"
end
$stdout.write(out)
