# 更新日志

本项目按时间倒序记录重要变更。完整提交历史见 [GitHub](https://github.com/openclawzhangchong/zc-codex-ccswitch/commits/main)。

## 2026-11-17（桥接三处修复 + 重打包，BRIDGE-FIX-20261117）

### 修复 CodexBridge.exe 在新机器上"装好却跑不通"的三个问题

- **routes.json 占位模板永久遮蔽 .env**：exe 首启播种的 `routes.json` 带占位
  default，而 WebUI 切换供应商只重写 `.env`，不同步 routes.json；api2codex 里
  routes.json 优先级高于 .env → 配好网关后请求仍打向占位地址。修复：
  `webui.py write_env()` 同步 routes.json 的 default（保留用户自定义前缀路由）
- **/v1/models 给默认上游模型加 "_" 前缀**：`list_models()` 把哨兵值 `"_"`
  当成真实前缀拼进模型 id（`_hy4flash-free`），而 `_resolve_upstream()` 并不
  剥它 → 模型选择器/test-bridge.ps1 认不出模型。修复：默认目标前缀改为 `""`
- **NO_PROXY 含 `[::1]` 时 httpx 全量崩溃**：部分宿主进程链注入
  `NO_PROXY=...,[::1],::1`，httpx 解析方括号 IPv6 抛 `Invalid port: ':1]'`，
  桥接每个上游请求 500。修复：api2codex.py 启动时剥掉 NO_PROXY 里的方括号
- 重打包 `bridge/exe/CodexBridge.exe`（22.9MB）并在新机器实测：
  `test-bridge.ps1 -Model hy4flash-free` 全 PASS；故意写坏 routes.json 后
  WebUI PUT 供应商 → 自动同步回真实网关（回归通过）；流式 SSE 全事件序列正常；
  `codex exec` 经桥真实回话；配 `model_catalog_json`（18 个网关模型 + 官方
  base prompt）后 "Model metadata not found" 警告消失
- 汉化副本桌面端端到端实测（同版本 26.1111.2228.0）：左上角须切到 **Codex**
  模式（默认 ChatGPT Work 走云端登录态）；模型选择器经 `model_catalog_json`
  列出网关模型，选 hy4flash-free 后中文对话真实回复；config.toml 的 `model`
  须写 hy4flash-free（App 首启可能改写为自带默认模型）。「完成 Windows 设置」
  横幅在 app-server 重连瞬间报「无法检查」属瞬态，点重试即恢复；store-copy
  无 MSIX 包身份（no-package-identity），走 bundled 运行时，不影响桥接对话

## 2026-11-17（复核纠错）

### 修正汉化文档：真正必需的只有 1 处 bool，5793 条 defaultMessage 替换是冗余的

- 复核发现此前文档夸大：把"当时顺手做的 5793 条 defaultMessage 替换"误写成"必需的双机制"
- 决定性证据：`enable_i18n=true` 后官方前端自动走 `locales/zh-CN.json → i.e(1561)`
  加载 39772 条中文；已汉化成品里 "New chat"（id=`chatgptConversations.customGpt.newChat`）
  等核心文案的 defaultMessage 仍是英文，界面却显示中文 → 翻译按 id 从 chunk 匹配，
  与 defaultMessage 无关
- 唯一必需的源码改动：`webview/assets/async/907538.*.js` 的 `get("enable_i18n",!1)` → `!0`
  （另一处 `184348.*.js` 本来就是 `!0`）
- `codex-zh/patch.py` 改为默认只改这一处；早期替换降为可选 `--with-messages`
- README / AGENTS / docs/官方桌面App.md / 经验总结 / 汉化 SOP 全部同步纠正，
  避免拉仓库的其他 AI 被误导去做无谓的大批量替换

## 2026-11-17（补充）

### 新增 CodexBridge.exe：托盘 + WebUI + 桥接三合一（免源码）

- 单文件 exe（`bridge/exe/CodexBridge.exe`，23MB）：双击即托盘图标 + 管理界面(:8789)
  + 桥接(:8787)，不装 Python 也能用；首次运行生成通用配置模板（无真实 Key），
  WebUI 里填自己的网关即可
- 单 exe 双角色：主进程跑托盘，子进程用同一 exe + `--bridge` 跑桥接（托盘负责
  拉起/重启），统一入口 `bridge/bridge_app.py`
- 冻结环境适配：`__file__` 在只读 `_MEIPASS`，可写数据（config/.env/pid/日志/routes）
  经 `BRIDGE_DATA_DIR` 重定向到 exe 同级 `bridge-data/`；源码模式无该变量时行为不变
- 打包：`bridge/build-exe.cmd` 一键（建 venv→装依赖+PyInstaller→按 spec 打包），
  `CodexBridge.spec` 关 UPX 降误报；requirements 补 pystray/Pillow
- 实测：托盘进程正常、WebUI `/api/state` 与首页 200、POST `/api/restart` 成功拉起
  `--bridge` 子进程、桥接 `/health` 200、端到端 Responses 对话返回标准结构
- 文档：`bridge/exe/README.md`、README/AGENTS 指向 exe 方案；真实 key 的
  config/.env/routes 加入 .gitignore，不随仓库分发

## 2026-11-17

### 🎉 界面中文化完成：官方 App 全中文界面（实测通过）

- 发现根因：官方 App 把整套简体中文翻译（**39772 条** FormatJS 消息）打包进了
  app.asar（chunk `webview/assets/async/1561.*.js`），但语言开关 `enable_i18n`
  由 Statsig 远程控制（Layer 72216192）且默认 `!1`——离线/受限网络拿不到配置，
  翻译 chunk 成"孤儿"，界面回退英文
- 汉化方案（工作副本，不动 WindowsApps 原版）：
  1. 复制 Store 版到 `~/.codex/codex-localized/app`（可写）
  2. 解包 app.asar，把 `enable_i18n` 默认值 `!1` → `!0`（前端主界面 1 处）
  3. 用官方 `@electron/asar` 重打包（保留每文件 integrity 字段）
  4. 更新 exe 内嵌 integrity 清单的 asar 哈希（PE 资源段 JSON）
  5. 以 `--lang=zh-CN` 启动
- 实测结果：菜单（文件/编辑/视图/帮助）、侧栏（新对话/定时任务/插件/项目/
  最近）、主界面（我们要构建什么？）、底部（选择项目/完全访问）全部中文 ✅
- exe 完整性校验踩坑：Electron 报错 `(expected vs actual)` 里的 actual 就是
  对当前 asar 的计算值——把 exe 里的 expected 改成该值迭代一次即可；该哈希
  **不是全文件 SHA256**，自算不可靠，必须让 Electron 自己报
- 澄清旧结论：昨日"汉化不可行"仅指**直接改 WindowsApps**（只读+签名校验）；
  工作副本方案绕开两者，当日即验证成功
- 桥接联动：汉化副本读取同一份 `~/.codex/config.toml`，桥接 provider 与模型
  选择不受影响；Computer use 仍为区域限制（维持不破解决策）

## 2026-11-16

## 2026-11-16

### 🎉 重大突破：官方 ChatGPT/Codex 桌面 App 原生兼容桥接

- `codex app` 触发 Microsoft Store 安装器，自动下载约 1GB 完成安装（包名
  `OpenAI.Codex`，Store 显示名 ChatGPT，版本 26.1111.2228.0），全程无需交互确认
- 安装后官方 App **直接读取同一份 `~/.codex/config.toml`**，桥接 `127.0.0.1:8787`
  被原生使用：provider 显示 `Bridge (api2codex)`，模型 `hy4flash-free` 对话成功
- 历史会话三端共享（CLI / CC GUI / 官方 App），因为会话存储都在 `~/.codex`
- 官方 App 不需要 CC GUI 也能获得完整桌面体验 —— 桥接成为"官方客户端适配器"
- 已知限制：App 内 ChatGPT 的 *Computer use* 功能被区域/账号限制
  （`Disabled by your organization or unavailable in your region`），与桥接无关
- 新增 `test/test-desktop-app.ps1` 检测官方 App 安装与桥接兼容性

### 界面语言与 Computer use 的实测结论

- 官方 App 自带 Language 设置（General → Language，可选简体中文）并会持久化，
  但**Codex 业务界面暂无中文翻译**：设为简体中文并重启后 New chat / Recents /
  What should we build? 仍为英文。zh-CN.pak 只覆盖 Chromium 框架层
- 汉化 app.asar 不可行：WindowsApps 只读且有 Store 签名校验（实测写入被拒）
- Computer use 的区域/账号灰度**不做客户端破解**：服务端会二次校验（大概率
  无效），且违反 OpenAI 条款；本机已有替代（CC GUI 的 computer-use 驱动、
  browser-use 自动化）
- 包真实性核实：SignatureKind=Store，由官方 CLI 的 `codex app` 调起，深度
  读取 ~/.codex（会话与 config 三端共享），确认非仿冒
### 多上游路由：两个网关的全部模型可在 CC GUI/官方 App 自选

- api2codex 升级为多上游路由：读 `routes.json`，默认上游 + 前缀路由
- 模型名带 `7864-` 前缀 → 转发 7864 网关并去前缀；其余走 7863
- `/v1/models` 合并全部上游（35s 超时，7864 响应约 20 秒），模型目录扩至 29 个
- 7864 网关探测结论：**无 11128 渠道指纹校验**（带 Codex 提示词直接 200），
  比本地网关 7863 更省心
- 新增 `bridge/routes.json.example` 路由表格式示例


### 运行时文件迁移到 D 盘

- 所有运行时文件统一到 `D:\zc-codex-ccswitch\`：
  - `cc-gui\` 桌面端、`cc-switch\` 供应商管理、`bridge\` 桥接 + 托盘 + 配置
- 开机自启注册表项 `CodexBridgeTray` 改为指向 D 盘托盘
- 桌面与开始菜单的 CC GUI 快捷方式改为指向 D 盘（开始菜单原是失效链接，一并修复）
- `config.json`、`.env`、用户配置在迁移前备份到 `D:\zc-codex-ccswitch\_backup-from-c\`
- 清理 C 盘 4 处旧运行时副本（约 300M），保留 git 源码仓库
- 从 D 盘启动、模拟开机、删除旧副本后均验证通过（对话返回 `DRIVE_OK` / `AFTER_DELETE`）

### 测试脚本、中文文档、仓库整理

- 新增 `test/` 目录，四个可直接运行的测试脚本：
  - `test-bridge.ps1` —— 桥接健康检查（/health、/v1/models、/v1/responses）
  - `test-tray.ps1` —— 托盘与开机自启（含 PID 一致性、WebUI 重启）
  - `test-no-flicker.ps1` —— 黑窗闪烁采样检测
  - `test-e2e.ps1` —— 全链路端到端验收
- 四个脚本全部在本机实测通过
- 注意：PowerShell 5.1 把无 BOM 的 `.ps1` 当 GBK 读取，因此测试脚本输出统一用 ASCII，中文说明放在文档里
- 新增 `CHANGELOG.md`，README 与文档全面中文化

### 修复控制台黑窗闪烁

- 现象：托盘每 5 秒调用 `tasklist` 检查进程，中文 Windows 上每次弹出黑色终端窗口
- 修复：`tray.py` 和 `webui.py` 增加 `_run_hidden()`，对所有 `tasklist` / `taskkill` / `wmic` 调用传入 `CREATE_NO_WINDOW`
- 顺手修复 PID 文件缺少结尾换行的问题
- 验证：修复前 12 秒采样可捕获 `tasklist.exe` 窗口，修复后 16 秒采样 0 次

### 修复托盘自启动与 PID 记录（由接手的 Codex 完成，本仓库同步）

- `os.chdir(BASE)` 让托盘从任意工作目录启动（开机自启时工作目录是 `C:\`）
- `start_bridge()` 直接启动 api2codex 并写入 `.bridge.pid`，不再经 `cmd /c`，无闪窗
- WebUI 内置到托盘进程，不再有单独的 `.webui.pid`
- 崩溃日志写入 `tray-error.log`，因为 `pythonw` 没有控制台
- 托盘启动时自动拉起桥接，让开机自启真正可用
- 从 `C:\` 模拟开机验证：托盘存活、PID 文件与 8787 端口拥有者一致、WebUI 重启正确更新 PID

### 切换上游时同步 Codex 模型

- 问题：切换 provider 只改了 `.env`，`~/.codex/config.toml` 仍写着旧模型，导致新上游收到不认识的模型名
- 修复：`write_codex_config()` 只改写 `model` 那一行，保留其他设置，写入不带 BOM
- 在切换和编辑当前上游时自动调用

### 新增托盘图标与管理 WebUI

- `bridge/config_store.py` —— 供应商列表，JSON 原子写入，单点切换
- `bridge/webui.py` —— 管理 API（默认 8789 端口），增删改查与切换上游
- `bridge/webui.html` —— 深色单页管理界面，无外部 CDN
- `bridge/tray.py` —— Windows 托盘图标：绿色运行中、灰色停止，菜单含启停/重启/开机自启/退出
- 切换上游会重写 `.env` 并重启桥接（api2codex 只在启动时读配置）

### 添加提示词中性化补丁

- 新增 `scripts/install-bridge.ps1`：克隆 api2codex（MIT）、打补丁、建虚拟环境、写 `.env`、生成启动器、重启桥接
- 补丁对上游代码做精确锚点匹配，上游结构变化会明确报错而不是静默装成未打补丁版本
- 生成 `start-bridge.cmd`，因为 api2codex 只读 `os.environ`、不解析 `.env`
- 新增两个模型：`deepseek-v4.1-flash`、`hy4flash-free`（同一网关，可自由切换）

## 2026-11-15

### 初始版本

- `scripts/install.ps1` —— 一键下载并安装 Codex CLI、CC GUI、CC Switch
- `scripts/checksums.psd1` —— 所有下载文件的 SHA256 校验
- `scripts/import-provider.ps1` —— 向 CC Switch 数据库写入 provider
- `scripts/verify.ps1` —— 四步端到端验证
- `config/codex-config.toml.template` —— Codex 配置模板
- `docs/why-a-proxy.md` —— 为什么需要协议转换代理
- `docs/api2codex-bridge.md` —— 桥接方案说明
- 创建 GitHub 仓库 `zc-codex-ccswitch`
