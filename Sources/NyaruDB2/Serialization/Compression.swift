import Foundation
import zlib

#if canImport(Compression)
  import Compression
#endif

/// Payload compression method.
///
/// `gzip` is the recommended method: it is implemented on top of zlib and is
/// portable to every platform NyaruDB may target (including Android).
/// `lzfse`/`lz4` use Apple's Compression framework and are only available on
/// Apple platforms; using them ties the data files to Apple devices.
public enum CompressionMethod: String, CaseIterable, Codable, Sendable {
  case none
  case gzip
  case lzfse
  case lz4

  var flagBit: UInt8 {
    switch self {
    case .none: return 0
    case .gzip: return RecordFlags.gzip
    case .lzfse: return RecordFlags.lzfse
    case .lz4: return RecordFlags.lz4
    }
  }

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

enum Compressor {
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

  static func crc32Checksum(_ data: Data) -> UInt32 {
    guard !data.isEmpty else { return 0 }
    return data.withUnsafeBytes { buffer -> UInt32 in
      let ptr = buffer.bindMemory(to: UInt8.self).baseAddress
      return UInt32(zlib.crc32(0, ptr, uInt(buffer.count)))
    }
  }

  // MARK: - gzip via zlib (portable)

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
    private static func appleCompress(_ data: Data, algorithm: compression_algorithm) throws -> Data
    {
      try appleStream(data, operation: COMPRESSION_STREAM_ENCODE, algorithm: algorithm)
    }

    private static func appleDecompress(_ data: Data, algorithm: compression_algorithm) throws
      -> Data
    {
      try appleStream(data, operation: COMPRESSION_STREAM_DECODE, algorithm: algorithm)
    }

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
