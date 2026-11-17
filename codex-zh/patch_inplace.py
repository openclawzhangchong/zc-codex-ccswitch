#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""In-place, equal-length localization patch for the official Codex/ChatGPT app.

Flips the single i18n gate default (enable_i18n !1 -> !0) directly inside
app.asar, then repairs the two integrity layers offline so Electron boots
without any FATAL / hash-from-error dance:

  1. asar data region : 1 byte  ('1' -> '0'), length unchanged
  2. asar header JSON : that file's integrity.hash + the one affected 4MB
                        block hash, both 64-hex equal-length swaps, so the
                        header length (u3) and every file offset stay identical
  3. ChatGPT.exe      : embedded SHA256(header JSON) value, 64-hex equal-length

All hashes are plain SHA256 and ARE reproducible offline (verified against the
stock 26.1111.2228.0 build): exe value == SHA256(header bytes), and each file
integrity.hash == SHA256(file content). No unpack / repack is performed.

Usage:
    python patch_inplace.py <app.asar> <ChatGPT.exe> [--dry-run] [--no-backup]

Idempotent: re-running on an already-patched pair is a no-op.
Never point this at the read-only WindowsApps original; use a writable copy.
"""
import argparse
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

ANCHORS = (b'enable_i18n",!1)', b'enable_i18n`,!1)')
DONE_ANCHORS = (b'enable_i18n",!0)', b'enable_i18n`,!0)')
EXE_PAT = re.compile(rb'app\.asar","alg":"SHA256","value":"([0-9a-f]{64})"')


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def read_header(fs):
    fs.seek(0)
    pre = fs.read(16)
    if len(pre) != 16:
        sys.exit('[error] asar too small')
    u0 = int.from_bytes(pre[0:4], 'little')
    u3 = int.from_bytes(pre[12:16], 'little')
    if u0 != 4 or u3 <= 0:
        sys.exit('[error] bad asar prefix')
    fs.seek(16)
    hdr = fs.read(u3)
    if len(hdr) != u3:
        sys.exit('[error] truncated asar header')
    return u3, 16 + u3, hdr


def node_region(hdr, filename):
    """Byte span of the target file's JSON object inside the header."""
    key = b'"' + filename.encode() + b'":'
    start = hdr.find(key)
    if start < 0:
        sys.exit('[error] node not found in header: %s' % filename)
    i = hdr.index(b'{', start + len(key))
    depth = 0
    in_str = False
    esc = False
    j = i
    while j < len(hdr):
        c = hdr[j]
        if in_str:
            if esc:
                esc = False
            elif c == 0x5C:
                esc = True
            elif c == 0x22:
                in_str = False
        elif c == 0x22:
            in_str = True
        elif c == 0x7B:
            depth += 1
        elif c == 0x7D:
            depth -= 1
            if depth == 0:
                return i, j + 1
        j += 1
    sys.exit('[error] unbalanced node object: %s' % filename)


def find_target(fs, data_offset, hdr):
    """Locate the async chunk whose content holds the i18n gate (version-robust)."""
    tree = json.loads(hdr.decode('utf-8'))
    try:
        async_files = tree['files']['webview']['files']['assets']['files']['async']['files']
    except (KeyError, TypeError):
        sys.exit('[error] webview/assets/async not present in this build')
    for name, node in async_files.items():
        if not isinstance(node, dict) or 'offset' not in node or 'size' not in node:
            continue
        size = int(node['size'])
        off = data_offset + int(node['offset'])
        fs.seek(off)
        blob = fs.read(size)
        hit = next((a for a in ANCHORS if a in blob), None)
        if hit is None:
            continue
        if blob.count(hit) != 1:
            sys.exit('[error] anchor occurs %d times in %s' % (blob.count(hit), name))
        return name, node, blob, hit
    # already patched? report the file that carries the enabled gate
    for name, node in async_files.items():
        if not isinstance(node, dict) or 'offset' not in node:
            continue
        fs.seek(data_offset + int(node['offset']))
        blob = fs.read(int(node['size']))
        if any(a in blob for a in DONE_ANCHORS):
            return name, node, blob, None
    sys.exit('[error] enable_i18n gate not found in any async chunk')


def swap_once(region, old, new, label):
    old_b = old.encode()
    new_b = new.encode()
    if len(old_b) != len(new_b):
        sys.exit('[error] %s swap not equal-length' % label)
    if region.count(old_b) != 1:
        sys.exit('[error] %s old hash occurs %d times in node' % (label, region.count(old_b)))
    return region.replace(old_b, new_b)


def main():
    ap = argparse.ArgumentParser(description='In-place equal-length Codex i18n patch')
    ap.add_argument('asar')
    ap.add_argument('exe')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--no-backup', action='store_true')
    args = ap.parse_args()

    asar = Path(args.asar)
    exe = Path(args.exe)
    if not asar.is_file() or not exe.is_file():
        sys.exit('[error] asar/exe missing')

    with open(asar, 'rb') as fs:
        u3, data_offset, hdr = read_header(fs)
        name, node, blob, anchor = find_target(fs, data_offset, hdr)
        size = int(node['size'])
        file_off = data_offset + int(node['offset'])
        integrity = node.get('integrity')

        if anchor is None:
            print('[skip] gate already enabled in %s; verifying hashes' % name)
            new_blob = blob
            idx = -1
        else:
            idx = blob.index(anchor) + len(anchor) - 2  # the '1' byte
            new_blob = bytearray(blob)
            new_blob[idx] = 0x30
            new_blob = bytes(new_blob)

        new_file_hash = sha256(new_blob)
        region_start, region_end = node_region(hdr, name)
        region = hdr[region_start:region_end]
        new_header = hdr
        block_idx = -1
        new_block_hash = None
        if integrity:
            old_file_hash = integrity['hash']
            block_size = int(integrity.get('blockSize', 4194304))
            blocks = integrity.get('blocks')
            # A file smaller than one block stores the same hash twice (file
            # hash == blocks[0]); the count==1 guard would reject that, so the
            # single-block case swaps both roles in one equal-length replace.
            single_block = bool(blocks) and len(blocks) == 1 and blocks[0] == old_file_hash
            if blocks and idx >= 0:
                block_idx = idx // block_size
                b_start = block_idx * block_size
                b_end = min(b_start + block_size, size)
                new_block_hash = sha256(new_blob[b_start:b_end])
            if old_file_hash != new_file_hash:
                if single_block:
                    n = region.count(old_file_hash.encode())
                    if n != 2:
                        sys.exit('[error] single-block hash occurs %d times in node' % n)
                    region = region.replace(old_file_hash.encode(), new_file_hash.encode())
                else:
                    region = swap_once(region, old_file_hash, new_file_hash, 'file')
            if blocks and idx >= 0 and not single_block:
                old_block_hash = blocks[block_idx]
                if old_block_hash != new_block_hash:
                    region = swap_once(region, old_block_hash, new_block_hash, 'block')
            new_header = hdr[:region_start] + region + hdr[region_end:]
        if len(new_header) != u3:
            sys.exit('[error] header length changed (%d -> %d)' % (u3, len(new_header)))
        new_exe_hash = sha256(new_header)

    exe_bytes = exe.read_bytes()
    m = EXE_PAT.search(exe_bytes)
    if not m:
        sys.exit('[error] exe integrity segment not found')
    old_exe_hash = m.group(1).decode()

    print('[info] target      : %s' % name)
    gate = 'already !0' if idx < 0 else 'offset %d in file' % idx
    print('[info] gate byte   : %s' % gate)
    print('[info] file hash   : %s -> %s' % (integrity['hash'] if integrity else '-', new_file_hash))
    if new_block_hash:
        print('[info] block[%d]   : -> %s' % (block_idx, new_block_hash))
    print('[info] header len  : %d (unchanged)' % u3)
    print('[info] exe hash    : %s -> %s' % (old_exe_hash, new_exe_hash))

    if args.dry_run:
        print('[dry-run] no writes performed')
        return
    if idx < 0 and old_exe_hash == new_exe_hash:
        print('[skip] already patched and consistent; nothing to do')
        return

    if not args.no_backup:
        bak = exe.with_suffix(exe.suffix + '.bak')
        if not bak.exists():
            shutil.copy2(exe, bak)
            print('[ok] exe backup  : %s' % bak)

    with open(asar, 'r+b') as fs:
        if idx >= 0:
            fs.seek(file_off + idx)
            fs.write(b'0')
        fs.seek(16)
        fs.write(new_header)
        fs.flush()
    new_exe = exe_bytes[:m.start(1)] + new_exe_hash.encode() + exe_bytes[m.end(1):]
    exe.write_bytes(new_exe)
    print('[ok] patched in place; no unpack/repack, no FATAL hash dance needed')


if __name__ == '__main__':
    main()