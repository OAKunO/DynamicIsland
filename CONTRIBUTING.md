# 参与开发

先阅读 [README](README.md)、[AGENTS.md](AGENTS.md) 与 [PRIVACY.md](PRIVACY.md)。代码、本项目文档、AppIcon 和已选定的 AI 状态图标采用 [MIT License](LICENSE)，署名为 OAKunO；涉及新素材的提交或再分发请先核实 [素材清单](docs/assets.md)。此前待确认的两个品牌图形已由自定义图标替换。

## 工程结构

| 位置（源码路径相对于 `DynamicIsland/`） | 职责 |
| --- | --- |
| `DynamicIslandApp.swift`、`IslandSessionMonitor.swift` | 应用入口与会话／锁定保护 |
| `ContentView.swift`、`AgentViews.swift`、`ExpandedIslandPager.swift` | 紧凑岛、工作台与展开面板 |
| `WindowManager.swift`、`IslandNotchGeometry.swift`、`IslandLength*.swift` | 窗口定位、刘海避让、布局预算与长度设置 |
| `*StatusMonitor.swift`、`Codex*Reader.swift` | 本地 AI、媒体、电源与设备状态 |
| `ProcessRunner.swift`、`AgentElapsed.swift`、`UnreadCompletionStore.swift` | 后台进程、耗时与未读完成记录 |
| `IslandModel.swift`、`TimeToolsState.swift`、`Notes*.swift` | 时间工具、备忘录状态与界面 |
| `Recording*.swift`、`ScreenRecordingController.swift` | 范围选择、录屏、分段保存与导出 |
| `Tests/`、`scripts/` | 独立 Swift 检查、UI 渲染、本地签名构建 |

Xcode 自动收集 `DynamicIsland/` 下的 Swift 源码。不要因静态引用搜索不到调用就移除动态加载的私有符号、AppleScript、selector 或系统 delegate 入口。

## 构建与验证

按 README 使用每台机器自己的固定本地身份构建。已有身份必须复用，不能通过重新生成或关闭签名绕过问题；已安装应用 Bundle ID 保持 `OAKunO.DynamicIsland`。

```sh
zsh scripts/build-and-install.sh
zsh scripts/run-tests.sh
git diff --check
```

每个 `scripts/run-*-tests.sh` 也可单独运行；共享编译选项和源码组在 `scripts/swift-test-common.sh`。改动对应 UI 时，可运行 `render-notes-ui.sh`、`render-notch-ui.sh` 或 `render-paging-ui.sh`；产物在 `.derivedData/`。

默认自动检查不安装应用、不录制真实屏幕。权限测试注入失败，导出测试使用合成媒体。不要将 `--live` 诊断或真实录屏加入默认测试流程；实机录屏需要明确授权。自动检查不替代真实设备、系统锁屏／解锁、键盘和触控板验收。

## 提交与反馈

- 保留他人的未提交修改，按实际改动选择文件；先检查 staged diff，再提交。
- 修改持久化格式时考虑现有 UserDefaults、备忘录 JSON 和长度迁移兼容性。
- 描述触发条件、改动后的行为、验证环境与已知限制。设计文档应明确标为提案，避免把尚未实现的行为写入功能列表。
- 问题反馈提供 macOS、Xcode、芯片架构、复现步骤和脱敏日志即可。删去任务标题、transcript、设备序列号、用户名、目录、屏幕内容和凭证；不要附完整个人数据库。
- 第三方素材必须记录来源、许可和必要署名；公开可下载不等于允许再分发。未确认的素材状态见 [docs/assets.md](docs/assets.md)。

不要提交 `.derivedData/`、`xcuserdata/`、安装包、私人数据、签名材料或宣传工作目录。`.gitignore` 不会删除已经进入 index 或历史的文件；首次发布另见 [docs/publishing.md](docs/publishing.md)。
