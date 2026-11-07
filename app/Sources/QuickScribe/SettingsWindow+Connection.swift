import AppKit
import QuickScribeCore

/// The custom-service block of Settings: the address, key and model fields,
/// and the connection test that answers in plain sentences. Moved whole
/// from SettingsWindow.swift; `private` marks lifted across the boundary,
/// nothing else changed.
@MainActor
extension SettingsWindow {

    // MARK: - Inference server

    func reloadConnection() {
        let s = endpointStore.load()
        addressField.stringValue = s.address
        keyField.stringValue = endpointStore.apiKey() ?? ""
        refreshWordsOutWarning()
    }

    /// Reads every control back into a settings value. The model choices are
    /// not on this page any more: they belong to the menu bar, and the saved
    /// ones are carried through untouched.
    private func collectConnection() -> EndpointSettings {
        var s = endpointStore.load()
        s.address = addressField.stringValue
        return s
    }

    private func connectionChanged(saveKey: Bool = false) {
        let before = endpointStore.load()
        // The stored key as it was. A key edit must be judged by what the store
        // holds before and after, never by the field it was just written from:
        // that comparison is always equal, so a new key was never noticed, and
        // the model fetch kept using none until the app restarted.
        let keyBefore = endpointStore.apiKey()
        let s = collectConnection()
        endpointStore.save(s)
        if saveKey {
            do {
                try endpointStore.setAPIKey(keyField.stringValue)
            } catch {
                connectionStatus.stringValue = error.localizedDescription
            }
        }
        let addressChanged = before.normalizedAddress != s.normalizedAddress
        let keyNow = endpointStore.apiKey()
        let keyChanged = saveKey && keyNow != keyBefore
        refreshWordsOutWarning()
        // The prompt editor shows the factory of the route cleanup now uses.
        // Unsaved typing stays put (showCurrentMode keeps dirty drafts).
        showCurrentMode()
        if !s.isEnabled { connectionStatus.stringValue = "" }
        onConnectionChanged?(addressChanged, keyChanged)
    }

    /// When words will leave the Mac for a non-local address, the screen says so.
    private func refreshWordsOutWarning() {
        let s = collectConnection()
        if let problem = s.addressProblem {
            wordsOutLabel.stringValue = problem
            wordsOutLabel.textColor = .systemRed
            wordsOutLabel.isHidden = false
        } else if s.speechUsesEndpoint || s.cleanupUsesEndpoint, !EndpointSettings.isLocal(host: s.hostName) {
            // Only a route actually set to Custom moves words. Plain http to
            // a remote address never reaches here: the check above refuses it.
            wordsOutLabel.stringValue = "Your words will leave this Mac and travel to \(s.hostName)."
            wordsOutLabel.textColor = .secondaryLabelColor
            wordsOutLabel.isHidden = false
        } else {
            wordsOutLabel.isHidden = true
        }
    }

    // MARK: - Connection actions

    @objc func connectionFieldEndedEditing(_ sender: NSTextField) {
        connectionChanged(saveKey: sender === keyField)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField,
           field === addressField || field === keyField {
            connectionFieldEndedEditing(field)
        }
    }

    @objc func testConnectionTapped() {
        connectionTestButton.isEnabled = false
        connectionStatus.stringValue = "Testing…"
        let s = collectConnection()
        // A pasted key often carries spaces or line breaks; the service wants
        // exactly what it handed out.
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        connectionChanged(saveKey: true)
        Task { [weak self] in
            let report = await Self.runConnectionTest(settings: s, apiKey: key)
            self?.connectionStatus.stringValue = report
            self?.connectionTestButton.isEnabled = true
        }
    }

    /// Reports plainly: reached the address, key accepted, speech works,
    /// cleanup works. Each line stands on its own. Internal for tests.
    static func runConnectionTest(settings: EndpointSettings, apiKey: String) async -> String {
        var lines: [String] = []
        if let problem = settings.addressProblem {
            return problem
        }
        guard settings.isEnabled else {
            return "No address set, so everything uses Apple Native."
        }
        // A server may load the model on its first call; the original app
        // allowed 120 s for that, so this must not read a slow load as failure.
        let client = OpenAICompatClient(settings: settings, apiKey: apiKey, timeout: 120)
        var reached = false, keyOK = false
        switch await client.fetchModels() {
        case .success(let entries):
            reached = true
            keyOK = true
            let lists = ModelCatalog.split(entries)
            lines.append(Self.modelsLine(lists))
        case .failure(let error):
            if case .unauthorized = error {
                reached = true
                lines.append("Reached the address.")
                lines.append("The service refused the key (401). Check the API key.")
            } else {
                lines.append(error.message)
            }
        }
        guard reached else { return lines.joined(separator: "\n") }
        if keyOK { lines.append("Key accepted.") }
        if !keyOK { return lines.joined(separator: "\n") }
        if settings.useCustomSpeech {
            if settings.speechModel.isEmpty {
                lines.append("Speech: no model chosen in the menu bar yet.")
            } else {
                do {
                    _ = try await client.transcribe(wav: silenceWAV(), model: settings.speechModel)
                    lines.append("Speech works with \(settings.speechModel).")
                } catch {
                    lines.append("Speech: \((error as? EndpointError)?.message ?? error.localizedDescription)")
                }
            }
        } else {
            lines.append("Speech: Apple Native is chosen in the menu bar.")
        }
        if settings.useCustomCleanup {
            if settings.cleanupModel.isEmpty {
                lines.append("Clean up: no model chosen in the menu bar yet.")
            } else {
                do {
                    _ = try await client.clean(text: "The connection test is a plain sentence.",
                                               model: settings.cleanupModel,
                                               systemPrompt: "Repeat the sentence back exactly.")
                    lines.append("Clean up works with \(settings.cleanupModel).")
                } catch {
                    lines.append("Clean up: \((error as? EndpointError)?.message ?? error.localizedDescription)")
                }
            }
        } else {
            lines.append("Clean up: Apple Native is chosen in the menu bar.")
        }
        return lines.joined(separator: "\n")
    }

    /// The one line Test Connection adds about what a service offers, split the
    /// way the menu splits it: "Connected. 5 speech, 7 clean up models."
    nonisolated static func modelsLine(_ lists: ModelCatalog.Lists) -> String {
        let speech = lists.speech.count, cleanup = lists.cleanup.count
        guard speech + cleanup > 0 else {
            return "Reached the address, but it lists no speech or clean up models."
        }
        func noun(_ n: Int, _ singular: String, _ plural: String) -> String {
            "\(n) \(n == 1 ? singular : plural)"
        }
        return "Connected. " + noun(speech, "speech", "speech") + ", "
            + noun(cleanup, "clean up model", "clean up models") + "."
    }

    /// A short silence as 16 kHz mono 16-bit PCM in a WAV container. Test
    /// Connection uses it instead of recorded words.
    nonisolated static func silenceWAV(seconds: Double = 0.3, sampleRate: Int = 16_000) -> Data {
        let samples = Int(seconds * Double(sampleRate))
        let pcmLength = samples * 2
        var data = Data()
        func ascii(_ s: String) { data.append(Data(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(36 + pcmLength); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        ascii("data"); u32(pcmLength)
        data.append(Data(count: pcmLength))
        return data
    }
}
