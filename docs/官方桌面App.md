# 官方桌面 App 已验证兼容桥接

> 2026-11-16 的重大突破。结论先行：**官方 ChatGPT 桌面 App（内含 Codex 桌面端）
> 原生读取 `~/.codex/config.toml`，本项目的桥接无需任何改造即被官方 App 直接使用。**

## 结论

| 验证点 | 结果 |
|---|---|
| 官方 App 显示 provider | `Bridge (api2codex)`（config.toml 的 `name`） |
| 默认模型 | `hy4flash-free`（config.toml 的 `model`），对话成功 |
| 模型目录 | 走 `model_catalog_json`（29 个模型：7863 原名 + 7864 前缀） |
| 历史会话 | 与 CLI / CC GUI **三端共享**（同一 `~/.codex` 会话存储） |
| 是否必须 CC GUI | 否——桥接让官方 App 也成为可用桌面端 |

## 安装方式

```powershell
codex app
```

CLI 检测到桌面 App 缺失时输出：

```
Desktop app not found; opening Windows installer...
After installing the Desktop app, open workspace <你的工作区>.
```

随后弹出 **Microsoft Store** 安装器并**自动开始下载**（无需点击确认）：

- Store 显示名：**ChatGPT**（OpenAI）
- 实际包名：**`OpenAI.Codex`**（x64）
- 实测版本：26.1111.2228.0
- 包大小约 1008 MB，实测下载到 95% 约需几分钟
- 安装位置：`C:\Program Files\WindowsApps\OpenAI.Codex_<版本>_x64__2p2nqsd0c76g0\`

安装完成后可用 `codex app` 启动，或从开始菜单启动 ChatGPT/Codex。

## 原理

官方桌面 App 与 Codex CLI 同源：都读取 `~/.codex/config.toml`，都通过
`model_provider` 指向的上游发送 Responses 请求。本项目桥接恰好提供标准
Responses 端点（`http://127.0.0.1:8787/v1`），因此：

```
官方桌面 App  ─┐
CC GUI         ├─→  api2codex 桥接 (:8787)  →  网关 7863 / 7864
Codex CLI      ┘        Responses ↔ Chat + 提示词中性化
```

三个客户端共用一份 config.toml、一份会话存储、一份模型目录。

## 已知限制

### Computer use 被禁用（与桥接无关）

App 设置里的 *Computer use*（让 ChatGPT 驱动本机应用，如 Google Chrome）显示：

> Disabled by your organization or unavailable in your region

这是 OpenAI **云端功能**的区域/账号限制——官方 App 的 ChatGPT 部分需要 OpenAI
账号体系，该功能按区域灰度。**Codex 本地功能（桥接对话、工作区、会话）完全不受影响。**

### 其他观察

- 官方 App 与 CC GUI 可以共存，互不冲突（不同进程、不同数据目录——CC GUI 有自己的
  会话管理，但历史会话都来自 `~/.codex`）
- `model_catalog_json` 生效：模型选择器列出 29 个模型（含 `7864-` 前缀）
- 提示词中性化（`SANITIZE_PROMPT=1`）对官方 App 同样生效——App 发送的提示词同样
  会被 7863 的渠道指纹拦截，桥接已统一改写

## 界面语言（实测结论）

官方 App **自带 Language 设置**：Settings → General → Language（App UI 语言），
下拉可选简体中文 / 繁體中文（台灣/香港）等，选择会持久化。

**但实测：把 Language 设为「简体中文」并重启后，Codex 业务界面（New chat /
Scheduled / Plugins / Recents / What should we build?）仍是英文。**

原因（已核实）：
- App 是 Chromium 内核打包（chrome.dll 336MB + 220 个语言包，含 zh-CN.pak），
  但 zh-CN.pak 只覆盖框架层文案（右键菜单、系统对话框）
- Codex 业务界面的文案在前端资源（app.asar）里，当前版本**没有中文翻译**
- `--lang=zh-CN` 启动参数同样无效（只影响框架层）

**无法安全汉化**：App 装在 `C:\Program Files\WindowsApps\`，实测写入被拒——
该目录由 TrustedInstaller 保护且有 Store 签名校验（AppxSignature.p7x），
修改 app.asar 会破坏签名导致 App 无法启动。等官方补全中文是唯一正路。

## Computer use 为什么是灰的（不破解）

App 内 *Computer use*（让 ChatGPT 驱动本机应用，如 Chrome）显示
`Disabled by your organization or unavailable in your region`。

**这是 OpenAI 服务端的区域/账号灰度，不做客户端破解**，三个理由：

1. 这类功能开关通常在服务端二次校验——客户端强开大概率被服务端拒绝，白做
2. 绕过 OpenAI 的区域访问控制违反其服务条款
3. 有现成的合法替代

**替代方案（本机已具备）**：

| 需求 | 用什么 |
|---|---|
| 操控本机应用（GUI 自动化） | CC GUI 自带的 computer-use 驱动（`ccgui-computer-use.exe`） |
| 浏览器自动化 | ZCode 的 browser-use；Codex CLI 的 `browser_use` 特性也是 stable |
| 网关对话 | 官方 App / CC GUI / CLI 三端走同一桥接 |

另外，7864 网关实测**没有** 11128 渠道指纹校验，是更干净的上游。

## 与 CC GUI 的取舍

| | 官方桌面 App | CC GUI |
|---|---|---|
| Codex 功能深度 | ✅ 官方一等公民，随 CLI 同步 | 需等第三方适配 |
| 多引擎（Claude/Gemini…） | ❌ 仅 Codex | ✅ |
| 中文界面 | ❌ | ✅ |
| 供应商/渠道管理 UI | ❌ 需手写配置 | ✅ WebUI |
| 网关兼容 | ✅（经桥接） | ✅（经桥接） |
| Computer use | ❌ 区域禁用 | —（无此功能） |

**建议**：主用 CC GUI（中文 + 多引擎 + 管理 UI），需要官方最新功能时用官方 App。
两者共享同一桥接与会话，可随时切换。
