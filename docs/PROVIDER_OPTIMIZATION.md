# 服务商优化与兼容性维护

本文记录为什么工程采用“通用客户端＋轻量服务商预设”、阿里云百炼问题的诊断过程，以及未来增加其它服务商时应修改和验证的内容。

返回[用户 README](../README.md)或[开发说明](DEVELOPMENT.md)。

## 设计原则

所有服务商仍共享 `TranslationClient`。预设只负责添加少量、经过官方文档确认的请求字段，不复制 URLSession、鉴权、错误处理或流式解析代码。

这样做的目标是同时满足：

- 未知兼容服务可以使用最小请求体。
- 常见厂商可以避免默认深度思考带来的首字延迟。
- 厂商不接受优化字段时仍能获得翻译。
- 新增厂商只影响枚举、参数映射和文档，不让工程线性膨胀。

## 当前预设矩阵

| 预设 | Responses API | Chat Completions |
| --- | --- | --- |
| 通用 OpenAI 兼容 | 不添加专用参数 | 不添加专用参数 |
| OpenAI | `reasoning.effort = none` | `reasoning_effort = none` |
| 阿里云百炼 | `reasoning.effort = none` | `enable_thinking = false` |
| 智谱 AI | 暂不添加专用参数 | `thinking.type = disabled` |

只有同时选择非通用预设并开启“翻译任务优化”才会应用这些字段。`stream: true` 无论是否优化都会发送。

如果带优化字段的请求收到 HTTP 400 或 422，客户端会记录原因并立即用相同模型、提示词和接口格式重试一次，但删除厂商优化字段。第二次请求不会再次回退。401、403、429 和 5xx 不属于参数不兼容，不自动重复消耗额度。

## 阿里云百炼调试记录

### 用户配置

```text
基础网址：
https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1

Chat Completions 最终地址：
https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions
```

`WorkspaceId`、API Key 和模型均已经在其它客户端验证可用。

### 第一阶段：报“服务端返回的流式数据格式不正确”

早期解析器对 OpenAI 标准 SSE 的格式假设过强。兼容服务可能出现以下差异：

- SSE 事件之间没有空行。
- 使用逐行 JSON，而不是带 `data:` 前缀的 SSE。
- Content-Type 写成 `application/json`，正文实际仍是流。
- 流末尾包含 `choices: []` 的 usage-only 事件。
- Chat 内容使用数组形式。

修复方式是按正文结构嗅探模式，并在每段 JSON 完整时立刻解析，而不是完全依赖 Content-Type 或空行。普通 JSON 响应仍保留为兜底。修复后已经能够稳定获得译文。

### 第二阶段：能翻译，但译文像一次性出现

开启诊断日志后，实际响应表明客户端一直在实时读取：请求开始后，服务端先连续返回大量 reasoning 事件和推理 token，约十几秒后才在同一秒内返回少量 `output_text.delta`。因此 UI 没有缓存译文，瓶颈是模型默认深度思考以及服务端的片段粒度。

对于翻译这类不需要长链推理的任务，处理方式是关闭思考：

- 阿里云 Chat Completions：`enable_thinking: false`
- 阿里云 Responses API：`reasoning: { "effort": "none" }`

关闭后，混合思考模型会更早生成最终译文。较长内容能明显看到流式追加；很短的输出仍可能在一次 UI 刷新内完成，这是服务端切片行为，不应通过人为延迟伪造逐字动画。

### 诊断结论

“没有流式显示”至少要区分三层：

1. 传输层：服务端是否真的分块发送，Content-Type 是否可信。
2. 协议层：返回的是 SSE、逐行 JSON，还是普通 JSON；事件名和字段形状是什么。
3. 模型层：模型是否先输出不展示的推理事件，最终译文是否只分成很少的片段。

不要只看 UI 现象就增加定时器或打字机动画。应先开启诊断日志，比较响应头、事件时间、reasoning 长度和 output delta 长度。

## 诊断日志格式与隐私

设置页中的日志开关默认关闭。开启后，每个请求带一个短请求 ID，记录：

- 请求次数、最终 URL、接口格式、优化预设、模型和提示词 UTF-8 字节数。
- HTTP 状态与 Content-Type。
- 每行事件的类型、序号、delta 字符数、reasoning 字符数、结束原因和 token 数。
- 优化参数被拒绝后的回退。
- 解析错误与最终错误信息。

正常成功事件不会记录译文或提示词正文，API Key 会被替换为 `<已脱敏>`。只有无法解析的原始事件会为了定位兼容问题而写入日志，这种事件可能包含模型返回文本。问题解决后建议关闭日志。

## 新增服务商优化方案

添加预设前先确认该厂商确实需要差异化参数。单纯换域名、Key 或模型名不需要新预设，使用通用方案即可。

### 1. 查阅官方文档

至少确认：

- 基础网址与最终 endpoint。
- 支持 Responses、Chat Completions，还是两者都支持。
- 流式开关和结束事件。
- 关闭或降低思考的正式字段、允许值及支持模型。
- 不支持字段时的错误状态码和错误 JSON 形状。

不要仅依据其它客户端的抓包或二手文章永久固化参数。

### 2. 扩展设置模型

在 `ProviderOptimizationPreset` 增加 case，并补充：

- `displayName`
- `detail`
- `defaultAPIStyle`

枚举值会写入用户设置，发布后不要随意重命名 raw value。如果必须迁移，编写自定义解码兼容旧值。

### 3. 集中添加请求字段

只修改 `TranslationClient.applyTranslationOptimizations` 中的 `(preset, apiStyle)` 映射。不要在 Provider 编辑页面或 `AppState` 内拼接网络字段。

如果新参数不是普通 JSON 值，仍应在此函数内完成结构组装，并返回不含秘密信息的简短描述用于日志。

### 4. 保持安全回退

只有实际加入了优化字段的请求才允许无优化重试。确认第二次请求完全移除了新增字段，而且最多重试一次。

如果厂商使用的“参数不支持”状态不是 400/422，要谨慎评估是否扩展回退条件。不要把鉴权失败、限流或服务端故障当作字段不兼容。

### 5. 覆盖测试

用自定义 `URLProtocol` 捕获请求体并返回固定数据，至少验证：

- 通用预设没有出现厂商字段。
- 新预设在每个支持的 APIStyle 下发送正确 JSON。
- 关闭“翻译任务优化”后不发送字段。
- 400/422 后第二次请求无厂商字段且翻译成功。
- 服务端标准 SSE 和实际观测到的非标准流均可逐片段解析。
- usage-only、结束事件和错误事件不会被误判为译文。

### 6. 更新文档和人工验证

- 更新本文的预设矩阵和调试记录。
- 更新用户 README 的配置示例。
- 在真实服务上使用一段较长文本，观察首个译文片段时间和后续片段数量。
- 完成后关闭诊断日志，确认关闭期间文件不再增长。

## 官方参考

这些链接可能随厂商文档调整；实施新改动时应重新核对当前页面：

- [OpenAI：Reasoning models 与 reasoning effort](https://developers.openai.com/api/docs/guides/reasoning#reasoning-effort)
- [阿里云百炼：通过 OpenAI Responses API 调用千问](https://help.aliyun.com/zh/model-studio/qwen-api-via-openai-responses)
- [阿里云百炼：通过 OpenAI Chat Completions 调用千问](https://help.aliyun.com/zh/model-studio/qwen-api-via-openai-chat-completions)
- [智谱 AI：思考模式](https://docs.bigmodel.cn/cn/guide/capabilities/thinking-mode)
