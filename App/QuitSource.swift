import AppKit
import Carbon.HIToolbox

/// Where a quit came from, for the log, in every build. A quit that another program asks for (a script, the Dock's Quit, the
/// system at log out, restart or shut down) arrives as a "quit application" Apple Event and names its sender, and may carry a
/// reason; a Command-Q or the Quit menu does not. AppKit's own handler turns the event into a terminate, which asks this delegate
/// first, while the event is still the current one. This only reads the event and says yes, so AppKit's handling is untouched.
@MainActor
final class QuitSource: NSObject, NSApplicationDelegate {
    /// The instance SwiftUI makes from `@NSApplicationDelegateAdaptor`.
    private(set) static var shared: QuitSource?

    override init() {
        super.init()
        Self.shared = self
    }

    /// The request that is being handled: the Apple Event's sender and reason, or nil for a menu or key quit.
    private(set) var apple: String?

    /// What the log says: the Apple Event's sender, else "menu or key".
    var described: String { apple ?? "menu or key" }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication) {
            apple = Self.describe(event)
        }
        return .terminateNow
    }

    static func describe(_ event: NSAppleEventDescriptor) -> String {
        var text = "Apple Event quit"
        if let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value, pid > 0 {
            let app = NSRunningApplication(processIdentifier: pid)
            text += " from pid \(pid), bundle id \(app?.bundleIdentifier ?? "none"), name \(app?.localizedName ?? "unknown")"
        } else {
            text += " from an unknown sender"
        }
        if let why = event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)) {
            text += ", reason \(reasonName(why.enumCodeValue))"
        }
        return text
    }

    /// The names of the reasons the system and other programs give.
    static func reasonName(_ code: OSType) -> String {
        switch code {
        case OSType(kAELogOut): return "log out"
        case OSType(kAEReallyLogOut): return "log out"
        case OSType(kAEShowRestartDialog), OSType(kAERestart): return "restart"
        case OSType(kAEShowShutdownDialog), OSType(kAEShutDown): return "shut down"
        case OSType(kAEQuitAll): return "quit all"
        default: return String(format: "code %08x", code)
        }
    }
}
