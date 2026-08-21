import AppKit
import Combine
import Foundation

enum TranslationState: Equatable {
    case idle
    case streaming
    case succeeded
    case failed(String)
}

enum AutoSubmitPhase: Equatable {
    case idle
    case quietWaiting
    case countdown(startedAt: Date)
}

struct ClipboardSuggestion: Equatable {
    let changeCount: Int
    let text: String
}

private struct TranslationSignature: Hashable {
    let sourceText: String
    let providerID: UUID
    let providerBaseURL: String
    let apiStyle: APIStyle
    let modelID: UUID
    let modelAPIName: String
    let targetLanguage: String
    let addition: String
    let promptTemplate: String
}

@MainActor
final class AppState: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard sideEffectsEnabled else { return }
            persistSettings()
            handleSettingsChange(from: oldValue)
        }
    }

    @Published private(set) var sourceText = ""
    @Published private(set) var translatedText = ""
    @Published private(set) var translationState: TranslationState = .idle
    @Published private(set) var autoSubmitPhase: AutoSubmitPhase = .idle
    @Published private(set) var isUserTyping = false
    @Published private(set) var clipboardSuggestion: ClipboardSuggestion?
    @Published private(set) var persistenceErrorMessage: String?

    private let settingsStore: SettingsStore
    private let keychainStore: KeychainStore
    private let translationClient: TranslationClient
    private let clipboardMonitor: ClipboardMonitor
    private var sideEffectsEnabled = false
    private var typingIdleTask: Task<Void, Never>?
    private var quietWaitTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var lastSuccessfulSignature: TranslationSignature?
    private var displayedResultSignature: TranslationSignature?
    private var autoRetryBlockedSignature: TranslationSignature?
    private var suppressedClipboardChangeCount: Int?
    private var isMainWindowVisible = false

    var onOpenSettings: (() -> Void)?
    var onAlwaysOnTopChanged: ((Bool) -> Void)?

    convenience init() {
        self.init(
            settingsStore: SettingsStore(),
            keychainStore: KeychainStore(),
            translationClient: TranslationClient(),
            clipboardMonitor: ClipboardMonitor()
        )
    }

    init(
        settingsStore: SettingsStore,
        keychainStore: KeychainStore,
        translationClient: TranslationClient,
        clipboardMonitor: ClipboardMonitor
    ) {
        self.settingsStore = settingsStore
        self.keychainStore = keychainStore
        self.translationClient = translationClient
        self.clipboardMonitor = clipboardMonitor

        var loadedSettings = settingsStore.load()
        loadedSettings.normalizeSelections()
        settings = loadedSettings
        NetworkDiagnosticLogger.shared.setEnabled(settings.resolvedNetworkDiagnosticsEnabled)
        sideEffectsEnabled = true
        persistSettings()
    }

    deinit {
        typingIdleTask?.cancel()
        quietWaitTask?.cancel()
        countdownTask?.cancel()
        translationTask?.cancel()
    }

    var promptValidation: PromptValidationResult {
        PromptEngine.validate(settings.promptTemplate)
    }

    var selectedProvider: ProviderConfiguration? { settings.selectedProvider }
    var selectedModel: ModelConfiguration? { settings.selectedModel }
    var selectedLanguage: LanguageMapping? { settings.selectedLanguage }
    var selectedAddition: AdditionMapping? { settings.selectedAddition }

    var configurationReady: Bool {
        guard let provider = selectedProvider,
              selectedModel != nil,
              keychainStore.containsAPIKey(for: provider.id),
              Self.isValidBaseURL(provider.baseURL) else {
            return false
        }
        return true
    }

    var translationPrerequisitesReady: Bool {
        configurationReady
            && promptValidation.isValid
            && !(selectedLanguage?.promptValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && selectedAddition != nil
    }

    var serviceConfigurationStatusMessage: String {
        guard let provider = selectedProvider else { return "请先添加服务商。" }
        guard Self.isValidBaseURL(provider.baseURL) else { return "服务商网址无效。" }
        guard keychainStore.containsAPIKey(for: provider.id) else { return "请为服务商填写 API 密钥。" }
        guard selectedModel != nil else { return "请为服务商添加并选择一个模型。" }
        return "服务商与模型设置已完备。"
    }

    var translationBlockerMessage: String? {
        guard configurationReady else { return serviceConfigurationStatusMessage }
        if let firstError = promptValidation.errors.first {
            return "提示词设置有误：\(firstError)"
        }
        guard selectedLanguage != nil else { return "请至少保留一种目标语言。" }
        guard selectedAddition != nil else { return "请至少保留一种附加要求。" }
        return nil
    }

    var isTranslating: Bool {
        if case .streaming = translationState { return true }
        return false
    }

    var isTranslateButtonEnabled: Bool {
        guard translationPrerequisitesReady,
              !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isTranslating,
              let signature = currentSignature else {
            return false
        }
        return signature != lastSuccessfulSignature
    }

    var isResultStale: Bool {
        guard !translatedText.isEmpty, let displayedResultSignature else { return false }
        return displayedResultSignature != currentSignature
    }

    var flattenedModels: [(provider: ProviderConfiguration, model: ModelConfiguration)] {
        settings.providers.flatMap { provider in
            provider.models.map { (provider, $0) }
        }
    }

    func countdownProgress(at date: Date) -> Double? {
        guard case .countdown(let startedAt) = autoSubmitPhase else { return nil }
        let elapsed = date.timeIntervalSince(startedAt)
        return max(0, min(1, 1 - elapsed / 5.0))
    }

    func userEditedSource(_ newValue: String) {
        guard newValue != sourceText else { return }
        sourceText = newValue
        interruptClipboardSuggestion()
        markCurrentRequestAsChanged()
        isUserTyping = true
        cancelQuietWaitAndCountdown()
        typingIdleTask?.cancel()

        if sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isUserTyping = false
            autoSubmitPhase = .idle
            return
        }

        let expectedSignature = currentSignature
        if settings.autoSubmitEnabled {
            autoSubmitPhase = .quietWaiting
        }
        typingIdleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard let self else { return }
            self.isUserTyping = false
            guard self.currentSignature == expectedSignature else { return }
            self.beginCountdownIfEligible(for: expectedSignature)
        }
    }

    func clearSource() {
        sourceText = ""
        translatedText = ""
        translationState = .idle
        displayedResultSignature = nil
        lastSuccessfulSignature = nil
        autoRetryBlockedSignature = nil
        isUserTyping = false
        interruptClipboardSuggestion()
        cancelAllAutomaticTasks()
    }

    func pasteClipboardSuggestion() {
        guard let suggestion = clipboardSuggestion else { return }
        suppressedClipboardChangeCount = suggestion.changeCount
        clipboardSuggestion = nil
        sourceText = suggestion.text
        isUserTyping = false
        markCurrentRequestAsChanged()
        typingIdleTask?.cancel()
        scheduleQuietWaitIfEligible()
    }

    func manualTranslate() {
        guard isTranslateButtonEnabled else { return }
        cancelAllAutomaticTasks()
        isUserTyping = false
        beginTranslation()
    }

    func copyTranslation() {
        guard !translatedText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(translatedText, forType: .string)
        clipboardMonitor.markCurrentAsObserved()
        suppressedClipboardChangeCount = pasteboard.changeCount
        clipboardSuggestion = nil
    }

    func setAutoSubmitEnabled(_ isEnabled: Bool) {
        settings.autoSubmitEnabled = isEnabled
    }

    func setAlwaysOnTop(_ isEnabled: Bool) {
        settings.alwaysOnTop = isEnabled
    }

    func setNetworkDiagnosticsEnabled(_ isEnabled: Bool) {
        settings.networkDiagnosticsEnabled = isEnabled
    }

    func selectLanguage(_ id: UUID?) {
        settings.selectedLanguageID = id
    }

    func selectAddition(_ id: UUID?) {
        settings.selectedAdditionID = id
    }

    func selectModel(_ modelID: UUID?) {
        guard let modelID,
              let entry = flattenedModels.first(where: { $0.model.id == modelID }) else {
            settings.selectedModelID = nil
            return
        }
        settings.selectedProviderID = entry.provider.id
        settings.selectedModelID = entry.model.id
    }

    func hasAPIKey(for providerID: UUID) -> Bool {
        keychainStore.containsAPIKey(for: providerID)
    }

    func upsertProvider(_ provider: ProviderConfiguration, apiKey: String?) throws {
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedKey.isEmpty {
            try keychainStore.setAPIKey(trimmedKey, for: provider.id)
        } else if !keychainStore.containsAPIKey(for: provider.id) {
            throw TranslationClientError.serverError("API 密钥不能为空。")
        }

        if let index = settings.providers.firstIndex(where: { $0.id == provider.id }) {
            settings.providers[index] = provider
        } else {
            settings.providers.append(provider)
        }
        settings.selectedProviderID = provider.id
        settings.normalizeSelections()
        persistSettings()
        markCurrentRequestAsChanged()
    }

    func deleteProvider(id: UUID) throws {
        try keychainStore.deleteAPIKey(for: id)
        settings.providers.removeAll { $0.id == id }
        settings.normalizeSelections()
        persistSettings()
        markCurrentRequestAsChanged()
    }

    func upsertModel(_ model: ModelConfiguration, providerID: UUID) {
        guard let providerIndex = settings.providers.firstIndex(where: { $0.id == providerID }) else { return }
        if let modelIndex = settings.providers[providerIndex].models.firstIndex(where: { $0.id == model.id }) {
            settings.providers[providerIndex].models[modelIndex] = model
        } else {
            settings.providers[providerIndex].models.append(model)
        }
        settings.selectedProviderID = providerID
        settings.selectedModelID = model.id
        settings.normalizeSelections()
        persistSettings()
        markCurrentRequestAsChanged()
    }

    func deleteModel(id: UUID, providerID: UUID) {
        guard let providerIndex = settings.providers.firstIndex(where: { $0.id == providerID }) else { return }
        settings.providers[providerIndex].models.removeAll { $0.id == id }
        settings.normalizeSelections()
        persistSettings()
        markCurrentRequestAsChanged()
    }

    func addLanguageMapping() {
        settings.languages.append(LanguageMapping(displayName: "新语言", promptValue: ""))
    }

    func deleteLanguageMapping(id: UUID) {
        guard settings.languages.count > 1 else { return }
        settings.languages.removeAll { $0.id == id }
        settings.normalizeSelections()
    }

    func addAdditionMapping() {
        settings.additions.append(AdditionMapping(displayName: "新要求", promptValue: ""))
    }

    func deleteAdditionMapping(id: UUID) {
        guard settings.additions.count > 1 else { return }
        settings.additions.removeAll { $0.id == id }
        settings.normalizeSelections()
    }

    func restoreDefaultPrompt() {
        settings.promptTemplate = PromptDefaults.template
    }

    func openSettings() {
        onOpenSettings?()
    }

    func mainWindowDidOpen() {
        isMainWindowVisible = true
        clipboardMonitor.start { [weak self] snapshot in
            self?.evaluateClipboard(snapshot, allowSuppressedVersion: false)
        }
        evaluateClipboard(clipboardMonitor.currentSnapshot, allowSuppressedVersion: true)
    }

    func mainWindowDidHide() {
        isMainWindowVisible = false
        clipboardMonitor.stop()
        clipboardSuggestion = nil
    }

    func cancelAllWork() {
        cancelAllAutomaticTasks()
        translationTask?.cancel()
        translationTask = nil
        clipboardMonitor.stop()
    }

    private var currentSignature: TranslationSignature? {
        signature(using: settings)
    }

    private func signature(using settings: AppSettings) -> TranslationSignature? {
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let provider = settings.selectedProvider,
              let model = settings.selectedModel,
              let language = settings.selectedLanguage,
              let addition = settings.selectedAddition else {
            return nil
        }
        return TranslationSignature(
            sourceText: sourceText,
            providerID: provider.id,
            providerBaseURL: provider.baseURL,
            apiStyle: provider.apiStyle,
            modelID: model.id,
            modelAPIName: model.apiName,
            targetLanguage: language.promptValue,
            addition: addition.promptValue,
            promptTemplate: settings.promptTemplate
        )
    }

    private func handleSettingsChange(from oldSettings: AppSettings) {
        if oldSettings.alwaysOnTop != settings.alwaysOnTop {
            onAlwaysOnTopChanged?(settings.alwaysOnTop)
        }

        if oldSettings.resolvedNetworkDiagnosticsEnabled != settings.resolvedNetworkDiagnosticsEnabled {
            NetworkDiagnosticLogger.shared.setEnabled(settings.resolvedNetworkDiagnosticsEnabled)
        }

        if oldSettings.autoSubmitEnabled != settings.autoSubmitEnabled {
            if settings.autoSubmitEnabled {
                if !isUserTyping { scheduleQuietWaitIfEligible() }
            } else {
                cancelQuietWaitAndCountdown()
            }
        }

        if signature(using: oldSettings) != currentSignature {
            markCurrentRequestAsChanged()
            if !isUserTyping { scheduleQuietWaitIfEligible() }
        }

        if clipboardSuggestion != nil && !clipboardConditionsAreMet(for: clipboardSuggestion?.text) {
            interruptClipboardSuggestion()
        }
    }

    private func markCurrentRequestAsChanged() {
        if !isTranslating {
            translationState = .idle
        }
        if autoRetryBlockedSignature != currentSignature {
            autoRetryBlockedSignature = nil
        }
    }

    private func scheduleQuietWaitIfEligible() {
        cancelQuietWaitAndCountdown()
        guard settings.autoSubmitEnabled,
              isTranslateButtonEnabled,
              !isUserTyping,
              let expectedSignature = currentSignature,
              expectedSignature != autoRetryBlockedSignature else {
            autoSubmitPhase = .idle
            return
        }

        autoSubmitPhase = .quietWaiting
        quietWaitTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard let self, self.currentSignature == expectedSignature else { return }
            self.beginCountdownIfEligible(for: expectedSignature)
        }
    }

    private func beginCountdownIfEligible(for expectedSignature: TranslationSignature?) {
        guard settings.autoSubmitEnabled,
              isTranslateButtonEnabled,
              !isUserTyping,
              let expectedSignature,
              currentSignature == expectedSignature,
              expectedSignature != autoRetryBlockedSignature else {
            autoSubmitPhase = .idle
            return
        }

        quietWaitTask?.cancel()
        quietWaitTask = nil
        countdownTask?.cancel()
        let startedAt = Date()
        autoSubmitPhase = .countdown(startedAt: startedAt)
        countdownTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard let self,
                  self.currentSignature == expectedSignature,
                  self.isTranslateButtonEnabled else { return }
            self.autoSubmitPhase = .idle
            self.beginTranslation()
        }
    }

    private func beginTranslation() {
        guard let signature = currentSignature,
              let provider = selectedProvider,
              let model = selectedModel,
              let language = selectedLanguage,
              let addition = selectedAddition else { return }

        let apiKey: String
        let prompt: String
        do {
            guard let storedKey = try keychainStore.apiKey(for: provider.id), !storedKey.isEmpty else {
                throw TranslationClientError.serverError("API 密钥不存在，请在设置中重新填写。")
            }
            apiKey = storedKey
            prompt = try PromptEngine.render(
                template: settings.promptTemplate,
                targetLanguage: language.promptValue,
                addition: addition.promptValue,
                input: sourceText
            )
        } catch {
            translationState = .failed(error.localizedDescription)
            return
        }

        cancelAllAutomaticTasks()
        interruptClipboardSuggestion()
        translatedText = ""
        displayedResultSignature = signature
        translationState = .streaming
        autoRetryBlockedSignature = nil

        let request = TranslationRequest(provider: provider, model: model, apiKey: apiKey, prompt: prompt)
        translationTask?.cancel()
        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await delta in self.translationClient.streamTranslation(request: request) {
                    try Task.checkCancellation()
                    self.translatedText.append(delta)
                }
                self.lastSuccessfulSignature = signature
                self.translationState = .succeeded
                self.translationTask = nil
                if self.currentSignature != signature {
                    self.scheduleQuietWaitIfEligible()
                }
            } catch is CancellationError {
                self.translationState = .idle
                self.translationTask = nil
            } catch {
                self.translationState = .failed(error.localizedDescription)
                self.translationTask = nil
                self.autoRetryBlockedSignature = signature
                self.cancelQuietWaitAndCountdown()
                if self.currentSignature != signature {
                    self.scheduleQuietWaitIfEligible()
                }
            }
        }
    }

    private func evaluateClipboard(_ snapshot: ClipboardSnapshot, allowSuppressedVersion: Bool) {
        guard isMainWindowVisible else { return }
        guard clipboardConditionsAreMet(for: snapshot.text) else {
            clipboardSuggestion = nil
            suppressedClipboardChangeCount = snapshot.changeCount
            return
        }
        guard allowSuppressedVersion || snapshot.changeCount != suppressedClipboardChangeCount else {
            return
        }
        clipboardSuggestion = ClipboardSuggestion(changeCount: snapshot.changeCount, text: snapshot.text ?? "")
    }

    private func clipboardConditionsAreMet(for text: String?) -> Bool {
        guard let text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text != sourceText,
              !isUserTyping,
              !isTranslating,
              configurationReady else {
            return false
        }
        return true
    }

    private func interruptClipboardSuggestion() {
        if let suggestion = clipboardSuggestion {
            suppressedClipboardChangeCount = suggestion.changeCount
        }
        clipboardSuggestion = nil
    }

    private func cancelQuietWaitAndCountdown() {
        quietWaitTask?.cancel()
        quietWaitTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        autoSubmitPhase = .idle
    }

    private func cancelAllAutomaticTasks() {
        typingIdleTask?.cancel()
        typingIdleTask = nil
        isUserTyping = false
        cancelQuietWaitAndCountdown()
    }

    private func persistSettings() {
        do {
            try settingsStore.save(settings)
            persistenceErrorMessage = nil
        } catch {
            persistenceErrorMessage = "无法保存设置：\(error.localizedDescription)"
        }
    }

    private static func isValidBaseURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            return false
        }
        return true
    }
}
