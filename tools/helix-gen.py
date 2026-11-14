#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate a scheme's Helix themes (<scheme>/helix/candy-for-gnome-<scheme>-{dark,light}.toml).

  python3 -I tools/helix-gen.py <scheme-dir> [--check]     # --check: print, write nothing

Helix 25.07 has no automatic light/dark switching (the `[theme] dark/light` table exists only on master), so the installer links
~/.config/helix/themes/candy-for-gnome.toml at the variant chosen at switch time and the user's config.toml says `theme = "candy-for-gnome"`.
Each file is a Helix theme: scope keys in the style of the bundled themes (gruvbox, base16_default) and a [palette] table. COLOURS and scope mapping:
the editor palette of tools/appthemes.py (as the GtkSourceView styles: keywords magenta, statements/storage red, strings green, numbers and
constants orange, types yellow, functions blue, operators, builtins and escapes cyan, preprocessor purple, comments the comment colour in italics;
every colour has 4.5:1 on the editor background, comments 3:1). UI: background = bg_deep, statusline and popups = the scheme's surface roles, selection =
the selection role, cursor = fg on bg_deep, modes = blue (normal), green (insert), orange (select). A dark-only scheme has only the dark file.
Marker: `# candy-for-gnome: <scheme>`.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import appthemes as A

def text(scheme, v):
    c = v.syn; R = v.R
    P = {'bg': c['bg-deep'], 'bg_line': c['bg'], 'surface': R['surface'].lower(), 'surface_high': R['surface_high'].lower(), 'selection': c['selection'],
         'fg': c['fg'], 'fg_dim': c['fg-dim'], 'comment': c['comment'], 'red': c['red'], 'orange': c['orange'], 'yellow': c['yellow'], 'green': c['green'],
         'cyan': c['cyan'], 'blue': c['blue'], 'magenta': c['magenta'], 'purple': c['purple']}
    K = [  # (scope, style); style is a palette name or an inline table body
        ('comment', '{ fg = "comment", modifiers = ["italic"] }'), ('constant', '"orange"'), ('constant.numeric', '"orange"'),
        ('constant.builtin', '"orange"'), ('constant.character', '"cyan"'), ('constant.character.escape', '"cyan"'), ('constant.macro', '"cyan"'),
        ('string', '"green"'), ('string.regexp', '"cyan"'), ('string.special', '"cyan"'), ('string.symbol', '"yellow"'),
        ('keyword', '"magenta"'), ('keyword.control', '"red"'), ('keyword.control.import', '"cyan"'), ('keyword.operator', '"cyan"'),
        ('keyword.directive', '"purple"'), ('keyword.storage', '"red"'), ('keyword.function', '"magenta"'),
        ('operator', '"cyan"'), ('punctuation', '"fg_dim"'), ('punctuation.delimiter', '"fg_dim"'), ('punctuation.bracket', '"fg_dim"'),
        ('type', '"yellow"'), ('type.builtin', '"yellow"'), ('type.enum.variant', '{ modifiers = ["italic"] }'), ('constructor', '"yellow"'),
        ('function', '"blue"'), ('function.builtin', '"cyan"'), ('function.macro', '"purple"'), ('function.method', '"blue"'),
        ('variable', '"fg"'), ('variable.builtin', '{ fg = "red", modifiers = ["italic"] }'), ('variable.parameter', '{ fg = "fg", modifiers = ["italic"] }'),
        ('variable.other.member', '"blue"'), ('attribute', '{ fg = "yellow", modifiers = ["italic"] }'), ('label', '"red"'),
        ('namespace', '"cyan"'), ('module', '"cyan"'), ('tag', '"red"'), ('special', '"purple"'), ('annotation', '"fg"'),
        ('markup.heading', '{ fg = "yellow", modifiers = ["bold"] }'), ('markup.bold', '{ modifiers = ["bold"] }'), ('markup.italic', '{ modifiers = ["italic"] }'),
        ('markup.strikethrough', '{ modifiers = ["crossed_out"] }'), ('markup.link.url', '{ fg = "blue", modifiers = ["underlined"] }'),
        ('markup.link.text', '"cyan"'), ('markup.link.label', '"blue"'), ('markup.quote', '"comment"'), ('markup.raw', '"orange"'), ('markup.list', '"cyan"'),
        ('diff.plus', '"green"'), ('diff.minus', '"red"'), ('diff.delta', '"yellow"'),
        ('error', '"red"'), ('warning', '"yellow"'), ('info', '"cyan"'), ('hint', '"blue"'),
        ('diagnostic', '{ underline = { color = "orange", style = "curl" } }'), ('diagnostic.error', '{ underline = { color = "red", style = "curl" } }'),
        ('diagnostic.warning', '{ underline = { color = "yellow", style = "curl" } }'), ('diagnostic.info', '{ underline = { color = "cyan", style = "curl" } }'),
        ('diagnostic.hint', '{ underline = { color = "blue", style = "curl" } }'), ('diagnostic.deprecated', '{ modifiers = ["crossed_out"] }'),
        ('diagnostic.unnecessary', '{ modifiers = ["dim"] }'), ('definition', '{ underline = { color = "cyan" } }'),
        ('ui.background', '{ bg = "bg" }'), ('ui.text', '{ fg = "fg" }'), ('ui.text.focus', '{ fg = "fg", bg = "selection" }'), ('ui.text.directory', '{ fg = "blue" }'),
        ('ui.text.inactive', '"comment"'), ('ui.text.info', '{ fg = "fg" }'),
        ('ui.cursor', '{ fg = "bg", bg = "fg_dim" }'), ('ui.cursor.primary', '{ fg = "bg", bg = "fg" }'), ('ui.cursor.match', '{ fg = "fg", bg = "selection", modifiers = ["bold"] }'),
        ('ui.cursor.primary.normal', '{ fg = "bg", bg = "fg" }'), ('ui.cursor.primary.insert', '{ fg = "bg", bg = "green" }'), ('ui.cursor.primary.select', '{ fg = "bg", bg = "orange" }'),
        ('ui.cursor.normal', '{ fg = "bg", bg = "fg_dim" }'), ('ui.cursor.insert', '{ fg = "bg", bg = "green" }'), ('ui.cursor.select', '{ fg = "bg", bg = "orange" }'),
        ('ui.selection', '{ bg = "selection" }'), ('ui.selection.primary', '{ bg = "selection" }'),
        ('ui.cursorline.primary', '{ bg = "bg_line" }'), ('ui.cursorline.secondary', '{ bg = "bg_line" }'),
        ('ui.linenr', '{ fg = "fg_dim" }'), ('ui.linenr.selected', '{ fg = "fg", bg = "bg_line" }'),
        ('ui.gutter', '{ bg = "bg" }'), ('ui.gutter.selected', '{ bg = "bg_line" }'),
        ('ui.statusline', '{ fg = "fg", bg = "surface" }'), ('ui.statusline.inactive', '{ fg = "fg_dim", bg = "surface" }'),
        ('ui.statusline.normal', '{ fg = "bg", bg = "blue", modifiers = ["bold"] }'), ('ui.statusline.insert', '{ fg = "bg", bg = "green", modifiers = ["bold"] }'),
        ('ui.statusline.select', '{ fg = "bg", bg = "orange", modifiers = ["bold"] }'),
        ('ui.bufferline', '{ fg = "fg_dim", bg = "surface" }'), ('ui.bufferline.active', '{ fg = "bg", bg = "blue", modifiers = ["bold"] }'),
        ('ui.bufferline.background', '{ bg = "surface" }'),
        ('ui.popup', '{ fg = "fg", bg = "surface" }'), ('ui.popup.info', '{ fg = "fg", bg = "surface" }'), ('ui.window', '{ fg = "comment" }'),
        ('ui.help', '{ fg = "fg", bg = "surface" }'), ('ui.menu', '{ fg = "fg", bg = "surface" }'),
        ('ui.menu.selected', '{ fg = "fg", bg = "surface_high", modifiers = ["bold"] }'), ('ui.menu.scroll', '{ fg = "fg_dim", bg = "surface_high" }'),
        ('ui.picker.header.column', '{ underline.style = "line" }'), ('ui.picker.header.column.active', '{ modifiers = ["bold"], underline.style = "line" }'),
        ('ui.virtual.ruler', '{ bg = "bg_line" }'), ('ui.virtual.whitespace', '"selection"'), ('ui.virtual.indent-guide', '"selection"'),
        ('ui.virtual.inlay-hint', '{ fg = "comment" }'), ('ui.virtual.jump-label', '{ fg = "purple", modifiers = ["bold"] }'),
        ('ui.virtual.wrap', '{ fg = "selection" }'),
    ]
    L = A.header(scheme, 'helix', v)
    L += ['']
    for k, s in K: L.append('"%s" = %s' % (k, s))
    L += ['', '[palette]'] + ['%s = "%s"' % (k, x) for k, x in P.items()]
    return '\n'.join(L) + '\n'

def build(d):
    scheme, vs, _ = A.model(d)
    return scheme, {A.ident(scheme, s) + '.toml': text(scheme, v) for s, v in vs.items()}

if __name__ == '__main__': A.main(build, 'helix', __doc__)
