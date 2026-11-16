# 更新日志

本项目按时间倒序记录重要变更。完整提交历史见 [GitHub](https://github.com/openclawzhangchong/zc-codex-ccswitch/commits/main)。

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
