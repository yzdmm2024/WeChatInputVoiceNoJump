#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fixup_macho.py — 链接后修复 Mach-O（解决 clang/lld 在本工具链下的两个坑）：
  1) --arm64e : 把 mach_header 的 cpusubtype 强制写为 0x2 (CPU_SUBTYPE_ARM64E)。
     原因：lld 链接时把 arm64e 对象文件的 cpusubtype 抹回 0x0(arm64)，
     iPhone 12 Pro(A14) 是 arm64e，缺此切片会导致 PreferenceLoader 报
     “已损坏或丢失必要的资源”(坑F)。
  2) --add-dylib p1 p2 ... : 在 header 后插入 LC_LOAD_DYLIB 命令，使 bundle 正确
     链接 UIKit/Foundation/PreferencesUI 等框架（坑E）。插入后同步修正既有
     load command 中的绝对文件偏移，保证二进制仍合法。

用法:
  python fixup_macho.py <in> <out> [--arm64e] [--add-dylib "/path/A" "/path/B"]
"""
import struct, sys

LC_SEGMENT_64          = 0x19
LC_SYMTAB              = 0x02
LC_DYSYMTAB            = 0x0b
LC_DYLD_INFO_ONLY      = 0x80000022
LC_DATA_IN_CODE        = 0x29
LC_CODE_SIGNATURE      = 0x1d
LC_LINKER_OPT_HINT     = 0x2e
LC_DYLD_CHAINED_FIXUPS = 0x80000034
LC_DYLD_EXPORTS_TRIE   = 0x80000033
# 以下均为 linkedit_data_command（cmd,cmdsize,dataoff,datasize = 16 字节）
LINKEDIT_DATA_CMDS = {LC_DATA_IN_CODE, LC_LINKER_OPT_HINT, LC_DYLD_CHAINED_FIXUPS,
                      LC_DYLD_EXPORTS_TRIE, LC_CODE_SIGNATURE}

ARM64E_SUBTYPE = 0x2

def set_arm64e(data: bytearray):
    ct, cs = struct.unpack_from('<II', data, 4)
    if (ct & 0x0fffffff) != 0x0100000c:
        print("  警告: 非 ARM64 (cputype=0x%x)，跳过 arm64e" % ct)
        return
    if cs != ARM64E_SUBTYPE:
        struct.pack_into('<I', data, 8, ARM64E_SUBTYPE)
        print("  cpusubtype 0x%x -> 0x%x (arm64e)" % (cs, ARM64E_SUBTYPE))

def patch_file_offsets(full: bytearray, ncmds: int, delta: int):
    """在 full 的 load commands 区(从 offset 32 起)就地修正绝对文件偏移。
    delta: 插入新命令后，其余内容向后移动的字节数。"""
    from struct import unpack_from, pack_into
    off = 32
    for _ in range(ncmds):
        cmd, size = unpack_from('<II', full, off)
        if cmd == LC_SEGMENT_64:
            fileoff = unpack_from('<Q', full, off + 0x28)[0]
            if fileoff:
                pack_into('<Q', full, off + 0x28, fileoff + delta)
            nsects = unpack_from('<I', full, off + 0x40)[0]
            sec = off + 0x48
            for _s in range(nsects):
                soff = unpack_from('<I', full, sec + 0x30)[0]
                if soff:
                    pack_into('<I', full, sec + 0x30, soff + delta)
                sec += 80
        elif cmd == LC_SYMTAB:
            symoff = unpack_from('<I', full, off + 0x8)[0]
            stroff = unpack_from('<I', full, off + 0x10)[0]
            if symoff: pack_into('<I', full, off + 0x8, symoff + delta)
            if stroff: pack_into('<I', full, off + 0x10, stroff + delta)
        elif cmd == LC_DYSYMTAB:
            for fld in (0x20, 0x28, 0x30, 0x38, 0x40, 0x48):
                v = unpack_from('<I', full, off + fld)[0]
                if v: pack_into('<I', full, off + fld, v + delta)
        elif cmd == LC_DYLD_INFO_ONLY:
            for fld in (0x8, 0xc, 0x10, 0x14, 0x18):
                v = unpack_from('<I', full, off + fld)[0]
                if v: pack_into('<I', full, off + fld, v + delta)
        elif cmd in LINKEDIT_DATA_CMDS:
            v = unpack_from('<I', full, off + 0x8)[0]
            if v: pack_into('<I', full, off + 0x8, v + delta)
        off += size

def make_load_dylib(name: str) -> bytes:
    nb = name.encode('utf-8') + b'\0'
    nb = nb + b'\0' * ((-len(nb)) % 8)   # 8 字节对齐
    cmdsize = 24 + len(nb)               # dylib_command(24) + name
    cmd = bytearray(cmdsize)
    struct.pack_into('<II', cmd, 0, 0x1c, cmdsize)   # LC_LOAD_DYLIB
    struct.pack_into('<I', cmd, 8, 24)              # name offset (relative to cmd)
    struct.pack_into('<I', cmd, 12, 0)              # timestamp
    struct.pack_into('<I', cmd, 16, 0x10000)        # current_version
    struct.pack_into('<I', cmd, 20, 0x10000)        # compat_version
    cmd[24:24+len(nb)] = nb
    return bytes(cmd)

def add_dylibs(data: bytearray, names: list) -> bytearray:
    new_cmds = b''.join(make_load_dylib(n) for n in names)
    delta = len(new_cmds)
    magic = struct.unpack_from('<I', data, 0)[0]
    assert magic == 0xfeedfacf, "仅支持 64 位 Mach-O"
    ncmds, sizeofcmds = struct.unpack_from('<II', data, 16)
    lc_end = 32 + sizeofcmds
    # 先修正既有命令的绝对文件偏移（就地改 full）
    patch_file_offsets(data, ncmds, delta)
    # 取修正后的旧 load commands 字节，组成 [header][new][old_lcs][rest(已后移 delta)]
    old_lcs = bytes(data[32:lc_end])
    rest = bytes(data[lc_end:])
    new = bytearray(data[:32])
    struct.pack_into('<I', new, 16, ncmds + len(names))
    struct.pack_into('<I', new, 20, sizeofcmds + delta)
    new += new_cmds
    new += old_lcs
    new += rest
    print("  插入 %d 个 LC_LOAD_DYLIB (delta=%d)" % (len(names), delta))
    for n in names:
        print("    + %s" % n)
    return new

def main():
    args = sys.argv[1:]
    if len(args) < 2:
        sys.stderr.write("usage: fixup_macho.py <in> <out> [--arm64e] [--add-dylib p1 p2 ...]\n")
        sys.exit(2)
    src, dst = args[0], args[1]
    rest = args[2:]
    arm64e = '--arm64e' in rest
    dylibs = []
    if '--add-dylib' in rest:
        i = rest.index('--add-dylib')
        dylibs = rest[i+1:]
    data = bytearray(open(src, 'rb').read())
    if arm64e:
        set_arm64e(data)
    if dylibs:
        data = add_dylibs(data, dylibs)
    open(dst, 'wb').write(data)
    print("fixup 完成: %s -> %s (%d bytes)" % (src, dst, len(data)))

if __name__ == '__main__':
    main()
