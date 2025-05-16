#if canImport(Compression)
import Compression
#endif
import Foundation
import zlib

/// An enumeration representing the available compression methods for data storage or transmission.
/// 
/// - `none`: No compression is applied.
/// - `gzip`: Uses the Gzip compression algorithm.
/// - `lzfse`: Uses the LZFSE compression algorithm, optimized for speed and compression ratio.
/// - `lz4`: Uses the LZ4 compression algorithm, optimized for very fast compression and decompression.
///
/// This enum conforms to `String`, `CaseIterable`, and `Codable` protocols, allowing it to be
/// represented as a string, iterated over all cases, and encoded/decoded.
public enum CompressionMethod: String, CaseIterable, Codable {
    case none
    case gzip
    case lzfse
    case lz4
}

/// An enumeration representing errors that can occur during compression or decompression operations.
///
/// - `compressionFailed`: Indicates that the compression process failed.
/// - `decompressionFailed`: Indicates that the decompression process failed.
/// - `unsupportedMethod`: Indicates that the specified compression method is not supported.
/// - `zlibError(code: Int)`: Represents an error returned by the zlib library, with an associated error code.
public enum CompressionError: Error {
    case compressionFailed
    case decompressionFailed
    case unsupportedMethod
    case zlibError(code: Int)
}

/// Compresses the given data using the specified compression method.
///
/// - Parameters:
///   - data: The data to be compressed.
///   - method: The compression method to use.
/// - Throws: An error if the compression process fails.
/// - Returns: The compressed data.
public func compressData(_ data: Data, method: CompressionMethod) throws -> Data
{
    guard !data.isEmpty else { return data }
    switch method {
    case .none:
        return data
    case .gzip:
        return try gzipCompress(data: data)
    case .lzfse:
        return try compress(data: data, algorithm: COMPRESSION_LZFSE)
    case .lz4:
        return try compress(data: data, algorithm: COMPRESSION_LZ4)
    }
}

/// Decompresses the given data using the specified compression method.
///
/// - Parameters:
///   - data: The compressed data to be decompressed.
///   - method: The compression method used to compress the data.
/// - Returns: The decompressed data.
/// - Throws: An error if the decompression process fails.
public func decompressData(_ data: Data, method: CompressionMethod) throws
    -> Data
{
    guard !data.isEmpty else { return data }
    switch method {
    case .none:
        return data
    case .gzip:
        return try gzipDecompress(data: data)
    case .lzfse:
        return try decompress(data: data, algorithm: COMPRESSION_LZFSE)
    case .lz4:
        return try decompress(data: data, algorithm: COMPRESSION_LZ4)
    }
}


/// Compresses the given data using the specified compression algorithm.
///
/// - Parameters:
///   - data: The data to be compressed.
///   - algorithm: The compression algorithm to use.
/// - Returns: A `Data` object containing the compressed data.
/// - Throws: An error if the compression process fails.
private func compress(data: Data, algorithm: compression_algorithm) throws
    -> Data
{
    let dstBufferSize = data.count + (data.count / 10) + 100
    let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(
        capacity: dstBufferSize
    )
    defer { destinationBuffer.deallocate() }

    var stream = compression_stream(
        dst_ptr: destinationBuffer,
        dst_size: dstBufferSize,
        src_ptr: (data as NSData).bytes.bindMemory(
            to: UInt8.self,
            capacity: data.count
        ),
        src_size: data.count,
        state: nil
    )

    // Inicializa o stream para codificação (compressão)
    let statusInit = compression_stream_init(
        &stream,
        COMPRESSION_STREAM_ENCODE,
        algorithm
    )
    guard statusInit == COMPRESSION_STATUS_OK else {
        throw CompressionError.compressionFailed
    }
    defer { compression_stream_destroy(&stream) }

    var outputData = Data()
    // Usa withUnsafeBytes para acessar os dados de forma segura
    try data.withUnsafeBytes { (srcPointer: UnsafeRawBufferPointer) in
        guard
            let baseAddress = srcPointer.baseAddress?.assumingMemoryBound(
                to: UInt8.self
            )
        else {
            throw CompressionError.compressionFailed
        }

        stream.src_ptr = baseAddress
        stream.src_size = data.count
        stream.dst_ptr = destinationBuffer
        stream.dst_size = dstBufferSize

        while true {
            let flag = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            let status = compression_stream_process(&stream, flag)
            switch status {
            case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                // Calcula quantos bytes foram escritos no buffer
                let count = dstBufferSize - stream.dst_size
                if count > 0 {
                    outputData.append(destinationBuffer, count: count)
                }
                if status == COMPRESSION_STATUS_END {
                    return
                }
                // Reseta o buffer de destino para a próxima rodada
                stream.dst_ptr = destinationBuffer
                stream.dst_size = dstBufferSize
            default:
                throw CompressionError.compressionFailed
            }
        }
    }
    return outputData
}

/// Decompresses the given data using the specified compression algorithm.
///
/// - Parameters:
///   - data: The compressed data to be decompressed.
///   - algorithm: The compression algorithm to use for decompression.
/// - Returns: The decompressed data.
/// - Throws: An error if the decompression process fails.
private func decompress(data: Data, algorithm: compression_algorithm) throws
    -> Data
{
    // Estimativa do tamanho do buffer de destino (em geral, o resultado descompactado pode ser maior)
    let dstBufferSize = data.count * 4
    let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(
        capacity: dstBufferSize
    )
    defer { destinationBuffer.deallocate() }

    var stream = compression_stream(
        dst_ptr: destinationBuffer,
        dst_size: dstBufferSize,
        src_ptr: (data as NSData).bytes.bindMemory(
            to: UInt8.self,
            capacity: data.count
        ),
        src_size: data.count,
        state: nil
    )

    let statusInit = compression_stream_init(
        &stream,
        COMPRESSION_STREAM_DECODE,
        algorithm
    )
    guard statusInit == COMPRESSION_STATUS_OK else {
        throw CompressionError.decompressionFailed
    }
    defer { compression_stream_destroy(&stream) }

    var outputData = Data()
    try data.withUnsafeBytes { (srcPointer: UnsafeRawBufferPointer) in
        guard
            let baseAddress = srcPointer.baseAddress?.assumingMemoryBound(
                to: UInt8.self
            )
        else {
            throw CompressionError.decompressionFailed
        }

        stream.src_ptr = baseAddress
        stream.src_size = data.count
        stream.dst_ptr = destinationBuffer
        stream.dst_size = dstBufferSize

        while true {
            let status = compression_stream_process(&stream, 0)
            switch status {
            case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                let count = dstBufferSize - stream.dst_size
                if count > 0 {
                    outputData.append(destinationBuffer, count: count)
                }
                if status == COMPRESSION_STATUS_END {
                    return
                }
                stream.dst_ptr = destinationBuffer
                stream.dst_size = dstBufferSize
            default:
                throw CompressionError.decompressionFailed
            }
        }
    }
    return outputData
}


/// Compresses the given data using the Gzip compression algorithm.
///
/// - Parameter data: The data to be compressed.
/// - Returns: A `Data` object containing the compressed data.
/// - Throws: An error if the compression process fails.
private func gzipCompress(data: Data) throws -> Data {
    var stream = z_stream()
    var status: Int32 = deflateInit2_(
        &stream,
        Z_DEFAULT_COMPRESSION,
        Z_DEFLATED,
        15 + 16,  // 15 bits + 16 para o header GZIP
        8,  // nível de memória
        Z_DEFAULT_STRATEGY,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
    )
    guard status == Z_OK else {
        throw CompressionError.zlibError(code: Int(status))
    }
    defer { deflateEnd(&stream) }

    var outputData = Data()
    let chunkSize = 4096
    var chunk = [UInt8](repeating: 0, count: chunkSize)

    try data.withUnsafeBytes { (srcPointer: UnsafeRawBufferPointer) in
        guard
            let baseAddress = srcPointer.baseAddress?.assumingMemoryBound(
                to: UInt8.self
            )
        else {
            throw CompressionError.compressionFailed
        }
        stream.next_in = UnsafeMutablePointer(mutating: baseAddress)
        stream.avail_in = UInt32(data.count)

        repeat {
            let bytesCompressed = try chunk.withUnsafeMutableBytes {
                buffer -> Int in
                guard
                    let outPtr = buffer.baseAddress?.assumingMemoryBound(
                        to: UInt8.self
                    )
                else {
                    throw CompressionError.compressionFailed
                }
                stream.next_out = outPtr
                stream.avail_out = UInt32(chunkSize)
                status = deflate(&stream, Z_FINISH)
                if status != Z_OK && status != Z_STREAM_END {
                    throw CompressionError.zlibError(code: Int(status))
                }
                return chunkSize - Int(stream.avail_out)
            }
            outputData.append(chunk, count: bytesCompressed)
        } while stream.avail_out == 0
    }

    guard status == Z_STREAM_END else {
        throw CompressionError.compressionFailed
    }
    return outputData
}

/// Decompresses the given data using the Gzip compression method.
/// 
/// - Parameter data: The compressed data to be decompressed.
/// - Returns: The decompressed data.
/// - Throws: An error if the decompression process fails.
private func gzipDecompress(data: Data) throws -> Data {
    var stream = z_stream()
    var status: Int32 = inflateInit2_(
        &stream,
        15 + 32,  // 15 bits + 32 para detecção automática de header GZIP
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
    )
    guard status == Z_OK else {
        throw CompressionError.zlibError(code: Int(status))
    }
    defer { inflateEnd(&stream) }

    var outputData = Data()
    let chunkSize = 4096
    var chunk = [UInt8](repeating: 0, count: chunkSize)

    try data.withUnsafeBytes { (srcPointer: UnsafeRawBufferPointer) in
        guard
            let baseAddress = srcPointer.baseAddress?.assumingMemoryBound(
                to: UInt8.self
            )
        else {
            throw CompressionError.decompressionFailed
        }
        stream.next_in = UnsafeMutablePointer(mutating: baseAddress)
        stream.avail_in = UInt32(data.count)

        repeat {
            let bytesDecompressed = chunk.withUnsafeMutableBytes {
                buffer -> Int in
                stream.next_out = buffer.baseAddress?.assumingMemoryBound(
                    to: UInt8.self
                )
                stream.avail_out = UInt32(chunkSize)
                status = inflate(&stream, Z_SYNC_FLUSH)
                return chunkSize - Int(stream.avail_out)
            }
            if status != Z_OK && status != Z_STREAM_END {
                throw CompressionError.zlibError(code: Int(status))
            }
            chunk.withUnsafeMutableBytes { buffer in
                outputData.append(
                    buffer.bindMemory(to: UInt8.self).baseAddress!,
                    count: bytesDecompressed
                )
            }
        } while stream.avail_out == 0 && status != Z_STREAM_END
    }

    guard status == Z_STREAM_END else {
        throw CompressionError.decompressionFailed
    }
    return outputData
}
