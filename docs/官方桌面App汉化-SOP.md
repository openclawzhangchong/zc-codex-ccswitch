# 官方 Codex/ChatGPT 桌面 App 汉化 SOP（给 AI 的可执行方案）

> 面向拿到本仓库的 AI / 开发者。**照做即可复现中文界面**，不用重新踩坑。
> 本文件是操作手册；原理与踩坑见 [`官方桌面App.md`](官方桌面App.md)、[`经验总结.md`](经验总结.md)。
>
> **核心结论（2026-11-17 复核修正）**：真正必需的源码改动只有 **1 处布尔值**——
> 把 `webview/assets/async/907538.*.js` 里的 `get("enable_i18n",!1)` 改成 `!0`。
> 官方前端会自动加载自带的 `locales/zh-CN.json`（chunk 1561，39772 条翻译），
> 界面即全中文。**不需要**批量替换 defaultMessage——早期做的 5793 条替换是冗余的。
> **也不需要解包/重打包**：改动是等长的，直接在 `app.asar` 里原位改 1 字节，
> 再离线同步两层 integrity 即可（见下）。"复制可写副本"仍是必需的，因为
> WindowsApps 只读；但除此之外的解包/重打包/启动报错回填哈希都已移除。

---

## 0. 一句话结论

官方 App 自带**完整简体中文翻译表**（39772 条，chunk `async/1561.*.js`），但语言开关
`enable_i18n` 默认关闭，翻译 chunk 不会被加载，界面才回退英文。
**汉化 = 等长原位改 1 处 bool → 离线同步 asar/exe 哈希**；翻译表由官方前端自动加载，
不用自己翻译、不用批量替换 defaultMessage、不用解包/重打包。

---

## 1. 关键事实（先读，避免走弯路）

| 事实 | 说明 |
|---|---|
| 不要改 WindowsApps 原版 | 只读 + 签名校验，写入必失败。必须复制可写副本到 `~/.codex/codex-localized/app` |
| 翻译表在哪 | app.asar 内 `webview/assets/async/1561.*.js`，已提取到本仓库 `codex-zh/zh-cn-messages.json`（39772 条，仅供查阅） |
| 开关在哪（**唯一必需改动**） | `webview/assets/async/907538.*.js` 里 `get("enable_i18n",!1)` → `!0`。另一处 `184348.*.js` 本来就是 `!0`，不用动 |
| 翻译表自动加载 | `enable_i18n` 为 true 后，官方前端走 `locales/zh-CN.json → i.e(1561)` 自动加载 39772 条中文。**不要**批量替换 defaultMessage |
| integrity **可离线复现** | exe 内嵌值 = **SHA256(asar header JSON)**；逐文件 `integrity.hash` = SHA256(文件内容)，4MB 分块。均普通 SHA256。2026-11-17 原版实测：SHA256(header) == exe 内嵌值 == `1c5b4197…`，逐文件 hash == SHA256(content)。`patch_inplace.py` 据此离线同步，**无需启动报错回填** |
| 校验哈希不是全文件 SHA256 | 实测 full-file SHA256 与 exe 值不符（因为它只哈希 header JSON）。这半句是对的；早期由此误推"内部算法、只能报错取 actual"是错的 |
| 权限/锁 | 改 exe 前先关闭正在运行的 App，否则文件被锁写入失败 |

---

## 2. 目录与工具（都在本仓库 `codex-zh/`）

| 文件 | 作用 |
|---|---|
| `install.ps1` | 一键：检测安装 → 复制可写副本（或直接补丁可写目录）→ **等长原位补丁 + 离线同步哈希** → 写配置/快捷方式 |
| `launch.ps1` / `launch.cmd` | 启动器：版本变化时自动重新本地化，带 `--lang=zh-CN` |
| **`patch_inplace.py`** | ★ 原位补丁核心：改 1 字节 + header 内等长更新 file/block hash + 离线重算 SHA256(header) 写回 exe。幂等，纯标准库 |
| `asar-util.ps1` | asar **解包**的 .NET 实现（供查阅/旧 `patch.py`）；**重打包 `New-Asar` 已移除** |
| `patch.py` | 旧的内容级补丁器（作用于已解包目录，默认只改 1 处 bool）；正常流程用 `patch_inplace.py` 即可 |
| `sync_exe_hash.py` | **应急**哈希回填：万一仍 FATAL，从报错提取 actual 写回 exe。正常流程不需要 |
| `zh-cn-messages.json` | 官方翻译表 39772 条（仅供查阅，**汉化不需要用它**） |
| `patch-rules.ps1` | 旧开源 installer 规则库（本版本未命中，仅历史参考） |

---

## 3. 完整操作步骤（AI 照做）

### 步骤 1 — 确认现场
```bash
# 1) 找到 Store 版 App 目录，确认版本
Get-AppxPackage | ? Name -match 'OpenAI.*Codex' | Select Name,Version,InstallLocation
# 2) 确认桥接在跑（汉化不影响桥接，但对话依赖它）
curl http://127.0.0.1:8787/health
```

### 步骤 2 — 一键：可写副本 + 原位补丁 + 离线同步哈希
```powershell
cd codex-zh
.\install.ps1
```
内部流程（`Patch-App` → `patch_inplace.py`）：
1. 复制 Store 版到可写副本（仅首次/版本变化；约 1–2GB）。
2. 在副本 `app.asar` 里**等长原位**把 `get("enable_i18n",!1)` 的 `1` 改 `0`（1 字节）。
3. 在 asar header 内**等长**更新该文件 `integrity.hash` 与受影响 4MB 分块 hash
   （header 长度 u3 与所有文件偏移保持不变）。
4. 离线重算 `SHA256(新 header JSON)`，**等长**写回副本 `ChatGPT.exe` 内嵌 integrity 值。

全程**不解包、不重打包、不启动报错回填**。预期输出含
`[ok] patched in place; no unpack/repack, no FATAL hash dance needed`。

> 想先看不改：`python patch_inplace.py <副本app.asar> <副本ChatGPT.exe> --dry-run`。
> 重复运行幂等：已补丁且哈希一致时输出 `[skip] already patched and consistent`。

### 步骤 3 — 验收
```powershell
.\launch.ps1                     # 带 --lang=zh-CN 启动
```
确认界面：菜单「文件/编辑/视图/帮助」、侧栏「新对话/定时任务/插件/项目/最近」、
主界面「我们要构建什么？」、底部「选择项目/完全访问」全部中文 ✅
同时确认桥接 provider 与模型选择正常（中文版读同一份 `~/.codex/config.toml`）。

> 注意区分：**对话内容是中文 ≠ 界面汉化**。未打补丁时输入中文也会得到中文回复，
> 但菜单/侧栏/按钮仍是英文。验收要看界面外壳（chrome），不是聊天内容。

---

## 4. AI 决策树（遇到情况怎么办）

- **要最小改动、怕风险** → `install.ps1` 或 `patch_inplace.py`，等长原位 1 字节 + 离线哈希，**足够**。
- **启动 FATAL、integrity failed**（理论上不应再出现）→ 应急：`sync_exe_hash.py <exe> --from-log <fatal日志>` 把 actual 写回；或重跑 `patch_inplace.py` 让它离线重算同步。
- **App 更新后中文丢失** → `launch.ps1` 自动检测版本变化并重跑 `install.ps1`；若失败手动重跑步骤 2。
- **exe 写入失败** → App 还在运行，先关进程。
- **想验证脚本正确性、不想改成品** → `patch_inplace.py ... --dry-run` / `sync_exe_hash.py ... --show`。
- **锚点未命中**（版本改了 chunk 结构）→ `patch_inplace.py` 会扫 `async/` 内容定位 `enable_i18n`；若仍报 not found，说明语言机制变更，需维护者更新锚点。

---

## 5. 本机已验证状态（2026-11-17）

- 版本 `26.1111.2228.0`，Store/MSIX 包；原版**只读、未改动**。
- 原位补丁算法已在 asar/exe **副本**上实测：gate=`!0`、header/asar/exe 三者等长、
  文件 hash 与全部 4MB 分块 hash 匹配、exe 内嵌值 == SHA256(新 header)、重跑幂等；
  与原版的差异仅 1 个数据字节 + header 内两个 hash 字段。
- `install.ps1 -Silent -NoShortcut` 端到端跑通（检测→补丁→写 install.json→部署脚本）。
- 桌面快捷方式「Codex 本地化版」→ `launch.cmd`（由 install.ps1 创建）。