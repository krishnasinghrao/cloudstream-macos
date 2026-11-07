import Foundation
import Security

/// The certificate roots this Mac trusts beyond Apple's built-in ones, for the
/// engine. JDK 17 cannot read keychain trust settings, so without this a
/// network whose TLS is inspected by a root installed in the keychain
/// (antivirus HTTPS scanning, a company proxy, an MDM profile) fails every
/// engine connection while Safari works.
///
/// Only certificates the user or admin trust domain marks as a trusted root
/// for SSL (or for every policy) are exported; a certificate the user domain
/// distrusts is left out even when the admin domain trusts it, and settings
/// limited to one application or one host name are ignored. The engine adds
/// these to the JDK's own roots (engine `SystemTrust.kt`).
enum SystemTrustAnchors {
    static let fileName = "system-anchors.pem"
    /// Mirrors the engine's limit; a keychain holds a few hundred roots at most.
    static let maxAnchors = 256

    /// Writes the anchors to `trust/system-anchors.pem` under `root` (owner-only)
    /// and returns its path, or removes a stale file and returns nil when there are none.
    static func export(to root: URL) -> String? {
        let directory = root.appendingPathComponent("trust", isDirectory: true)
        let file = directory.appendingPathComponent(fileName)
        let anchors = trustedRoots()
        guard !anchors.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(pem(anchors).utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file.path
        } catch {
            DaemonLog.client("trust.export_failed", fields: ["error": "\((error as NSError).code)"])
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }

    /// DER encodings of the trusted roots, user domain first.
    static func trustedRoots() -> [Data] {
        var result: [Data] = []
        var seen = Set<Data>()
        var distrusted = Set<Data>()
        for domain in [SecTrustSettingsDomain.user, .admin] {
            var certificates: CFArray?
            guard SecTrustSettingsCopyCertificates(domain, &certificates) == errSecSuccess,
                  let list = certificates as? [SecCertificate] else { continue }
            for certificate in list {
                let der = SecCertificateCopyData(certificate) as Data
                guard !seen.contains(der), !distrusted.contains(der) else { continue }
                var settings: CFArray?
                guard SecTrustSettingsCopyTrustSettings(certificate, domain, &settings) == errSecSuccess else { continue }
                switch decision(settings as? [[String: Any]] ?? []) {
                case .trusted:
                    seen.insert(der)
                    if result.count < maxAnchors { result.append(der) }
                case .denied:
                    // The user domain overrides admin trust for the same certificate.
                    distrusted.insert(der)
                case .unspecified:
                    break
                }
            }
        }
        return result
    }

    enum Decision { case trusted, denied, unspecified }

    /// The SSL decision of one certificate's trust settings. An empty array
    /// means "always trust as root"; otherwise the first entry that applies to
    /// SSL for every app and host decides (Apple's evaluation order).
    static func decision(_ settings: [[String: Any]]) -> Decision {
        if settings.isEmpty { return .trusted }
        for entry in settings {
            if entry[kSecTrustSettingsApplication as String] != nil { continue }
            if entry[kSecTrustSettingsPolicyString as String] != nil { continue }
            if let policy = entry[kSecTrustSettingsPolicy as String] {
                guard CFGetTypeID(policy as CFTypeRef) == SecPolicyGetTypeID() else { continue }
                // swiftlint:disable:next force_cast
                let properties = SecPolicyCopyProperties(policy as! SecPolicy) as? [String: Any]
                guard let oid = properties?[kSecPolicyOid as String] as? String,
                      oid == (kSecPolicyAppleSSL as String) else { continue }
            }
            let raw = (entry[kSecTrustSettingsResult as String] as? NSNumber)?.uint32Value
                ?? SecTrustSettingsResult.trustRoot.rawValue
            switch SecTrustSettingsResult(rawValue: raw) {
            case .trustRoot?, .trustAsRoot?: return .trusted
            case .deny?: return .denied
            default: continue // unspecified: keep looking
            }
        }
        return .unspecified
    }

    static func pem(_ certificates: [Data]) -> String {
        certificates.map { der in
            "-----BEGIN CERTIFICATE-----\n"
                + der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
                + "\n-----END CERTIFICATE-----\n"
        }.joined()
    }
}
