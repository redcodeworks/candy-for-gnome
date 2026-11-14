#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate a scheme's eza themes (<scheme>/eza/candy-for-gnome-<scheme>-{dark,light}.yml).

  python3 -I tools/eza-gen.py <scheme-dir> [--check]     # --check: print, write nothing

eza reads ONE file, $XDG_CONFIG_HOME/eza/theme.yml, and has no light/dark variants: the installer links it at the variant chosen at switch time.
The key set is eza's (eza_colors-explanation(5), eza 0.23): filekinds, perms, size, users, links, git, git_repo, security_context, file_type and the
single-colour entries; the structure is the one of the long-standing hand-made Gruvbox Material file. COLOURS: the editor palette of tools/appthemes.py
(every colour has at least 4.5:1 on the editor background, secondary text (fg-dim, comment) 4.5 and 3:1 respectively); the mapping: normal = fg,
directories and mount points = blue (bold), symlinks = cyan, executables = green (bold), devices = orange (bold), pipes = yellow, sockets and
specials = magenta, write bits and root = red, read bits and your user = yellow, dates, punctuation and temp files = comment. A set EZA_COLORS or
LS_COLORS may override parts of the file. Marker: `# candy-for-gnome: <scheme>`.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import appthemes as A

TEMPLATE = '''filekinds:
  normal: {{foreground: "{fg}"}}
  directory: {{foreground: "{blue}", is_bold: true}}
  symlink: {{foreground: "{cyan}"}}
  pipe: {{foreground: "{yellow}"}}
  block_device: {{foreground: "{orange}", is_bold: true}}
  char_device: {{foreground: "{orange}", is_bold: true}}
  socket: {{foreground: "{magenta}"}}
  special: {{foreground: "{magenta}"}}
  executable: {{foreground: "{green}", is_bold: true}}
  mount_point: {{foreground: "{blue}", is_bold: true, is_underline: true}}

perms:
  user_read: {{foreground: "{yellow}"}}
  user_write: {{foreground: "{red}"}}
  user_execute_file: {{foreground: "{green}", is_underline: true}}
  user_execute_other: {{foreground: "{green}", is_underline: true}}
  group_read: {{foreground: "{yellow}"}}
  group_write: {{foreground: "{red}"}}
  group_execute: {{foreground: "{green}"}}
  other_read: {{foreground: "{yellow}"}}
  other_write: {{foreground: "{red}"}}
  other_execute: {{foreground: "{green}"}}
  special_user_file: {{foreground: "{magenta}"}}
  special_other: {{foreground: "{magenta}"}}
  attribute: {{foreground: "{fg_dim}"}}

size:
  major: {{foreground: "{green}"}}
  minor: {{foreground: "{cyan}"}}
  number_byte: {{foreground: "{green}"}}
  number_kilo: {{foreground: "{green}"}}
  number_mega: {{foreground: "{yellow}"}}
  number_giga: {{foreground: "{orange}"}}
  number_huge: {{foreground: "{red}"}}
  unit_byte: {{foreground: "{fg_dim}"}}
  unit_kilo: {{foreground: "{fg_dim}"}}
  unit_mega: {{foreground: "{fg_dim}"}}
  unit_giga: {{foreground: "{fg_dim}"}}
  unit_huge: {{foreground: "{fg_dim}"}}

users:
  user_you: {{foreground: "{yellow}"}}
  user_root: {{foreground: "{red}"}}
  user_other: {{foreground: "{fg_dim}"}}
  group_yours: {{foreground: "{yellow}"}}
  group_other: {{foreground: "{fg_dim}"}}
  group_root: {{foreground: "{red}"}}

links:
  normal: {{foreground: "{magenta}"}}
  multi_link_file: {{foreground: "{orange}"}}

git:
  new: {{foreground: "{green}"}}
  modified: {{foreground: "{yellow}"}}
  deleted: {{foreground: "{red}"}}
  renamed: {{foreground: "{cyan}"}}
  ignored: {{foreground: "{comment}"}}
  conflicted: {{foreground: "{orange}", is_bold: true}}

git_repo:
  branch_main: {{foreground: "{green}"}}
  branch_other: {{foreground: "{magenta}"}}
  git_clean: {{foreground: "{green}"}}
  git_dirty: {{foreground: "{yellow}"}}

security_context:
  none: {{foreground: "{comment}"}}
  selinux:
    colon: {{foreground: "{comment}"}}
    user: {{foreground: "{blue}"}}
    role: {{foreground: "{magenta}"}}
    typ: {{foreground: "{yellow}"}}
    range: {{foreground: "{green}"}}

file_type:
  image: {{foreground: "{magenta}"}}
  video: {{foreground: "{magenta}", is_bold: true}}
  music: {{foreground: "{orange}"}}
  crypto: {{foreground: "{red}"}}
  document: {{foreground: "{green}"}}
  compressed: {{foreground: "{yellow}"}}
  temp: {{foreground: "{comment}"}}
  compiled: {{foreground: "{orange}"}}
  build: {{foreground: "{yellow}", is_bold: true}}
  source: {{foreground: "{cyan}"}}

punctuation: {{foreground: "{comment}"}}
date: {{foreground: "{comment}"}}
inode: {{foreground: "{magenta}"}}
blocks: {{foreground: "{comment}"}}
header: {{foreground: "{fg}", is_underline: true}}
octal: {{foreground: "{magenta}"}}
flags: {{foreground: "{magenta}"}}
control_char: {{foreground: "{red}"}}
broken_symlink: {{foreground: "{red}"}}
broken_path_overlay: {{foreground: "{comment}", is_underline: true}}
'''

def text(scheme, v):
    c = {k.replace('-', '_'): x for k, x in v.syn.items()}
    return '\n'.join(A.header(scheme, 'eza', v)) + '\n\n' + TEMPLATE.format(**c)

def build(d):
    scheme, vs, _ = A.model(d)
    return scheme, {A.ident(scheme, s) + '.yml': text(scheme, v) for s, v in vs.items()}

if __name__ == '__main__': A.main(build, 'eza', __doc__)
