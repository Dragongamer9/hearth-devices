#!/usr/bin/env python3
"""Recover a panel's power-on command sequence from a stock MediaTek panel module.

Oukitel's RT8 panel modules are built from MediaTek's reference "jdi" panel
template: every init command is a small const array in .rodata, sent with
mipi_dsi_generic_write() / mipi_dsi_dcs_write_buffer(dsi, data, len) from
jdi_prepare(). This walks the disassembly of jdi_prepare in order and prints
each command, plus the delays and GPIO toggles between them.

  extract-panel-init.py <panel.ko> [--dts]

Needs aarch64-linux-gnu-objdump/objcopy/nm (binutils-aarch64-linux-gnu).
--dts prints the commands as a "cust,initial-command" property for the
wb,drm_lcm panel driver (delay ms, length, bytes...).
"""
import re, subprocess, sys

WRITES = ('mipi_dsi_generic_write', 'mipi_dsi_dcs_write_buffer')
SLEEPS = ('usleep_range', 'msleep', 'udelay', '__const_udelay', '__udelay')

def tool(name, *args):
    return subprocess.run([f'aarch64-linux-gnu-{name}', *args], capture_output=True, check=True).stdout

def func_range(ko, func):
    syms = tool('nm', '-n', ko).decode().splitlines()
    addrs = [(int(a, 16), n) for a, t, n in (l.split() for l in syms if len(l.split()) == 3) if t in 'tT']
    for i, (a, n) in enumerate(addrs):
        if n == func:
            return a, addrs[i + 1][0]
    sys.exit(f'{func} not found in {ko}')

def walk(ko, func='jdi_prepare'):
    lo, hi = func_range(ko, func)
    asm = tool('objdump', '-dr', '--no-show-raw-insn', f'--start-address={lo:#x}',
               f'--stop-address={hi:#x}', ko).decode().splitlines()
    rodata = tool('objcopy', '-O', 'binary', '--only-section=.rodata', ko, '/dev/stdout')
    regs, pending, seq = {}, None, []
    for ln in asm:
        m = re.search(r'R_AARCH64_ADD_ABS_LO12_NC\s+\.rodata(?:\+0x([0-9a-f]+))?', ln)
        if m and pending:
            regs[pending] = ('ro', int(m.group(1) or '0', 16)); pending = None; continue
        m = re.search(r'\badd\s+(x\d+),\s*x\d+,\s*#0x0\b', ln)
        if m:
            pending = m.group(1); continue
        m = re.search(r'\bmov\s+[wx](\d+),\s*#(0x[0-9a-f]+|\d+)', ln)
        if m:
            regs['x' + m.group(1)] = ('imm', int(m.group(2), 0)); continue
        m = re.search(r'R_AARCH64_CALL26\s+(\S+)', ln)
        if not m:
            continue
        f = m.group(1)
        if f in WRITES:
            a, n = regs.get('x1'), regs.get('x2')
            if a and a[0] == 'ro' and n and n[0] == 'imm':
                seq.append(('cmd', rodata[a[1]:a[1] + n[1]]))
            else:
                seq.append(('cmd?', None))
        elif f in SLEEPS:
            v = regs.get('x0')
            us = v[1] if v else 0
            seq.append(('sleep_ms', us if f == 'msleep' else us // 1000))
        elif f == 'gpiod_set_value':
            v = regs.get('x1'); seq.append(('gpio', v[1] if v else None))
        for r in [r for r in regs if r in {f'x{i}' for i in range(9)}]:
            regs.pop(r)
    return seq

def main():
    ko = sys.argv[1]; dts = '--dts' in sys.argv
    seq = walk(ko)
    cmds, delay = [], 0
    # Pair each command with the delay that follows it.
    for kind, val in seq:
        if kind == 'cmd':
            cmds.append([val, 0])
        elif kind == 'sleep_ms' and cmds:
            cmds[-1][1] += val
    if not dts:
        for kind, val in seq:
            print('DCS ' + val.hex(' ') if kind == 'cmd' else f'{kind} {val}')
        print(f'# {len(cmds)} commands', file=sys.stderr)
        return
    # wb,drm_lcm format (struct dsi_cmd_desc): <wait_ms len payload...> per command,
    # sent with mipi_dsi_dcs_write_buffer(). wait is one byte, so cap at 255 ms.
    rows = []
    for b, d in cmds:
        rows.append(f'\t\t\t{min(d, 255):02x} {len(b):02x} ' + ' '.join(f'{x:02x}' for x in b))
    print('cust,initial-command = [\n' + '\n'.join(rows) + '\n\t\t];')

if __name__ == '__main__':
    main()
