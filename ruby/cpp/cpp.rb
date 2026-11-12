# encoding: binary
# frozen_string_literal: true
# cpp.rb - the Ruby runtime of the SWMM6 port (module Cpp): loads its parts in dependency order and includes Cpp into
# Object, so the generated engine (ruby/gen/engine.rb) calls the runtime's functions (R_Lit, NewVecD, Math_Pow_d, ...)
# by their bare names, as the C# calls its static members. The parts follow cs/runtime (the C# runtime, which is the
# specification) by way of the Python port's modules (py/cpp); see ruby/README.md and tools/cs2x/RB.md.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.

%w[core_num core_ptr core_str core_vec primelist containers algo stdalgo crt crtmath crtmisc rfs fs streams].each do |f|
  require_relative f
end

Object.include(Cpp)
