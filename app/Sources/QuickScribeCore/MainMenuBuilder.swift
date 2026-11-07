import Foundation

/// The words the menu bar shows for its three choice submenus: Mode, Speech
/// Model, Clean Up Model. Kept as pure values so the exact text people read can
/// be tested without a menu bar.
public enum MainMenuBuilder {
    /// How long a name may get inside a menu title before it is cut. A title
    /// carrying a very long model name would push the whole menu wider than the
    /// screen; the full name is still inside the submenu.
    public static let titleNameLimit = 34

    public static let noServerNote = "Server can't be reached"
    public static let notAvailableNote = "not available"
    public static let noSpeechModelsNote = "The server lists no speech models"
    public static let noCleanupModelsNote = "The server lists no clean up models"

    /// A name cut with an ellipsis at `limit` characters. Characters, not bytes,
    /// so the cut lands where the person sees it.
    public static func shortened(_ name: String, limit: Int = titleNameLimit) -> String {
        guard name.count > limit, limit > 1 else { return name }
        return String(name.prefix(limit - 1)) + "…"
    }

    /// "Mode: Polish", "Speech Model: Apple Native", "Clean Up Model: Qwen…"
    public static func title(_ label: String, _ choice: String, limit: Int = titleNameLimit) -> String {
        "\(label): \(shortened(choice, limit: limit))"
    }

    public static let modeLabel = "Mode"
    public static let speechLabel = "Speech Model"
    public static let cleanupLabel = "Clean Up Model"
}
