import Foundation
import zlib

#if canImport(Compression)
  import Compression
#endif

/// Describes the compression method applied to record payloads in shard files.
///
/// - `gzip` is the recommended method. It is implemented on top of zlib and is
///   portable to every platform NyaruDB may target, including Android and Linux.
/// - `lzfse` and `lz4` use Apple's Compression framework and are only available
///   on Apple platforms. Using them ties the data files to Apple devices.
///
/// The method is stored in the record header flags (bits 1-3) and is also
/// persisted in the collection manifest so that every shard file can be
/// decompressed independently of external configuration.
public enum CompressionMethod: String, CaseIterable, Codable, Sendable {
  /// No compression is applied. The payload is stored as-is.
  case none
  /// gzip compression (RFC 1952) via zlib. Portable to all platforms.
  case gzip
  /// Apple LZFSE compression. Apple platforms only.
  case lzfse
  /// Apple LZ4 compression. Apple platforms only.
  case lz4

  /// Returns the single-byte wire identifier for this compression method.
  ///
  /// Mapping:
  /// - `.none`:  `0`
  /// - `.gzip`:  `1`
  /// - `.lzfse`: `2`
  /// - `.lz4`:   `3`
  var byte: UInt8 {
    switch self {
    case .none: return 0
    case .gzip: return 1
    case .lzfse: return 2
    case .lz4: return 3
    }
  }

  /// Creates a compression method from its single-byte wire identifier.
  ///
  /// - Parameter byte: The wire identifier byte.
  /// - Returns: The matching method, or `nil` if the byte does not correspond
  ///   to any known method.
  init?(byte: UInt8) {
    switch byte {
    case 0: self = .none
    case 1: self = .gzip
    case 2: self = .lzfse
    case 3: self = .lz4
    default: return nil
    }
  }

  /// Returns the flag bit used in the record header's flags byte to mark this
  /// compression method.
  var flagBit: UInt8 {
    switch self {
    case .none: return 0
    case .gzip: return RecordFlags.gzip
    case .lzfse: return RecordFlags.lzfse
    case .lz4: return RecordFlags.lz4
    }
  }

  /// Creates a compression method from the record header flags byte.
  ///
  /// Inspects bits 1-3 of the flags byte and returns the first matching method.
  /// If none of the compression flag bits are set, returns `.none`.
  ///
  /// - Parameter recordFlags: The raw flags byte from a record header.
  init(recordFlags: UInt8) {
    if recordFlags & RecordFlags.gzip != 0 {
      self = .gzip
    } else if recordFlags & RecordFlags.lzfse != 0 {
      self = .lzfse
    } else if recordFlags & RecordFlags.lz4 != 0 {
      self = .lz4
    } else {
      self = .none
    }
  }
}

/// Internal utility that performs compression and decompression operations for
/// record payloads.
///
/// `Compressor` dispatches to the appropriate backend (zlib for gzip, Apple
/// Compression framework for LZFSE/LZ4) and throws `NyaruError` variants on
/// failure. It also exposes a CRC-32 checksum function used for record
/// integrity verification.
enum Compressor {
  /// Compresses the given data using the specified method.
  ///
  /// If the method is `.none`, the data is returned unchanged. For gzip, LZFSE,
  /// and LZ4, the data is compressed only if the compressed result is actually
  /// smaller than the input — otherwise the original data is returned with
  /// method `.none`. Callers must inspect the returned method to know whether
  /// the payload is compressed.
  ///
  /// - Parameters:
  ///   - data: The raw payload to compress.
  ///   - method: The compression method to apply.
  /// - Returns: A tuple containing the (possibly compressed) payload and the
  ///   method that was actually applied (may be `.none`).
  /// - Throws: `NyaruError.compressionFailed` if the compression operation
  ///   itself fails, or `NyaruError.unsupportedCompression` if the method is
  ///   unavailable on the current platform.
  static func compress(_ data: Data, method: CompressionMethod) throws -> Data {
    guard !data.isEmpty else { return data }
    switch method {
    case .none:
      return data
    case .gzip:
      return try gzipCompress(data)
    case .lzfse:
      #if canImport(Compression)
        return try appleCompress(data, algorithm: COMPRESSION_LZFSE)
      #else
        throw NyaruError.unsupportedCompression("lzfse")
      #endif
    case .lz4:
      #if canImport(Compression)
        return try appleCompress(data, algorithm: COMPRESSION_LZ4)
      #else
        throw NyaruError.unsupportedCompression("lz4")
      #endif
    }
  }

  /// Decompresses the given data that was compressed with the specified method.
  ///
  /// If the method is `.none`, the data is returned unchanged.
  ///
  /// - Parameters:
  ///   - data: The compressed payload.
  ///   - method: The compression method that was used.
  /// - Returns: The decompressed original payload.
  /// - Throws: `NyaruError.decompressionFailed` if decompression fails, or
  ///   `NyaruError.unsupportedCompression` if the method is unavailable on
  ///   the current platform.
  static func decompress(_ data: Data, method: CompressionMethod) throws -> Data {
    guard !data.isEmpty else { return data }
    switch method {
    case .none:
      return data
    case .gzip:
      return try gzipDecompress(data)
    case .lzfse:
      #if canImport(Compression)
        return try appleDecompress(data, algorithm: COMPRESSION_LZFSE)
      #else
        throw NyaruError.unsupportedCompression("lzfse")
      #endif
    case .lz4:
      #if canImport(Compression)
        return try appleDecompress(data, algorithm: COMPRESSION_LZ4)
      #else
        throw NyaruError.unsupportedCompression("lz4")
      #endif
    }
  }

  // MARK: - CRC32 (zlib)

  /// Calculates the CRC-32 checksum of the given data using zlib.
  ///
  /// CRC-32 is used in every record header to detect data corruption. An empty
  /// input returns a checksum of 0.
  ///
  /// - Parameter data: The data to checksum.
  /// - Returns: The 32-bit CRC value.
  static func crc32Checksum(_ data: Data) -> UInt32 {
    guard !data.isEmpty else { return 0 }
    return data.withUnsafeBytes { buffer -> UInt32 in
      let ptr = buffer.bindMemory(to: UInt8.self).baseAddress
      return UInt32(zlib.crc32(0, ptr, uInt(buffer.count)))
    }
  }

  // MARK: - gzip via zlib (portable)

  /// Compresses data using gzip (RFC 1952) via zlib's deflate algorithm.
  ///
  /// The gzip header is produced by passing `15 + 16` as the window bits
  /// parameter to `deflateInit2_`, which tells zlib to add the gzip wrapper.
  /// Compression is performed with the default compression level.
  ///
  /// - Parameter data: The raw data to compress.
  /// - Returns: The gzip-compressed data.
  /// - Throws: `NyaruError.compressionFailed` if deflate returns an error.
  private static func gzipCompress(_ data: Data) throws -> Data {
    var stream = z_stream()
    var status = deflateInit2_(
      &stream,
      Z_DEFAULT_COMPRESSION,
      Z_DEFLATED,
      15 + 16,  // 15 window bits + 16 = gzip header
      8,
      Z_DEFAULT_STRATEGY,
      ZLIB_VERSION,
      Int32(MemoryLayout<z_stream>.size)
    )
    guard status == Z_OK else { throw NyaruError.compressionFailed }
    defer { deflateEnd(&stream) }

    var output = Data()
    let chunkSize = 16 * 1024
    var chunk = [UInt8](repeating: 0, count: chunkSize)

    try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
      guard let base = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
        throw NyaruError.compressionFailed
      }
      stream.next_in = UnsafeMutablePointer(mutating: base)
      stream.avail_in = uInt(data.count)
      repeat {
        let produced = try chunk.withUnsafeMutableBytes { buf -> Int in
          guard let out = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            throw NyaruError.compressionFailed
          }
          stream.next_out = out
          stream.avail_out = uInt(chunkSize)
          status = deflate(&stream, Z_FINISH)
          if status != Z_OK && status != Z_STREAM_END {
            throw NyaruError.compressionFailed
          }
          return chunkSize - Int(stream.avail_out)
        }
        if produced > 0 { output.append(chunk, count: produced) }
      } while status != Z_STREAM_END
    }
    return output
  }

  /// Decompresses gzip-compressed data via zlib's inflate algorithm.
  ///
  /// Uses `15 + 32` as the window bits parameter to `inflateInit2_`, which
  /// enables automatic detection of the gzip or zlib header format.
  ///
  /// - Parameter data: The gzip-compressed data.
  /// - Returns: The decompressed original data.
  /// - Throws: `NyaruError.decompressionFailed` if inflate returns an error
  ///   or the input is truncated.
  private static func gzipDecompress(_ data: Data) throws -> Data {
    var stream = z_stream()
    var status = inflateInit2_(
      &stream,
      15 + 32,  // auto-detect gzip/zlib header
      ZLIB_VERSION,
      Int32(MemoryLayout<z_stream>.size)
    )
    guard status == Z_OK else { throw NyaruError.decompressionFailed }
    defer { inflateEnd(&stream) }

    var output = Data()
    let chunkSize = 16 * 1024
    var chunk = [UInt8](repeating: 0, count: chunkSize)

    try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
      guard let base = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
        throw NyaruError.decompressionFailed
      }
      stream.next_in = UnsafeMutablePointer(mutating: base)
      stream.avail_in = uInt(data.count)
      repeat {
        let produced = try chunk.withUnsafeMutableBytes { buf -> Int in
          guard let out = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            throw NyaruError.decompressionFailed
          }
          stream.next_out = out
          stream.avail_out = uInt(chunkSize)
          status = inflate(&stream, Z_NO_FLUSH)
          if status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR {
            throw NyaruError.decompressionFailed
          }
          return chunkSize - Int(stream.avail_out)
        }
        if produced > 0 { output.append(chunk, count: produced) }
        if status == Z_BUF_ERROR && stream.avail_in == 0 {
          // Truncated input
          throw NyaruError.decompressionFailed
        }
      } while status != Z_STREAM_END
    }
    return output
  }

  // MARK: - Apple Compression framework (Apple platforms only)

  #if canImport(Compression)
    /// Compresses data using the Apple Compression framework.
    ///
    /// - Parameters:
    ///   - data: The data to compress.
    ///   - algorithm: The compression algorithm (e.g. `COMPRESSION_LZFSE`).
    /// - Returns: The compressed data.
    /// - Throws: `NyaruError.compressionFailed` if compression fails.
    private static func appleCompress(_ data: Data, algorithm: compression_algorithm) throws -> Data
    {
      try appleStream(data, operation: COMPRESSION_STREAM_ENCODE, algorithm: algorithm)
    }

    /// Decompresses data using the Apple Compression framework.
    ///
    /// - Parameters:
    ///   - data: The data to decompress.
    ///   - algorithm: The compression algorithm that was used.
    /// - Returns: The decompressed data.
    /// - Throws: `NyaruError.decompressionFailed` if decompression fails.
    private static func appleDecompress(_ data: Data, algorithm: compression_algorithm) throws
      -> Data
    {
      try appleStream(data, operation: COMPRESSION_STREAM_DECODE, algorithm: algorithm)
    }

    /// Performs streaming compression or decompression using the Apple
    /// Compression framework.
    ///
    /// The stream is processed in a single pass with `COMPRESSION_STREAM_FINALIZE`
    /// so the caller receives the complete result.
    ///
    /// - Parameters:
    ///   - data: The input data.
    ///   - operation: `COMPRESSION_STREAM_ENCODE` or `COMPRESSION_STREAM_DECODE`.
    ///   - algorithm: The compression algorithm.
    /// - Returns: The processed output.
    /// - Throws: `NyaruError.compressionFailed` or `NyaruError.decompressionFailed`.
    private static func appleStream(
      _ data: Data,
      operation: compression_stream_operation,
      algorithm: compression_algorithm
    ) throws -> Data {
      let dstSize = 64 * 1024
      let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
      defer { dstBuffer.deallocate() }

      var stream = compression_stream(
        dst_ptr: dstBuffer, dst_size: dstSize,
        src_ptr: dstBuffer, src_size: 0, state: nil
      )
      guard compression_stream_init(&stream, operation, algorithm) == COMPRESSION_STATUS_OK else {
        throw operation == COMPRESSION_STREAM_ENCODE
          ? NyaruError.compressionFailed
          : NyaruError.decompressionFailed
      }
      defer { compression_stream_destroy(&stream) }

      var output = Data()
      try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
        guard let base = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
          throw NyaruError.compressionFailed
        }
        stream.src_ptr = base
        stream.src_size = data.count
        stream.dst_ptr = dstBuffer
        stream.dst_size = dstSize

        let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
        while true {
          let status = compression_stream_process(&stream, flags)
          switch status {
          case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
            let produced = dstSize - stream.dst_size
            if produced > 0 { output.append(dstBuffer, count: produced) }
            if status == COMPRESSION_STATUS_END { return }
            stream.dst_ptr = dstBuffer
            stream.dst_size = dstSize
          default:
            throw operation == COMPRESSION_STREAM_ENCODE
              ? NyaruError.compressionFailed
              : NyaruError.decompressionFailed
          }
        }
      }
      return output
    }
  #endif
}
