import Foundation
import Security

/// One-shot fix for the recurring "CCBar이(가) 'Claude Code-credentials' 키
/// 접근을 허용하고자 합니다" popup.
///
/// Root cause (verified by dumping the item's ACL): macOS records a keychain
/// "Always Allow" as a *trusted application* pinned to the app's path + signing
/// identity. CCBar's identity changes on every rebuild / Sparkle update / run
/// location, so the stored entry never matches the running app — each "Always
/// Allow" just appends another non-matching entry and the prompt returns. (This
/// is unrelated to code-signing trust, which only governs TCC.)
///
/// The only identity-independent fix is to relax the *item's* read ACL to
/// "allow all applications" — a property of the keychain item itself. This does
/// exactly that, and also clears the accumulated stale trusted-app entries.
///
/// Uses the deprecated `SecKeychain*` ACL APIs on purpose: they are the only
/// way to edit a file-based login-keychain item's ACL, and there is no modern
/// replacement.
public enum KeychainAccessGrant {

    /// Service name of Claude Code's OAuth credential item.
    public static let claudeCredentialsService = "Claude Code-credentials"

    public enum GrantError: Error, Sendable, Equatable {
        case itemNotFound          // Claude Code not logged in / no item
        case accessReadFailed(OSStatus)
        case noReadACL
        case saveFailed(OSStatus)  // errSecUserCanceled(-128) if the password dialog is dismissed

        /// True when the user dismissed/cancelled the password dialog.
        public var isUserCancel: Bool {
            if case .saveFailed(let s) = self { return s == errSecUserCanceled }
            return false
        }
    }

    /// Sets the read (Decrypt) ACL of `service` to "allow all applications".
    ///
    /// Triggers ONE login-keychain password dialog (ACLAuthorizationChangeACL).
    /// Safe: the item's owner (Claude Code) keeps its own access regardless, and
    /// the stored secret is never read or modified — only the ACL is.
    ///
    /// Call off the main thread; the password dialog is presented out-of-process
    /// by the system but the call blocks until the user responds.
    public static func allowAllApplicationsToRead(
        service: String = claudeCredentialsService
    ) -> Result<Void, GrantError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnRef as String: true,
        ]
        var ref: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &ref) == errSecSuccess,
              let item = ref
        else { return .failure(.itemNotFound) }
        let kcItem = item as! SecKeychainItem

        var access: SecAccess?
        let aStatus = SecKeychainItemCopyAccess(kcItem, &access)
        guard aStatus == errSecSuccess, let access else {
            return .failure(.accessReadFailed(aStatus))
        }
        var aclArray: CFArray?
        let lStatus = SecAccessCopyACLList(access, &aclArray)
        guard lStatus == errSecSuccess, let acls = aclArray as? [SecACL] else {
            return .failure(.accessReadFailed(lStatus))
        }

        var didChange = false
        for acl in acls {
            let auths = SecACLCopyAuthorizations(acl) as? [String] ?? []
            guard auths.contains(kSecACLAuthorizationDecrypt as String) else { continue }

            var appList: CFArray?
            var desc: CFString?
            var prompt = SecKeychainPromptSelector()
            SecACLCopyContents(acl, &appList, &desc, &prompt)

            // nil application list  → any application is trusted (allow all).
            // empty prompt selector → never warn. Replacing the list also drops
            // the accumulated stale per-build trusted-app entries.
            _ = SecACLSetContents(
                acl, nil,
                (desc as String? ?? service) as CFString,
                SecKeychainPromptSelector()
            )
            didChange = true
        }
        guard didChange else { return .failure(.noReadACL) }

        let setStatus = SecKeychainItemSetAccess(kcItem, access)
        guard setStatus == errSecSuccess else {
            return .failure(.saveFailed(setStatus))
        }
        return .success(())
    }
}
