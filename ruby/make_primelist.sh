#!/bin/bash
# Write ruby/cpp/primelist.rb, libstdc++'s __prime_list, from the C# runtime's cs/runtime/PrimeList.cs (which
# tests/stdcheck/primes.cpp extracted from the system libstdc++).
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md and ruby/README.md.
set -e
cd "$(dirname "$0")"
{
  echo "# encoding: binary"
  echo "# frozen_string_literal: true"
  echo "# primelist.rb - libstdc++'s std::__detail::__prime_list (C# Cpp.PrimeList.P, cs/runtime/PrimeList.cs, which"
  echo "# tests/stdcheck/primes.cpp extracted from the system libstdc++): the bucket counts its hash tables take, ending"
  echo "# with the largest 64-bit prime. Written by ruby/make_primelist.sh from cs/runtime/PrimeList.cs; do not edit."
  echo "# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md."
  echo
  echo "module Cpp"
  echo "  PRIMES = ["
  grep -E '^[0-9]' ../cs/runtime/PrimeList.cs | sed -E 's/UL//g; s/^/    /; s/,? *$/,/'
  echo "  ].freeze"
  echo "end"
} > cpp/primelist.rb
