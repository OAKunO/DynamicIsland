# 素材来源与发布状态

检查日期：2026-10-28。代码和本项目文档已采用 [MIT License](../LICENSE)，版权署名为 OAKunO。此清单记录来源证据，不替代授权，也不授予品牌或第三方作品的使用权。

维护者已确认 **AppIcon 由 AI 生成并允许公开**，并选定 C1「代码火花」与 D1「蓝色放大镜」作为两种 AI 集成的自定义状态标识。这些项目素材随 MIT 许可提供；生成与精修 prompts、文件哈希见 [generated-status-icons.json](generated-status-icons.json)。此前待确认的 OpenAI PNG 与 DeepSeek SVG 已从应用资源和公开快照工作树移除，仅保留于被忽略的本机备份，不进入新仓库提交。替换前的官方条款核验留存于 [brand-usage-review.md](brand-usage-review.md)。

| 素材 | 当前证据 | 发布状态／下一步 |
| --- | --- | --- |
| `DynamicIsland/Assets.xcassets/AppIcon.appiconset/icon_*.png`（10 个尺寸） | 瓷白底、黑色胶囊、薄荷绿状态灯；维护者于 2026-10-28 明确确认由 AI 生成并允许公开 | **可公开**：纳入候选暂存，随项目 MIT 许可提供；不再列为待确认 |
| `DynamicIsland/Assets.xcassets/CodexStatusIcon.imageset/codex-code-spark.png` | 内置 imagegen 生成 C1，维护者选定后进行透明边缘精修；白色括号与中央火花，作为模板图显示 | **已选定，可公开**：随项目 MIT 许可提供，属于项目自定义状态标识 |
| `DynamicIsland/Assets.xcassets/DeepSeekStatusIcon.imageset/deepseek-discovery.png` | 内置 imagegen 生成 D1，维护者选定后进行透明边缘精修；蓝色放大镜与中央火花 | **已选定，可公开**：随项目 MIT 许可提供，属于项目自定义状态标识 |
| 原 `OpenAIStatusIcon.imageset/openai-status.png` 与 `DeepSeekStatusIcon.imageset/deepseek-status.svg` | 原始来源与再分发范围未确认，已完成官方条款核验 | **已替换，不分发**：已移出两个仓库的应用资源；旧文件仅保留在忽略的本地备份 |
| `docs/screenshots/expanded-demo.png` | 从 `.derivedData/NotesUI/screenshots/expanded.png` 原样复制；由 `Tests/NotesUIRender.swift` 的内存 fixture 与项目 UI 渲染 | 已检查内容：无用户屏幕、真实任务、歌曲封面、AppIcon 或上述品牌图形；作为本项目 UI 的演示图随项目 MIT 许可提供 |
| `docs/screenshots/notes-demo.png` | 从同一 renderer 的 `editor.png` 原样复制，备忘录文字来自测试源码 | 同上；不是用户备忘录截图 |
| 代码绘制的 Shape、计时／番茄图形与系统 SF Symbols | 源码绘制或通过 macOS 系统 API 使用，未复制第三方独立素材包 | 属于平台 UI 使用；不要从系统中导出字体／符号包并作为独立资产再分发 |
| 运行时应用图标、歌曲封面、歌词 | 来自本机应用、Music／系统接口或 LRCLIB，不是仓库内静态资产 | 不随仓库分发；分享实际截图前另查权利和私人内容 |
| `output/`、`generated_images/` 中的海报、影片、图标概念和其他设计源文件 | 含生成图、交付记录、本机路径、第三方图形，以及既有实机素材；本次未复核全部宣传内容的权利 | **排除发布**：继续保留在本机并忽略，不用于 README，不上传到 GitHub；未来发布须重新审核 |

本次只新生成项目自身视图的离屏截图，没有进行真实屏幕录制。README 的演示图不是完整功能兼容性或录屏端到端验收的证明。

`DynamicIsland` 名称及文中提到的 Apple、Music、Codex、Claude Code、OpenAI、DeepSeek 等名称用于描述项目或兼容对象，不表示官方关系或背书；若使用品牌标志，应另行满足对应权利方要求。
