import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Foundation

let KeyCodeMap: [Character: CGKeyCode] = [
    "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B), "c": CGKeyCode(kVK_ANSI_C),
    "d": CGKeyCode(kVK_ANSI_D), "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F),
    "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H), "i": CGKeyCode(kVK_ANSI_I),
    "j": CGKeyCode(kVK_ANSI_J), "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
    "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N), "o": CGKeyCode(kVK_ANSI_O),
    "p": CGKeyCode(kVK_ANSI_P), "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R),
    "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T), "u": CGKeyCode(kVK_ANSI_U),
    "v": CGKeyCode(kVK_ANSI_V), "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
    "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z), " ": CGKeyCode(kVK_Space),
]

// axfocus <bundle> <textarea|omnibox|note-editor> <seed|-> [--noclick]
// Activate app, expose web AX, find target element, focus (AX set + click),
// optionally type seed, print "VALUE:<value>".

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(el, name as CFString, &v)
    return v
}
func str(_ el: AXUIElement, _ name: String) -> String { (attr(el, name) as? String) ?? "" }
func kids(_ el: AXUIElement) -> [AXUIElement] { (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] }

func find(_ el: AXUIElement, depth: Int, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
    if match(el) { return el }
    if depth <= 0 { return nil }
    for c in kids(el) { if let f = find(c, depth: depth - 1, match) { return f } }
    return nil
}

let args = CommandLine.arguments
guard args.count >= 4 else { print("usage: axfocus <bundle> <sel> <seed|-> [--noclick]"); exit(2) }
let bundle = args[1], sel = args[2]
let seed = args[3]
let noClick = args.contains("--noclick")

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { print("ERR no-app"); exit(1) }
app.activate(options: [])
Thread.sleep(forTimeInterval: 1.0)
let ax = AXUIElementCreateApplication(app.processIdentifier)
// Unlock web content AX in Chromium apps (harmless elsewhere).
AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
if bundle.contains("Chrome") { Thread.sleep(forTimeInterval: 1.2) }

func click(_ el: AXUIElement) {
    var pos: CGPoint = .zero; var sz: CGSize = .zero
    if let p = attr(el, kAXPositionAttribute as String) { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
    if let s = attr(el, kAXSizeAttribute as String) { AXValueGetValue(s as! AXValue, .cgSize, &sz) }
    let cx = pos.x + sz.width / 2, cy = pos.y + sz.height / 2
    if let m1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: .left) { m1.post(tap: .cghidEventTap) }
    if let m2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: .left) { m2.post(tap: .cghidEventTap) }
}

guard let wins = attr(ax, kAXWindowsAttribute as String) as? [AXUIElement], !wins.isEmpty else { print("ERR no-window"); exit(2) }
// Pick the window that actually contains the target (Siri orb dialogs steal index 0).
func locate(_ w: AXUIElement) -> AXUIElement? {
    switch sel {
    case "textarea":
        return find(w, depth: 18) { str($0, kAXRoleAttribute as String) == "AXTextArea" }
    case "omnibox":
        return find(w, depth: 18) { el in
            str(el, kAXRoleAttribute as String) == "AXTextField" &&
            (str(el, kAXDescriptionAttribute as String).contains("Address") || str(el, kAXSubroleAttribute as String).contains("SearchField"))
        }
    default: return nil
    }
}
let target: AXUIElement?
if let hit = wins.compactMap({ locate($0) }).first {
    target = hit
} else {
    target = nil
}
guard let el = target else { print("ERR not-found"); exit(3) }

AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
if !noClick {
    var pos: CGPoint = .zero; var sz: CGSize = .zero
    if let p = attr(el, kAXPositionAttribute as String) { AXValueGetValue(p as! AXValue, .cgPoint, &pos) }
    if let s = attr(el, kAXSizeAttribute as String) { AXValueGetValue(s as! AXValue, .cgSize, &sz) }
    let cx = pos.x + sz.width / 2, cy = pos.y + sz.height / 2
    if let m1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: .left) { m1.post(tap: .cghidEventTap) }
    if let m2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: cx, y: cy), mouseButton: .left) { m2.post(tap: .cghidEventTap) }
}
Thread.sleep(forTimeInterval: 0.3)

if seed != "-" {
    let src = CGEventSource(stateID: .hidSystemState)
    for ch in seed.lowercased() {
        guard let kc = KeyCodeMap[ch] else { continue }
        let down = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: true)!
        let up = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: false)!
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
    }
    Thread.sleep(forTimeInterval: 0.3)
}
print("VALUE:" + str(el, kAXValueAttribute as String))
