import Foundation
import Synchronization

enum ProfileLockSecurity {
    static let service = "com.lagradost.cloudstream.locked-profiles"
    private static let account = "locked-ids"
    private static let isolatedLocked = Mutex<Set<String>>([])

    enum LockStatus {
        case unlocked(Set<UUID>)
        case inaccessible
    }

    static func recordLocked(profileIDs: Set<UUID>) {
        if AppEnvironment.isIsolated() {
            isolatedLocked.withLock { $0 = Set(profileIDs.map(\.uuidString)) }
            return
        }
        let list = Array(profileIDs.map(\.uuidString)).sorted()
        guard let data = try? JSONEncoder().encode(list) else { return }
        GenericPasswordKeychain.save(data, service: service, account: account)
    }

    static func readLockedStatus() -> LockStatus {
        if AppEnvironment.isIsolated() {
            return .unlocked(Set(isolatedLocked.withLock { $0 }.compactMap(UUID.init(uuidString:))))
        }
        switch GenericPasswordKeychain.readResult(service: service, account: account) {
        case .found(let data):
            guard let list = try? JSONDecoder().decode([String].self, from: data) else { return .unlocked([]) }
            return .unlocked(Set(list.compactMap(UUID.init(uuidString:))))
        case .locked:
            return .inaccessible
        case .missing, .unavailable:
            return .unlocked([])
        }
    }

    static func readLocked() -> Set<UUID> {
        if case .unlocked(let set) = readLockedStatus() {
            return set
        }
        return []
    }
}
