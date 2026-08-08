import Foundation

public struct RadrootsIdentityCustodyConfiguration: Sendable {
    public let namespace: String
    public let secretPolicy: RadrootsSecretAccessPolicy

    public init(
        namespace: String,
        secretPolicy: RadrootsSecretAccessPolicy = .userPresenceLocalSecret
    ) throws {
        let normalized = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 128,
              !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw RadrootsIdentityCustodyError.invalidConfiguration
        }
        self.namespace = normalized
        self.secretPolicy = secretPolicy
    }
}

public actor RadrootsIdentityCustody {
    private struct UnlockedSession {
        let record: RadrootsIdentityPublicRecord
        let signerHandle: String
        let generation: UInt64
    }

    private enum TransactionKind: String, Codable {
        case replace
        case delete
    }

    private enum TransactionPhase: String, Codable {
        case prepared
        case activeSecretCommitted
        case metadataCommitted
        case activeSecretRemoved
        case metadataRemoved
    }

    private struct TransactionJournal: Codable {
        let version: UInt16
        let operationID: String
        let kind: TransactionKind
        var phase: TransactionPhase
        let previous: RadrootsIdentityPublicRecord?
        let candidate: RadrootsIdentityPublicRecord?
        let startedAtUnixMilliseconds: UInt64

        func validated() throws -> Self {
            guard version == 1,
                  RadrootsOpaqueSignRequest.canonicalUUID(operationID),
                  startedAtUnixMilliseconds > 0,
                  (kind == .replace) == (candidate != nil)
            else {
                throw RadrootsIdentityCustodyError.corruptMetadata
            }
            if let previous {
                _ = try RadrootsIdentityPublicRecord(
                    identityHandle: previous.identityHandle,
                    publicKeyHex: previous.publicKeyHex,
                    label: previous.label,
                    createdAtUnixMilliseconds: previous.createdAtUnixMilliseconds,
                    updatedAtUnixMilliseconds: previous.updatedAtUnixMilliseconds
                )
            }
            if let candidate {
                _ = try RadrootsIdentityPublicRecord(
                    identityHandle: candidate.identityHandle,
                    publicKeyHex: candidate.publicKeyHex,
                    label: candidate.label,
                    createdAtUnixMilliseconds: candidate.createdAtUnixMilliseconds,
                    updatedAtUnixMilliseconds: candidate.updatedAtUnixMilliseconds
                )
            }
            return self
        }
    }

    private let configuration: RadrootsIdentityCustodyConfiguration
    private let secureStore: any RadrootsSecureStore
    private let metadataStore: any RadrootsIdentityMetadataStore
    private let userPresence: any RadrootsUserPresence
    private let protectedData: RadrootsProtectedDataProvider
    private let now: @Sendable () -> UInt64
    private let cryptography = RadrootsIdentityCryptography()
    private var session: UnlockedSession?
    private var generation: UInt64 = 0
    private var activeOperations = Set<String>()
    private var cancelledOperations: [String: UInt64] = [:]
    private let maximumActiveSigningOperations = 8

    public init(
        configuration: RadrootsIdentityCustodyConfiguration,
        secureStore: any RadrootsSecureStore,
        metadataStore: any RadrootsIdentityMetadataStore,
        userPresence: any RadrootsUserPresence,
        protectedData: RadrootsProtectedDataProvider = .available,
        now: @escaping @Sendable () -> UInt64 = {
            UInt64(Date().timeIntervalSince1970 * 1000)
        }
    ) {
        self.configuration = configuration
        self.secureStore = secureStore
        self.metadataStore = metadataStore
        self.userPresence = userPresence
        self.protectedData = protectedData
        self.now = now
    }

    public func snapshot() -> RadrootsIdentitySnapshot {
        do {
            let record = try loadRecord()
            if try loadJournal() != nil {
                return Self.snapshot(.recoveryRequired, record, nil, "identity.transaction_pending")
            }
            let hasSecret = try secureStore.contains(secretKey(.active))
            guard record != nil || hasSecret else {
                return Self.snapshot(.absent, nil, nil, nil)
            }
            guard let record, hasSecret else {
                return Self.snapshot(.corrupt, record, nil, "identity.inconsistent_state")
            }
            guard protectedData.currentState() == .available else {
                return Self.snapshot(
                    .protectedDataUnavailable, record, nil, "identity.protected_data_unavailable"
                )
            }
            if let session, session.record == record {
                return Self.snapshot(.unlocked, record, session.signerHandle, nil)
            }
            return Self.snapshot(.locked, record, nil, nil)
        } catch RadrootsIdentityCustodyError.corruptMetadata {
            return Self.snapshot(.corrupt, nil, nil, "identity.corrupt_metadata")
        } catch {
            return Self.snapshot(.recoveryRequired, nil, nil, "identity.storage_unavailable")
        }
    }

    @discardableResult
    public func recover() throws -> RadrootsIdentitySnapshot {
        try requireProtectedData()
        guard var journal = try loadJournal() else {
            try cleanupTransactionSecrets()
            return snapshot()
        }
        session = nil
        generation &+= 1
        do {
            switch journal.kind {
            case .replace:
                try recoverReplace(&journal)
            case .delete:
                try recoverDelete(&journal)
            }
            return snapshot()
        } catch let error as RadrootsIdentityCustodyError {
            throw error
        } catch {
            throw RadrootsIdentityCustodyError.recoveryRequired
        }
    }

    @discardableResult
    public func createIdentity(label: String? = nil) async throws -> RadrootsIdentitySnapshot {
        _ = try recover()
        guard try loadRecord() == nil, try !secureStore.contains(secretKey(.active)) else {
            throw RadrootsIdentityCustodyError.identityAlreadyExists
        }
        let expectedGeneration = generation
        try await requireUserPresence(reason: "Create your local Nostr identity.")
        guard generation == expectedGeneration else {
            throw RadrootsIdentityCustodyError.recoveryRequired
        }
        let secret = try cryptography.generateSecret()
        return try commitReplacement(
            material: RadrootsIdentitySecretMaterial(rawRepresentation: secret),
            label: label,
            importedCreatedAt: nil,
            replaceExisting: false
        )
    }

    @discardableResult
    public func importIdentity(
        _ material: RadrootsIdentitySecretMaterial,
        label: String? = nil,
        replaceExisting: Bool = false
    ) async throws -> RadrootsIdentitySnapshot {
        _ = try recover()
        _ = try cryptography.publicKeyHex(for: material.copyBytes())
        let existing = try loadRecord()
        let hasActive = try secureStore.contains(secretKey(.active))
        guard (existing != nil) == hasActive else {
            throw RadrootsIdentityCustodyError.inconsistentState
        }
        if existing != nil, !replaceExisting {
            throw RadrootsIdentityCustodyError.identityAlreadyExists
        }
        let expectedGeneration = generation
        try await requireUserPresence(reason: "Import your local Nostr identity.")
        guard generation == expectedGeneration else {
            throw RadrootsIdentityCustodyError.recoveryRequired
        }
        return try commitReplacement(
            material: material,
            label: label,
            importedCreatedAt: nil,
            replaceExisting: replaceExisting
        )
    }

    @discardableResult
    public func importPortableIdentity(
        _ envelope: RadrootsIdentityPortabilityEnvelope,
        passphrase: RadrootsIdentityPassphrase,
        replaceExisting: Bool = false
    ) async throws -> RadrootsIdentitySnapshot {
        let opened = try RadrootsIdentityPortabilityCodec.open(envelope, passphrase: passphrase)
        _ = try recover()
        let existing = try loadRecord()
        let hasActive = try secureStore.contains(secretKey(.active))
        guard (existing != nil) == hasActive else {
            throw RadrootsIdentityCustodyError.inconsistentState
        }
        if existing != nil, !replaceExisting {
            throw RadrootsIdentityCustodyError.identityAlreadyExists
        }
        let expectedGeneration = generation
        try await requireUserPresence(reason: "Import your encrypted Nostr identity.")
        guard generation == expectedGeneration else {
            throw RadrootsIdentityCustodyError.recoveryRequired
        }
        return try commitReplacement(
            material: opened.0,
            label: opened.1,
            importedCreatedAt: opened.2,
            replaceExisting: replaceExisting
        )
    }

    public func exportPortableIdentity(
        passphrase: RadrootsIdentityPassphrase
    ) async throws -> RadrootsIdentityPortabilityEnvelope {
        try requireProtectedData()
        guard let session else {
            throw RadrootsIdentityCustodyError.identityLocked
        }
        let expectedGeneration = session.generation
        try await requireUserPresence(reason: "Export your encrypted Nostr identity.")
        guard let current = self.session,
              current.generation == expectedGeneration,
              current.signerHandle == session.signerHandle
        else {
            throw RadrootsIdentityCustodyError.staleSigner
        }
        var secret = try readSecret(.active)
        defer { secret.resetBytes(in: secret.startIndex ..< secret.endIndex) }
        guard try cryptography.publicKeyHex(for: secret) == current.record.publicKeyHex else {
            throw RadrootsIdentityCustodyError.inconsistentState
        }
        return try RadrootsIdentityPortabilityCodec.seal(
            secret: secret,
            record: current.record,
            passphrase: passphrase
        )
    }

    @discardableResult
    public func migrateLegacyIdentity(
        from legacyKey: RadrootsSecureStoreKey,
        label: String? = nil
    ) async throws -> RadrootsIdentitySnapshot {
        if let existing = try loadRecord(), try secureStore.contains(secretKey(.active)) {
            guard let legacy = try secureStore.get(legacyKey) else {
                return snapshot()
            }
            guard let text = String(data: legacy, encoding: .utf8),
                  let material = try? RadrootsIdentitySecretMaterial(importText: text),
                  try cryptography.publicKeyHex(for: material.copyBytes()) == existing.publicKeyHex
            else {
                throw RadrootsIdentityCustodyError.inconsistentState
            }
            try secureStore.delete(legacyKey)
            return snapshot()
        }
        guard let legacy = try secureStore.get(legacyKey),
              let text = String(data: legacy, encoding: .utf8)
        else {
            throw RadrootsIdentityCustodyError.identityNotFound
        }
        let material = try RadrootsIdentitySecretMaterial(importText: text)
        let result = try await importIdentity(material, label: label)
        do {
            try secureStore.delete(legacyKey)
        } catch {
            throw RadrootsIdentityCustodyError.recoveryRequired
        }
        return result
    }

    @discardableResult
    public func unlockIdentity() async throws -> RadrootsIdentitySnapshot {
        _ = try recover()
        try requireProtectedData()
        let record = try requiredRecord()
        let expectedGeneration = generation
        try await requireUserPresence(reason: "Unlock your local Nostr identity.")
        guard generation == expectedGeneration else {
            throw RadrootsIdentityCustodyError.staleSigner
        }
        var secret = try readSecret(.active)
        defer { secret.resetBytes(in: secret.startIndex ..< secret.endIndex) }
        guard try cryptography.publicKeyHex(for: secret) == record.publicKeyHex else {
            throw RadrootsIdentityCustodyError.inconsistentState
        }
        generation &+= 1
        let handle = UUID().uuidString.lowercased()
        session = UnlockedSession(record: record, signerHandle: handle, generation: generation)
        return Self.snapshot(.unlocked, record, handle, nil)
    }

    @discardableResult
    public func selectIdentity(identityHandle: String) async throws -> RadrootsIdentitySnapshot {
        guard RadrootsIdentityPublicRecord.validHandle(identityHandle) else {
            throw RadrootsIdentityCustodyError.invalidMetadata
        }
        let record = try requiredRecord()
        guard record.identityHandle == identityHandle else {
            throw RadrootsIdentityCustodyError.identityNotFound
        }
        return try await unlockIdentity()
    }

    public func lockIdentity() {
        generation &+= 1
        session = nil
        let cancellationTime = now()
        for operationID in activeOperations {
            cancelledOperations[operationID] = cancellationTime
        }
        pruneCancellations()
    }

    @discardableResult
    public func deleteIdentity() async throws -> RadrootsIdentitySnapshot {
        _ = try recover()
        try requireProtectedData()
        let record = try requiredRecord()
        let expectedGeneration = generation
        try await requireUserPresence(reason: "Delete your local Nostr identity.")
        guard generation == expectedGeneration,
              try requiredRecord() == record
        else {
            throw RadrootsIdentityCustodyError.recoveryRequired
        }
        lockIdentity()
        let operationID = UUID().uuidString.lowercased()
        let backup = try readSecret(.active)
        try secureStore.put(backup, for: secretKey(.backup), policy: configuration.secretPolicy)
        var journal = TransactionJournal(
            version: 1,
            operationID: operationID,
            kind: .delete,
            phase: .prepared,
            previous: record,
            candidate: nil,
            startedAtUnixMilliseconds: now()
        )
        try writeJournal(journal)
        do {
            try secureStore.delete(secretKey(.active))
            journal.phase = .activeSecretRemoved
            try writeJournal(journal)
            try metadataStore.delete(.activeIdentity)
            journal.phase = .metadataRemoved
            try writeJournal(journal)
            try cleanupTransactionSecrets()
            try metadataStore.delete(.transactionJournal)
            return Self.snapshot(.absent, nil, nil, nil)
        } catch {
            throw RadrootsIdentityCustodyError.recoveryRequired
        }
    }

    @discardableResult
    public func repairCorruptMetadata(label: String? = nil) async throws -> RadrootsIdentitySnapshot {
        try requireProtectedData()
        guard try loadJournal() == nil, try secureStore.contains(secretKey(.active)) else {
            throw RadrootsIdentityCustodyError.recoveryRequired
        }
        let expectedGeneration = generation
        try await requireUserPresence(reason: "Repair your local Nostr identity.")
        guard generation == expectedGeneration else {
            throw RadrootsIdentityCustodyError.staleSigner
        }
        var secret = try readSecret(.active)
        defer { secret.resetBytes(in: secret.startIndex ..< secret.endIndex) }
        let publicKey = try cryptography.publicKeyHex(for: secret)
        let timestamp = now()
        let record = try makeRecord(
            publicKeyHex: publicKey,
            label: label,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try saveRecord(record)
        try metadataStore.delete(.quarantinedMetadata)
        generation &+= 1
        let handle = UUID().uuidString.lowercased()
        session = UnlockedSession(record: record, signerHandle: handle, generation: generation)
        return Self.snapshot(.unlocked, record, handle, nil)
    }

    public func sign(_ request: RadrootsOpaqueSignRequest) async throws -> RadrootsOpaqueSignature {
        try requireProtectedData()
        guard now() <= request.deadlineUnixMilliseconds else {
            throw RadrootsIdentityCustodyError.timedOut
        }
        guard cancelledOperations.removeValue(forKey: request.operationID) == nil else {
            throw RadrootsIdentityCustodyError.cancelled
        }
        guard activeOperations.count < maximumActiveSigningOperations else {
            throw RadrootsIdentityCustodyError.signingSaturated
        }
        guard activeOperations.insert(request.operationID).inserted else {
            throw RadrootsIdentityCustodyError.duplicateOperation
        }
        defer { activeOperations.remove(request.operationID) }
        guard let session else {
            throw RadrootsIdentityCustodyError.identityLocked
        }
        guard session.signerHandle == request.signerHandle,
              session.record.publicKeyHex == request.publicKeyHex
        else {
            throw RadrootsIdentityCustodyError.staleSigner
        }
        let expectedGeneration = session.generation
        try await requireUserPresence(reason: signingReason(request.purpose))
        guard cancelledOperations.removeValue(forKey: request.operationID) == nil else {
            throw RadrootsIdentityCustodyError.cancelled
        }
        guard now() <= request.deadlineUnixMilliseconds else {
            throw RadrootsIdentityCustodyError.timedOut
        }
        guard let current = self.session,
              current.generation == expectedGeneration,
              current.signerHandle == request.signerHandle,
              current.record.publicKeyHex == request.publicKeyHex
        else {
            throw RadrootsIdentityCustodyError.staleSigner
        }
        var secret = try readSecret(.active)
        defer { secret.resetBytes(in: secret.startIndex ..< secret.endIndex) }
        guard try cryptography.publicKeyHex(for: secret) == request.publicKeyHex else {
            throw RadrootsIdentityCustodyError.inconsistentState
        }
        let signature = try cryptography.sign(secret: secret, digest: request.digest)
        guard
            cryptography.verify(
                signature: signature,
                digest: request.digest,
                publicKeyHex: request.publicKeyHex
            )
        else {
            throw RadrootsIdentityCustodyError.invalidSignature
        }
        return try RadrootsOpaqueSignature(
            operationID: request.operationID,
            publicKeyHex: request.publicKeyHex,
            signature: signature,
            purpose: request.purpose
        )
    }

    public func cancelSigning(operationID: String) throws {
        guard RadrootsOpaqueSignRequest.canonicalUUID(operationID) else {
            throw RadrootsIdentityCustodyError.invalidSignRequest
        }
        cancelledOperations[operationID] = now()
        pruneCancellations()
    }

    private func commitReplacement(
        material: RadrootsIdentitySecretMaterial,
        label: String?,
        importedCreatedAt: UInt64?,
        replaceExisting: Bool
    ) throws -> RadrootsIdentitySnapshot {
        try requireProtectedData()
        let previous = try loadRecord()
        let hasActive = try secureStore.contains(secretKey(.active))
        guard (previous != nil) == hasActive else {
            throw RadrootsIdentityCustodyError.inconsistentState
        }
        if previous != nil, !replaceExisting {
            throw RadrootsIdentityCustodyError.identityAlreadyExists
        }
        let candidateSecret = material.copyBytes()
        let publicKey = try cryptography.publicKeyHex(for: candidateSecret)
        let timestamp = now()
        let createdAt: UInt64 = if let previous, previous.publicKeyHex == publicKey {
            previous.createdAtUnixMilliseconds
        } else {
            importedCreatedAt ?? timestamp
        }
        let candidate = try makeRecord(
            publicKeyHex: publicKey,
            label: label,
            createdAt: createdAt,
            updatedAt: max(timestamp, createdAt)
        )
        if hasActive {
            let current = try readSecret(.active)
            try secureStore.put(current, for: secretKey(.backup), policy: configuration.secretPolicy)
        } else {
            try secureStore.delete(secretKey(.backup))
        }
        try secureStore.put(
            candidateSecret, for: secretKey(.candidate), policy: configuration.secretPolicy
        )
        var journal = TransactionJournal(
            version: 1,
            operationID: UUID().uuidString.lowercased(),
            kind: .replace,
            phase: .prepared,
            previous: previous,
            candidate: candidate,
            startedAtUnixMilliseconds: timestamp
        )
        try writeJournal(journal)
        do {
            try secureStore.put(
                candidateSecret, for: secretKey(.active), policy: configuration.secretPolicy
            )
            journal.phase = .activeSecretCommitted
            try writeJournal(journal)
            try saveRecord(candidate)
            journal.phase = .metadataCommitted
            try writeJournal(journal)
            try cleanupTransactionSecrets()
            try metadataStore.delete(.transactionJournal)
        } catch {
            session = nil
            generation &+= 1
            throw RadrootsIdentityCustodyError.recoveryRequired
        }
        generation &+= 1
        let handle = UUID().uuidString.lowercased()
        session = UnlockedSession(record: candidate, signerHandle: handle, generation: generation)
        return Self.snapshot(.unlocked, candidate, handle, nil)
    }

    private func recoverReplace(_ journal: inout TransactionJournal) throws {
        guard let candidate = journal.candidate else {
            throw RadrootsIdentityCustodyError.corruptMetadata
        }
        var activeMatches =
            try secret(.active).map {
                try cryptography.publicKeyHex(for: $0) == candidate.publicKeyHex
            } ?? false
        if !activeMatches {
            if let candidateSecret = try secret(.candidate) {
                guard try cryptography.publicKeyHex(for: candidateSecret) == candidate.publicKeyHex else {
                    throw RadrootsIdentityCustodyError.corruptMetadata
                }
                try secureStore.put(
                    candidateSecret,
                    for: secretKey(.active),
                    policy: configuration.secretPolicy
                )
                activeMatches = true
            } else {
                try rollbackReplacement(journal)
                return
            }
        }
        guard activeMatches else {
            throw RadrootsIdentityCustodyError.recoveryRequired
        }
        journal.phase = .activeSecretCommitted
        try writeJournal(journal)
        try saveRecord(candidate)
        journal.phase = .metadataCommitted
        try writeJournal(journal)
        try cleanupTransactionSecrets()
        try metadataStore.delete(.transactionJournal)
    }

    private func rollbackReplacement(_ journal: TransactionJournal) throws {
        if let previous = journal.previous {
            guard let backup = try secret(.backup),
                  try cryptography.publicKeyHex(for: backup) == previous.publicKeyHex
            else {
                throw RadrootsIdentityCustodyError.recoveryRequired
            }
            try secureStore.put(backup, for: secretKey(.active), policy: configuration.secretPolicy)
            try saveRecord(previous)
        } else {
            try secureStore.delete(secretKey(.active))
            try metadataStore.delete(.activeIdentity)
        }
        try cleanupTransactionSecrets()
        try metadataStore.delete(.transactionJournal)
    }

    private func recoverDelete(_ journal: inout TransactionJournal) throws {
        try secureStore.delete(secretKey(.active))
        journal.phase = .activeSecretRemoved
        try writeJournal(journal)
        try metadataStore.delete(.activeIdentity)
        journal.phase = .metadataRemoved
        try writeJournal(journal)
        try cleanupTransactionSecrets()
        try metadataStore.delete(.transactionJournal)
    }

    private func requireUserPresence(reason: String) async throws {
        try requireProtectedData()
        let request: RadrootsUserPresenceRequest
        do {
            request = try RadrootsUserPresenceRequest(reason: reason)
        } catch {
            throw RadrootsIdentityCustodyError.invalidConfiguration
        }
        do {
            let result = try await userPresence.verify(request)
            guard result.verified else {
                throw RadrootsIdentityCustodyError.userPresenceRequired
            }
        } catch let error as RadrootsIdentityCustodyError {
            throw error
        } catch let error as RadrootsUserPresenceError {
            switch error {
            case .userCancelled:
                throw RadrootsIdentityCustodyError.cancelled
            case .timeout:
                throw RadrootsIdentityCustodyError.timedOut
            default:
                throw RadrootsIdentityCustodyError.userPresenceRequired
            }
        } catch {
            throw RadrootsIdentityCustodyError.userPresenceRequired
        }
        try requireProtectedData()
    }

    private func requireProtectedData() throws {
        guard protectedData.currentState() == .available else {
            throw RadrootsIdentityCustodyError.protectedDataUnavailable
        }
    }

    private func requiredRecord() throws -> RadrootsIdentityPublicRecord {
        guard let record = try loadRecord() else {
            throw RadrootsIdentityCustodyError.identityNotFound
        }
        guard try secureStore.contains(secretKey(.active)) else {
            throw RadrootsIdentityCustodyError.inconsistentState
        }
        return record
    }

    private func loadRecord() throws -> RadrootsIdentityPublicRecord? {
        guard let data = try metadataStore.data(for: .activeIdentity) else {
            return nil
        }
        do {
            let decoded = try JSONDecoder().decode(RadrootsIdentityPublicRecord.self, from: data)
            return try RadrootsIdentityPublicRecord(
                identityHandle: decoded.identityHandle,
                publicKeyHex: decoded.publicKeyHex,
                label: decoded.label,
                createdAtUnixMilliseconds: decoded.createdAtUnixMilliseconds,
                updatedAtUnixMilliseconds: decoded.updatedAtUnixMilliseconds
            )
        } catch {
            do {
                try metadataStore.put(data, for: .quarantinedMetadata)
            } catch {
                throw RadrootsIdentityCustodyError.storageUnavailable
            }
            throw RadrootsIdentityCustodyError.corruptMetadata
        }
    }

    private func saveRecord(_ record: RadrootsIdentityPublicRecord) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try metadataStore.put(encoder.encode(record), for: .activeIdentity)
        } catch let error as RadrootsIdentityCustodyError {
            throw error
        } catch {
            throw RadrootsIdentityCustodyError.storageUnavailable
        }
    }

    private func loadJournal() throws -> TransactionJournal? {
        guard let data = try metadataStore.data(for: .transactionJournal) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(TransactionJournal.self, from: data).validated()
        } catch let error as RadrootsIdentityCustodyError {
            throw error
        } catch {
            throw RadrootsIdentityCustodyError.corruptMetadata
        }
    }

    private func writeJournal(_ journal: TransactionJournal) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try metadataStore.put(encoder.encode(journal.validated()), for: .transactionJournal)
        } catch let error as RadrootsIdentityCustodyError {
            throw error
        } catch {
            throw RadrootsIdentityCustodyError.storageUnavailable
        }
    }

    private enum SecretSlot: String {
        case active = "active_secret_v1"
        case candidate = "candidate_secret_v1"
        case backup = "backup_secret_v1"
    }

    private func secretKey(_ slot: SecretSlot) -> RadrootsSecureStoreKey {
        RadrootsSecureStoreKey(namespace: configuration.namespace, name: slot.rawValue)
    }

    private func secret(_ slot: SecretSlot) throws -> Data? {
        do {
            return try secureStore.get(secretKey(slot))
        } catch {
            throw RadrootsIdentityCustodyError.storageUnavailable
        }
    }

    private func readSecret(_ slot: SecretSlot) throws -> Data {
        guard let secret = try secret(slot) else {
            throw RadrootsIdentityCustodyError.inconsistentState
        }
        guard secret.count == 32 else {
            throw RadrootsIdentityCustodyError.invalidSecret
        }
        return secret
    }

    private func cleanupTransactionSecrets() throws {
        do {
            try secureStore.delete(secretKey(.candidate))
            try secureStore.delete(secretKey(.backup))
        } catch {
            throw RadrootsIdentityCustodyError.storageUnavailable
        }
    }

    private func makeRecord(
        publicKeyHex: String,
        label: String?,
        createdAt: UInt64,
        updatedAt: UInt64
    ) throws -> RadrootsIdentityPublicRecord {
        try RadrootsIdentityPublicRecord(
            identityHandle: cryptography.identityHandle(forPublicKeyHex: publicKeyHex),
            publicKeyHex: publicKeyHex,
            label: label,
            createdAtUnixMilliseconds: createdAt,
            updatedAtUnixMilliseconds: updatedAt
        )
    }

    private func signingReason(_ purpose: RadrootsOpaqueSignPurpose) -> String {
        switch purpose {
        case .nostrEvent:
            "Sign this Nostr event with your local identity."
        case .blossomUpload:
            "Authorize this Blossom media upload with your local identity."
        }
    }

    private func pruneCancellations() {
        guard cancelledOperations.count > 128 else {
            return
        }
        let ordered = cancelledOperations.sorted { $0.value < $1.value }
        for (operationID, _) in ordered.prefix(cancelledOperations.count - 128) {
            cancelledOperations.removeValue(forKey: operationID)
        }
    }

    private static func snapshot(
        _ state: RadrootsIdentityState,
        _ identity: RadrootsIdentityPublicRecord?,
        _ signerHandle: String?,
        _ recoveryCode: String?
    ) -> RadrootsIdentitySnapshot {
        RadrootsIdentitySnapshot(
            state: state,
            identity: identity,
            signerHandle: signerHandle,
            recoveryCode: recoveryCode
        )
    }
}

public final class RadrootsOpaqueSignerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private let cancelAction: @Sendable () -> Void

    init(cancelAction: @escaping @Sendable () -> Void) {
        self.cancelAction = cancelAction
    }

    public func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        lock.unlock()
        cancelAction()
    }
}

public final class RadrootsOpaqueSignerBridge: Sendable {
    private let custody: RadrootsIdentityCustody

    public init(custody: RadrootsIdentityCustody) {
        self.custody = custody
    }

    @discardableResult
    public func submit(
        _ request: RadrootsOpaqueSignRequest,
        completion:
        @escaping @Sendable (Result<RadrootsOpaqueSignature, RadrootsIdentityCustodyError>) -> Void
    ) -> RadrootsOpaqueSignerCancellation {
        let completionState = RadrootsOpaqueSignerCompletion(completion: completion)
        let custody = custody
        let task = Task {
            do {
                if Task.isCancelled {
                    try await custody.cancelSigning(operationID: request.operationID)
                }
                try await completionState.finish(.success(custody.sign(request)))
            } catch let error as RadrootsIdentityCustodyError {
                completionState.finish(.failure(error))
            } catch {
                completionState.finish(.failure(.cryptographyFailed))
            }
        }
        return RadrootsOpaqueSignerCancellation {
            task.cancel()
            Task {
                try? await custody.cancelSigning(operationID: request.operationID)
            }
        }
    }
}

private final class RadrootsOpaqueSignerCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completion:
        (@Sendable (Result<RadrootsOpaqueSignature, RadrootsIdentityCustodyError>) -> Void)?

    init(
        completion:
        @escaping @Sendable (Result<RadrootsOpaqueSignature, RadrootsIdentityCustodyError>) -> Void
    ) {
        self.completion = completion
    }

    func finish(_ result: Result<RadrootsOpaqueSignature, RadrootsIdentityCustodyError>) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(result)
    }
}
