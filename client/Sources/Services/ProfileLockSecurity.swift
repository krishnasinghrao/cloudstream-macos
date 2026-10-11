import Foundation
import Synchronization

enum ProfileLockSecurity {
    private static let service = "com.lagradost.cloudstream.locked-profiles"
    private static let account = "locked-ids"
    private static let isolatedLocked = Mutex<Set<String>>([])

    static func recordLocked(profileIDs: Set<UUID>) {
        if AppEnvironment.isIsolated() {
            isolatedLocked.withLock { $0 = Set(profileIDs.map(\.uuidString)) }
            return
        }
        let list = Array(profileIDs.map(\.uuidString)).sorted()
        guard let data = try? JSONEncoder().encode(list) else { return }
        GenericPasswordKeychain.save(data, service: service, account: account)
    }

    static func readLocked() -> Set<UUID> {
        if AppEnvironment.isIsolated() {
            return Set(isolatedLocked.withLock { $0 }.compactMap(UUID.init(uuidString:)))
        }
        guard let data = GenericPasswordKeychain.read(service: service, account: account),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list.compactMap(UUID.init(uuidString:)))
    }
}
