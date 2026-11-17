# zc-codex-ccswitch

> 🎉 **重大发现（2026-11-16）**：官方 **ChatGPT 桌面 App（包名 `OpenAI.Codex`）原生读取同一份
> `~/.codex/config.toml`** —— 我们的桥接 `127.0.0.1:8787` 被官方 App 直接使用，非官方模型
> 对话成功，历史会话多端共享（CLI / 官方 App）。详见
> [`docs/官方桌面App.md`](docs/官方桌面App.md)。

> 📖 **文档网站**：<https://openclawzhangchong.github.io/zc-codex-ccswitch/>
> 📦 **代码仓库**：<https://github.com/openclawzhangchong/zc-codex-ccswitch>

**双击一个 exe 装好桥接（托盘 + 管理界面 + 协议转换三合一），一条命令汉化官方桌面 App**，
让 Codex CLI / 官方桌面 App 接上你的自建网关。

```
官方桌面 App / Codex CLI  →  CodexBridge.exe (:8787 桥接 + :8789 管理界面)  →  你的网关
                              Responses ↔ Chat 转换 + 提示词中性化
```

> ⚠️ **旧三件套路线已移除（2026-11-17）**：`scripts/install.ps1`（CC GUI + CC Switch + CLI
> 三件套安装器）、`scripts/install-bridge.ps1`（克隆上游源码建桥）等旧脚本已删除。
> 它们把组件装到 `%LOCALAPPDATA%` 并依赖 CC Switch，与现在的 exe 路线冲突、容易误导。
> 需要考古可从 git 历史找回（`git log -- scripts/`）。**新机器一律走下面的 exe 路线。**

---

## 为什么需要这个项目

Codex 0.169 **移除了 `wire_api = "chat"`**，只支持 Responses API。但大多数自建网关只提供 `/v1/chat/completions`，导致 Codex 直接报 404。

更麻烦的是，有些网关会按 Codex 系统提示词做渠道校验，不匹配就返回 `11128 Illegal API invocation from an unapproved channel`，随后账号进入冷却（503）。

所以本项目采用 **api2codex 协议转换 + 提示词中性化补丁**，打包进一个零依赖的
[`CodexBridge.exe`](bridge/exe/README.md)。

> 详细原理见 [`docs/why-a-proxy.md`](docs/why-a-proxy.md) 和 [`docs/api2codex-bridge.md`](docs/api2codex-bridge.md)（含历史方案，仅作考古）。

---

## 三种网关对应的方案

| 你的网关 | 应该用什么 |
|---|---|
| 原生支持 `/v1/responses` | 不用桥接，`config.toml` 的 `base_url` 直接指过去 |
| 只有 Chat Completions，**不**校验渠道 | `CodexBridge.exe`，WebUI 里关掉提示词中性化 |
| 只有 Chat Completions，**会**校验渠道（`11128`） | `CodexBridge.exe`，WebUI 里开启提示词中性化（默认开） |

---

## 🖥️ 官方桌面 App 已验证可用

`codex app` 会打开 Microsoft Store 安装器（Store 显示名 **ChatGPT**，实际包名
**`OpenAI.Codex`**，当前版本 26.1111.2228.0，自动下载约 1GB，无需交互确认）。

安装后官方 App **直接使用本项目的桥接**：

- 左下角 provider 显示 config.toml 里的 name（如 `Bridge (api2codex)`）
- 默认模型 = config.toml 的 `model`，对话成功（**须在 Codex 模式下**；ChatGPT Work 模式不走本地 provider）
- 历史会话与 CLI 完全共享（同一 `~/.codex` 会话存储）
- 模型选择器读 `model_catalog_json` 指向的静态文件——**WebUI 切换上游时会自动按新上游的
  `/v1/models` 重建这份目录**，重启 App 后选择器即为新网关的模型列表

**界面中文化（已实现 ✅）**：官方 App 自带完整简体中文翻译表但语言开关
`enable_i18n` 默认关闭，本项目在可写副本里**只改这一处开关**（`!1→!0`），
官方前端即自动加载自带翻译，全中文——菜单（文件/编辑/视图/帮助）、侧栏（新对话/
定时任务/插件/项目/最近）、主界面（我们要构建什么？）全部中文。**不需要批量替换文案。**

> **要让新机器也汉化 / 你也是接手的 AI？** 直接照
> [`docs/官方桌面App汉化-SOP.md`](docs/官方桌面App汉化-SOP.md) 逐步执行
> （核心就 1 处 bool，等长原位补丁 + 离线同步 asar/exe 哈希，不解包/不重打包）；
> 脚本在 [`codex-zh/`](codex-zh/)（`install.ps1` 一键、`patch_inplace.py` 原位补丁）；原理与踩坑见
> [`docs/官方桌面App.md`](docs/官方桌面App.md)。

**已知限制**：ChatGPT 侧的 *Computer use* 被区域/账号灰度禁用（`Disabled by your
organization or unavailable in your region`），与桥接无关，不做客户端破解。

启动方式：安装后运行 `codex app`，或从开始菜单启动 ChatGPT/Codex；中文版用桌面
快捷方式「Codex 本地化版」。

---

## 环境要求

- Windows 10 1803+ / Windows 11（x64）
- **桥接（exe 路线）：零依赖**，不需要 Python / Node
- 汉化官方 App：Python 3.8+（仅打补丁用）：<https://www.python.org/>
- Codex CLI（可选）：Node.js 22+：<https://nodejs.org/>
- 自己改源码/打包：Python 3.10+
- 一个 OpenAI 兼容网关（地址、API Key、模型名）

---

## 快速开始

1. **下载并双击 [`bridge/exe/CodexBridge.exe`](bridge/exe/README.md)**（放到任意目录，
   建议 `D:\CodexBridge\`）。首次运行在 exe 旁生成 `bridge-data\` 配置模板（不含真实 Key），
   托盘图标出现，桥接(:8787)和管理界面(:8789)自动启动。
2. **浏览器打开 <http://127.0.0.1:8789/>**：添加上游（地址 / API Key / 模型名）→
   点「**验证**」确认 Key 有效 → 点「切换」启用。切换会自动重写 `.env`、`routes.json`、
   `~/.codex/config.toml` 的 `model` 行和模型目录，并重启桥接。
3. **首次使用**按 [`config/codex-config.toml.template`](config/codex-config.toml.template)
   把 `~/.codex/config.toml` 的 provider 指向 `http://127.0.0.1:8787/v1`（之后 WebUI 只同步
   `model` 行，不动你其他设置）。
4. **验收**：

```powershell
powershell -ExecutionPolicy Bypass -File .\test\test-bridge.ps1 -Model 你的模型名
```

5. **（可选）汉化官方桌面 App**：

```powershell
powershell -ExecutionPolicy Bypass -File .\codex-zh\install.ps1
```

---

## 托盘与管理界面

### 托盘图标

`CodexBridge.exe` 双击即托盘（源码方式为 `bridge/tray.py`）。绿点代表桥接运行中，灰点代表停止。

- **左键**：打开管理界面
- **右键菜单**：启动 / 停止 / 重启桥接、开机自动启动、退出

托盘启动时会自动拉起桥接和 WebUI，开机自启只需在菜单勾选一次（写一条 `HKCU\...\Run`）。
托盘从任意工作目录都能启动，PID 文件会如实记录桥接进程。

### Web 管理界面

浏览器打开 <http://127.0.0.1:8789/>：

- 每个上游一张卡片，当前使用的会高亮
- 添加 / 编辑 / 删除 / 切换上游
- **验证**：对上游发一次带 Key 的 `/v1/models` 请求，直接告诉你 Key 是否有效
  （401/403 = Key 无效）、地址是否可达、模型名是否在上游列表里。添加/编辑弹窗里也能先验证再保存
- 提示词中性化开关
- 连接信息

切换上游会重写 `.env`、`routes.json`、`~/.codex/config.toml` 的 `model` 行，
**并按新上游的模型列表重建 `model_catalog_json` 目录文件**，然后重启桥接。

> 注意：api2codex 只在启动时读配置，所以切换需要重启（WebUI 自动做）。桥接会把请求里的
> `model` 原样转发——**同一网关的多个模型可以同时使用**，用 `-m` 或 `/model` 切换即可，
> 不必改配置。跨网关可用 `routes.json` 的前缀路由（`前缀/模型名`），`/v1/models` 会合并列出。

---

## 模型切换

```powershell
# 方式 1：CLI 临时指定（不改任何配置）
codex exec -m 模型A "问题"
codex exec -m 模型B "问题"

# 方式 2：WebUI 点「切换」（换网关/换默认模型）
# 方式 3：改 ~/.codex/config.toml 的 model 行
```

同一网关的多个模型共用地址和 Key，桥接层无需改动。官方桌面 App 的模型选择器
在 WebUI 切换后**重启 App** 即刷新。

---

## 源码方式（开发者）

不想用 exe、要改代码：`bridge/` 下是全部源码（api2codex 桥接 + 补丁、config_store、
webui、tray）。建 venv 装 `fastapi uvicorn httpx pystray Pillow` 后运行
`python bridge_app.py`（统一入口，首启自动播种配置；**不要直接跑 tray.py**，会跳过播种）。
改完用 `bridge/build-exe.cmd` 重新打包出 `bridge/exe/CodexBridge.exe`
（详见 [exe 说明](bridge/exe/README.md)）。

---

## 测试脚本

全部脚本在 `test/` 目录，**已在本机实测通过**。

| 脚本 | 作用 |
|---|---|
| `test-bridge.ps1` | 桥接健康检查：`/health`、`/v1/models`、`/v1/responses` |
| `test-tray.ps1` | 托盘与自启：从 `C:\` 启动、PID 一致性、WebUI 重启 |
| `test-no-flicker.ps1` | 黑窗闪烁采样检测 |
| `test-e2e.ps1` | 全链路端到端：CLI + 桥接 + 工具调用 + WebUI |
| `test-desktop-app.ps1` | 官方桌面 App：进程/配置/桥接指向检查 |

```powershell
powershell -ExecutionPolicy Bypass -File .\test\test-bridge.ps1 -Model 你的模型名
powershell -ExecutionPolicy Bypass -File .\test\test-no-flicker.ps1 -Seconds 10
powershell -ExecutionPolicy Bypass -File .\test\test-e2e.ps1
```

> 脚本输出刻意使用 ASCII：Windows PowerShell 5.1 把无 BOM 的 `.ps1` 当 GBK 读取，中文输出字符串会导致解析错误。中文说明都放在文档里。

---

## 常见问题

### `404 ... /v1/responses`
网关只有 Chat Completions，却把 `base_url` 直接指给了网关。让 Codex 指向桥接
`http://127.0.0.1:8787/v1`，由桥接做协议转换。

### WebUI「验证」报 Key 无效（HTTP 401/403）
Key 本身不对——常见错误是把账号 ID / QQ 号当成了 API Key。去网关后台重新生成或复制
真正的 Key。验证功能就是为在切换前拦住这种错误而加的。

### `11128 Illegal API invocation from an unapproved channel`
网关按提示词指纹拦截非官方客户端。开启 WebUI 的提示词中性化。请确认你有授权使用该网关。

### `wire_api = "chat" is no longer supported`
Codex 0.169 已移除该选项，不要试图设置，改用 Responses + 协议转换。

### 官方 App 模型选择器还是旧网关的模型
选择器读静态 `model_catalog_json` 文件。用新版 WebUI 切换会自动重建它；改完后**重启 App**。

### 出现周期性黑窗
检查 `_run_hidden()` 是否对 `tasklist`/`taskkill`/`wmic` 传了 `CREATE_NO_WINDOW`。用 `test-no-flicker.ps1` 验证。

### 旧会话报 provider 不存在
会话绑定创建时的 provider。新建会话即可，旧会话按设计保留。

更多问题见 [`docs/经验总结.md`](docs/经验总结.md)。

---

## 目录结构

```
CHANGELOG.md                       更新日志
README.md                          本文档
config/codex-config.toml.template  Codex 配置模板
bridge/exe/CodexBridge.exe         三合一成品（托盘+WebUI+桥接）
bridge/build-exe.cmd               一键打包 exe
bridge/api2codex.py                桥接本体（含提示词中性化补丁）
bridge/config_store.py             供应商配置（JSON 原子写）
bridge/webui.py                    管理 API（含 Key 验证、目录同步）
bridge/webui.html                  管理页面
bridge/tray.py                     Windows 托盘
codex-zh/install.ps1               官方 App 汉化一键安装
codex-zh/patch_inplace.py          等长原位补丁（1 bool + 哈希同步）
test/*.ps1                         测试脚本
docs/why-a-proxy.md                协议断层原理
docs/api2codex-bridge.md           桥接方案与补丁（含历史方案）
docs/官方桌面App.md                官方 App 接入与汉化原理
docs/官方桌面App汉化-SOP.md        汉化标准操作流程
docs/经验总结.md                   踩坑与经验
```

---

## 本机实际安装位置（2026-11-17 实测）

```
D:\CodexBridge\
  ├─ CodexBridge.exe     三合一成品（托盘+WebUI+桥接）
  └─ bridge-data\        config.json + .env + routes.json + PID 文件
```

- 开机自启注册表项 `CodexBridgeTray` 指向 `D:\CodexBridge\CodexBridge.exe`
- 汉化副本：`~/.codex/codex-localized/`，桌面快捷方式「Codex 本地化版」
- Codex 配置与数据：`~/.codex/`
- 旧三件套（CC GUI / CC Switch / C 盘旧桥）已于 2026-11-17 清除

> 若手动启动源码版托盘，不要用 `Start-Process -WindowStyle Hidden`——这会让 pystray 进程退出。注册表 Run 项本身不带此参数，开机自启正常。

---

## 校验与版本

- exe 由 `bridge/build-exe.cmd` 从本仓库源码构建（PyInstaller，依赖版本在脚本内固定）。
- 汉化补丁自带离线校验：`codex-zh/install.ps1 -DryRun` 检查副本状态；`patch_inplace.py`
  锚点不匹配即报错退出，不会盲改。
- Codex CLI 用精确版本号安装（`@openai/codex@0.169.0`），由 npm 注册表保证完整性。

当前版本：Codex CLI `0.169.0` / 官方桌面 App `26.1111.2228.0` / api2codex（MIT）。

许可证见 [LICENSE](LICENSE)。