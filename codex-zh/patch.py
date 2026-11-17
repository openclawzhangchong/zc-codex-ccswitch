#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Codex 桌面 App 汉化补丁注入器（双机制）。

用法：
    python patch.py <解包目录> [--no-messages] [--stats 统计文件.json]

    <解包目录>  = app.asar 解包后的根目录（能看到 webview\\assets 那层）

做两件事：
  1) 解锁官方多语言开关：enable_i18n 的 Statsig 默认值 !1 -> !0
     （官方把 39772 条简体中文翻译打包进了 app.asar，但开关默认关闭，
       翻译成"孤儿 chunk"永不加载，界面回退英文）
  2) 用官方翻译表 zh-cn-messages.json 补全 defaultMessage
     （覆盖 id 不在翻译表里的文案；这两步是"双保险"，1 是核心必需）

两个补丁都幂等：重复运行不会破坏已打补丁的文件。
不碰 app.asar 本身——打完补丁请用 @electron/asar 重新打包（见 docs/SOP）。
"""
import argparse, json, re, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
TABLE = HERE / 'zh-cn-messages.json'

# enable_i18n 的两种实际写法（不同版本/不同 chunk 都覆盖）
I18N_PATTERNS = [
    re.compile(r'(enable_i18n"?,!)(1)(\))'),   # 双引号: x?.get("enable_i18n",!1)
    re.compile(r'(enable_i18n`,!)(1)(\))'),    # 反引号: a?.get(`enable_i18n`,!1)
]

# FormatJS 消息结构（两种字段顺序）
PAT_A = re.compile(r'\{id:"((?:[^"\\]|\\.)+)",defaultMessage:"((?:[^"\\]|\\.)*)"\}')
PAT_B = re.compile(r'\{defaultMessage:"((?:[^"\\]|\\.)*)",id:"((?:[^"\\]|\\.)+)"\}')
CJK = re.compile(r'[\u4e00-\u9fff]')


def js_escape(s: str) -> str:
    return (s.replace('\\', '\\\\').replace('"', '\\"')
             .replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t'))


def patch_i18n(root: Path):
    """递归扫描 webview/assets 下所有 .js，把 enable_i18n 默认 !1 改成 !0。"""
    base = root / 'webview' / 'assets'
    if not base.exists():
        # 兼容某些版本把 JS 放在别处：退化到全目录扫（跳过 app.asar 等大二进制）
        base = root
    hits, files = 0, set()
    for js in base.rglob('*.js'):
        try:
            text = js.read_text(encoding='utf-8')
        except (OSError, UnicodeDecodeError):
            continue
        new = text
        for pat in I18N_PATTERNS:
            new, n = pat.subn(lambda m: m.group(1) + '0' + m.group(3), new)
            hits += n
        if new != text:
            js.write_text(new, encoding='utf-8', newline='')
            files.add(str(js.relative_to(root)))
    return hits, sorted(files)


def patch_messages(root: Path, msgs: dict):
    """用官方翻译表补全未翻译的 defaultMessage（已含中文的跳过，保证幂等）。"""
    base = root / 'webview' / 'assets'
    if not base.exists():
        base = root
    hits, files, missing = 0, set(), set()

    def repl_a(m):
        nonlocal hits
        mid, dm = m.group(1), m.group(2)
        if CJK.search(dm):            # 已翻译，跳过
            return m.group(0)
        zh = msgs.get(mid)
        if not zh:
            missing.add(mid)
            return m.group(0)
        hits += 1
        return '{id:"%s",defaultMessage:"%s"}' % (mid, js_escape(zh))

    def repl_b(m):
        nonlocal hits
        dm, mid = m.group(1), m.group(2)
        if CJK.search(dm):
            return m.group(0)
        zh = msgs.get(mid)
        if not zh:
            missing.add(mid)
            return m.group(0)
        hits += 1
        return '{defaultMessage:"%s",id:"%s"}' % (js_escape(zh), mid)

    for js in base.rglob('*.js'):
        try:
            text = js.read_text(encoding='utf-8')
        except (OSError, UnicodeDecodeError):
            continue
        if 'defaultMessage:' not in text:
            continue
        new = PAT_A.sub(repl_a, text)
        new = PAT_B.sub(repl_b, new)
        if new != text:
            js.write_text(new, encoding='utf-8', newline='')
            files.add(str(js.relative_to(root)))
    return hits, sorted(files), len(missing)


def main():
    ap = argparse.ArgumentParser(description='Codex 桌面 App 汉化补丁注入器（双机制）')
    ap.add_argument('root', help='app.asar 解包后的根目录')
    ap.add_argument('--no-messages', action='store_true', help='只解锁 enable_i18n，不替换 defaultMessage')
    ap.add_argument('--stats', help='把统计写到指定 JSON 文件')
    args = ap.parse_args()

    root = Path(args.root).resolve()
    if not root.is_dir():
        sys.exit('[错误] 解包目录不存在: %s' % root)

    t0 = time.time()
    n_i18n, f_i18n = patch_i18n(root)
    print('[OK] enable_i18n 解锁: %d 处 / %d 文件' % (n_i18n, len(f_i18n)))
    for f in f_i18n[:10]:
        print('     ', f)

    n_msg = n_miss = 0
    f_msg = []
    if not args.no_messages:
        if not TABLE.exists():
            print('[警告] 翻译表缺失: %s（跳过 defaultMessage 补强）' % TABLE)
        else:
            msgs = json.loads(TABLE.read_text(encoding='utf-8'))
            n_msg, f_msg, n_miss = patch_messages(root, msgs)
            print('[OK] defaultMessage 补全: %d 条 / %d 文件（无翻译 id: %d）'
                  % (n_msg, len(f_msg), n_miss))
            for f in f_msg[:10]:
                print('     ', f)

    print('[完成] 耗时 %.1fs。下一步：用 @electron/asar pack 重打包，再同步 exe 哈希。' % (time.time() - t0))

    if args.stats:
        Path(args.stats).write_text(json.dumps({
            'enable_i18n': {'hits': n_i18n, 'files': f_i18n},
            'defaultMessage': {'replacements': n_msg, 'files': f_msg, 'missing_ids': n_miss},
        }, ensure_ascii=False, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
