import ClipboardCore
import ServiceManagement
import ClipboardSettings

/// Clipboard's own login item: only the app itself can register it, so Explorer's Settings ask it to.
enum LoginItem {
    static var status: ClipboardSettings.LoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    static func set(_ on: Bool) {
        do {
            on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
        } catch {
            NSLog("Clipboard: could not change the login item: \(error)")
        }
    }
}
