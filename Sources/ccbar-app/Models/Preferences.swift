import Foundation
import Observation

/// User-tunable knobs persisted in `UserDefaults` under the `CCBar.` prefix.
///
/// Kept tiny on purpose — every value here adds a question on the Settings UI.
/// Add things only when there's a real reason a user would want them different.
@MainActor
@Observable
final class Preferences {
    /// How long a toast stays on screen. `.never` means the user must dismiss
    /// manually via the X button.
    public enum ToastDuration: Int, CaseIterable, Identifiable, Codable {
        case three  = 3
        case five   = 5
        case ten    = 10
        case never  = 0   // 0 == disable auto-dismiss

        public var id: Int { rawValue }

        public var label: String {
            switch self {
            case .three: "3초"
            case .five:  "5초"
            case .ten:   "10초"
            case .never: "수동으로 닫기"
            }
        }

        var seconds: TimeInterval? {
            self == .never ? nil : TimeInterval(rawValue)
        }
    }

    var toastDuration: ToastDuration {
        didSet {
            UserDefaults.standard.set(toastDuration.rawValue, forKey: Self.toastDurationKey)
        }
    }

    /// Whether `claude -p` (sdk-cli) sessions appear in the card list and
    /// trigger toasts. Default off — they're one-shot invocations and
    /// usually noise for the popover.
    var showNonInteractive: Bool {
        didSet {
            UserDefaults.standard.set(showNonInteractive, forKey: Self.showNonInteractiveKey)
        }
    }

    private static let toastDurationKey = "CCBar.toastDurationSeconds"
    private static let showNonInteractiveKey = "CCBar.showNonInteractive"

    init() {
        let stored = UserDefaults.standard.integer(forKey: Self.toastDurationKey)
        self.toastDuration = ToastDuration(rawValue: stored) ?? .five
        // UserDefaults.standard.bool returns false when the key is absent — which
        // is exactly our desired default.
        self.showNonInteractive = UserDefaults.standard.bool(forKey: Self.showNonInteractiveKey)
    }
}
