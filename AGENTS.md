# AGENTS.md — 给拿到本仓库的 AI

> 如果你是接手这个项目的 AI，**先读这个文件**，再按需深入。这里集中放"不知道就会踩坑"的信息。

## 这个项目是什么

让官方 Codex / ChatGPT 桌面 App 和 CC GUI 通过自建桥接（`api2codex`，`:8787`）访问只支持
Chat Completions 且做渠道校验（11128）的本地网关（`:7863` / `:7864`）。
仓库既能让新机器一键复现安装，也包含官方 App 的完整汉化方案。

## 先读哪个文档

| 你的任务 | 先读 |
|---|---|
| **把官方 App 改成中文** | [`docs/官方桌面App汉化-SOP.md`](docs/官方桌面App汉化-SOP.md) ← 逐步可执行，AI 照做即可 |
| 理解汉化原理/踩坑 | [`docs/官方桌面App.md`](docs/官方桌面App.md)、[`docs/经验总结.md`](docs/经验总结.md) |
| 装整套环境 | [`README.md`](README.md) 快速开始 + `scripts/install.ps1` / `install-bridge.ps1` |
| 桥接协议/提示词中性化 | [`docs/api2codex-bridge.md`](docs/api2codex-bridge.md)、[`docs/why-a-proxy.md`](docs/why-a-proxy.md) |
| 跑验收测试 | `test/` 下 5 个 `.ps1`，README「测试脚本」段有命令 |

## 关于官方 App 汉化（最重要，别重新踩坑）

**结论：能汉化，且已经成功。** 不要再说"只读+签名不可行"——那只是指直接改
WindowsApps 原版；正确做法是用可写副本。三句话记住：

1. **翻译表是现成的**：39772 条简体中文就打在 app.asar 里（`async/1561.*.js`），
   已提取到 `codex-zh/zh-cn-messages.json`。不需要自己翻译。
2. **只解锁开关不够**：核心补丁是 `enable_i18n` 的 Statsig 默认值 `!1→!0`，
   我们实测的成品还叠加了 5793 条 `defaultMessage` 中文补全（双机制）。
   用 `codex-zh/patch.py` 一条命令搞定两者，幂等。
3. **重打包后必须同步 exe 哈希**：Electron 启动会校验 app.asar，不匹配 FATAL。
   integrity 算法离线算不出来，**让 App 启动一次报错、从报错里取 actual，
   用 `codex-zh/sync_exe_hash.py` 写回 exe**。改 exe 前先关 App。

> 不要批量跑全量正则替换 3000+ 文件（试过，慢且脆，被叫停）。用 `patch.py`。

## 代码/脚本约定

- PowerShell 必须能在 **5.1** 下跑（本机无 pwsh 7）。脚本输出**刻意用 ASCII**：
  PS 5.1 把无 BOM 的 `.ps1` 当 GBK，中文字符串会导致解析错误。中文说明放文档里。
- 写 `~/.codex/config.toml` **不能带 BOM**，用 `UTF8Encoding($false)`。
- Python 补丁脚本在 `codex-zh/`，标准库实现，Windows 直接 `python xxx.py` 即可。
- 提交信息用英文（说明原因+验证方式）；文档、交付说明用中文。

## 环境事实（本机 2026-11-17 实测）

- 运行时根目录：`D:\zc-codex-ccswitch\`（`cc-gui\` / `cc-switch\` / `bridge\`）
- 仓库工作副本：`C:\Users\Administrator\.zcode\workspace\draft-c9b55466-d599-41e8-a0f9-1e2e853b591d\zc-codex-ccswitch`
- 桥接 `:8787`，WebUI `:8789`，网关 `:7863`（默认）/ `:7864`（`7864-` 前缀路由）
- 官方 App 汉化副本：`~/.codex/codex-localized/app`，快捷方式「Codex 本地化版」
- git 直连 GitHub 常被重置 → 用 `gh api` 走 Data API 推送（详见 HANDOFF）
