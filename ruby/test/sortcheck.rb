# encoding: binary
# frozen_string_literal: true
# sortcheck.rb - the cases of tests/stdcheck/sortcheck.cpp through ruby/cpp/stdalgo.rb; output must equal
# sortcheck.cpp's byte for byte. Mode O: the generic StdAlgo_Sort / StdAlgo_StableSort / StdAlgo_PartialSort over an
# Array of structs. D, I or L: the same permutations from the specialisations (StdAlgo_Sort__I over the ids, ordered
# by their keys, and so on). After tests/stdcheck/sortcheck.py.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
require_relative '../cpp/cpp'

M = 0xFFFFFFFFFFFFFFFF
$s = 1729
def rnd
  s = $s
  s ^= (s << 13) & M
  s ^= s >> 7
  s ^= (s << 17) & M
  $s = s
end

E = Struct.new(:key, :id)
mode = ARGV[0] || 'O'
run = if mode == 'O'
        lambda do |key, n, which|
          a = Array.new(n) { |i| E.new(key[i], i) }
          lt = ->(x, y) { x.key < y.key }
          case which
          when 0 then StdAlgo_Sort(a, 0, n, lt)
          when 1 then StdAlgo_StableSort(a, 0, n, lt)
          else StdAlgo_PartialSort(a, 0, n, n, lt)
          end
          a.map(&:id)
        end
      else
        conv = mode == 'D' ? ->(i) { i.to_f } : ->(i) { i }
        lambda do |key, n, which|
          a = Array.new(n) { |i| conv.call(i) }
          lt = ->(x, y) { key[x.to_i] < key[y.to_i] }
          case which
          when 0 then send("StdAlgo_Sort__#{mode}", a, 0, n, lt)
          when 1 then send("StdAlgo_StableSort__#{mode}", a, 0, n, lt)
          else send("StdAlgo_PartialSort__#{mode}", a, 0, n, n, lt)
          end
          a.map(&:to_i)
        end
      end
out = +''
((0..300).to_a + [511, 512, 513, 1000, 4096, 10_007]).each do |n|
  7.times do |pat|
    key = Array.new(n) do |i|
      case pat
      when 0 then rnd % 5
      when 1 then rnd % 1_000_000
      when 2 then i / 3
      when 3 then (n - i) / 2
      when 4 then 7
      when 5 then i < n / 2 ? i : n - i
      else (i * 7919) % 31
      end
    end
    [['sort', 0], ['stable', 1], ['heap', 2]].each do |tag, which|
      out << "#{tag} #{n} #{pat}:" << run.call(key, n, which).map { |x| " #{x}" }.join << "\n"
    end
  end
end
$stdout.write(out)
