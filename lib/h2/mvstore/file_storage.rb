# frozen_string_literal: true

require "fcntl"
require "rbconfig"

module H2
  module MVStore
    class FileStorage
      OFD_SETLK = 37
      attr_reader :path, :read_only

      def initialize(path, read_only:)
        @path = File.expand_path(path)
        @read_only = read_only
        unless RbConfig::CONFIG["host_os"].include?("linux") && ["x86_64", "aarch64"].include?(RbConfig::CONFIG["host_cpu"])
          raise Error.new(5, "File-backed MVStore currently requires 64-bit Linux OFD locks")
        end
        @file = File.open(@path, read_only ? File::RDONLY : File::RDWR | File::CREAT, 0o600)
        @file.binmode
        lock = [read_only ? Fcntl::F_RDLCK : Fcntl::F_WRLCK, IO::SEEK_SET, 0, 0, 0].pack("s!s!x4q!q!i!x4")
        @file.fcntl(OFD_SETLK, lock)
      rescue Errno::EAGAIN, Errno::EACCES => error
        @file&.close
        raise Error.new(7, "File is locked: #{error.message}")
      rescue Error
        @file&.close
        raise
      rescue SystemCallError, IOError => error
        @file&.close
        raise Error.new(read_only ? 1 : 2, "Cannot open MVStore: #{error.message}")
      end

      def size
        @file.stat.size
      end

      def read_at(offset, length)
        raise Error.new(6, "Read outside file boundaries") if offset.negative? || length.negative? || offset + length > size

        data = @file.pread(length, offset)
        raise Error.new(6, "Truncated file read") unless data.bytesize == length

        data
      rescue SystemCallError, IOError => error
        raise Error.new(1, "MVStore read failed: #{error.message}")
      end

      def write_at(offset, bytes)
        raise Error.new(2, "MVStore is read-only") if read_only

        written = 0
        while written < bytes.bytesize
          count = @file.pwrite(bytes.byteslice(written..), offset + written)
          raise Error.new(2, "No progress writing MVStore") unless count.positive?

          written += count
        end
      rescue SystemCallError, IOError => error
        raise Error.new(2, "MVStore write failed: #{error.message}")
      end

      def sync
        @file.fsync
      rescue SystemCallError, IOError => error
        raise Error.new(2, "MVStore sync failed: #{error.message}")
      end

      def sync_parent
        File.open(File.dirname(path), File::RDONLY) { it.fsync }
      rescue SystemCallError, IOError => error
        raise Error.new(2, "MVStore directory sync failed: #{error.message}")
      end

      def close
        @file.close unless @file.closed?
      end
    end
  end
end
