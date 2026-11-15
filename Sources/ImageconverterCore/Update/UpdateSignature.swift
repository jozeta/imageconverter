import Foundation
import Security

/// The code-signature check of a downloaded app (Security framework, offline apart from what the `notarized`
/// requirement itself looks up): the whole bundle, every architecture and nested code, strictly, against
/// `requirement` (by default Developer ID of this team, this bundle identifier, notarized). Revocation checks are
/// enforced, so a revoked Developer ID certificate is refused (the system may ask Apple's revocation service).
public enum UpdateSignature {
    public static let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode
                                                   | SecCSFlags.enforceRevocationChecks.rawValue)

    /// Throws `UpdateError.signatureRejected` unless `bundle` is validly signed and meets `requirement`.
    public static func check(_ bundle: URL, requirement: String = UpdatePolicy.codeRequirement) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.signatureRejected
        }
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled else {
            throw UpdateError.signatureRejected
        }
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, compiled, &error)
        error?.release()
        guard status == errSecSuccess else { throw self.error(forStatus: status) }
    }

    /// Statuses that mean the revocation or notarization lookup couldn't be made (offline), not that the app is bad.
    public static let unavailableStatuses: Set<OSStatus> = [errSecNetworkFailure, errSecOCSPUnavailable,
                                                             errSecOCSPStatusUnrecognized, errSecCRLServerDown]

    /// `.signatureUnconfirmed` when the check couldn't reach Apple, else `.signatureRejected` (a revoked certificate
    /// or notarization, a failed requirement and every other failure are refusals).
    public static func error(forStatus status: OSStatus) -> UpdateError {
        unavailableStatuses.contains(status) ? .signatureUnconfirmed : .signatureRejected
    }
}
