import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let message = appState.persistenceErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.red.opacity(0.08))
            }

            TabView {
                ServiceAndModelSettingsView(appState: appState)
                    .tabItem { Label("服务与模型", systemImage: "server.rack") }

                PromptSettingsView(appState: appState)
                    .tabItem { Label("提示词", systemImage: "text.quote") }

                MappingSettingsView(appState: appState)
                    .tabItem { Label("变量映射", systemImage: "arrow.left.arrow.right") }

                DiagnosticSettingsView(appState: appState)
                    .tabItem { Label("诊断", systemImage: "doc.text.magnifyingglass") }
            }
            .padding(18)
        }
        .frame(width: 900, height: 580)
    }
}

private struct ServiceAndModelSettingsView: View {
    private struct ProviderEditorPresentation: Identifiable {
        let id = UUID()
        let provider: ProviderConfiguration?
    }

    private struct ModelEditorPresentation: Identifiable {
        let id = UUID()
        let providerID: UUID
        let model: ModelConfiguration?
    }

    @ObservedObject var appState: AppState
    @State private var selectedProviderID: UUID?
    @State private var selectedModelID: UUID?
    @State private var providerEditorPresentation: ProviderEditorPresentation?
    @State private var modelEditorPresentation: ModelEditorPresentation?
    @State private var confirmingProviderDeletion = false
    @State private var confirmingModelDeletion = false
    @State private var operationError: String?

    private var sortedProviders: [ProviderConfiguration] {
        appState.settings.providers.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private var selectedProvider: ProviderConfiguration? {
        appState.settings.providers.first(where: { $0.id == selectedProviderID })
    }

    private var selectedModel: ModelConfiguration? {
        selectedProvider?.models.first(where: { $0.id == selectedModelID })
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(
                    appState.serviceConfigurationStatusMessage,
                    systemImage: appState.configurationReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                .foregroundStyle(appState.configurationReady ? .green : .orange)
                Spacer()
                Text("至少需要一个带密钥的服务商和一个模型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HSplitView {
                settingsColumn(title: "服务商") {
                    List(selection: $selectedProviderID) {
                        ForEach(sortedProviders) { provider in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(provider.displayName)
                                HStack(spacing: 5) {
                                    Image(systemName: appState.hasAPIKey(for: provider.id) ? "key.fill" : "key.slash")
                                    Text("\(provider.apiStyle.displayName) · \(provider.resolvedOptimizationPreset.displayName)")
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            .tag(provider.id)
                            .onTapGesture(count: 2) {
                                selectedProviderID = provider.id
                                editProvider(provider)
                            }
                            .contextMenu {
                                Button("编辑") { editProvider(provider) }
                                Button("删除", role: .destructive) {
                                    selectedProviderID = provider.id
                                    confirmingProviderDeletion = true
                                }
                            }
                        }
                    }
                    .overlay {
                        if sortedProviders.isEmpty {
                            ContentUnavailableView(
                                "尚无服务商",
                                systemImage: "server.rack",
                                description: Text("点击下方的加号开始配置。")
                            )
                        }
                    }

                    addRemoveBar(
                        addAction: addProvider,
                        removeAction: { confirmingProviderDeletion = true },
                        removeDisabled: selectedProvider == nil,
                        editAction: { if let selectedProvider { editProvider(selectedProvider) } },
                        editDisabled: selectedProvider == nil
                    )
                }
                .frame(minWidth: 300)

                settingsColumn(title: selectedProvider.map { "\($0.displayName) 的模型" } ?? "模型") {
                    List(selection: $selectedModelID) {
                        ForEach(selectedProvider?.models ?? []) { model in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.resolvedDisplayName)
                                if model.resolvedDisplayName != model.apiName {
                                    Text(model.apiName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(model.id)
                            .onTapGesture(count: 2) {
                                selectedModelID = model.id
                                editModel(model)
                            }
                            .contextMenu {
                                Button("编辑") { editModel(model) }
                                Button("删除", role: .destructive) {
                                    selectedModelID = model.id
                                    confirmingModelDeletion = true
                                }
                            }
                        }
                    }
                    .overlay {
                        if selectedProvider == nil {
                            ContentUnavailableView("请先选择服务商", systemImage: "arrow.left")
                        } else if selectedProvider?.models.isEmpty == true {
                            ContentUnavailableView(
                                "尚无模型",
                                systemImage: "cpu",
                                description: Text("点击下方的加号添加模型。")
                            )
                        }
                    }

                    addRemoveBar(
                        addAction: addModel,
                        removeAction: { confirmingModelDeletion = true },
                        removeDisabled: selectedModel == nil,
                        editAction: { if let selectedModel { editModel(selectedModel) } },
                        editDisabled: selectedModel == nil,
                        addDisabled: selectedProvider == nil
                    )
                }
                .frame(minWidth: 360)
            }

            if let operationError {
                Label(operationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            selectedProviderID = appState.settings.selectedProviderID ?? sortedProviders.first?.id
            selectedModelID = selectedProvider?.models.first?.id
        }
        .onChange(of: selectedProviderID) { _, newValue in
            selectedModelID = appState.settings.providers
                .first(where: { $0.id == newValue })?
                .models.first?.id
        }
        .sheet(item: $providerEditorPresentation) { presentation in
            ProviderEditorView(appState: appState, provider: presentation.provider) { id in
                selectedProviderID = id
                providerEditorPresentation = nil
            }
        }
        .sheet(item: $modelEditorPresentation) { presentation in
            ModelEditorView(
                appState: appState,
                providerID: presentation.providerID,
                model: presentation.model
            ) { id in
                selectedModelID = id
                modelEditorPresentation = nil
            }
        }
        .confirmationDialog(
            "删除服务商及其全部模型？",
            isPresented: $confirmingProviderDeletion,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deleteSelectedProvider() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("对应的本地 API 密钥也会从钥匙串中删除，此操作无法撤销。")
        }
        .confirmationDialog(
            "删除所选模型？",
            isPresented: $confirmingModelDeletion,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deleteSelectedModel() }
            Button("取消", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func settingsColumn<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 8)
            content()
        }
        .padding(8)
    }

    private func addRemoveBar(
        addAction: @escaping () -> Void,
        removeAction: @escaping () -> Void,
        removeDisabled: Bool,
        editAction: @escaping () -> Void,
        editDisabled: Bool,
        addDisabled: Bool = false
    ) -> some View {
        HStack(spacing: 0) {
            Button(action: addAction) { Image(systemName: "plus") }
                .disabled(addDisabled)
            Divider().frame(height: 16)
            Button(action: removeAction) { Image(systemName: "minus") }
                .disabled(removeDisabled)
            Spacer()
            Button("编辑", action: editAction)
                .disabled(editDisabled)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    private func addProvider() {
        providerEditorPresentation = ProviderEditorPresentation(provider: nil)
    }

    private func editProvider(_ provider: ProviderConfiguration) {
        providerEditorPresentation = ProviderEditorPresentation(provider: provider)
    }

    private func addModel() {
        guard let providerID = selectedProviderID else { return }
        modelEditorPresentation = ModelEditorPresentation(providerID: providerID, model: nil)
    }

    private func editModel(_ model: ModelConfiguration) {
        guard let providerID = selectedProviderID else { return }
        modelEditorPresentation = ModelEditorPresentation(providerID: providerID, model: model)
    }

    private func deleteSelectedProvider() {
        guard let id = selectedProviderID else { return }
        do {
            try appState.deleteProvider(id: id)
            selectedProviderID = appState.settings.selectedProviderID
            selectedModelID = appState.settings.selectedModelID
            operationError = nil
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func deleteSelectedModel() {
        guard let providerID = selectedProviderID, let modelID = selectedModelID else { return }
        appState.deleteModel(id: modelID, providerID: providerID)
        selectedModelID = selectedProvider?.models.first?.id
    }
}

private struct DiagnosticSettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Toggle(
                "输出网络诊断日志",
                isOn: Binding(
                    get: { appState.settings.resolvedNetworkDiagnosticsEnabled },
                    set: appState.setNetworkDiagnosticsEnabled
                )
            )

            LabeledContent("日志目录") {
                Text(NetworkDiagnosticLogger.logDirectoryURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            Text("关闭后不会再写入新内容，已经生成的日志不会自动删除。日志按 4 MB 轮换，文件名为 network-diagnostics.log 和 network-diagnostics.previous.log。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("日志不会记录 API 密钥或完整提示词；解析失败时会保留对应的原始响应事件，以便排查兼容性问题，其中可能包含服务端返回的文本。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(8)
    }
}

private struct ProviderEditorView: View {
    @ObservedObject var appState: AppState
    let providerID: UUID
    let existingModels: [ModelConfiguration]
    let isEditing: Bool
    let onSaved: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var baseURL: String
    @State private var apiStyle: APIStyle
    @State private var optimizationPreset: ProviderOptimizationPreset
    @State private var translationOptimizationsEnabled: Bool
    @State private var apiKey = ""
    @State private var errorMessage: String?

    init(appState: AppState, provider: ProviderConfiguration?, onSaved: @escaping (UUID) -> Void) {
        self.appState = appState
        providerID = provider?.id ?? UUID()
        existingModels = provider?.models ?? []
        isEditing = provider != nil
        self.onSaved = onSaved
        _displayName = State(initialValue: provider?.displayName ?? "")
        _baseURL = State(initialValue: provider?.baseURL ?? "")
        _apiStyle = State(initialValue: provider?.apiStyle ?? .chatCompletions)
        _optimizationPreset = State(initialValue: provider?.resolvedOptimizationPreset ?? .generic)
        _translationOptimizationsEnabled = State(
            initialValue: provider?.resolvedTranslationOptimizationsEnabled ?? false
        )
    }

    private var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validURL
            && (!apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.hasAPIKey(for: providerID))
    }

    private var validURL: Bool {
        guard let components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("显示名称", text: $displayName, prompt: Text("例如：OpenAI"))
                TextField("基础网址", text: $baseURL, prompt: Text("https://api.openai.com/v1"))
                Picker("接口格式", selection: $apiStyle) {
                    ForEach(APIStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Picker("优化方案", selection: $optimizationPreset) {
                    ForEach(ProviderOptimizationPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                Toggle("翻译任务优化", isOn: $translationOptimizationsEnabled)
                    .disabled(optimizationPreset == .generic)
                SecureField(
                    "API 密钥",
                    text: $apiKey,
                    prompt: Text(isEditing ? "留空以保留现有密钥" : "仅保存到本机钥匙串")
                )

                Text(optimizationPreset.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("基础网址既可以填写到 /v1，也可以填写完整接口地址。应用不会把密钥写入普通设置或日志。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(18)
        }
        .frame(width: 540, height: 455)
        .onChange(of: optimizationPreset) { _, newValue in
            translationOptimizationsEnabled = newValue != .generic
            if !isEditing, let defaultAPIStyle = newValue.defaultAPIStyle {
                apiStyle = defaultAPIStyle
            }
        }
    }

    private func save() {
        let provider = ProviderConfiguration(
            id: providerID,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiStyle: apiStyle,
            optimizationPreset: optimizationPreset,
            translationOptimizationsEnabled: translationOptimizationsEnabled,
            models: existingModels
        )
        do {
            try appState.upsertProvider(provider, apiKey: apiKey)
            errorMessage = nil
            onSaved(providerID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ModelEditorView: View {
    @ObservedObject var appState: AppState
    let providerID: UUID
    let modelID: UUID
    let onSaved: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var apiName: String

    init(
        appState: AppState,
        providerID: UUID,
        model: ModelConfiguration?,
        onSaved: @escaping (UUID) -> Void
    ) {
        self.appState = appState
        self.providerID = providerID
        modelID = model?.id ?? UUID()
        self.onSaved = onSaved
        _displayName = State(initialValue: model?.displayName ?? "")
        _apiName = State(initialValue: model?.apiName ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("显示名称（可选）", text: $displayName, prompt: Text("留空则使用真实名称"))
                TextField("真实名称", text: $apiName, prompt: Text("例如：模型 API 中使用的名称"))
                Text("真实名称会原样写入请求的 model 字段。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(apiName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(18)
        }
        .frame(width: 480, height: 250)
    }

    private func save() {
        let model = ModelConfiguration(
            id: modelID,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            apiName: apiName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        appState.upsertModel(model, providerID: providerID)
        onSaved(modelID)
    }
}

private struct PromptSettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("翻译提示词")
                        .font(.headline)
                    Text("三个系统变量都必须完整且只出现一次。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("恢复默认", systemImage: "arrow.counterclockwise") {
                    appState.restoreDefaultPrompt()
                }
            }

            HStack(spacing: 8) {
                variableBadge("{{target_language}}", description: "目标语言映射")
                variableBadge("{{addition}}", description: "附加要求映射")
                variableBadge("{{input}}", description: "源文本")
            }

            TextEditor(text: $appState.settings.promptTemplate)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
                }

            if appState.promptValidation.isValid {
                Label("提示词校验通过", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(appState.promptValidation.errors, id: \.self) { error in
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
        .padding(8)
    }

    private func variableBadge(_ variable: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(variable).font(.system(.caption, design: .monospaced).weight(.semibold))
            Text(description).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct MappingSettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("变量映射")
                    .font(.headline)
                Text("界面显示值与写入提示词的值相互独立，因此可以自由改用中文或英文提示词。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 14) {
                mappingCard(title: "目标语言", variable: "{{target_language}}") {
                    ForEach($appState.settings.languages) { $language in
                        mappingRow(
                            displayName: $language.displayName,
                            promptValue: $language.promptValue,
                            deleteDisabled: appState.settings.languages.count <= 1,
                            deleteAction: { appState.deleteLanguageMapping(id: language.id) }
                        )
                    }
                } addAction: {
                    appState.addLanguageMapping()
                }

                mappingCard(title: "附加要求", variable: "{{addition}}") {
                    ForEach($appState.settings.additions) { $addition in
                        mappingRow(
                            displayName: $addition.displayName,
                            promptValue: $addition.promptValue,
                            deleteDisabled: appState.settings.additions.count <= 1,
                            deleteAction: { appState.deleteAdditionMapping(id: addition.id) }
                        )
                    }
                } addAction: {
                    appState.addAdditionMapping()
                }
            }
        }
        .padding(8)
    }

    private func mappingCard<Content: View>(
        title: String,
        variable: String,
        @ViewBuilder content: () -> Content,
        addAction: @escaping () -> Void
    ) -> some View {
        GroupBox {
            VStack(spacing: 8) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text(variable)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("界面显示")
                    Spacer()
                    Text("替换内容")
                    Spacer().frame(width: 26)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ScrollView {
                    LazyVStack(spacing: 7) {
                        content()
                    }
                }

                HStack {
                    Button("添加", systemImage: "plus", action: addAction)
                    Spacer()
                }
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func mappingRow(
        displayName: Binding<String>,
        promptValue: Binding<String>,
        deleteDisabled: Bool,
        deleteAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 7) {
            TextField("显示名称", text: displayName)
            TextField("替换内容", text: promptValue)
            Button(role: .destructive, action: deleteAction) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(deleteDisabled)
        }
    }
}
