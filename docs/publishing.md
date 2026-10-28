# GitHub 发布与预构建版本

本文记录源码发布、下载版本与后续维护步骤。维护者已确认采用 MIT、版权署名 OAKunO，选择独立的干净源码快照，并于 2026-10-28 明确授权公开到 `OAKunO/DynamicIsland`。源码仓库已公开；当前新增已验证的预构建应用和下载说明。发布提交采用 GitHub 隐私署名，避免公开私人邮箱。项目未上架 Mac App Store。

## 下载版本

- 首个可下载预览版：[v1.0.0-preview.1](https://github.com/OAKunO/DynamicIsland/releases/tag/v1.0.0-preview.1)，应用版本 1.0（build 1），架构 arm64。
- Release 资源为 `DynamicIsland-1.0-arm64.zip` 与 `DynamicIsland-1.0-arm64.zip.sha256`。运行无需 Xcode；下载与安装说明见 [README](../README.md)。
- 应用已通过 Developer ID Application 签名、Apple 公证、公证票据、Gatekeeper 和 ZIP 解压复验；包内提供 MIT License、安装说明与 Applications 链接。
- SHA-256：`3b72b7a082b0c299f4fe87e6c36201667ff696b12b3f468e6a35572936058787`。
- 最低部署版本 macOS 26.5 尚未实机验收；已验证构建环境为 macOS 27.0.1 / Xcode 27.0。Intel / Universal，以及另一台无 Xcode 的 Mac 上的完整运行验收尚未完成；其他限制见 README。
- 应用构建源码基线为 `b513b09dcce00a537845580abbb41cd9685d559a`；下载说明是之后独立的文档更新，没有改变已公证应用。本次没有进行真实屏幕录制。

下载版使用发布者的 Developer ID 身份，本机维护的开发安装版本仍遵守 [AGENTS.md](../AGENTS.md) 的固定本地身份和安装流程。私钥只在钥匙串中使用，不提交、不打印、不随包提供；不删除或重建已有的本地开发身份。签名证书会显示开发者账号的姓名或组织名，发布前同时核对证书和包内文件不含私人邮箱。

`.xcarchive`、`.dSYM`、证书、CSR、钥匙串、账号凭证和构建日志不作为下载资源上传。准备阶段文件名含 local-preview 或 awaiting-notarization 的候选产物不代表最终公证包，不发布为正式下载。发布后须从公开地址下载资源，复核大小、SHA-256、版本与 README 链接；不要仅凭本地文件名或上传成功提示判断完整性。

## 已确认事项

- 发布账号为 `OAKunO`，仓库为 `OAKunO/DynamicIsland`，可见性为 `public`；首次创建时通过已登录浏览器核实账号、名称及写入权限。
- 已添加 [MIT License](../LICENSE)：`Copyright (c) 2026 OAKunO`。AppIcon 及维护者选定的 AI 自定义状态图标纳入许可和候选暂存，详见 [assets.md](assets.md)。
- 此前待确认的两个品牌图形已用自定义「代码火花」与「蓝色放大镜」替换，旧文件退出应用资源。新提交须使用 GitHub 隐私署名，不沿用本机私人邮箱；通过网页提交时应先确认邮箱隐私开关已启用。
- 原始开发仓库的历史、index 和既有源码修改保留在本机；旧提交包含的个人邮箱、Xcode 用户配置及本地 checkpoint refs 不复制进快照。

## 独立的本地快照

发布副本位于原开发仓库的同级目录 `DynamicIsland-public/`，分支名为 `main`。它独立建立并与新 GitHub 仓库关联，没有复制原开发仓库的 `.git`、历史、reflog 或 refs。

快照只复制当前源码、工程、测试、脚本、文档和候选资源。构建产物、宣传工作目录、签名材料、私人数据和 `xcuserdata` 不复制。创建时应检查每个候选路径与文件哈希，不递归复制整个开发目录。

本地草稿包含维护者确认可公开的 10 个 AppIcon PNG，以及 AI 生成的两个自定义状态图标。旧 OpenAI PNG 和 DeepSeek SVG 仅保留于原开发仓库被忽略的备份目录，不存在于快照工作树、index 或新对象库；此前针对这两个旧路径的本地暂存排除已清除。新图形的 prompts 与来源记录一并纳入候选。

审核过的文件使用 GitHub 隐私署名创建新的提交，避免把私人邮箱写入新历史。MIT 版权署名与账号权限是独立事项，发布前仍应核对当前登录账号及目标仓库。

原始开发仓库没有被重置、过滤、amend 或 force push，其 index 不因建立快照而变化。原仓库历史中的私人信息继续仅留在本机。发现真实凭证泄露时，还应先撤销／轮换凭证，单纯删除文件不足以修复。

## 发布前复查

1. 在 `DynamicIsland-public/` 中复核已替换的素材，并确认 GitHub 账号与公开提交邮箱；检查最终的 `git diff`、`git diff --cached` 和待新增文件清单。
2. 使用确认后的公开署名／邮箱创建新的初始提交。检查选定分支可达的全部提交、已删除文件及 author／committer 元数据，确认没有原开发仓库历史或本地 `refs/codex/`。
3. 确认 `.derivedData/`、`output/`、`generated_images/`、证书私钥、私人数据与 Xcode 用户状态未进入公开快照。不要仅依赖 `.gitignore`，应检查 `git ls-files` 和实际历史。
4. 运行 `zsh scripts/run-tests.sh`、`zsh scripts/build-and-install.sh` 与 `git diff --check`；需要截图时只使用审核过的样例 renderer。日志可能含本机路径，不直接上传原始日志。
5. 通过已连接的 GitHub 工具、已登录的浏览器，或 GitHub CLI 核实账号、remote 与目标仓库的存在／可见性。CLI 可使用 `gh auth status`、`gh api user --jq .login`；网页提交须启用邮箱隐私。不要输出 token 或读取 `gh auth token`。
6. 给维护者一份最终摘要：账号／仓库名／可见性、具体提交与文件、License、未解决风险、检查结果。**拿到明确公开确认后再执行下面的外部写入步骤。**

## 仅供确认后执行的命令模板

以下命令没有在本次准备中执行。应在最终选定的发布仓库目录运行；先核实 staged 文件并创建维护者已确认的提交，再填入经登录验证的账号。

```sh
# 确认登录账号为维护者指定的 OAKunO，并核实目标路径。
gh auth status
gh api user --jq .login
git status --short --branch
git remote -v
git log --oneline main

# 仅当目标仓库尚不存在、origin 未配置且已明确批准公开时：
github_owner='OAKunO'
gh repo create "${github_owner}/DynamicIsland" --public --source=. --remote=origin

# 创建成功后复查，再显式只推 main：
gh repo view "${github_owner}/DynamicIsland" --json nameWithOwner,visibility,url
git push -u origin main
```

若仓库或 remote 已存在，应先读其实际状态，不覆盖 origin，不擅自把 private 改 public。不要使用 `git push --mirror`、`--all` 或推送本地 `refs/codex/*`。网页上传同样只使用审核过的文件；发布后应逐文件核对远端内容，并确认所有新提交使用隐私邮箱。不得以已选 MIT 或已建立本地快照作为公开发布的授权。
