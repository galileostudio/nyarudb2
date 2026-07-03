import Crypto
import Foundation

/// Key derivation algorithms available for encrypting the database.
public enum KeyDerivationAlgorithm: Sendable {
  /// PBKDF2-HMAC-SHA256. Use this for low-entropy secrets (user passwords).
  /// - Parameter iterations: The number of iterations. OWASP recommends >= 210,000.
  case pbkdf2sha256(iterations: Int = 210_000)

  /// HKDF-SHA256. Use this for high-entropy secrets (e.g. random keys from Keychain).
  /// It is fast and provides zero brute-force resistance.
  case hkdf
}

public enum NyaruCrypto {

  /// Generates a random 256-bit AES key.
  /// This is the recommended path: generate once, store in the Keychain, and pass to the database.
  public static func generateRandomKey() -> SymmetricKey {
    SymmetricKey(size: .bits256)
  }

  /// Generates a random salt for key derivation.
  /// Persist this alongside the database; it is not secret.
  public static func generateSalt(byteCount: Int = 16) -> Data {
    Data((0..<byteCount).map { _ in UInt8.random(in: 0...255) })
  }

  /// Derives an AES-256 key from a password or secret using the specified algorithm.
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

  private static func pbkdf2(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
    let passwordData = Data(password.utf8)
    let key = SymmetricKey(data: passwordData)

    var derivedKey = Data()
    let hLen = 32  // SHA256 digest size
    let dkLen = 32  // We want a 256-bit key
    let blocks = Int(ceil(Double(dkLen) / Double(hLen)))

    for blockIndex in 1...blocks {
      // Step 1: F(Password, Salt, c, i) = U1 ^ U2 ^ ... ^ Uc
      var saltBlock = salt
      saltBlock.append(UInt8(blockIndex >> 24))
      saltBlock.append(UInt8(blockIndex >> 16))
      saltBlock.append(UInt8(blockIndex >> 8))
      saltBlock.append(UInt8(blockIndex))

      // U1 = HMAC(Password, Salt || INT_32_BE(i))
      var u = Data(HMAC<SHA256>.authenticationCode(for: saltBlock, using: key))
      var T = u

      // U2 to Uc
      for _ in 1..<iterations {
        u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
        // XOR current U into T
        for i in 0..<T.count {
          T[i] ^= u[i]
        }
      }

      derivedKey.append(T)
    }

    return SymmetricKey(data: derivedKey.prefix(dkLen))
  }
}
