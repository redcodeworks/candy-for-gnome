#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate a scheme's Claude Code custom themes (<scheme>/claude/<scheme>-{dark,light}.json).

  python3 -I tools/claude-gen.py <scheme-dir> [--check]     # --check: print, write nothing

Claude Code reads custom themes from ~/.claude/themes/<slug>.json: {"name", "base", "overrides": {token: "#rrggbb"}}. A custom theme has ONE `base`
(dark or light), so there is no pair per theme: the installer copies the variant chosen at switch time to ~/.claude/themes/candy-for-gnome.json (selected
in Claude Code with /theme, stored as `custom:candy-for-gnome`). JSON has no comments: the marker is the `name`: "candy-for-gnome: <scheme> <variant>".
Tokens are the theme keys of Claude Code 2.1 (the built-in theme object); only the ones that map onto colours of the scheme are overridden, the rest
(system spinner blue, clawd, rate limit, fast mode, effort, brief labels) stay with the base. COLOURS: the editor palette of tools/appthemes.py (text tokens
at 4.5:1 on the editor background); text = fg, inverseText = bg_deep, claude = orange, permission/suggestion/ide = blue, success = green, error = red,
warning = yellow, merged/autoAccept/skill = purple, remember/bashBorder = magenta, planMode = cyan, inactive = comment (3:1), subtle = fg-dim,
promptBorder = comment, diff backgrounds = green/red mixed 18 % (word 38 %) into the editor background, user message = the current line colour,
selection = the scheme's selection role; shimmer = the colour moved 25 % towards fg; subagent and rainbow colours = the scheme's accents.
"""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import appthemes as A

def overrides(v):
    c = v.syn; B = c['bg-deep']; m = A.mix
    sh = lambda x: m(x, c['fg'], 0.25)
    tok = {
        'claude': c['orange'], 'text': c['fg'], 'inverseText': B, 'inactive': c['comment'], 'subtle': c['fg-dim'],
        'permission': c['blue'], 'suggestion': c['blue'], 'ide': c['blue'], 'remember': c['magenta'], 'bashBorder': c['magenta'],
        'success': c['green'], 'error': c['red'], 'warning': c['yellow'], 'merged': c['purple'], 'autoAccept': c['purple'], 'skill': c['purple'],
        'planMode': c['cyan'], 'promptBorder': c['comment'], 'background': c['cyan'],
        'diffAdded': m(B, c['green'], 0.18), 'diffRemoved': m(B, c['red'], 0.18), 'diffAddedDimmed': m(B, c['green'], 0.10), 'diffRemovedDimmed': m(B, c['red'], 0.10),
        'diffAddedWord': m(B, c['green'], 0.38), 'diffRemovedWord': m(B, c['red'], 0.38),
        'userMessageBackground': c['bg'], 'userMessageBackgroundHover': m(c['bg'], c['selection'], 0.5), 'selectionBg': c['selection'],
        'bashMessageBackgroundColor': c['bg'], 'memoryBackgroundColor': c['bg'],
        'red_FOR_SUBAGENTS_ONLY': c['red'], 'blue_FOR_SUBAGENTS_ONLY': c['blue'], 'green_FOR_SUBAGENTS_ONLY': c['green'], 'yellow_FOR_SUBAGENTS_ONLY': c['yellow'],
        'purple_FOR_SUBAGENTS_ONLY': c['purple'], 'orange_FOR_SUBAGENTS_ONLY': c['orange'], 'pink_FOR_SUBAGENTS_ONLY': c['magenta'], 'cyan_FOR_SUBAGENTS_ONLY': c['cyan'],
        'rainbow_red': c['red'], 'rainbow_orange': c['orange'], 'rainbow_yellow': c['yellow'], 'rainbow_green': c['green'], 'rainbow_blue': c['cyan'],
        'rainbow_indigo': c['blue'], 'rainbow_violet': c['purple'],
    }
    for k in ('claude', 'autoAccept', 'permission', 'promptBorder', 'inactive', 'warning'): tok[k + 'Shimmer'] = sh(tok[k])
    for k in ('red', 'orange', 'yellow', 'green', 'blue', 'indigo', 'violet'): tok['rainbow_%s_shimmer' % k] = sh(tok['rainbow_' + k])
    return tok

def text(scheme, v):
    return json.dumps({'name': 'candy-for-gnome: %s %s' % (scheme, v.slot), 'base': v.slot, 'overrides': overrides(v)}, indent=2) + '\n'

def build(d):
    scheme, vs, _ = A.model(d)
    return scheme, {'%s-%s.json' % (scheme, s): text(scheme, v) for s, v in vs.items()}

if __name__ == '__main__': A.main(build, 'claude', __doc__)
