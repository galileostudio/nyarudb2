import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

private func systemClose(_ fd: Int32) -> Int32 {
  #if canImport(Darwin)
    return Darwin.close(fd)
  #else
    return Glibc.close(fd)
  #endif
}

/// A thin wrapper over a POSIX file descriptor using positioned I/O.
///
/// `pread`/`pwrite` perform a positioned access in a single syscall, where
/// `FileHandle` needs a `seek` plus the access — two syscalls and
/// Objective-C dispatch per operation. All shard-file I/O routes through
/// this type.
///
/// **Thread safety.** Positioned I/O carries no shared cursor, but `RawFile`
/// is still owned by a single `SlottedFile` (itself owned by one
/// `ShardActor`), so access is serialised by the actor.
final class RawFile {
  private let fd: Int32
  private var isOpen = true

  /// Opens an existing file.
  ///
  /// - Parameters:
  ///   - path: The filesystem path.
  ///   - readOnly: Open for reading only (default read-write).
  /// - Throws: `NyaruError.ioError` if the file cannot be opened.
  init(path: String, readOnly: Bool = false) throws {
    fd = open(path, readOnly ? O_RDONLY : O_RDWR)
    guard fd >= 0 else {
      throw NyaruError.ioError("open(\(path)) failed: \(String(cString: strerror(errno)))")
    }
  }

  deinit {
    if isOpen { _ = systemClose(fd) }
  }

  /// Reads up to `count` bytes starting at `offset` in one syscall.
  ///
  /// - Returns: The bytes read — shorter than `count` at end of file.
  /// - Throws: `NyaruError.ioError` on a read failure.
  func read(count: Int, at offset: UInt64) throws -> Data {
    guard count > 0 else { return Data() }
    var data = Data(count: count)
    let total = try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Int in
      var total = 0
      while total < count {
        let n = pread(fd, buffer.baseAddress! + total, count - total, off_t(offset) + off_t(total))
        if n == 0 { break }  // EOF
        if n < 0 {
          if errno == EINTR { continue }
          throw NyaruError.ioError("pread failed: \(String(cString: strerror(errno)))")
        }
        total += n
      }
      return total
    }
    if total < count { data.removeSubrange(total..<count) }
    return data
  }

  /// Writes all of `data` starting at `offset`.
  ///
  /// - Throws: `NyaruError.ioError` on a write failure.
  func write(_ data: Data, at offset: UInt64) throws {
    guard !data.isEmpty else { return }
    try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
      var total = 0
      while total < buffer.count {
        let n = pwrite(
          fd, buffer.baseAddress! + total, buffer.count - total, off_t(offset) + off_t(total))
        if n < 0 {
          if errno == EINTR { continue }
          throw NyaruError.ioError("pwrite failed: \(String(cString: strerror(errno)))")
        }
        total += n
      }
    }
  }

  /// Returns the current file size in bytes.
  func size() throws -> UInt64 {
    var info = stat()
    guard fstat(fd, &info) == 0 else {
      throw NyaruError.ioError("fstat failed: \(String(cString: strerror(errno)))")
    }
    return UInt64(info.st_size)
  }

  /// Truncates (or extends) the file to the given size.
  func truncate(to size: UInt64) throws {
    guard ftruncate(fd, off_t(size)) == 0 else {
      throw NyaruError.ioError("ftruncate failed: \(String(cString: strerror(errno)))")
    }
  }

  /// Flushes kernel buffers for this file to disk (fsync).
  func sync() throws {
    guard fsync(fd) == 0 else {
      throw NyaruError.ioError("fsync failed: \(String(cString: strerror(errno)))")
    }
  }

  /// Closes the descriptor. Safe to call once; further I/O is invalid.
  func close() throws {
    guard isOpen else { return }
    isOpen = false
    guard systemClose(fd) == 0 else {
      throw NyaruError.ioError("close failed: \(String(cString: strerror(errno)))")
    }
  }
}
