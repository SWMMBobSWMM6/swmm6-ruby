In a Ruby file marked `# encoding: binary`, `"�"` is a binary String, so `String#scrub("�")` on UTF-8 text raised `Encoding::CompatibilityError` and the Ruby command line stopped before reading its arguments.

Every file of the Ruby runtime and engine starts with `# encoding: binary`, because C strings are bytes and every
literal must be bytes too. The runtime turns command-line arguments into .NET strings as .NET does (UTF-8, an invalid
sequence replaced by U+FFFD):

```ruby
# ruby/cpp/rfs.rb (first version)
  def self.net_str(b) = b.dup.force_encoding('UTF-8').scrub("�")
```

```
/home/claude/swmm6-ports/ruby/cpp/rfs.rb:13:in `scrub': incompatible character encodings: UTF-8 and ASCII-8BIT (Encoding::CompatibilityError)
	from /home/claude/swmm6-ports/ruby/runswmm6.rb:137:in `map'
```

The replacement must be a UTF-8 String; it is now made from its bytes and tagged:

```ruby
  REPL = "\xEF\xBF\xBD".dup.force_encoding('UTF-8').freeze
  def self.net_str(b) = b.dup.force_encoding('UTF-8').scrub(REPL)
```

The first attempt at the fix did not take, because the file-writing tool had written the escape as the character
itself; `grep -nP '[^\x00-\x7F]' ruby/cpp/*.rb` now finds no byte above 127 in the runtime's sources. In a source file
whose encoding is binary, build any text that must carry an encoding from bytes, and check the file for raw non-ASCII
bytes after writing it.
