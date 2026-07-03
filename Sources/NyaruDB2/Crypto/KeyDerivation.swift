//
//  KeyDerivation.swift
//  NyaruDB2
//
//  Created by Demetrius Albuquerque on 2026-07-03.
//

import Crypto
import Foundation

/// Security helpers for generating encryption keys.
public enum NyaruCrypto {

  /// Derives a stable AES-256 key from a password and salt.
  /// Use this so the user doesn't have to deal with raw `SymmetricKey` bytes.
  ///
  /// - Parameters:
  ///   - password: The user's password (e.g., entered on the app's login screen).
  ///   - salt: A unique random value per installation (store in Keychain/UserDefaults).
  /// - Returns: A `SymmetricKey` ready to be used in `DatabaseOptions`.
  /// /// - Warning: HKDF is designed for high-entropy key material, NOT for raw user passwords.
  ///   If you pass a user password directly, it is vulnerable to brute-force attacks.
  ///   For user passwords, you MUST hash them with a slow KDF (like Argon2 or PBKDF2)
  ///   before passing the result to this method, OR use `generateRandomKey()`
  ///   and store it securely in the device's Keychain.
  public static func deriveKey(from password: String, salt: String) -> SymmetricKey {
    let passwordData = Data(password.utf8)
    let saltData = Data(salt.utf8)

    // HKDF (HMAC-based Extract-and-Expand Key Derivation Function)
    // Transforms a variable-entropy password into a 256-bit key.
    return HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: passwordData),
      salt: saltData,
      info: Data("NyaruDB2.AES.GCM.Encryption".utf8),
      outputByteCount: 32  // 256 bits for AES-256
    )
  }

  /// Generates a random 256-bit key.
  /// Warning: If you use this, YOU MUST save the key in the Keychain, otherwise you will lose data on restart.
  public static func generateRandomKey() -> SymmetricKey {
    return SymmetricKey(size: .bits256)
  }
}
