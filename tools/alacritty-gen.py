#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate a scheme's Alacritty colour fragments (<scheme>/alacritty/candy-for-gnome-<scheme>-{dark,light}.toml).

  python3 -I tools/alacritty-gen.py <scheme-dir> [--check]     # --check: print, write nothing

Alacritty has no native light/dark switching, so the installer links ~/.config/alacritty/themes/candy-for-gnome.toml at the variant chosen at switch time.
Each file is a TOML fragment ([colors.primary], [colors.cursor], [colors.selection], [colors.normal], [colors.bright]) for `general.import`.
COLOURS: the terminal colours of tools/appthemes.py (the Ptyxis built-in decision, as Ghostty); cursor = Foreground on Background, selection = the
scheme's `selection` role with Foreground. A dark-only scheme has only the dark file. Marker: `# candy-for-gnome: <scheme>`.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import appthemes as A

NAMES = ('black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white')

def text(scheme, v):
    t = v.term; L = A.header(scheme, 'alacritty', v)
    L += ['[colors.primary]', 'background = "%s"' % t['Background'], 'foreground = "%s"' % t['Foreground'], '',
          '[colors.cursor]', 'text = "%s"' % t['CursorText'], 'cursor = "%s"' % t['Cursor'], '',
          '[colors.selection]', 'text = "%s"' % t['SelectionForeground'], 'background = "%s"' % t['SelectionBackground'], '']
    for tab, off in (('normal', 0), ('bright', 8)):
        L.append('[colors.%s]' % tab); L += ['%s = "%s"' % (n, t['Color%d' % (i + off)]) for i, n in enumerate(NAMES)]; L.append('')
    return '\n'.join(L).rstrip('\n') + '\n'

def build(d):
    scheme, vs, _ = A.model(d)
    return scheme, {A.ident(scheme, s) + '.toml': text(scheme, v) for s, v in vs.items()}

if __name__ == '__main__': A.main(build, 'alacritty', __doc__)
