# 开发与维护说明

本文面向准备修改工程的人类开发者和接手任务的 AI。用户使用方式见[根目录 README](../README.md)，服务商兼容策略见[服务商优化说明](PROVIDER_OPTIMIZATION.md)。

## 工程概要

| 项目 | 当前值 |
| --- | --- |
| 产品类型 | macOS 菜单栏应用 |
| UI | SwiftUI，窗口生命周期使用 AppKit |
| 最低系统 | macOS 14.0 |
| Swift 语言版本 | Swift 5 |
| Bundle ID | `AI.Translator` |
| App Sandbox | 关闭（全局辅助功能选区读取所需） |
| 第三方依赖 | 无 |
| 设置 Schema | 3 |

工程启用了 `LSUIElement`，因此应用不显示普通 Dock 图标。由于 Apple 将沙盒内辅助应用使用 Accessibility API 列为不兼容能力，本项目为读取其他应用真实选区采用非沙盒直接分发方式。

## 目录与职责

```text
Translator/
├── App/
│   ├── AppDelegate.swift              菜单栏入口、窗口控制器生命周期
│   ├── AppState.swift                 全局界面状态、选区文本与自动翻译
│   ├── SelectionMonitor.swift         AX 选区轮询和稳定状态防抖
│   ├── SelectionDotWindowController.swift 红点悬停入口
│   ├── MainWindowController.swift     非激活悬浮翻译卡片
│   └── SettingsWindowController.swift 设置窗口
├── Core/
│   ├── Networking/NetworkDiagnosticLogger.swift 日志开关、脱敏和轮换
│   ├── Networking/TranslationClient.swift     请求组装、流解析与兼容回退
│   ├── Persistence/SettingsStore.swift         UserDefaults 编解码
│   ├── Prompt/PromptEngine.swift               模板校验与渲染
│   └── Security/KeychainStore.swift            API 密钥读写
├── Models/AppSettings.swift            全部持久化模型和服务商策略枚举
├── UI/
│   ├── Main/                           主窗口 SwiftUI
│   ├── Settings/SettingsView.swift     设置页和编辑 Sheet
│   └── Shared/VisualEffectView.swift   AppKit 毛玻璃桥接
└── TranslatorApp.swift                 SwiftUI App 入口
```

Xcode 工程使用文件系统同步的源文件分组，新建到 `Translator/` 下的 Swift 文件会参与构建，无需手工维护逐文件的 PBXBuildFile 条目。

## 应用启动和窗口

1. `TranslatorApp` 创建 `AppDelegate`。
2. `AppDelegate.applicationDidFinishLaunching` 将应用设为 accessory，创建菜单栏图标并连接设置回调。
3. `AppState` 从 `SettingsStore` 读取设置、规范化选中项，并同步日志开关。
4. 启动全局 AX 选区监视；首次启动时请求辅助功能授权。
5. 配置不完整时，启动后约 0.25 秒自动打开设置窗口。
6. 选区稳定约 120 ms 后显示红点；悬停红点时才创建并显示翻译卡片。

翻译卡片是非激活 `NSPanel`，尽量不抢回前台应用焦点。鼠标离开红点和卡片后卡片自动隐藏；菜单栏左键用于打开设置。

翻译卡片按需创建并显示；鼠标离开红点和卡片后自动隐藏，菜单栏应用继续运行。退出应用时停止选区监视并取消翻译任务。

## 状态与翻译数据流

`AppState` 标注为 `@MainActor`，是界面状态的唯一协调点。主要流程如下：

```text
AXUIElement 读取焦点控件的 AXSelectedText
        ↓
选区连续稳定约 120 ms → 红点 → 悬停后载入原文
        ↓
原文编辑停止约 500 ms 后自动提交（按钮可立即提交）
        ↓
PromptEngine 校验并替换三个变量
        ↓
从 KeychainStore 读取所选服务商密钥
        ↓
TranslationClient 组装 URL 和请求体
        ↓
URLSession.AsyncBytes 逐行消费响应
        ↓
每个非空 delta 立即追加到 translatedText
```

`TranslationSignature` 包含源文本、服务商、接口格式、模型、目标语言、附加要求和提示词。它用于：

- 避免对完全相同的成功请求重复提交。
- 标记当前结果是否已经过期。
- 阻止同一个失败请求被自动无限重试。
- 在设置或输入变化后安全地安排下一次自动翻译。

取消任务时要同时考虑编辑防抖任务和网络翻译任务。新增会影响请求结果的设置时，也应把它加入 `TranslationSignature`。

## URL 与请求体

`APIStyle` 目前有两种：

| 接口格式 | 自动补全路径 | 主要请求字段 |
| --- | --- | --- |
| Responses | `responses` | `model`、`input`、`stream: true`、`store: false` |
| Chat Completions | `chat/completions` | `model`、`messages`、`stream: true` |

基础网址会先删除 query 和 fragment。如果路径已经等于或以目标接口路径结尾，不会重复追加；否则使用 `appending(path:)` 补全。因此 `/v1` 和完整接口地址都能使用。

请求统一带有：

```text
Content-Type: application/json
Accept: text/event-stream, application/json
Authorization: Bearer <API key>
```

不要把厂商逻辑分散到 UI 或复制成多套客户端。厂商专用参数集中在 `TranslationClient.applyTranslationOptimizations`。

## 流式响应兼容

`TranslationClient.consumeResponseBody` 同时处理：

- 标准 SSE：空行分隔 `data:` 事件。
- 没有空行、连续出现的 `data: {...}`。
- 正文是逐行 JSON，但 Content-Type 是 `text/event-stream`。
- 正文是 JSON 流，但 Content-Type 缺失或写成 `application/json`。
- `[DONE]` 结束标记。
- Chat Completions 的 usage-only 空 choices 事件。
- Chat `delta.content` 为字符串或文本数组。
- Responses 的 `response.output_text.delta` 和完成事件。
- 非流式普通 JSON 作为兜底。

只有非空译文片段才会 yield 给 UI。推理事件、usage 事件和心跳不会显示。服务端负责决定每个片段的大小，客户端不实现人为打字机动画。

新增解析分支时要保持两个不变量：

1. 服务端已经返回的译文应尽早 yield，不能先收集完整正文。
2. 未知但合法的元数据事件应忽略；明确的 error 事件应显示服务端消息。

## 设置迁移

设置存入 `UserDefaults`，JSON 数据键仍为 `translator.app-settings.v1`，内部通过 `schemaVersion` 演进。

- Schema 1：基础服务商、模型、提示词和界面设置。
- Schema 2：服务商优化方案与翻译优化开关。
- Schema 3：网络诊断日志开关。

为旧版本新增的字段使用 Optional，并通过 `resolved...` 计算属性提供默认值，避免合成的 `Codable` 因字段缺失而丢弃整份设置。`normalizeSelections()` 会更新 Schema、物化兼容默认值并修复失效选中项。

如果解码仍失败，原始数据会复制到 `translator.app-settings.v1.corrupt`，应用随后使用默认设置启动。

## 密钥和日志

`KeychainStore` 使用 Generic Password：

- Service：`AI.Translator.ProviderAPIKey`
- Account：服务商 UUID
- Accessible：`kSecAttrAccessibleAfterFirstUnlock`

删除服务商时会同步删除该服务商的钥匙串项。

网络日志默认关闭。`NetworkDiagnosticLogger` 只有在 `setEnabled(true)` 后才创建目录和文件；关闭时关闭文件句柄但不删除历史日志。写入过程受锁保护，日志写入失败不会中断翻译。

沙盒下常见目录为：

```text
~/Library/Containers/AI.Translator/Data/Library/Logs/AI.Translator/
```

以设置页显示的 `NetworkDiagnosticLogger.logDirectoryURL.path` 为准。日志 4 MB 轮换一次，只保留 `network-diagnostics.log` 与 `network-diagnostics.previous.log`。

## 本地构建与检查

在工程根目录执行：

```bash
xcodebuild \
  -project Translator.xcodeproj \
  -scheme Translator \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/TranslatorDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

提交前至少检查：

```bash
git diff --check
file -I README.md docs/*.md Translator/**/*.swift
```

当前没有测试 Target。网络解析改动建议使用自定义 `URLProtocol` 构造固定响应，至少覆盖标准 SSE、缺少空行的 SSE、逐行 JSON、usage-only、普通 JSON、每个厂商参数以及 400/422 自动回退。

## 修改检查清单

- 中文源文件以 UTF-8 保存。
- 新持久化字段能够解码旧设置。
- 新的请求差异会使旧译文进入“结果已过期”状态。
- 密钥、Authorization 和完整提示词不进入常规日志。
- 主线程状态只在 `@MainActor` 上修改。
- 流式响应不会被无意收集成完整结果后才显示。
- Debug 构建成功。
- 如果修改服务商参数，同步更新[服务商优化说明](PROVIDER_OPTIMIZATION.md)。
