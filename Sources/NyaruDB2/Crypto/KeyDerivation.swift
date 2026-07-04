import Crypto
import Foundation

/// Defines the supported key derivation algorithms for deriving database
/// encryption keys from user-provided secrets.
///
/// Choose the algorithm based on the entropy level of the secret:
/// - **PBKDF2**: For low-entropy secrets such as user passwords. It applies
///   a configurable number of iterations to slow down brute-force attacks.
/// - **HKDF**: For high-entropy secrets such as random Keychain material. It
///   is lightweight and does not need iteration counts.
///
/// Both algorithms produce a 256-bit AES key suitable for use with
/// `DatabaseOptions.encryptionKey`.
public enum KeyDerivationAlgorithm: Sendable {
  /// Derives a key using PBKDF2-HMAC-SHA256, appropriate for user-supplied
  /// passwords with limited entropy.
  ///
  /// - Parameter iterations: The number of PBKDF2 iterations. OWASP currently
  ///   recommends at least 210,000 iterations for password hashing. Higher
  ///   values increase security at the cost of derivation time.
  case pbkdf2sha256(iterations: Int = 210_000)

  /// Derives a key using HKDF-SHA256, appropriate for high-entropy secrets
  /// such as random data from the Secure Enclave or Keychain.
  ///
  /// HKDF does not use iteration counts; it is a single-pass extract-and-expand
  /// construction.
  case hkdf
}

/// Provides cryptographic helpers for generating and deriving database
/// encryption keys.
///
/// Use `NyaruCrypto` to:
/// 1. Generate a random 256-bit AES key with `generateRandomKey()` (store the
///    result in the iOS Keychain).
/// 2. Generate a random salt with `generateSalt()` (persist the salt alongside
///    the database — it is not secret).
/// 3. Derive an encryption key from a password with `deriveKey(fromPassword:salt:using:)`.
///
/// The derived or generated key is then passed to `DatabaseOptions` as the
/// `encryptionKey` parameter.
public enum NyaruCrypto {

  /// Generates a cryptographically random 256-bit AES symmetric key.
  ///
  /// Call this once during initial setup, store the returned key in the system
  /// Keychain, and pass it to `DatabaseOptions(encryptionKey:)` every time the
  /// database is opened.
  ///
  /// - Returns: A new random `SymmetricKey` of length 32 bytes (256 bits).
  public static func generateRandomKey() -> SymmetricKey {
    SymmetricKey(size: .bits256)
  }

  /// Generates a cryptographically random salt value for key derivation.
  ///
  /// The salt should be persisted alongside the database files — it is not
  /// secret and does not need protection. A new salt should be generated for
  /// each database instance.
  ///
  /// - Parameter byteCount: The length of the salt in bytes (default 16).
  /// - Returns: Random salt data.
  public static func generateSalt(byteCount: Int = 16) -> Data {
    Data((0..<byteCount).map { _ in UInt8.random(in: 0...255) })
  }

  /// Derives a 256-bit AES symmetric key from a password or secret using the
  /// specified algorithm.
  ///
  /// Use PBKDF2 when the input is a user-memorable password (low entropy) and
  /// HKDF when the input is already cryptographically random (high entropy).
  ///
  /// - Parameters:
  ///   - password: The password or secret string.
  ///   - salt: A salt value (generated with `generateSalt()`), persisted
  ///     alongside the database.
  ///   - algorithm: The key derivation algorithm (defaults to PBKDF2-SHA256
  ///     with 210,000 iterations).
  /// - Returns: A 256-bit AES symmetric key.
  /// - Throws: `NyaruError` if key derivation fails.
  public static func deriveKey(
    fromPassword password: String,
    salt: Data,
    using algorithm: KeyDerivationAlgorithm = .pbkdf2sha256()
  ) throws -> SymmetricKey {
    switch algorithm {
    case .pbkdf2sha256(let iterations):
      return try pbkdf2(password: password, salt: salt, iterations: iterations)
    case .hkdf:
      return HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: Data(password.utf8)),
        salt: salt,
        info: Data("NyaruDB2.AES.GCM.Encryption".utf8),
        outputByteCount: 32
      )
    }
  }

  // MARK: - Pure Swift PBKDF2 (Multiplatform, no CommonCrypto needed)

  /// Implements PBKDF2-HMAC-SHA256 key derivation in pure Swift using the
  /// CryptoKit HMAC API, avoiding a dependency on CommonCrypto.
  ///
  /// This implementation follows RFC 2898 section 5.2 and produces exactly
  /// 32 bytes (256 bits) of derived key material.
  ///
  /// - Parameters:
  ///   - password: The password string.
  ///   - salt: The salt data.
  ///   - iterations: The number of PBKDF2 iterations.
  /// - Returns: A 256-bit derived symmetric key.
  /// - Throws: Does not throw; included for future error handling.
  private static func pbkdf2(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
    let passwordData = Data(password.utf8)
    let key = SymmetricKey(data: passwordData)

    var derivedKey = Data()
    let hLen = 32  // SHA256 digest size
    let dkLen = 32  // We want a 256-bit key
    let blocks = Int(ceil(Double(dkLen) / Double(hLen)))

    for blockIndex in 1...blocks {
      var saltBlock = salt
      saltBlock.append(UInt8(blockIndex >> 24))
      saltBlock.append(UInt8(blockIndex >> 16))
      saltBlock.append(UInt8(blockIndex >> 8))
      saltBlock.append(UInt8(blockIndex))

      var u = Data(HMAC<SHA256>.authenticationCode(for: saltBlock, using: key))
      var T = u

      for _ in 1..<iterations {
        u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
        for i in 0..<T.count {
          T[i] ^= u[i]
        }
      }

      derivedKey.append(T)
    }

    return SymmetricKey(data: derivedKey.prefix(dkLen))
  }
}
