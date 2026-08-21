import SwiftUI

struct MainView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    .ignoresSafeArea()

                HStack(spacing: 0) {
                    sourcePane
                    Rectangle()
                        .fill(.primary.opacity(0.18))
                        .frame(width: 1)
                    targetPane
                }
                .padding(.top, 28)
                .disabled(!appState.configurationReady)
                .opacity(appState.configurationReady ? 1 : 0.5)

                TranslationButton(
                    isEnabled: appState.isTranslateButtonEnabled,
                    isTranslating: appState.isTranslating,
                    autoSubmitPhase: appState.autoSubmitPhase,
                    action: appState.manualTranslate
                )
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2 + 4)

                if !appState.configurationReady {
                    incompleteConfigurationOverlay
                }
            }
        }
        .frame(minWidth: 820, minHeight: 380)
    }

    private var sourcePane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("源语言：自动检测")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
            .background(.white.opacity(0.035))

            sourceEditor

            HStack(spacing: 14) {
                Button("清空", systemImage: "trash") {
                    appState.clearSource()
                }
                .disabled(appState.sourceText.isEmpty)

                Toggle(
                    "自动提交",
                    isOn: Binding(
                        get: { appState.settings.autoSubmitEnabled },
                        set: appState.setAutoSubmitEnabled
                    )
                )
                .toggleStyle(.checkbox)

                Spacer(minLength: 8)

                Text("附加要求：")
                    .foregroundStyle(.secondary)
                Picker(
                    "附加要求",
                    selection: Binding(
                        get: { appState.settings.selectedAdditionID },
                        set: appState.selectAddition
                    )
                ) {
                    ForEach(appState.settings.additions) { addition in
                        Text(addition.displayName).tag(addition.id as UUID?)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 150)
            }
            .controlSize(.small)
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(.black.opacity(0.035))
        }
    }

    private var sourceEditor: some View {
        ZStack(alignment: .bottom) {
            ZStack(alignment: .topLeading) {
                TextEditor(
                    text: Binding(
                        get: { appState.sourceText },
                        set: appState.userEditedSource
                    )
                )
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                if appState.sourceText.isEmpty {
                    Text("输入文本…")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 15))
                        .padding(.leading, 20)
                        .padding(.top, 18)
                        .allowsHitTesting(false)
                }
            }

            if let suggestion = appState.clipboardSuggestion {
                Button(action: appState.pasteClipboardSuggestion) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("剪贴板内容：")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(suggestion.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .help("点击后覆盖源文本")
            }
        }
        .animation(.easeOut(duration: 0.2), value: appState.clipboardSuggestion != nil)
    }

    private var targetPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("目标语言：")
                    .font(.headline)
                Picker(
                    "目标语言",
                    selection: Binding(
                        get: { appState.settings.selectedLanguageID },
                        set: appState.selectLanguage
                    )
                ) {
                    ForEach(appState.settings.languages) { language in
                        Text(language.displayName).tag(language.id as UUID?)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)

                Spacer()

                if appState.isResultStale {
                    Label("结果已过期", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button {
                    appState.setAlwaysOnTop(!appState.settings.alwaysOnTop)
                } label: {
                    Image(systemName: appState.settings.alwaysOnTop ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(appState.settings.alwaysOnTop ? "解除窗口置顶" : "启用窗口置顶")
                .accessibilityLabel(appState.settings.alwaysOnTop ? "解除窗口置顶" : "启用窗口置顶")
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
            .background(.white.opacity(0.035))

            targetOutput

            HStack(spacing: 10) {
                Text("模型：")
                    .foregroundStyle(.secondary)
                Picker(
                    "模型",
                    selection: Binding(
                        get: { appState.settings.selectedModelID },
                        set: appState.selectModel
                    )
                ) {
                    ForEach(appState.flattenedModels, id: \.model.id) { entry in
                        Text("\(entry.provider.displayName) · \(entry.model.resolvedDisplayName)")
                            .tag(entry.model.id as UUID?)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 230)

                Spacer()

                Button("复制", systemImage: "doc.on.doc") {
                    appState.copyTranslation()
                }
                .disabled(appState.translatedText.isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(.black.opacity(0.035))
        }
    }

    private var targetOutput: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                Text(appState.translatedText)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(20)
            }

            if appState.translatedText.isEmpty && !appState.isTranslating {
                Text("翻译结果…")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 15))
                    .padding(20)
            }

            if appState.isTranslating {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在翻译…")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(12)
                .background(.thinMaterial, in: Capsule())
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }

            if case .failed(let message) = appState.translationState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }

    private var incompleteConfigurationOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("需要完成模型设置")
                .font(.headline)
            Text(appState.serviceConfigurationStatusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("打开设置", systemImage: "gearshape") {
                appState.openSettings()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(width: 310)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.24), radius: 22, y: 12)
    }
}
