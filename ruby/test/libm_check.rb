# encoding: binary
# frozen_string_literal: true
# libm_check.rb - compare the Ruby runtime's math (ruby/cpp/crtmath.rb: MRI's Math where it calls glibc unchanged,
# glibc itself through Fiddle elsewhere, and the exact functions computed in Ruby) bit for bit with vectors computed
# by C programs linked against the system libm: tools/libm/test/mkvectors.c and mkedge.c (exp, log, log10, pow, sin,
# cos, tan, asin, acos, atan), mkvectors2.c (cbrt, hypot, atan2, cosh, sinh, tanh, log2, expm1, log1p) and
# ruby/test/mkexact.c (sqrt, floor, ceil, trunc, fabs, round, copysign). Each function is called the way the generated
# engine calls it (sqrt as the engine's inline Math.sqrt / Math_Sqrt_d, fabs as Float#abs). Every bit must match,
# NaN sign and payload included. fma, frexp and ldexp, which the vector files also hold for the ports that
# translate glibc, are skipped: the Ruby port calls none of them.
#   ruby --disable-gems libm_check.rb FILE...
# After fsharp/test/LibmCheck.fs. Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md.
require_relative '../cpp/cpp'

FNS = {
  'exp' => [1, ->(a) { Math_Exp_d(a[0]) }], 'log' => [1, ->(a) { Math_Log_d(a[0]) }],
  'log10' => [1, ->(a) { Math_Log10_d(a[0]) }], 'pow' => [2, ->(a) { Math_Pow_d(a[0], a[1]) }],
  'sin' => [1, ->(a) { Math_Sin_d(a[0]) }], 'cos' => [1, ->(a) { Math_Cos_d(a[0]) }],
  'tan' => [1, ->(a) { Math_Tan_d(a[0]) }], 'asin' => [1, ->(a) { Math_Asin_d(a[0]) }],
  'acos' => [1, ->(a) { Math_Acos_d(a[0]) }], 'atan' => [1, ->(a) { Math_Atan_d(a[0]) }],
  'cbrt' => [1, ->(a) { Math_Cbrt_d(a[0]) }], 'hypot' => [2, ->(a) { LibM_hypot(a[0], a[1]) }],
  'atan2' => [2, ->(a) { Math_Atan2_d(a[0], a[1]) }], 'cosh' => [1, ->(a) { Math_Cosh_d(a[0]) }],
  'sinh' => [1, ->(a) { Math_Sinh_d(a[0]) }], 'tanh' => [1, ->(a) { Math_Tanh_d(a[0]) }],
  'log2' => [1, ->(a) { Math_Log2_d(a[0]) }], 'expm1' => [1, ->(a) { LibM_expm1(a[0]) }],
  'log1p' => [1, ->(a) { LibM_log1p(a[0]) }],
  'sqrt' => [1, ->(a) { x = a[0]; x > 0.0 ? Math.sqrt(x) : Math_Sqrt_d(x) }],
  'floor' => [1, ->(a) { Math_Floor_d(a[0]) }], 'ceil' => [1, ->(a) { Math_Ceiling_d(a[0]) }],
  'trunc' => [1, ->(a) { Math_Truncate_d(a[0]) }], 'fabs' => [1, ->(a) { a[0].abs }],
  'round' => [1, ->(a) { LibM_round(a[0]) }], 'copysign' => [2, ->(a) { Math_CopySign_d(a[0], a[1]) }]
}.freeze
SKIPPED = { 'fma' => 4, 'frexp' => 3, 'ldexp' => 3 }.freeze

def bits(x) = [x].pack('E').unpack1('Q<')

total = 0
bad_all = 0
ARGV.each do |path|
  puts "== #{File.basename(path)}"
  File.open(path, 'rb') do |f|
    until f.eof?
      name = f.gets("\0").chomp("\0")
      n = f.read(4).unpack1('L<')
      fn = FNS[name]
      if fn.nil?
        per = SKIPPED.fetch(name) { raise "unknown function #{name}" }
        f.seek(n * per * 8, IO::SEEK_CUR)
        puts format('%-9s skipped (%d records; the Ruby port does not call it)', name, n)
        next
      end
      na, g = fn
      rec = na + 1
      vals = f.read(n * rec * 8).unpack('E*')
      bad = nan_sign = nan_pay = shown = 0
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      args = Array.new(na)
      i = 0
      n.times do
        na.times { |k| args[k] = vals[i + k] }
        want = vals[i + na]
        got = g.call(args)
        gb = bits(got)
        wb = bits(want)
        if gb != wb
          if got.nan? && want.nan?
            if (gb >> 63) != (wb >> 63) then nan_sign += 1 else nan_pay += 1 end
          else
            bad += 1
            if shown < 4
              shown += 1
              puts format('  %s(%s) = %016x, libm %016x', name, args.map { |x| x.inspect }.join(', '), gb, wb)
            end
          end
        end
        i += rec
      end
      dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      total += n
      bad_all += bad + nan_sign + nan_pay
      puts format('%-9s %d of %d differ, %d NaN sign, %d NaN payload   (%.3f us/call)', name, bad, n, nan_sign, nan_pay, dt * 1e6 / n)
    end
  end
end
puts "records checked: #{total}"
puts "total mismatches: #{bad_all}"
