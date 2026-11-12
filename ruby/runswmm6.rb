# encoding: binary
# frozen_string_literal: true
# runswmm6.rb - the SWMM6 command line (src/cli/main.cpp), a hand port of cs/runtime/Program.cs by way of the Python
# runner (py/runswmm6.py): the same calls into the engine's C API (the top-level F__global_swmm_* functions of
# ruby/gen/engine.rb) in the same order, the same messages on stdout and the same exit code; R_FlushAll before exit,
# as returning from main calls exit(), which flushes every open FILE.
# What the C# gets from .NET is made explicit:
#   - the engine runs on a thread with a large stack (ruby/runswmm6 sets RUBY_THREAD_VM_STACK_SIZE and
#     RUBY_THREAD_MACHINE_STACK_SIZE before Ruby starts);
#   - an exception that escapes the engine ends the process as .NET's unhandled-exception handler does:
#     "Unhandled exception. ..." on stderr, no flushing of the C files, and exit code 134 (SIGABRT's);
#   - the command-line arguments are the .NET strings (UTF-8, an invalid sequence replaced by U+FFFD), handed to the
#     engine as R.Lit makes them (each UTF-16 unit stored as its low byte) and echoed as Encoding.Latin1 writes them
#     ('?' for a char above U+00FF);
#   - {1:F2} of the elapsed seconds is .NET Core's: the exact value rounded half away from zero to two places.
# The engine is loaded after the argument checks (.NET runs static initialisers on first use).
# Usage: ruby --disable-gems ruby/runswmm6.rb <input.inp> <report.rpt> [output.out]   (ruby/runswmm6 is the wrapper)
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.

require_relative 'cpp/cpp'

module Runner
  VERSION = '6.0.0-alpha.4'
  HERE = __dir__

  # Encoding.Latin1.GetBytes(s) written to the C stdout's stream, which writes through
  def self.out(s) = Cpp::R_stdout_.S.write(Cpp.latin1_bytes(s))

  # R.Str(CPtr): the Latin-1 text of a C string
  def self.str(p) = Cpp.latin1_str(Cpp.cbs(p))

  # .NET Core's {0:F2} of a double: the exact value rounded half away from zero to two decimals
  def self.f2(x)
    q = (Rational(x) * 100).round(half: :up)
    format('%s%d.%02d', q < 0 ? '-' : '', q.abs / 100, q.abs % 100)
  end

  def self.load_engine
    require File.join(HERE, 'gen', 'engine')
  end

  def self.main(argv)
    rc = run(argv)
    R_FlushAll()          # returning from main calls exit(), which flushes every open FILE
    rc
  end

  def self.err_msg(engine) = str(F__global_swmm_get_last_error_msg(engine))

  def self.run(argv)
    if argv.empty?
      out("\nError: not enough arguments. Use --help for usage.\n\n")
      return 1
    end
    if argv[0] == '--version' || argv[0] == '-v'
      out("openswmm.engine #{VERSION}\n")
      return 0
    end
    if argv.length < 2
      out("\nError: need at least input and report file paths.\n")
      out("Usage: openswmm <input.inp> <report.rpt> [output.out]\n\n")
      return 1
    end
    inp = argv[0]
    rpt = argv[1]
    outf = argv.length > 2 ? argv[2] : ''
    load_engine
    out("\n... OpenSWMM Engine #{VERSION}\n... Input: #{inp}\n... Report: #{rpt}\n... Output: #{outf}\n")
    R_fflush(Cpp::R_stdout_)
    t0 = Process.clock_gettime(Process::CLOCK_REALTIME)
    engine = F__global_swmm_engine_create()
    if engine.nil?
      out("Error: failed to create engine instance.\n")
      return 1
    end
    err = F__global_swmm_engine_open(engine, Cpp.net_lit(inp), Cpp.net_lit(rpt), Cpp.net_lit(outf), Cpp::CPtr_ZERO)
    if err != 0
      out("Error opening input file: #{err_msg(engine)}\n")
      F__global_swmm_engine_destroy(engine)
      return err
    end
    err = F__global_swmm_engine_initialize(engine)
    if err != 0
      out("Error initializing: #{err_msg(engine)}\n")
      F__global_swmm_engine_close(engine)
      F__global_swmm_engine_destroy(engine)
      return err
    end
    err = F__global_swmm_engine_start(engine, outf.empty? ? 0 : 1)
    if err != 0
      out("Error starting simulation: #{err_msg(engine)}\n")
      F__global_swmm_engine_close(engine)
      F__global_swmm_engine_destroy(engine)
      return err
    end
    elapsed = [0.0]
    ptr = NewPtrD_TA_l(elapsed, 0)
    steps = 0
    loop do
      err = F__global_swmm_engine_step(engine, ptr)
      if err != 0
        out("\nError at step #{steps}: #{err_msg(engine)}\n")
        break
      end
      break if elapsed[0] <= 0.0
      steps += 1
    end
    out("\n... #{steps} steps completed.\n")
    result = err
    fin = lambda do |status, phase|
      if status != 0
        out("Error #{phase}: #{err_msg(engine)}\n")
        result = status if result == 0
      end
    end
    fin.call(F__global_swmm_engine_end(engine), 'ending simulation')
    fin.call(F__global_swmm_engine_report(engine), 'writing report')
    fin.call(F__global_swmm_engine_close(engine), 'closing simulation')
    F__global_swmm_engine_destroy(engine)
    t = Process.clock_gettime(Process::CLOCK_REALTIME) - t0
    out("... OpenSWMM Engine #{result == 0 ? 'completed' : 'failed'} in #{f2(t)} seconds.\n\n")
    result
  end

  # .NET's unhandled-exception handler: the exception on stderr, then abort (no exit(), so no FILE flushing)
  def self.crash(e)
    msg = "Unhandled exception. #{e.class}: #{e.message}\n   #{(e.backtrace || []).first(30).join("\n   ")}\n"
    begin
      $stderr.syswrite(msg.b)
    rescue StandardError
      nil
    end
    exit!(134)
  end
end

argv = ARGV.map { |a| Cpp.net_str(a.b) }
box = {}
th = Thread.new do
  box[:rc] = Runner.main(argv)
rescue Exception => e # rubocop:disable Lint/RescueException - an exception escaping main ends the process as .NET's does
  box[:crash] = e
end
th.report_on_exception = false
th.join
Runner.crash(box[:crash]) if box.key?(:crash)
exit!((box[:rc] || 0) & 0xFF)
