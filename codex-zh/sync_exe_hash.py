#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""同步 exe 里内嵌的 app.asar integrity 哈希（启动 FATAL 时用）。

原理：
  官方 ChatGPT.exe 的 PE 资源段内嵌一条 JSON：
    [{"file":"resources\\\\app.asar","alg":"SHA256","value":"<64位hex>"}]
  Electron 启动时会校验 app.asar，不匹配就 FATAL:
    asar_util.cc:144 Integrity check failed for asar archive
    (expected: <A> vs actual: <B>)
  报错里的 **actual 就是 Electron 对当前 asar 算出的值**——所以正确做法不是
  自己算 SHA256（算不出来，Electron 用的是内部算法），而是把 B 写进 exe。

用法：
    # 方式1：直接给 actual（从 Electron 报错的 "actual:" 后面复制）
    python sync_exe_hash.py <ChatGPT.exe> <64位hex>

    # 方式2：从日志/标准输入自动提取 "actual: <hex>"
    python sync_exe_hash.py <ChatGPT.exe> --from-log <日志文件>
    python sync_exe_hash.py <ChatGPT.exe> --from-log -     # 从 stdin 读

    # 只查看当前值
    python sync_exe_hash.py <ChatGPT.exe> --show

注意：exe 被运行中的 App 锁定时写入会失败——先关掉 App 再执行。
"""
import argparse, re, shutil, sys
from pathlib import Path

# integrity JSON 固定结构，value 是 64 位 hex；后面是 PADDINGX 填充区，改同长度安全
PAT = re.compile(rb'(\{"file":"resources\\\\app\.asar","alg":"SHA256","value":")([0-9a-f]{64})("\})')
HEX64 = re.compile(r'\b[0-9a-fA-F]{64}\b')


def show(exe: Path):
    data = exe.read_bytes()
    m = PAT.search(data)
    if not m:
        sys.exit('[错误] 未找到 app.asar integrity 段（exe 版本可能不同）')
    print('当前 exe 内嵌哈希:', m.group(2).decode())


def extract_actual(text: str):
    # 优先抓 "actual: <hex>" / "actual <hex>" / "(expected ... vs actual ...)"
    m = re.search(r'actual[^0-9a-fA-F]{0,20}([0-9a-fA-F]{64})', text, re.I)
    if m:
        return m.group(1).lower()
    # 退化：取出现的所有 64hex，若正好两个（expected/actual），取后一个
    found = HEX64.findall(text)
    if len(found) >= 2:
        return found[-1].lower()
    sys.exit('[错误] 未能从日志提取 actual 哈希。请直接把 64 位 hex 作为参数传入。')


def sync(exe: Path, actual: str, backup: bool = True, dry_run: bool = False):
    if not re.fullmatch(r'[0-9a-fA-F]{64}', actual):
        sys.exit('[错误] 哈希必须是 64 位 hex: %r' % actual)
    actual = actual.lower()
    data = exe.read_bytes()
    m = PAT.search(data)
    if not m:
        sys.exit('[错误] 未找到 app.asar integrity 段')
    old = m.group(2).decode()
    if old == actual:
        print('[跳过] 已是目标值:', old)
        return
    if dry_run:
        print('[dry-run] %s -> %s' % (old, actual))
        return
    if backup:
        bak = exe.with_suffix(exe.suffix + '.bak')
        shutil.copy2(exe, bak)
        print('[OK] 已备份:', bak)
    # 等长替换，不改文件长度（保持 PE 结构/签名占位不变）
    new_data = data[:m.start(2)] + actual.encode() + data[m.end(2):]
    exe.write_bytes(new_data)
    print('[OK] %s -> %s' % (old, actual))


def main():
    ap = argparse.ArgumentParser(description='同步 exe 里 app.asar 的 integrity 哈希')
    ap.add_argument('exe', help='ChatGPT.exe 路径')
    ap.add_argument('hash', nargs='?', help='Electron 报错里的 actual（64位 hex）')
    ap.add_argument('--from-log', help='从此文件提取 actual；传 - 表示 stdin')
    ap.add_argument('--show', action='store_true', help='只显示当前值')
    ap.add_argument('--no-backup', action='store_true', help='不创建 .bak')
    ap.add_argument('--dry-run', action='store_true', help='只显示将发生的变更，不写入')
    args = ap.parse_args()

    exe = Path(args.exe).resolve()
    if not exe.is_file():
        sys.exit('[错误] exe 不存在: %s' % exe)
    if args.show:
        show(exe)
        return

    if args.from_log:
        text = sys.stdin.read() if args.from_log == '-' else Path(args.from_log).read_text(encoding='utf-8', errors='replace')
        actual = extract_actual(text)
        print('[信息] 从日志提取 actual:', actual)
    elif args.hash:
        actual = args.hash
    else:
        sys.exit('[错误] 请提供 64 位 hex，或用 --from-log 指定日志')
    sync(exe, actual, backup=not args.no_backup, dry_run=args.dry_run)


if __name__ == '__main__':
    main()
