#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate a scheme's kitty colour files (<scheme>/kitty/candy-for-gnome-<scheme>-{dark,light}.conf).

  python3 -I tools/kitty-gen.py <scheme-dir> [--check]     # --check: print, write nothing

kitty (0.38+) switches colours by itself from three files in its config directory: dark-theme.auto.conf, light-theme.auto.conf and
no-preference-theme.auto.conf (GNOME reports a preference, but the no-preference file must still carry the light colours). The installer links those at
the scheme's two files here (a dark-only scheme: its dark file for all three). Each file sets foreground, background, selection, cursor, url and the
16 colours. COLOURS: the terminal colours of tools/appthemes.py (as Ghostty). Marker: `# candy-for-gnome: <scheme>`.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import appthemes as A

def text(scheme, v):
    t = v.term; L = A.header(scheme, 'kitty', v)
    L += ['foreground %s' % t['Foreground'], 'background %s' % t['Background'], 'selection_foreground %s' % t['Foreground'], 'selection_background %s' % v.sel,
          'cursor %s' % t['Cursor'], 'cursor_text_color %s' % t['Background'], 'url_color %s' % v.syn['blue'],
          'active_border_color %s' % v.syn['blue'], 'inactive_border_color %s' % v.syn['comment'],
          'active_tab_foreground %s' % t['Background'], 'active_tab_background %s' % v.syn['blue'],
          'inactive_tab_foreground %s' % t['Foreground'], 'inactive_tab_background %s' % v.R['surface'].lower()]
    L += ['color%d %s' % (i, t['Color%d' % i]) for i in range(16)]
    return '\n'.join(L) + '\n'

def build(d):
    scheme, vs, _ = A.model(d)
    return scheme, {A.ident(scheme, s) + '.conf': text(scheme, v) for s, v in vs.items()}

if __name__ == '__main__': A.main(build, 'kitty', __doc__)
