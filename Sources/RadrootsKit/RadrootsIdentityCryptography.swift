import CryptoKit
import Foundation
import P256K
import Security

public struct RadrootsIdentityPortabilityEnvelope: Sendable, CustomDebugStringConvertible {
    private let serialized: Data

    public init(serializedRepresentation: Data) throws {
        _ = try RadrootsIdentityPortabilityCodec.decodeWire(serializedRepresentation)
        serialized = serializedRepresentation
    }

    public var serializedRepresentation: Data {
        serialized
    }

    public var version: UInt16 {
        (try? RadrootsIdentityPortabilityCodec.decodeWire(serialized).version) ?? 0
    }

    public var debugDescription: String {
        "RadrootsIdentityPortabilityEnvelope(version: \(version), encryptedPayload: <redacted>)"
    }
}

struct RadrootsIdentityCryptography: Sendable {
    func generateSecret() throws -> Data {
        do {
            return try P256K.Schnorr.PrivateKey().dataRepresentation
        } catch {
            throw RadrootsIdentityCustodyError.cryptographyFailed
        }
    }

    func publicKeyHex(for secret: Data) throws -> String {
        do {
            return try Self.hex(P256K.Schnorr.PrivateKey(dataRepresentation: secret).xonly.bytes)
        } catch {
            throw RadrootsIdentityCustodyError.invalidSecret
        }
    }

    func identityHandle(forPublicKeyHex publicKeyHex: String) throws -> String {
        guard let bytes = Self.decodeHex(publicKeyHex), bytes.count == 32 else {
            throw RadrootsIdentityCustodyError.invalidMetadata
        }
        return "rrid1_\(Self.hex(CryptoKit.SHA256.hash(data: bytes)))"
    }

    func sign(secret: Data, digest: Data) throws -> Data {
        guard digest.count == 32 else {
            throw RadrootsIdentityCustodyError.invalidSignRequest
        }
        do {
            let key = try P256K.Schnorr.PrivateKey(dataRepresentation: secret)
            var message = [UInt8](digest)
            var auxiliary = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, auxiliary.count, &auxiliary) == errSecSuccess
            else {
                throw RadrootsIdentityCustodyError.cryptographyFailed
            }
            let signature = try auxiliary.withUnsafeMutableBytes { buffer in
                try key.signature(
                    message: &message,
                    auxiliaryRand: buffer.baseAddress,
                    strict: true
                )
            }
            let signatureData = signature.dataRepresentation
            guard key.xonly.isValid(signature, for: &message) else {
                throw RadrootsIdentityCustodyError.invalidSignature
            }
            return signatureData
        } catch let error as RadrootsIdentityCustodyError {
            throw error
        } catch {
            throw RadrootsIdentityCustodyError.cryptographyFailed
        }
    }

    func verify(signature: Data, digest: Data, publicKeyHex: String) -> Bool {
        guard signature.count == 64,
              digest.count == 32,
              let publicKey = Self.decodeHex(publicKeyHex),
              publicKey.count == 32,
              let parsedSignature = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: signature)
        else {
            return false
        }
        let key = P256K.Schnorr.XonlyKey(dataRepresentation: publicKey)
        var message = [UInt8](digest)
        return key.isValid(parsedSignature, for: &message)
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func decodeHex(_ value: String) -> Data? {
        guard value.count.isMultiple(of: 2),
              value.unicodeScalars.allSatisfy({
                  (48 ... 57).contains($0.value) || (97 ... 102).contains($0.value)
              })
        else {
            return nil
        }
        var output = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index ..< next], radix: 16) else {
                return nil
            }
            output.append(byte)
            index = next
        }
        return output
    }
}

enum RadrootsIdentityPortabilityCodec {
    static let version: UInt16 = 1
    static let kdf = "pbkdf2-hmac-sha256"
    static let cipher = "aes-256-gcm"
    static let iterations: UInt32 = 210_000
    static let maximumEnvelopeBytes = 128 * 1024

    struct Wire: Codable {
        let version: UInt16
        let kdf: String
        let iterations: UInt32
        let cipher: String
        let publicKeyHex: String
        let salt: Data
        let nonce: Data
        let ciphertext: Data
        let tag: Data
    }

    struct Plaintext: Codable {
        let version: UInt16
        let secret: Data
        let publicKeyHex: String
        let label: String?
        let createdAtUnixMilliseconds: UInt64
    }

    static func seal(
        secret: Data,
        record: RadrootsIdentityPublicRecord,
        passphrase: RadrootsIdentityPassphrase
    ) throws -> RadrootsIdentityPortabilityEnvelope {
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else {
            throw RadrootsIdentityCustodyError.cryptographyFailed
        }
        let plaintext = Plaintext(
            version: version,
            secret: secret,
            publicKeyHex: record.publicKeyHex,
            label: record.label,
            createdAtUnixMilliseconds: record.createdAtUnixMilliseconds
        )
        var cleartext = try encoder().encode(plaintext)
        defer { cleartext.resetBytes(in: cleartext.startIndex ..< cleartext.endIndex) }
        do {
            let key = try deriveKey(
                passphrase: passphrase.copyBytes(),
                salt: Data(salt),
                iterations: iterations
            )
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(
                cleartext,
                using: key,
                nonce: nonce,
                authenticating: aad(
                    version: version,
                    kdf: kdf,
                    iterations: iterations,
                    cipher: cipher,
                    publicKeyHex: record.publicKeyHex
                )
            )
            let wire = Wire(
                version: version,
                kdf: kdf,
                iterations: iterations,
                cipher: cipher,
                publicKeyHex: record.publicKeyHex,
                salt: Data(salt),
                nonce: nonce.withUnsafeBytes { Data($0) },
                ciphertext: sealed.ciphertext,
                tag: sealed.tag
            )
            return try RadrootsIdentityPortabilityEnvelope(
                serializedRepresentation: encoder().encode(wire)
            )
        } catch let error as RadrootsIdentityCustodyError {
            throw error
        } catch {
            throw RadrootsIdentityCustodyError.cryptographyFailed
        }
    }

    static func open(
        _ envelope: RadrootsIdentityPortabilityEnvelope,
        passphrase: RadrootsIdentityPassphrase
    ) throws -> (RadrootsIdentitySecretMaterial, String?, UInt64) {
        let wire = try decodeWire(envelope.serializedRepresentation)
        do {
            let key = try deriveKey(
                passphrase: passphrase.copyBytes(),
                salt: wire.salt,
                iterations: wire.iterations
            )
            let nonce = try AES.GCM.Nonce(data: wire.nonce)
            let box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: wire.ciphertext,
                tag: wire.tag
            )
            var cleartext = try AES.GCM.open(
                box,
                using: key,
                authenticating: aad(
                    version: wire.version,
                    kdf: wire.kdf,
                    iterations: wire.iterations,
                    cipher: wire.cipher,
                    publicKeyHex: wire.publicKeyHex
                )
            )
            defer { cleartext.resetBytes(in: cleartext.startIndex ..< cleartext.endIndex) }
            let plaintext = try decoder().decode(Plaintext.self, from: cleartext)
            guard plaintext.version == version,
                  plaintext.publicKeyHex == wire.publicKeyHex,
                  plaintext.createdAtUnixMilliseconds > 0
            else {
                throw RadrootsIdentityCustodyError.portabilityAuthenticationFailed
            }
            let material = try RadrootsIdentitySecretMaterial(rawRepresentation: plaintext.secret)
            let derived = try RadrootsIdentityCryptography().publicKeyHex(for: plaintext.secret)
            guard derived == wire.publicKeyHex else {
                throw RadrootsIdentityCustodyError.portabilityAuthenticationFailed
            }
            return (material, plaintext.label, plaintext.createdAtUnixMilliseconds)
        } catch let error as RadrootsIdentityCustodyError {
            throw error
        } catch {
            throw RadrootsIdentityCustodyError.portabilityAuthenticationFailed
        }
    }

    static func decodeWire(_ serialized: Data) throws -> Wire {
        guard !serialized.isEmpty, serialized.count <= maximumEnvelopeBytes else {
            throw RadrootsIdentityCustodyError.unsupportedPortabilityEnvelope
        }
        do {
            let wire = try decoder().decode(Wire.self, from: serialized)
            guard wire.version == version,
                  wire.kdf == kdf,
                  wire.iterations == iterations,
                  wire.cipher == cipher,
                  RadrootsIdentityPublicRecord.validHex(wire.publicKeyHex, byteCount: 32),
                  wire.salt.count == 16,
                  wire.nonce.count == 12,
                  !wire.ciphertext.isEmpty,
                  wire.ciphertext.count <= 64 * 1024,
                  wire.tag.count == 16
            else {
                throw RadrootsIdentityCustodyError.unsupportedPortabilityEnvelope
            }
            return wire
        } catch let error as RadrootsIdentityCustodyError {
            throw error
        } catch {
            throw RadrootsIdentityCustodyError.unsupportedPortabilityEnvelope
        }
    }

    private static func aad(
        version: UInt16,
        kdf: String,
        iterations: UInt32,
        cipher: String,
        publicKeyHex: String
    ) -> Data {
        Data(
            "org.radroots.identity.portability|\(version)|\(kdf)|\(iterations)|\(cipher)|\(publicKeyHex)"
                .utf8
        )
    }

    private static func deriveKey(
        passphrase: Data,
        salt: Data,
        iterations: UInt32
    ) throws -> SymmetricKey {
        guard !passphrase.isEmpty, iterations == Self.iterations else {
            throw RadrootsIdentityCustodyError.invalidPassphrase
        }
        let key = SymmetricKey(data: passphrase)
        var block = salt
        block.append(contentsOf: [0, 0, 0, 1])
        var previous = Data(HMAC<CryptoKit.SHA256>.authenticationCode(for: block, using: key))
        var output = previous
        if iterations > 1 {
            for _ in 2 ... iterations {
                previous = Data(HMAC<CryptoKit.SHA256>.authenticationCode(for: previous, using: key))
                for index in output.indices {
                    output[index] ^= previous[index]
                }
            }
        }
        defer {
            previous.resetBytes(in: previous.startIndex ..< previous.endIndex)
            output.resetBytes(in: output.startIndex ..< output.endIndex)
        }
        return SymmetricKey(data: output)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}
