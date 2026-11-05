import AppKit
import QuickScribeCore

/// The custom-service block of Settings: the address, key and model fields,
/// and the connection test that answers in plain sentences. Moved whole
/// from SettingsWindow.swift; `private` marks lifted across the boundary,
/// nothing else changed.
@MainActor
extension SettingsWindow {

    // MARK: - Custom service

    func reloadConnection() {
        let s = endpointStore.load()
        addressField.stringValue = s.address
        keyField.stringValue = endpointStore.apiKey() ?? ""
        speechChoice.selectItem(at: s.useCustomSpeech ? 1 : 0)
        cleanupChoice.selectItem(at: s.useCustomCleanup ? 1 : 0)
        speechModelField.stringValue = s.speechModel
        cleanupModelField.stringValue = s.cleanupModel
        refreshWordsOutWarning()
        if s.isEnabled { fetchModels() }
    }

    /// Reads every control back into a settings value. The person's typed model
    /// names survive whatever the list fetch does.
    private func collectConnection() -> EndpointSettings {
        EndpointSettings(address: addressField.stringValue,
                         speechModel: speechModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                         cleanupModel: cleanupModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                         useCustomSpeech: speechChoice.indexOfSelectedItem == 1,
                         useCustomCleanup: cleanupChoice.indexOfSelectedItem == 1)
    }

    private func connectionChanged(saveKey: Bool = false) {
        let s = collectConnection()
        endpointStore.save(s)
        if saveKey {
            do {
                try endpointStore.setAPIKey(keyField.stringValue)
            } catch {
                connectionStatus.stringValue = error.localizedDescription
            }
        }
        refreshWordsOutWarning()
        // The prompt editor shows the factory of the route cleanup now uses.
        // Unsaved typing stays put (showCurrentMode keeps dirty drafts).
        showCurrentMode()
        if s.isEnabled { fetchModels() } else { connectionStatus.stringValue = "" }
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

    /// Fills the model pickers from GET /models. Services that do not list
    /// models are fine: the fields stay typed by hand.
    private func fetchModels() {
        modelsFetchGeneration += 1
        let generation = modelsFetchGeneration
        let s = collectConnection()
        let client = OpenAICompatClient(settings: s, apiKey: endpointStore.apiKey(), timeout: 8)
        Task { [weak self] in
            let models = await client.listModels()
            guard let self, generation == self.modelsFetchGeneration, !models.isEmpty else { return }
            self.fill(speechModelField, with: models)
            self.fill(self.cleanupModelField, with: models)
        }
    }

    private func fill(_ box: NSComboBox, with models: [String]) {
        let typed = box.stringValue
        box.removeAllItems()
        box.addItems(withObjectValues: models)
        box.stringValue = typed
    }

    // MARK: - Connection actions

    @objc func connectionFieldEndedEditing(_ sender: NSTextField) {
        connectionChanged(saveKey: sender === keyField)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField,
           field === addressField || field === keyField || field === speechModelField || field === cleanupModelField {
            connectionFieldEndedEditing(field)
        }
    }

    @objc func connectionChoiceChanged() {
        connectionChanged()
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
            return "No address set, so everything runs on Apple's own models on this Mac."
        }
        // A server may load the model on its first call; the original app
        // allowed 120 s for that, so this must not read a slow load as failure.
        let client = OpenAICompatClient(settings: settings, apiKey: apiKey, timeout: 120)
        var reached = false, keyOK = false
        switch await client.checkModels() {
        case .success(let models):
            reached = true
            keyOK = true
            lines.append(models.isEmpty
                ? "Reached the address, but it does not list models. You can still type the names."
                : "Reached the address. It has \(models.count) model\(models.count == 1 ? "" : "s").")
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
                lines.append("Speech: no model name typed yet.")
            } else {
                do {
                    _ = try await client.transcribe(wav: silenceWAV(), model: settings.speechModel)
                    lines.append("Speech works.")
                } catch {
                    lines.append("Speech: \((error as? EndpointError)?.message ?? error.localizedDescription)")
                }
            }
        } else {
            lines.append("Speech: Apple's on-device model is chosen, not the service.")
        }
        if settings.useCustomCleanup {
            if settings.cleanupModel.isEmpty {
                lines.append("Cleanup: no model name typed yet.")
            } else {
                do {
                    _ = try await client.clean(text: "The connection test is a plain sentence.",
                                               model: settings.cleanupModel,
                                               systemPrompt: "Repeat the sentence back exactly.")
                    lines.append("Cleanup works.")
                } catch {
                    lines.append("Cleanup: \((error as? EndpointError)?.message ?? error.localizedDescription)")
                }
            }
        } else {
            lines.append("Cleanup: Apple's on-device model is chosen, not the service.")
        }
        return lines.joined(separator: "\n")
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
