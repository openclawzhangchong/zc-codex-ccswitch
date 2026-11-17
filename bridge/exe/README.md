# CodexBridge.exe — 免源码安装（托盘 + WebUI + 桥接三合一）

不想装 Python、不想改源码的用户/AI，直接用这个exe即可。想自己改再打包的看文末「从源码打包」。

## 它是什么

一个 `CodexBridge.exe` 同时承担三个角色：

| 角色 | 说明 |
|---|---|
| 托盘 | 右下角图标，绿=桥接运行中、灰=停止；菜单可启动/停止/重启桥接、开关机自启、打开管理界面、退出 |
| 管理 WebUI | http://127.0.0.1:8789/ —— 图形化配置网关地址、API Key、模型、多上游路由 |
| 桥接 `:8787` | api2codex：把 Codex 的 Responses API 转成网关的 Chat Completions（含 11128 渠道校验的提示词中性化） |

单文件设计：托盘进程用同一个 exe 加 `--bridge` 参数拉起桥接子进程，因此分发只需一个文件。

## 直接用（推荐）

1. 从本目录下载 `CodexBridge.exe`，放到任意文件夹（例如 `D:\CodexBridge\`）。
   **不要放在 `C:\Program Files` 等需要管理员权限的目录**——它要在同目录写配置。
2. 双击运行。首次运行会在 exe 同级自动创建 `bridge-data\`，里面是通用配置模板
   （**不含任何真实 API Key**，需你自己填）。
3. 右键托盘图标 →「打开管理界面」，浏览器打开 http://127.0.0.1:8789/。
4. 在 WebUI 里把网关地址、API Key、模型改成你自己的，先点「验证」确认 Key 有效，再点切换。
5. 让 Codex CLI / 官方 App 指向 `http://127.0.0.1:8787/v1`
   （按 `../../config/codex-config.toml.template` 写 `~/.codex/config.toml`）。

`bridge-data\` 里的文件：
- `config.json` — 供应商/模型配置（WebUI 读写）
- `.env` — 桥接进程环境变量（上游地址、Key、`SANITIZE_PROMPT=1`）
- `routes.json` — 多上游路由（如 `7864-` 前缀转发到第二个网关）
- `.bridge.pid` / `*.log` — 运行状态与日志

## 开机自启

托盘菜单勾选「开机自动启动」即可（写 `HKCU\...\Run`，指向 exe 自身，无需管理员权限）。

## 从源码打包（想改代码自己来）

```cmd
cd bridge
build-exe.cmd
```

脚本会：建独立 venv → 装依赖 + PyInstaller → 按 `CodexBridge.spec` 打包 → 输出
`bridge\exe\CodexBridge.exe`。需联网（首次装依赖）、Python 3.10+。

源码入口是 `bridge_app.py`（统一入口），改造后的 `tray.py` / `webui.py` / `api2codex.py`
通过环境变量 `BRIDGE_DATA_DIR` 区分「源码目录」和「exe 的 bridge-data 目录」——
源码模式（直接 `python bridge_app.py`）行为与打包前完全一致。

## 常见问题

- **双击没反应 / 托盘没出现**：看 `bridge-data\tray-error.log`。多半是端口被占用或配置损坏。
- **WebUI 打不开**：托盘菜单点「打开管理界面」会先启动它；或看 `bridge-data\webui-tray.log`。
- **桥接连不上网关**：确认网关（如 :7863）在跑、Key 正确、`.env` 里 `SANITIZE_PROMPT=1`。
- **换端口**：WebUI 里改 config.json 的 `port`，或 `.env` 的 `PORT`（两者要一致）。
- **杀毒软件报毒**：PyInstaller onefile 偶有误报；`spec` 里已关闭 UPX 压缩降低误报，
  仍报的话可加白名单或从源码打包。
