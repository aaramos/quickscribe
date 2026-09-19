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

    private static let keptTypes: [NSPasteboard.PasteboardType] = {
        var types: [NSPasteboard.PasteboardType] = [
            .string, .rtf, .rtfd, .html,
            .tiff, .png,
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
            NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
        ]
        // Preserve any unknown registered types we can read as data.
        return types
    }()

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

    /// Insert text into the focused app. `completion(onMain, ok, restoreLostImages)`.
    static func insert(_ text: String, completion: @escaping (Bool, Bool) -> Void) {
        let pb = NSPasteboard.general
        let snap = snapshot(pb)

        pb.clearContents()
        var wroteMarker = false
        let ok = pb.setString(text, forType: .string)
        if ok {
            // Marker lets us recognize (and not re-restore) our own writes.
            wroteMarker = pb.setData(Data(AppInfo.displayName.utf8), forType: markerType)
        }
        _ = wroteMarker

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
