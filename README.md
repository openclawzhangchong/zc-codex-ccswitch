# zc-codex-ccswitch

> 📖 **文档网站**：<https://openclawzhangchong.github.io/zc-codex-ccswitch/>
> 📦 **代码仓库**：<https://github.com/openclawzhangchong/zc-codex-ccswitch>

在一台全新的 Windows 电脑上，一条命令装好 **Codex CLI + CC GUI 桌面端 + CC Switch**，并打通自建网关。

```
CC GUI 桌面端  →  Codex CLI  →  api2codex 桥接 (:8787)  →  你的网关 (:7863)
                                Responses ↔ Chat 转换 + 提示词中性化
```

---

## 为什么需要这个项目

Codex 0.169 **移除了 `wire_api = "chat"`**，只支持 Responses API。但大多数自建网关只提供 `/v1/chat/completions`，导致 Codex 直接报 404。

更麻烦的是，有些网关会按 Codex 系统提示词做渠道校验，不匹配就返回 `11128 Illegal API invocation from an unapproved channel`，随后账号进入冷却（503）。

CC Switch 的路由能做协议转换，但**它不改写请求体**，过不了渠道校验。所以本项目采用 **api2codex + 提示词中性化补丁** 的方案。

> 详细原理见 [`docs/why-a-proxy.md`](docs/why-a-proxy.md) 和 [`docs/api2codex-bridge.md`](docs/api2codex-bridge.md)。

---

## 三种网关对应的方案

| 你的网关 | 应该用什么 |
|---|---|
| 原生支持 `/v1/responses` | 只装 Codex CLI + CC GUI，`base_url` 直接指过去，无需代理 |
| 只有 Chat Completions，**不**校验渠道 | `install.ps1` + CC Switch 路由（Upstream format 设为 Chat Completions） |
| 只有 Chat Completions，**会**校验渠道（`11128`） | `install-bridge.ps1`（本项目推荐的完整方案） |

---

## 环境要求

- Windows 10 1803+ / Windows 11（x64）
- Node.js 22+（仅 Codex CLI 需要）：<https://nodejs.org/>
- 若要装桥接：Python 3.10+：<https://www.python.org/>
- 一个 OpenAI 兼容网关（地址、API Key、模型名）

---

## 快速开始

在仓库根目录打开 PowerShell：

```powershell
# 1. 安装全部组件
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1

# 2. 安装桥接（带提示词中性化，应对 11128 渠道校验）
powershell -ExecutionPolicy Bypass -File .\scripts\install-bridge.ps1 `
    -BaseUrl http://127.0.0.1:7863/v1 -ApiKey sk-xxx `
    -Model deepseek-v4.1-flash -Start

# 3. 完整验收测试
powershell -ExecutionPolicy Bypass -File .\test\test-e2e.ps1
```

`install-bridge.ps1` 会：克隆 api2codex（MIT）→ 精确锚点打补丁（上游变化会报错）→ 建虚拟环境 → 写 `.env` → 生成 `start-bridge.cmd` → 改写 `~/.codex/config.toml` → 可选启动。

---

## 桌面端与管理界面

### 托盘图标

运行 `bridge/tray.py`（`pythonw` 无控制台）。绿点代表桥接运行中，灰点代表停止。

- **左键**：打开管理界面
- **右键菜单**：启动 / 停止 / 重启桥接、开机自动启动、退出

托盘启动时会自动拉起桥接和 WebUI，所以开机自启只需在菜单勾选一次（写一条 `HKCU\...\Run`）。托盘从任意工作目录都能启动，PID 文件会如实记录桥接进程。

### Web 管理界面

浏览器打开 <http://127.0.0.1:8789/>：

- 每个上游一张卡片，当前使用的会高亮
- 添加 / 编辑 / 删除 / 切换上游
- 提示词中性化开关
- 连接信息

切换上游会重写 `.env` 和 `~/.codex/config.toml`，并重启桥接。

> 注意：api2codex 只在启动时读配置，所以切换需要重启。当前是「单点切换」，因为桥接会把请求里的 `model` 原样转发——**同一网关的多个模型其实可以同时使用**，用 `-m` 或 `/model` 切换即可，不必改配置。

---

## 模型切换

```powershell
# 方式 1：CLI 临时指定（不改任何配置）
codex exec -m hy4flash-free "问题"
codex exec -m deepseek-v4.1-flash "问题"

# 方式 2：WebUI 点「切换」
# 方式 3：改 ~/.codex/config.toml 的 model 行
```

两个模型共用同一个网关地址和 Key，所以桥接层无需改动。

---

## 测试脚本

全部脚本在 `test/` 目录，**已在本机实测通过**。

| 脚本 | 作用 |
|---|---|
| `test-bridge.ps1` | 桥接健康检查：`/health`、`/v1/models`、`/v1/responses` |
| `test-tray.ps1` | 托盘与自启：从 `C:\` 启动、PID 一致性、WebUI 重启 |
| `test-no-flicker.ps1` | 黑窗闪烁采样检测 |
| `test-e2e.ps1` | 全链路端到端：CLI + 桥接 + 工具调用 + WebUI |

```powershell
powershell -ExecutionPolicy Bypass -File .\test\test-bridge.ps1  -Model hy4flash-free
powershell -ExecutionPolicy Bypass -File .\test\test-no-flicker.ps1 -Seconds 10
powershell -ExecutionPolicy Bypass -File .\test\test-e2e.ps1
```

> 脚本输出刻意使用 ASCII：Windows PowerShell 5.1 把无 BOM 的 `.ps1` 当 GBK 读取，中文输出字符串会导致解析错误。中文说明都放在文档里。

---

## 常见问题

### `404 ... /v1/responses`
provider 的「上游格式」还是 `Responses (原生)`。改成 `Chat Completions (translated)`。

### `11128 Illegal API invocation from an unapproved channel`
网关按提示词指纹拦截非官方客户端。CC Switch 过不了这关，用带提示词中性化的 api2codex 桥接。请确认你有授权使用该网关。

### `wire_api = "chat" is no longer supported`
Codex 0.169 已移除该选项，不要试图设置，改用 Responses + 协议转换。

### 出现周期性黑窗
检查 `_run_hidden()` 是否对 `tasklist`/`taskkill`/`wmic` 传了 `CREATE_NO_WINDOW`。用 `test-no-flicker.ps1` 验证。

### 旧会话报 provider "custom" 不存在
会话绑定创建时的 provider。新建会话即可，旧会话按设计保留。

更多问题见 [`docs/经验总结.md`](docs/经验总结.md)。

---

## 目录结构

```
CHANGELOG.md                    更新日志
README.md                       本文档
config/codex-config.toml.template  Codex 配置模板
scripts/install.ps1             一键安装三个组件
scripts/import-provider.ps1     写入 CC Switch 数据库
scripts/install-bridge.ps1      api2codex 桥接 + 补丁
scripts/verify.ps1              四步验证
scripts/checksums.psd1          下载文件校验值
bridge/config_store.py          供应商配置（JSON 原子写）
bridge/webui.py                 管理 API
bridge/webui.html               管理页面
bridge/tray.py                  Windows 托盘
test/*.ps1                      四个测试脚本
docs/why-a-proxy.md             协议断层原理
docs/api2codex-bridge.md        桥接方案与补丁
docs/经验总结.md                踩坑与经验
```

---

## 校验与版本

`scripts/checksums.psd1` 为每个下载文件固定 SHA256，安装时强制校验。npm 包用精确版本号（`@openai/codex@0.169.0`），由 npm 注册表保证完整性。

当前版本：Codex CLI `0.169.0` / CC GUI `1.2.4` / CC Switch `4.0.32` / api2codex（MIT，latest）。

许可证见 [LICENSE](LICENSE)。
