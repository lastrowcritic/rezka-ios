#if REZKA_CLOUDKIT
import CloudKit
import CryptoKit
import Foundation

/// Private to the signed-in iCloud user. Each episode has its own record so two
/// devices watching different titles cannot overwrite a whole-library snapshot.
@MainActor
final class AppleCloudWatchSyncClient: WatchHistorySyncBackend {
    enum AccountError: LocalizedError {
        case unavailable, changed, missingContainer
        var errorDescription: String? {
            switch self {
            case .unavailable: "Sign in to iCloud in device Settings and allow iCloud access for Rezka."
            case .changed: "The iCloud account changed. Sync was turned off. Choose Apple Cloud again to sync this device’s history with the new account."
            case .missingContainer: "This build is missing its iCloud container configuration."
            }
        }
    }

    private let defaults: UserDefaults
    private let zoneID = CKRecordZone.ID(zoneName: "WatchLibrary", ownerName: CKCurrentUserDefaultName)

    init(defaults: UserDefaults) { self.defaults = defaults }

    func exchange(_ local: WatchHistorySnapshot) async throws -> WatchHistorySnapshot {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "RezkaCloudContainer") as? String,
              !identifier.isEmpty, !identifier.contains("$(") else { throw AccountError.missingContainer }
        let container = CKContainer(identifier: identifier)
        guard try await container.accountStatus() == .available else { throw AccountError.unavailable }
        let user = try await container.userRecordID().recordName
        try Task.checkCancellation()
        if let previous = defaults.string(forKey: "watchSyncAppleAccount"), previous != user { throw AccountError.changed }
        defaults.set(user, forKey: "watchSyncAppleAccount")
        let database = container.privateCloudDatabase
        _ = try await database.save(CKRecordZone(zoneID: zoneID))

        // Conditional saves protect a newer update made after our read. On a
        // conflict fetch again and merge, rather than replacing the server value.
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let existing = try await fetchRecords(database)
            var remote = WatchHistorySnapshot()
            let decoder = JSONDecoder()
            for record in existing.values {
                if record.recordID.recordName == "clear-marker" {
                    remote.clearedAt = record["clearedAt"] as? Date ?? remote.clearedAt
                } else if let data = record["payload"] as? Data {
                    // Do not silently overwrite history written by an incompatible version.
                    remote.records.append(try decoder.decode(WatchRecord.self, from: data))
                }
            }
            let merged = local.merging(remote)
            var changes: [CKRecord] = []
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for progress in merged.records {
                let name = SHA256.hash(data: Data(progress.syncKey.utf8)).map { String(format: "%02x", $0) }.joined()
                let id = CKRecord.ID(recordName: name, zoneID: zoneID)
                let payload = try encoder.encode(progress)
                if let stored = existing[id], stored["payload"] as? Data == payload { continue }
                let record = existing[id] ?? CKRecord(recordType: "WatchProgress", recordID: id)
                record["payload"] = payload as CKRecordValue
                changes.append(record)
            }
            if merged.clearedAt > remote.clearedAt {
                let id = CKRecord.ID(recordName: "clear-marker", zoneID: zoneID)
                let marker = existing[id] ?? CKRecord(recordType: "WatchLibraryState", recordID: id)
                marker["clearedAt"] = merged.clearedAt as CKRecordValue
                changes.insert(marker, at: 0)
            }
            var conflict = false
            for start in stride(from: 0, to: changes.count, by: 100) {
                try Task.checkCancellation()
                let batch = Array(changes[start..<min(start + 100, changes.count)])
                let result = try await database.modifyRecords(saving: batch, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
                for saved in result.saveResults.values {
                    if case .failure(let error) = saved {
                        if (error as? CKError)?.code == .serverRecordChanged { conflict = true }
                        else { throw error }
                    }
                }
            }
            if !conflict { return merged }
            if attempt == 2 { throw CKError(.serverRecordChanged) }
        }
        return local
    }

    private func fetchRecords(_ database: CKDatabase) async throws -> [CKRecord.ID: CKRecord] {
        // Zone changes require no query indexes and include every page. Reading
        // from the beginning also recovers cleanly after reinstall or token expiry.
        var records: [CKRecord.ID: CKRecord] = [:]
        var token: CKServerChangeToken?
        while true {
            try Task.checkCancellation()
            let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            for (id, result) in page.modificationResultsByID { records[id] = try result.get().record }
            for deletion in page.deletions { records.removeValue(forKey: deletion.recordID) }
            token = page.changeToken
            if !page.moreComing { return records }
        }
    }
}
#endif
