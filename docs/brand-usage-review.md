# OpenAI / DeepSeek 图标条款核验

核验日期：2026-10-28。本文保留替换前的官方条款核验。维护者随后选定 AI 生成的 C1「代码火花」与 D1「蓝色放大镜」，已将原 OpenAI PNG 与 DeepSeek SVG 移出应用资源和公开快照，来源记录见 [generated-status-icons.json](generated-status-icons.json)。未取得品牌方单独授权，也未联系品牌方；公开源码不包含这两个旧品牌图形。

## 本次结论

| 素材 | 状态 | 本地快照处理 |
| --- | --- | --- |
| AppIcon 的 10 个 PNG | 维护者已确认由 AI 生成并允许公开，来源依据为维护者于核验日期的明确确认 | 纳入候选暂存，随项目 MIT 许可提供 |
| 原 `OpenAIStatusIcon.imageset/openai-status.png` | 官方有条件允许品牌使用；原文件的来源与随源码再分发范围未核实 | **已移除并替换**；旧文件只留在忽略的本地备份 |
| 原 `DeepSeekStatusIcon.imageset/deepseek-status.svg` | 未查到明确覆盖原 SVG 的公开再分发授权 | **已移除并替换**；旧文件只留在忽略的本地备份 |
| C1「代码火花」与 D1「蓝色放大镜」 | 由 AI 生成，维护者明确选择用于应用和快照 | 作为项目自定义状态标识随 MIT 许可提供并暂存 |

“有条件使用品牌”与“将图标文件按 MIT 交给他人自由修改、销售或再许可”不是同一授权范围。以下将官方条款与本项目判断分开记录；未找到明确授权，不等于已判定所有法域下的相关使用都被禁止。

## OpenAI

官方依据：[Design Guidelines — How to use our Logos / Usage terms / Contact](https://openai.com/brand/)。页面公开提供品牌使用条件与 logo 下载入口，完整品牌门户目前需要登录。

- 图标用途须直接关联 OpenAI 服务，使用官方提供的原样，保留规定留白并承认归属；不得修改、用于自身主品牌或暗示官方背书。
- 品牌许可为非独占、不可转让，可被撤回；品牌方可要求调整。
- 该页面没有明确说明第三方可以把原图文件随公开源码仓库独立再分发，也没有授予本项目以 MIT 再许可图标的权利。

**替换前判断**：用作 Codex 状态标识具有服务关联性，但仍不能据此确认原 PNG 可随库分发。原始来源未建立，原图也曾用于改变透明度与缩放的状态动画。现在该文件已移除，`CodexWorkingIcon` 使用项目自定义「代码火花」；本项目未把旧品牌图形标成已获授权。

如保留图标，需核对官方原文件与当前版本，并获得对源码／应用内打包分发范围的明确依据。官方品牌许可咨询地址见上述 Contact：`partnercomms@openai.com`；本次未发送邮件。

## DeepSeek

与本项目集成对象直接相关的官方依据为 [DeepSeek Harness 用户协议](https://www.deepseek.com/harness/terms-of-use/)第“一、通用条款／4.知识产权和其他权利”（[英文版](https://www.deepseek.com/en/harness/terms-of-use/)，页面更新日期 2026-09-20）。其中第（1）项承认法律及开源协议另行授予的权利，第（2）项对未经许可使用 logo 等品牌标识作出限制。通用服务的 [Terms of Use](https://cdn.deepseek.com/policies/en-US/deepseek-terms-of-use.html)第 6.2 条也有相应规定。

[Harness 官方品牌素材使用规范](https://github.com/deepseek-ai/deepseek-harness/blob/master/BRAND_GUIDELINES.zh.md)允许在描述文字中如实说明兼容关系，并要求避免造成背书、合作或授权误解；没有明确列出当前鲸鱼 SVG 的复制／再分发许可。

官方 Harness 仓库采用 [MIT](https://github.com/deepseek-ai/deepseek-harness/blob/master/LICENSE)。**本项目判断**：当前 SVG 的来源与该仓库授权范围尚未建立对应，不能把代码采用 MIT 直接当作当前图标的品牌授权，也不能将“未暗示背书”当成已获得图标文件再分发许可。

如保留图标，需要明确覆盖本项目显示、源码副本、应用打包及下游使用的依据。可通过[官网](https://www.deepseek.com/)公开的 `service@deepseek.com` 咨询；本次未发送消息。

## 后续处理

两个第三方图形已通过替换退出应用资源与公开候选，原有授权缺口不再阻塞当前素材。若未来恢复使用，应先记录原文件来源、允许范围、必要署名及适用限制；本次生成的自定义图标不表示官方关系或背书。

素材状态总表见 [assets.md](assets.md)。GitHub 账号、公开提交邮箱与明确的发布确认仍待落实，当前不创建提交或 remote。
