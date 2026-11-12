# encoding: binary
# frozen_string_literal: true
# fs.rb - the FsPath, Fs and FileStatus classes of cs/runtime/Fs.cs, and the parts of .NET's System.IO that
# cs/runtime/Streams.cs and Fs.cs rely on; a port of py/cpp/fs.py and py/cpp/fsnet.py.
#   std::filesystem::path with POSIX paths, as libstdc++ on Linux; FsPath.p holds the path's bytes (a Str).
#   The std::filesystem functions over .NET's file system calls as the C# port makes them: canonical and
#   weakly_canonical are Path.GetFullPath (lexical, links left alone), equivalent compares the two full paths, the
#   error-code overloads set ENOENT (2), EACCES (13), EEXIST (17) or EISDIR (21) as the C# port does, and the plain
#   overloads let .NET's exceptions through (as SysException).
#   .NET: Path.GetFullPath on Unix (lexical: "." and ".." and doubled separators removed against the current
#   directory; ArgumentException for an empty path or a NUL), File.Exists / Directory.Exists (stat, then lstat for a
#   broken link; a full path ending in '/' is never a file), File.Move (rename(2), or copy and delete across file
#   systems) / File.Copy / File.Delete / Directory.Delete / Directory.CreateDirectory, FileInfo.Length, the
#   FileStream constructor's open (a directory refused), a FileStream's write buffer (BufferedFileStreamStrategy)
#   and its position, which .NET keeps itself and reads and writes at with pread / pwrite, and a MemoryStream.
# A .NET path string is a UTF-8 Ruby String (the Latin-1 text of the C++ bytes); it reaches the OS as its UTF-8, as
# .NET marshals it.
# Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.

module Cpp
  SEEK_BEFORE_BEGIN = 'An attempt was made to move the position before the beginning of the stream.'
  SEEK_APPEND = 'Unable seek backward to overwrite data that previously existed in a file opened in Append mode.'

  def self.sys_exc(kind, msg) = SysException.new(kind, msg)
  def self.io_exc(e) = SysException.new('IO.IOException', e.is_a?(SystemCallError) ? Cpp.strerror(e) : e.message)

  # glibc's strerror text of a SystemCallError (Ruby's message adds " @ rb_sysopen - path" and the like)
  def self.strerror(e) = SystemCallError.new(nil, e.errno).message.sub(/ - \z/, '')

  # ------------------------------------------------------------------------------------------- text and bytes
  def self.latin1_str(b) = b.dup.force_encoding('ISO-8859-1').encode('UTF-8')

  # Encoding.Latin1.GetBytes: a char above U+00FF becomes '?'
  def self.latin1_bytes(s) = s.encode('ISO-8859-1', undef: :replace, invalid: :replace, replace: '?').b

  # ------------------------------------------------------------------------------------------- Path.GetFullPath
  def self.cwd = Cpp.net_str(Dir.pwd.b)

  # Path.GetFullPath on Unix: ArgumentException for an empty path or a NUL; a relative path is put under the
  # current directory (Path.Combine), then PathInternal.RemoveRelativeSegments collapses it
  def self.full_path(path)
    raise Cpp.sys_exc('ArgumentException', "The value cannot be an empty string. (Parameter 'path')") if path.empty?
    raise Cpp.sys_exc('ArgumentException', "Null character in path. (Parameter 'path')") if path.include?("\0")
    unless path.start_with?('/')
      c = Cpp.cwd
      path = c.end_with?('/') ? c + path : "#{c}/#{path}"
    end
    return path unless path.include?('//') || path.include?('/.')
    r = Cpp.remove_relative_segments(path, 1)
    r.empty? ? '/' : r
  end

  # PathInternal.RemoveRelativeSegments (dotnet/runtime) for '/' separators
  def self.remove_relative_segments(path, root_length)
    skip = root_length
    skip -= 1 if path[skip - 1] == '/'
    sb = skip > 0 ? path[0, skip].chars : []
    n = path.length
    i = skip
    while i < n
      c = path[i]
      if c == '/' && i + 1 < n
        if path[i + 1] == '/'
          i += 1
          next
        end
        if (i + 2 == n || path[i + 2] == '/') && path[i + 1] == '.'
          i += 2
          next
        end
        if i + 2 < n && (i + 3 == n || path[i + 3] == '/') && path[i + 1] == '.' && path[i + 2] == '.'
          s = sb.length - 1
          while s >= skip
            if sb[s] == '/'
              sb.slice!((i + 3 >= n && s == skip ? s + 1 : s)..)
              break
            end
            s -= 1
          end
          sb.slice!(skip..) if s < skip
          i += 3
          next
        end
      end
      sb << c
      i += 1
    end
    sb << path[root_length - 1] if skip != root_length && sb.length < root_length
    sb.join
  end

  # ------------------------------------------------------------------------------------------- existence
  # stat(2), or lstat(2) when stat fails (a broken link): nil when nothing is there
  def self.stat(full)
    File.stat(full)
  rescue SystemCallError, ArgumentError
    begin
      File.lstat(full)
    rescue SystemCallError, ArgumentError
      nil
    end
  end

  # FileSystem.FileExists of a full path: something that is not a directory
  def self.fs_file_exists(full)
    return false if full.length > 1 && full.end_with?('/')
    st = Cpp.stat(full)
    !st.nil? && !st.directory?
  end

  def self.fs_dir_exists(full)
    st = Cpp.stat(full)
    !st.nil? && st.directory?
  end

  # System.IO.File.Exists
  def self.file_exists(path)
    return false if path.nil? || path.empty?
    f = begin
      Cpp.full_path(path)
    rescue StandardError
      return false
    end
    return false if f.end_with?('/')
    Cpp.fs_file_exists(f)
  end

  # System.IO.Directory.Exists
  def self.dir_exists(path)
    return false if path.nil? || path.empty?
    f = begin
      Cpp.full_path(path)
    rescue StandardError
      return false
    end
    Cpp.fs_dir_exists(f)
  end

  # ------------------------------------------------------------------------------------------- file operations
  # whether the directory of a full path exists (.NET tells a missing directory from a missing file)
  def self.parent_exists(full)
    k = full.rindex('/')
    Cpp.fs_dir_exists(k.nil? || k <= 0 ? '/' : full[0, k])
  end

  # FileSystem.MoveFile(fa, fb, overwrite: true) of two full paths: a directory destination is refused; rename(2),
  # or copy and delete across file systems (EXDEV). Raises SystemCallError.
  def self.move_full(fa, fb)
    raise Errno::EISDIR if Cpp.fs_dir_exists(fb)
    begin
      File.rename(fa, fb)
    rescue Errno::EXDEV
      Cpp.copy_full(fa, fb, true)
      File.unlink(fa)
    end
  end

  # File.Move(a, b, overwrite: true): only a file moves. Raises SysException: FileNotFoundException for a missing
  # source (or a missing name in an existing directory), DirectoryNotFoundException for a missing destination
  # directory, IOException otherwise.
  def self.move_file(a, b)
    fa = Cpp.full_path(a)
    fb = Cpp.full_path(b)
    raise Cpp.sys_exc('IO.FileNotFoundException', "Could not find file '#{fa}'.") unless Cpp.fs_file_exists(fa)
    begin
      Cpp.move_full(fa, fb)
    rescue Errno::ENOENT
      raise Cpp.sys_exc('IO.DirectoryNotFoundException', "Could not find a part of the path '#{fb}'.") unless Cpp.parent_exists(fb)
      raise Cpp.sys_exc('IO.FileNotFoundException', "Could not find file '#{fb}'.")
    rescue SystemCallError => e
      raise Cpp.io_exc(e)
    end
  end

  # FileSystem.CopyFile: the bytes and the permission bits; a directory source is refused. Raises SystemCallError.
  def self.copy_full(fa, fb, overwrite)
    File.open(fa, File::RDONLY | File::BINARY) do |src|
      st = src.stat
      raise Errno::EISDIR if st.directory?
      flags = File::WRONLY | File::CREAT | File::BINARY | (overwrite ? File::TRUNC : File::EXCL)
      File.open(fb, flags, st.mode & 0o7777) do |dst|
        while (chunk = src.read(1 << 20))
          dst.write(chunk)
        end
      end
    end
  end

  # File.Copy(a, b) without overwrite
  def self.copy_file(a, b)
    fa = Cpp.full_path(a)
    fb = Cpp.full_path(b)
    begin
      Cpp.copy_full(fa, fb, false)
    rescue Errno::EISDIR
      raise Cpp.sys_exc('UnauthorizedAccessException', "Access to the path '#{fa}' is denied.")
    rescue SystemCallError => e
      raise Cpp.io_exc(e)
    end
  end

  # File.Delete of a full path (a missing file is not an error)
  def self.delete_file(full)
    File.unlink(full)
  rescue Errno::ENOENT
    nil
  rescue SystemCallError => e
    raise Cpp.io_exc(e)
  end

  # Directory.Delete(path) (not recursive): rmdir(2)
  def self.delete_dir(full)
    Dir.rmdir(full)
  rescue SystemCallError => e
    raise Cpp.io_exc(e)
  end

  # Directory.CreateDirectory: the directory and its missing parents; an existing directory is fine
  def self.create_directories(path)
    f = Cpp.full_path(path)
    parts = f.split('/').reject(&:empty?)
    cur = ''
    parts.each do |x|
      cur += "/#{x}"
      next if File.directory?(cur)
      begin
        Dir.mkdir(cur)
      rescue Errno::EEXIST
        raise Cpp.io_exc(Errno::EEXIST.new) unless File.directory?(cur)
      end
    end
  rescue SystemCallError => e
    raise Cpp.io_exc(e)
  end

  # new FileInfo(path).Length: FileNotFoundException for a missing path or a directory
  def self.file_length(path)
    f = Cpp.full_path(path)
    st = f.length > 1 && f.end_with?('/') ? nil : Cpp.stat(f)
    raise Cpp.sys_exc('IO.FileNotFoundException', "Could not find file '#{f}'.") if st.nil? || st.directory?
    st.size
  end

  # FileMode / FileAccess combinations the streams open with
  O_READ = File::RDONLY
  O_CREATE = File::WRONLY | File::CREAT | File::TRUNC     # FileMode.Create, FileAccess.Write
  O_APPEND = File::WRONLY | File::CREAT                   # FileMode.Append (.NET seeks to the end itself)
  O_RW = File::RDWR | File::CREAT                         # FileMode.OpenOrCreate, FileAccess.ReadWrite

  # the FileStream constructor's open: the full path (exceptions as .NET's), a directory refused; files are created
  # with mode 0666 less the umask, as .NET creates them. Returns a binary File; raises on failure.
  def self.open_fd(path, flags)
    full = Cpp.full_path(path)
    raise Errno::EISDIR if full.length > 1 && full.end_with?('/')
    f = File.new(full, flags | File::BINARY, 0o666)
    begin
      raise Errno::EISDIR if f.stat.directory?
    rescue StandardError
      f.close
      raise
    end
    f
  end

  # A FileStream opened for reading as IStream uses it: every read asks for a whole buffer, which
  # BufferedFileStreamStrategy passes straight to pread at the position .NET keeps (FileStream.Position)
  class FileIn
    attr_accessor :pos

    def initialize(f)
      @f = f
      @pos = 0
    end

    def read(n)
      b = begin
        @f.pread(n, @pos)
      rescue EOFError
        ''.b
      rescue SystemCallError => e
        raise Cpp.io_exc(e)
      end
      @pos += b.bytesize
      b
    end

    def length = @f.size

    def seek(np)
      @pos = np
    end

    def close
      return if @f.nil?
      f = @f
      @f = nil
      f.close
    rescue StandardError
      nil
    end
  end

  # A FileStream opened for writing, with its write buffer (BufferedFileStreamStrategy over the file)
  class FileOut
    def initialize(f, size, append)
      @f = f
      @size = size
      @buf = ''.b
      if append
        @fpos = f.size
        @append_start = @fpos
      else
        @fpos = 0
        @append_start = -1
      end
    end

    def raw(data)
      pos = @fpos
      n = data.bytesize
      k = 0
      begin
        while k < n
          w = @f.pwrite(k == 0 ? data : data.byteslice(k, n - k), pos)
          pos += w
          k += w
        end
      rescue SystemCallError => e
        raise Cpp.io_exc(e)
      ensure
        @fpos = pos
      end
    end

    def flush_write
      return if @buf.empty?
      b = @buf
      @buf = ''.b
      raw(b)
    end

    # BufferedFileStreamStrategy.WriteSpan of a binary String
    def write(data)
      n = data.bytesize
      w = @buf.bytesize
      if w > 0
        room = @size - w
        if room > 0
          if room >= n
            @buf << data
            return
          end
          @buf << data.byteslice(0, room)
          data = data.byteslice(room, n - room)
          n -= room
        end
        flush_write
      end
      if n >= @size
        raw(data)
        return
      end
      return if n == 0
      @buf = data.b.dup
    end

    def position = @fpos + @buf.bytesize

    def length
      ln = @f.size
      e = @fpos + @buf.bytesize
      e > ln ? e : ln
    end

    # FileStream.Seek: the buffer flushed, then the new position (IOException before 0 or, in append mode, before
    # the end the file had when it was opened)
    def seek(off, d)
      flush_write
      np = case d
           when 0 then off
           when 2 then length + off
           else @fpos + off
           end
      raise Cpp.sys_exc('IO.IOException', SEEK_BEFORE_BEGIN) if np < 0
      raise Cpp.sys_exc('IO.IOException', SEEK_APPEND) if @append_start != -1 && np < @append_start
      @fpos = np
    end

    def flush = flush_write

    def close
      flush_write
    ensure
      unless @f.nil?
        f = @f
        @f = nil
        begin
          f.close
        rescue StandardError
          nil
        end
      end
    end
  end

  # A MemoryStream: the bytes and the position (writes overwrite, extend, and zero-fill a gap)
  class MemStream
    attr_reader :b

    def initialize
      @b = ''.b
      @pos = 0
    end

    def write(data)
      n = data.bytesize
      return if n <= 0
      ln = @b.bytesize
      if @pos == ln
        @b << data
      else
        @b << ("\0" * (@pos - ln)) if @pos > ln
        @b[@pos, n] = data
      end
      @pos += n
    end

    def to_array = @b.dup

    def seek(off, d)
      np = case d
           when 0 then off
           when 1 then @pos + off
           else @b.bytesize + off
           end
      raise Cpp.sys_exc('IO.IOException', SEEK_BEFORE_BEGIN) if np < 0
      if np > 0x7FFFFFFF
        raise Cpp.sys_exc('ArgumentOutOfRangeException',
                          "Stream length must be non-negative and less than 2^31 - 1 - origin. (Parameter 'offset')")
      end
      @pos = np
    end
  end

  # ------------------------------------------------------------------------------------------- FsPath
  def self.pb(p) = p.p.b[0, p.p.n].pack('C*')

  def self.mkpath(data)
    f = FsPath.new
    f.p = Cpp.str_of(data)
    f
  end

  # std::filesystem::path (Cpp.FsPath). FsPath.new is the raw object; the constructors are NewFsPath*.
  class FsPath
    include ICopy
    attr_accessor :p

    def Clone
      f = FsPath.new
      f.p = @p.Clone
      f
    end

    def clear = (@p = Cpp.str_of(''))
    def Assign_FsPath(o) = (@p = o.p.Clone)
    alias Assign Assign_FsPath
    def Assign_Str(s) = (@p = s.Clone)

    def MoveFrom(o)
      @p = o.p
      o.p = Cpp.str_of('')
    end

    def CompareTo(o) = Cpp.path_compare(@p, o.p)
    def compare(o) = Cpp.path_compare(@p, o.p)
    def ToString = Cpp.latin1_str(Cpp.pb(self))
    def string = @p.Clone
    def generic_string = @p.Clone
    def native = @p.Clone
    def c_str = @p.c_str
    def u8string = @p.Clone
    def empty = @p.n == 0
    def is_absolute = @p.n > 0 && @p.b[0] == 47
    def is_relative = !is_absolute
    def has_filename = filename.p.n > 0
    def has_parent_path = parent_path.p.n > 0
    def has_extension = extension.p.n > 0

    # the last element (libstdc++: the part after the last '/'; "" when the path ends in '/')
    def filename
      s = Cpp.pb(self)
      i = s.rindex('/')
      Cpp.mkpath(i.nil? ? s : s.byteslice(i + 1, s.bytesize))
    end

    def parent_path
      s = Cpp.pb(self)
      i = s.rindex('/')
      return Cpp.mkpath('') if i.nil?
      return Cpp.mkpath('/') if i == 0
      j = i
      j -= 1 while j > 0 && s.getbyte(j - 1) == 47
      Cpp.mkpath(s.byteslice(0, j == 0 ? 1 : j))
    end

    def stem
      f = Cpp.pb(filename)
      return Cpp.mkpath(f) if f == '.' || f == '..'
      i = f.rindex('.')
      Cpp.mkpath(i.nil? || i <= 0 ? f : f.byteslice(0, i))
    end

    def extension
      f = Cpp.pb(filename)
      return Cpp.mkpath('') if f == '.' || f == '..'
      i = f.rindex('.')
      Cpp.mkpath(i.nil? || i <= 0 ? '' : f.byteslice(i, f.bytesize))
    end

    # replace_extension(ext): the extension removed, then ext added (with a '.' in front unless it has one); a nil
    # or empty ext only removes
    def replace_extension_FsPath(ext = nil)
      e = Cpp.pb(extension)
      a = Cpp.pb(self)
      s = a.byteslice(0, a.bytesize - e.bytesize)
      s += (ext.p.b[0] == 46 ? '' : '.') + Cpp.pb(ext) if !ext.nil? && ext.p.n > 0
      @p = Cpp.str_of(s)
      self
    end
    alias replace_extension replace_extension_FsPath

    def replace_extension_Str(ext) = replace_extension_FsPath(NewFsPath_Str(ext))

    def replace_filename(f)
      @p = parent_path.Join_FsPath(f).p
      self
    end

    def remove_filename
      s = Cpp.pb(self)
      i = s.rindex('/')
      @p = Cpp.str_of(i.nil? ? '' : s.byteslice(0, i + 1))
      self
    end

    # operator/ : an absolute right side replaces the path; otherwise a separator is added
    def Join_FsPath(o)
      return o.Clone if o.is_absolute
      s = Cpp.pb(self)
      return o.Clone if s.empty?
      s += '/' if !s.end_with?('/') && o.p.n > 0
      Cpp.mkpath(s + Cpp.pb(o))
    end

    def Join_Str(o) = Join_FsPath(NewFsPath_Str(o))
    def Join_CPtr(o) = Join_FsPath(NewFsPath_CPtr(o))

    # empty and "." elements dropped, ".." taking the element before it away (dropped at the root), a trailing '/'
    # kept, "." for an empty result
    def lexically_normal
      s = Cpp.pb(self)
      return Cpp.mkpath('') if s.empty?
      ab = s.start_with?('/')
      parts = []
      s.split('/').each do |x|
        next if x.empty? || x == '.'
        if x == '..' && !parts.empty? && parts[-1] != '..'
          parts.pop
          next
        end
        next if x == '..' && ab
        parts << x
      end
      r = (ab ? '/' : '') + parts.join('/')
      r += '/' if s.end_with?('/') && !parts.empty?
      r = '.' if r.empty?
      Cpp.mkpath(r)
    end
  end

  # path::compare as the C# port has it: Str.compare (unsigned bytes, then length)
  def self.path_compare(a, b)
    x = a.b[0, a.n]
    y = b.b[0, b.n]
    m = [x.length, y.length].min
    m.times { |i| return x[i] < y[i] ? -1 : 1 if x[i] != y[i] }
    x.length - y.length
  end

  def NewFsPath = Cpp.mkpath('')
  def NewFsPath_Str(s) = FsPath.new.tap { |f| f.p = s.Clone }
  def NewFsPath_CPtr(s) = Cpp.mkpath(Cpp.cbs(s))
  def NewFsPath_str(s) = Cpp.mkpath(Cpp.latin1_bytes(s))

  # ------------------------------------------------------------------------------------------- FileStatus
  # std::filesystem::file_status as far as the engine asks: not found (-1), a regular file (1) or a directory (2)
  # (File.Exists, then Directory.Exists, as .NET sees them: links followed)
  class FileStatus
    attr_accessor :kind

    def initialize(k = 0)
      @kind = k
    end

    def type = @kind
    def Clone = FileStatus.new(@kind)
  end

  def NewFileStatus = FileStatus.new
  def FileStatus_Of(s) = FileStatus.new(Cpp.file_exists(s) ? 1 : (Cpp.dir_exists(s) ? 2 : -1))

  # ------------------------------------------------------------------------------------------- Cpp.Fs
  def self.ps(p) = Cpp.latin1_str(Cpp.pb(p))

  def Fs_exists_FsPath(p) = Cpp.file_exists(Cpp.ps(p)) || Cpp.dir_exists(Cpp.ps(p))
  def Fs_exists_FsPath_ErrorCode(p, _ec) = Fs_exists_FsPath(p)
  def Fs_is_regular_file_FsPath(p) = Cpp.file_exists(Cpp.ps(p))
  def Fs_is_directory_FsPath(p) = Cpp.dir_exists(Cpp.ps(p))

  # new FileInfo(p).Length: a missing file or a directory throws (FileNotFoundException)
  def Fs_file_size_FsPath(p) = Cpp.file_length(Cpp.ps(p))

  # file_size(p, ec): libstdc++ sets ENOENT for a missing file, EISDIR for a directory and returns
  # static_cast<uintmax_t>(-1) on error
  def Fs_file_size_FsPath_ErrorCode(p, ec)
    s = Cpp.ps(p)
    if Cpp.file_exists(s)
      ec.v = 0
      return Cpp.file_length(s)
    end
    ec.v = Cpp.dir_exists(s) ? 21 : 2
    M64
  end

  # removes a file (not a directory); reports whether one was removed
  def Fs_remove_FsPath(p)
    s = Cpp.ps(p)
    if Cpp.file_exists(s)
      Cpp.delete_file(Cpp.full_path(s))
      return true
    end
    false
  rescue StandardError
    false
  end

  # Directory.CreateDirectory: true unless it fails (an existing directory is fine)
  def Fs_create_directories_FsPath(p)
    Cpp.create_directories(Cpp.ps(p))
    true
  rescue StandardError
    false
  end

  def Fs_current_path = NewFsPath_str(Cpp.cwd)
  def Fs_absolute(p) = p.is_absolute ? p.Clone : Fs_current_path().Join_FsPath(p)
  def Fs_canonical_FsPath(p) = NewFsPath_str(Cpp.full_path(Cpp.ps(p)))
  def Fs_weakly_canonical_FsPath(p) = NewFsPath_str(Cpp.full_path(Cpp.ps(p)))

  # $TMPDIR, or /tmp when it is not set
  def Fs_temp_directory_path = NewFsPath_str(Cpp.net_environ.fetch('TMPDIR', '/tmp'))

  # File.Move(a, b, true), which throws when it fails
  def Fs_rename_FsPath_FsPath(a, b) = Cpp.move_file(Cpp.ps(a), Cpp.ps(b))
  def Fs_equivalent_FsPath_FsPath(a, b) = Cpp.full_path(Cpp.ps(a)) == Cpp.full_path(Cpp.ps(b))

  def Fs_equivalent_FsPath_FsPath_ErrorCode(a, b, ec)
    unless Fs_exists_FsPath(a) && Fs_exists_FsPath(b)
      ec.v = 2
      return false
    end
    ec.v = 0
    Fs_equivalent_FsPath_FsPath(a, b)
  end

  # remove(p, ec): a file or an empty directory (EACCES = 13 when that fails)
  def Fs_remove_FsPath_ErrorCode(p, ec)
    ec.v = 0
    s = Cpp.ps(p)
    begin
      if Cpp.file_exists(s)
        Cpp.delete_file(Cpp.full_path(s))
        return true
      end
      if Cpp.dir_exists(s)
        Cpp.delete_dir(Cpp.full_path(s))
        return true
      end
    rescue StandardError
      ec.v = 13
    end
    false
  end

  # rename(a, b, ec): File.Move(a, b, true); FileNotFoundException gives ENOENT (2), anything else EACCES (13)
  def Fs_rename_FsPath_FsPath_ErrorCode(a, b, ec)
    begin
      fa = Cpp.full_path(Cpp.ps(a))
      fb = Cpp.full_path(Cpp.ps(b))
    rescue StandardError
      ec.v = 13
      return
    end
    unless Cpp.fs_file_exists(fa)
      ec.v = 2
      return
    end
    begin
      Cpp.move_full(fa, fb)
      ec.v = 0
    rescue Errno::ENOENT
      ec.v = Cpp.parent_exists(fb) ? 2 : 13
    rescue StandardError
      ec.v = 13
    end
  end

  # the C# port's create_hard_link(target, link, ec): EEXIST (17) when link exists, otherwise a copy of target at
  # link (ENOENT when that fails)
  def Fs_create_hard_link(target, link, ec)
    if Cpp.file_exists(Cpp.ps(link))
      ec.v = 17
      return
    end
    begin
      Cpp.copy_file(Cpp.ps(target), Cpp.ps(link))
      ec.v = 0
    rescue StandardError
      ec.v = 2
    end
  end

  def Fs_weakly_canonical_FsPath_ErrorCode(p, ec)
    ec.v = 0
    Fs_weakly_canonical_FsPath(p)
  end

  def Fs_canonical_FsPath_ErrorCode(p, ec)
    unless Fs_exists_FsPath(p)
      ec.v = 2
      return NewFsPath()
    end
    ec.v = 0
    Fs_canonical_FsPath(p)
  end

  def Fs_status_FsPath(p) = FileStatus_Of(Cpp.ps(p))
  def Fs_status_FsPath_ErrorCode(p, ec) = (ec.v = 0; FileStatus_Of(Cpp.ps(p)))
  def Fs_symlink_status_FsPath(p) = FileStatus_Of(Cpp.ps(p))
  def Fs_symlink_status_FsPath_ErrorCode(p, ec) = (ec.v = 0; FileStatus_Of(Cpp.ps(p)))
  def Fs_exists_FileStatus(s) = s.kind != -1
  def Fs_is_regular_file_FileStatus(s) = s.kind == 1
  def Fs_is_directory_FileStatus(s) = s.kind == 2
  def Fs_is_symlink(_s) = false
  def Fs_create_directories_FsPath_ErrorCode(p, ec) = (ec.v = 0; Fs_create_directories_FsPath(p))

  # System.IO.File.Exists(string): the engine passes a C# string (a Ruby String) or a Str's text
  def File_Exists(path)
    s = path.is_a?(String) ? path : path.ToString
    s = Cpp.latin1_str(s) if s.encoding == Encoding::BINARY
    Cpp.file_exists(s)
  end
end
