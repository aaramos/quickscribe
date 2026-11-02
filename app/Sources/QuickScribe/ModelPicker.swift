import AppKit

/// Reusable menu-bar model picker (Polish LLM + Transcription STT).
///
/// Extracted from the original t_741dd1a3 polish-only picker so both model
/// classes share the SAME honest semantics:
///   • list + active come from the sidecar (the app never knows models);
///   • the checkmark tracks the sidecar-reported ACTIVE model, never the
///     requested one — a failed switch leaves the old model checked;
///   • the user's choice persists to UserDefaults and is re-applied once at
///     launch if the sidecar booted on its config default instead;
///   • fetch/apply completions may arrive off-main; this class hops.
@MainActor
final class ModelPicker: NSObject {
    typealias Fetch = (@escaping ([String]?, String?) -> Void) -> Void
    typealias Apply = (String, @escaping (Bool, String?) -> Void) -> Void

    let title: String
    private let storageKey: String
    private let fetch: Fetch
    private let apply: Apply
    private let notify: (String, TimeInterval?) -> Void
    private let onChanged: () -> Void

    private var availableModels: [String] = []
    private var activeModel: String?
    private var loading = false
    private var switching = false
    private var didApplyPersisted = false

    init(title: String, storageKey: String,
         fetch: @escaping Fetch, apply: @escaping Apply,
         notify: @escaping (String, TimeInterval?) -> Void,
         onChanged: @escaping () -> Void) {
        self.title = title
        self.storageKey = storageKey
        self.fetch = fetch
        self.apply = apply
        self.notify = notify
        self.onChanged = onChanged
    }

    /// Build the submenu fresh for the current state (menu is rebuilt on every
    /// state change — the NSStatusItem menu is rebuilt wholesale anyway).
    var submenuItem: NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        if activeModel == nil && availableModels.isEmpty && !loading && !switching {
            let none = NSMenuItem(title: "(sidecar down — no models)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        if loading {
            let l = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
            l.isEnabled = false
            sub.addItem(l)
        }
        if switching {
            let l = NSMenuItem(title: "Switching…", action: nil, keyEquivalent: "")
            l.isEnabled = false
            sub.addItem(l)
        }
        for m in availableModels {
            let it = NSMenuItem(title: m, action: #selector(selectModel(_:)), keyEquivalent: "")
            it.target = self
            it.state = (m == activeModel) ? .on : .off
            it.isEnabled = !switching
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let ref = NSMenuItem(title: "Refresh", action: #selector(refreshTapped), keyEquivalent: "")
        ref.target = self
        ref.isEnabled = !loading && !switching
        sub.addItem(ref)

        item.submenu = sub
        return item
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        onChanged()
        fetch { [weak self] list, current in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loading = false
                if let list = list {
                    self.availableModels = list
                    self.activeModel = current
                }
                self.onChanged()
                self.applyPersistedIfNeeded()
            }
        }
    }

    /// One-shot: if the user's persisted choice differs from the active model
    /// (e.g. sidecar restarted on its config default), re-apply their choice.
    private func applyPersistedIfNeeded() {
        guard !didApplyPersisted, !switching else { return }
        guard let saved = UserDefaults.standard.string(forKey: storageKey),
              saved != activeModel else { didApplyPersisted = true; return }
        didApplyPersisted = true
        performSwitch(to: saved, silent: true)
    }

    @objc private func refreshTapped() { refresh() }
    @objc private func selectModel(_ sender: NSMenuItem) { performSwitch(to: sender.title, silent: false) }

    private func performSwitch(to model: String, silent: Bool) {
        guard !switching else { return }
        switching = true
        onChanged()
        apply(model) { [weak self] ok, active in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.switching = false
                if ok {
                    self.activeModel = active ?? model
                    UserDefaults.standard.set(self.activeModel, forKey: self.storageKey)
                } else if !silent {
                    // Keep existing model as default/fallback — say so honestly.
                    self.notify("Switch to \(model) failed — still on \(self.activeModel ?? "?")", 4)
                }
                self.onChanged()
            }
        }
    }
}
