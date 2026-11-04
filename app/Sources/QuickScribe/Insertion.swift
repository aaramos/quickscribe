import AppKit
import Carbon.HIToolbox

/// Clipboard-restore insertion (brief §3, §9): snapshot the user's clipboard,
/// write our text, synthesize ⌘V into the focused app, restore the clipboard.
enum Insertion {
    struct Snapshot {
        let changeCount: Int
        let items: [[NSPasteboard.PasteboardType: Data]]
        var lostImageData: Bool = false
    }

    /// Types we can restore verbatim. Anything else is dropped in `data(for:)`
    /// (allowlist: these types plus any `public.*` / `com.apple.*` readable as data).
    private static let keptTypes: [NSPasteboard.PasteboardType] = [
        .string, .rtf, .rtfd, .html,
        .tiff, .png,
        NSPasteboard.PasteboardType("public.file-url"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
    ]

    static func snapshot(_ pb: NSPasteboard = .general) -> Snapshot {
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        var lost = false
        for item in pbItems(pb) {
            var bag: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = data(for: item, type: type) { bag[type] = data }
            }
            // Image items whose data lives only in the cloud (Universal
            // Clipboard promises we can't realize) → can't fully restore.
            if bag.isEmpty, item.types.contains(where: { $0.rawValue.contains("image") }) { lost = true }
            items.append(bag)
        }
        return Snapshot(changeCount: pb.changeCount, items: items, lostImageData: lost)
    }

    private static func pbItems(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        // NSPasteboard only exposes items via pastboardItems on macOS.
        return pb.pasteboardItems ?? []
    }

    private static func data(for item: NSPasteboardItem, type: NSPasteboard.PasteboardType) -> Data? {
        // Never snapshot QuickScribe's own marker — protects against recursion.
        if type == markerType { return nil }
        guard keptTypes.contains(type) || type.rawValue.hasPrefix("public.") || type.rawValue.hasPrefix("com.apple.") else { return nil }
        return item.data(forType: type)
    }

    static let markerType = NSPasteboard.PasteboardType("com.quickscribe.internal")

    /// Puts the text on the clipboard and leaves it there.
    @discardableResult
    static func copy(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(text, forType: .string)
    }

    /// Pastes when the focused app might accept it, and leaves the text on the clipboard
    /// so it isn't lost if that app turns out to have nowhere to put it.
    static func pasteAndKeep(_ text: String) -> Bool {
        let ok = copy(text)
        if ok { pasteCmdV() }
        return ok
    }

    /// Insert text into the focused app. `completion(onMain, ok, restoreLostImages)`.
    static func insert(_ text: String, completion: @escaping (Bool, Bool) -> Void) {
        let pb = NSPasteboard.general
        let snap = snapshot(pb)

        pb.clearContents()
        let ok = pb.setString(text, forType: .string)
        if ok {
            // Marker lets us recognize (and not re-restore) our own writes.
            // If the write fails the marker check below simply treats the
            // clipboard as "someone else's" and leaves it — conservative, safe.
            pb.setData(Data(AppInfo.displayName.utf8), forType: markerType)
        }

        pasteCmdV()

        // Restore after the paste has had time to be consumed by the target.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if pb.changeCount != snap.changeCount && pb.string(forType: markerType) != nil {
                // Still holding our payload — safe to restore.
                restore(snap, pb)
            } else if pb.changeCount != snap.changeCount {
                // Target (or user) changed the clipboard mid-flight; leave it.
            }
            completion(ok, snap.lostImageData)
        }
    }

    private static func restore(_ snap: Snapshot, _ pb: NSPasteboard) {
        pb.clearContents()
        guard !snap.items.isEmpty else { return }
        var items: [NSPasteboardItem] = []
        for bag in snap.items {
            let item = NSPasteboardItem()
            for (type, data) in bag { item.setData(data, forType: type) }
            items.append(item)
        }
        pb.writeObjects(items)
    }

    private static func pasteCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}

/// Where dictated text can go, judged from what has keyboard focus right now.
enum InsertionTarget: Equatable {
    case textField
    case notText
    /// Web and Electron apps often don't say what's focused, so a real text box can look
    /// like nothing at all. Treating these as "not text" would stop pasting in those apps.
    case unsure

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    private static let vagueRoles: Set<String> = ["AXWebArea", "AXGroup", "AXUnknown"]

    static func classify(role: String?, hasTextCursor: Bool) -> InsertionTarget {
        guard let role else { return .unsure }
        if textRoles.contains(role) || hasTextCursor { return .textField }
        return vagueRoles.contains(role) ? .unsure : .notText
    }

    static func current() -> InsertionTarget {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)   // a hung app must not delay the text
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return classify(role: nil, hasTextCursor: false)
        }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var cursorSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &cursorSettable)
        return classify(role: role as? String, hasTextCursor: cursorSettable.boolValue)
    }
}
