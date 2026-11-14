#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate a scheme's zellij theme file (<scheme>/zellij/candy-for-gnome-<scheme>.kdl).

  python3 -I tools/zellij-gen.py <scheme-dir> [--check]     # --check: print, write nothing

One KDL file per scheme that defines TWO themes, `candy-for-gnome-dark` and `candy-for-gnome-light` (zellij 0.42+: several themes per file; `theme_dark` and
`theme_light` in config.kdl pick one by the system appearance). A dark-only scheme defines both names from its dark colours, a light-only one from its
light colours. The components are zellij's current format (text_unselected, text_selected, ribbon_*, table_*, list_*, frame_*, exit_code_*,
multiplayer_user_colors, terminal_colors), colours as `r g b`.
COLOURS: the editor palette of tools/appthemes.py (4.5:1 on the editor background) and the scheme roles: panes = fg on the window colour (`bg`), selected
rows = fg on the selection role, ribbons: selected = bg_deep text on the green accent, unselected = fg on surface_high (moved towards the editor background until 4.5:1); emphasis_0..3 = orange, cyan, green,
magenta (zellij's own order); on the filled ribbons the emphasis colours are the editor background mixed 25 % with those accents so they stay readable.
The ribbon accent is moved in lightness only until bg_deep text has 4.5:1 on it. terminal_colors = the terminal colours (as Ghostty).
Marker: `// candy-for-gnome: <scheme>`.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import appthemes as A

NAMES = ('black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white')

def theme(v, name):
    c, R, t = v.syn, v.R, v.term
    B, win = c['bg-deep'], R['bg'].lower()
    emph = [c['orange'], c['cyan'], c['green'], c['magenta']]
    rib = v.ink(c['green'], B)      # a ribbon colour with 4.5:1 for the editor-background text on it
    rib_e = [A.mix(B, x, 0.25) for x in (c['red'], c['orange'], c['blue'], c['magenta'])]
    surf = A.fit(R['surface_high'].lower(), c['fg'], B); sel = c['selection']
    comps = []
    def comp(n, base, bg, e):
        body = ['base %s' % A.rgb3(base), 'background %s' % (A.rgb3(bg) if bg else '0')] + ['emphasis_%d %s' % (i, A.rgb3(x)) for i, x in enumerate(e)]
        comps.append('        %s {\n%s\n        }' % (n, '\n'.join('            ' + b for b in body)))
    comp('text_unselected', c['fg'], win, emph); comp('text_selected', c['fg'], sel, emph)
    comp('ribbon_selected', B, rib, rib_e); comp('ribbon_unselected', c['fg'], surf, emph); comp('ribbon_hover', B, c['blue'], rib_e)
    comp('table_title', c['yellow'], win, emph); comp('table_cell_selected', c['fg'], sel, emph); comp('table_cell_unselected', c['fg'], win, emph)
    comp('list_selected', c['fg'], sel, emph); comp('list_unselected', c['fg'], win, emph)
    comp('frame_selected', c['green'], None, [c['orange'], c['cyan'], c['magenta'], c['magenta']])
    comp('frame_highlight', c['orange'], None, [c['magenta'], c['orange'], c['red'], c['red']])
    comp('exit_code_success', c['green'], None, [c['cyan'], win, c['magenta'], c['blue']])
    comp('exit_code_error', c['red'], None, [c['yellow'], c['orange'], c['magenta'], c['green']])
    players = [c['magenta'], c['cyan'], c['red'], c['yellow'], c['green'], c['blue'], c['orange'], c['purple'], c['fg-dim'], c['comment']]
    mp = '\n'.join('            player_%d %s' % (i + 1, A.rgb3(x)) for i, x in enumerate(players))
    tc = '\n'.join('            %s %s' % (n if i < 8 else 'bright_' + NAMES[i - 8], A.rgb3(t['Color%d' % i])) for i, n in enumerate(NAMES + NAMES))
    return '    %s {\n%s\n        multiplayer_user_colors {\n%s\n        }\n        terminal_colors {\n%s\n        }\n    }' % (name, '\n'.join(comps), mp, tc)

def build(d):
    scheme, vs, S = A.model(d)
    dark = vs.get('dark') or vs['light']; light = vs.get('light') or vs['dark']
    L = A.header(scheme, 'zellij', dark, '//')
    L[2] = '// %s, a dark and a light theme (a scheme without one of them repeats the other).' % dark.title
    L += ['themes {', theme(dark, 'candy-for-gnome-dark'), theme(light, 'candy-for-gnome-light'), '}']
    return scheme, {'candy-for-gnome-%s.kdl' % scheme: '\n'.join(L) + '\n'}

if __name__ == '__main__': A.main(build, 'zellij', __doc__)
