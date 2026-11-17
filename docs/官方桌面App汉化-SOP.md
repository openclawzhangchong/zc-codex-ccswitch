# 官方 Codex/ChatGPT 桌面 App 汉化 SOP（给 AI 的可执行方案）

> 面向拿到本仓库的 AI / 开发者。**照做即可复现中文界面**，不用重新踩坑。
> 本文件是操作手册；原理与踩坑见 [`官方桌面App.md`](官方桌面App.md)、[`经验总结.md`](经验总结.md)。

---

## 0. 一句话结论

官方 App 自带**完整简体中文翻译表**（39772 条，就打在 app.asar 里），但语言开关
`enable_i18n` 由 Statsig 远程控制、默认关闭，翻译 chunk 成了"孤儿"，界面才回退英文。
**汉化 = 解锁开关 + 补全消息 + 重打包 + 同步 exe 哈希**，四步全做才能启动且全中文。

---

## 1. 关键事实（先读，避免走弯路）

| 事实 | 说明 |
|---|---|
| 不要改 WindowsApps 原版 | 只读 + 签名校验，写入必失败。必须复制可写副本到 `~/.codex/codex-localized/app` |
| 翻译表在哪 | app.asar 内 `webview/assets/async/1561.*.js`，已提取到本仓库 `codex-zh/zh-cn-messages.json`（39772 条） |
| 开关在哪 | `webview/assets/async/907538.*.js`（和另一处）里 `x?.get("enable_i18n",!0)`，原值是 `!1` |
| 是**双机制** | ①`enable_i18n !1→!0`（核心）②`defaultMessage` 中文补全（实测 5793 条/15 文件）——两者都做了才是我们验证过的成品 |
| 第三方 installer 的坑 | 网上开源 installer 的规则是反引号 + 只扫顶层 `webview/assets`，在 26.1111 上**未命中**（实测日志"关键补丁点未命中"）。它的 asar 打包也**不保留逐文件 integrity、不同步 exe 哈希**，单独跑会 FATAL。所以本仓库方案是"它负责复制/解包/重打包壳，我们补双机制补丁 + 哈希同步" |
| integrity 算法不可离线复现 | Electron 的 asar 逐文件 integrity 不是裸 SHA256（实测不匹配）。**必须让 Electron 自己启动一次报出 actual**，再写回 exe。这就是 `sync_exe_hash.py` 的作用 |
| 权限/锁 | 改 exe 前先关闭正在运行的 App，否则文件被锁写入失败 |

---

## 2. 目录与工具（都在本仓库 `codex-zh/`）

| 文件 | 作用 |
|---|---|
| `install.ps1` | 复制 Store 版 → 可写副本、解包 asar、重打包（纯 .NET，无第三方依赖） |
| `launch.ps1` / `launch.cmd` | 启动器：版本变化时自动重打补丁，带 `--lang=zh-CN` |
| `asar-util.ps1` | asar 解包/打包的 .NET 实现（install.ps1 依赖） |
| `patch-rules.ps1` | 开源 installer 的规则库（**本版本未命中，仅作参考/旧版兼容**） |
| `zh-cn-messages.json` | 官方翻译表，39772 条（从 1561 chunk 提取） |
| **`patch.py`** | ★ 我们写的双机制补丁注入器（幂等）：解锁 `enable_i18n` + 补全 `defaultMessage` |
| **`sync_exe_hash.py`** | ★ 我们写的 exe 哈希同步器：从 Electron 报错提取 actual 并写回 exe |

---

## 3. 完整操作步骤（AI 照做）

### 步骤 1 — 确认现场
```bash
# 1) 找到 Store 版 App 目录，确认版本
Get-AppxPackage | ? Name -match 'OpenAI.*Codex' | Select Name,Version,InstallLocation
# 2) 确认桥接在跑（汉化不影响桥接，但对话依赖它）
curl http://127.0.0.1:8787/health
```

### 步骤 2 — 生成可写副本 + 解包
```powershell
cd codex-zh
.\install.ps1                    # 默认 store-copy 模式：复制到 ~/.codex/codex-localized/app 并解包
```
> 若 `install.ps1` 提示"关键补丁点未命中"，**属正常**——它的规则在本版本没命中，
> 真正的补丁在步骤 3 由 `patch.py` 完成。

### 步骤 3 — 注入双机制补丁（★核心）
解包目录是 `~/.codex/codex-localized/work-*/asar-extracted`（install.ps1 会打印路径），
或任意你自己解包 app.asar 的目录：
```bash
python codex-zh/patch.py "<解包目录>" --stats patch-stats.json
```
预期输出类似：
```
[OK] enable_i18n 解锁: 2 处 / 2 文件
[OK] defaultMessage 补全: N 条 / M 文件（无翻译 id: ...）
```
> `--no-messages` 可只解锁开关（最小改动）。**推荐全做**（我们验证过的成品是双机制）。

### 步骤 4 — 重打包 app.asar
用仓库自带的 `asar-util.ps1`（`install.ps1` 已经做过一次重打包；如果你在它解包后的目录
上跑了 `patch.py`，需要重新打包覆盖）：
```powershell
# 参照 install.ps1 里 New-Asar 的调用方式；或直接用 @electron/asar：
npx --yes @electron/asar pack "<解包目录>" "app.asar"
```
> 用 `@electron/asar` 会自动生成逐文件 integrity（最重要）。仓库的 `asar-util.ps1`
> 也能打包，但它不生成 integrity——若用它，Electron 会跳过逐文件校验，只剩 exe 整包校验，
> 也能工作（我们早期版本这么做过）。**优先 `@electron/asar`**。

把新 `app.asar` 覆盖到 `~/.codex/codex-localized/app/resources/app.asar`。

### 步骤 5 — 同步 exe 哈希（★必须）
先**关闭所有 ChatGPT/Codex 进程**，然后：
```powershell
# 5a) 启动本地化副本，让它报 actual
& "$env:USERPROFILE\.codex\codex-localized\app\ChatGPT.exe" --lang=zh-CN
# 若 FATAL: asar_util.cc:144 Integrity check failed ... (expected: X vs actual: Y)
# 把报错整段存到日志，关掉 App
```
```bash
# 5b) 从日志提取 actual 并写回 exe（自动备份 .bak）
python codex-zh/sync_exe_hash.py "...\app\ChatGPT.exe" --from-log fatal.log
# 或手动：python sync_exe_hash.py <exe> <actual的64位hex>
# 先用 --dry-run 验证，确认无误再去掉它真正写入
```

### 步骤 6 — 验收
```powershell
.\launch.ps1                     # 带 --lang=zh-CN 启动
```
确认界面：菜单「文件/编辑/视图/帮助」、侧栏「新对话/定时任务/插件/项目/最近」、
主界面「我们要构建什么？」、底部「选择项目/完全访问」全部中文 ✅
同时确认桥接 provider 与模型选择正常（中文版读同一份 `~/.codex/config.toml`）。

---

## 4. AI 决策树（遇到情况怎么办）

- **要最小改动、怕风险** → `patch.py --no-messages`，只解锁 `enable_i18n`；但本版本实测
  仅解锁后部分文案仍英文，完整中文请做双机制。
- **install.ps1 报"关键补丁点未命中"** → 不必修它，那是开源规则与新版本不匹配；
  用 `patch.py` 即可。
- **启动 FATAL、integrity failed** → 步骤 5，`sync_exe_hash.py` 从报错提取 actual 写回。
- **App 更新后中文丢失** → `launch.ps1` 会自动检测版本变化并重打补丁；若失败，重跑步骤 2–5。
- **exe 写入失败** → App 还在运行，先关进程。
- **想验证脚本正确性、不想改成品** → `sync_exe_hash.py ... --show` / `--dry-run`。

---

## 5. 本机已验证状态（2026-11-17）

- 版本 `26.1111.2228.0`，Store/MSIX 包
- 工作副本 `C:\Users\Administrator\.codex\codex-localized\app`
- 桌面快捷方式「Codex 本地化版」→ `launch.cmd`
- 已部署 asar：2 处 `enable_i18n !0` + 5793 条中文 defaultMessage
- exe 内嵌哈希已同步为 Electron 报出的 actual：`02e1209c...672453`
- 界面全中文 + 桥接 provider/模型正常，对话验证 `ZH_UI_SUCCESS`
