import Foundation
import SwiftData

/// Committed in the same transaction as rekeyed rows and their dependencies.
@Model
final class LibraryMigrationRecord {
    @Attribute(.unique) var name: String
    var completedAt: Date = Date()
    var recoverySnapshotPath: String?
    var schemaRecoverySnapshotPath: String?
    var keyMappingData: Data = Data()
    var unresolvedCount: Int = 0
    init(name: String) { self.name = name }
}
