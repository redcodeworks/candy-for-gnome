#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate a scheme's Yazi flavors (<scheme>/yazi/candy-for-gnome-<scheme>-{dark,light}.yazi/{flavor.toml,tmtheme.xml}).

  python3 -I tools/yazi-gen.py <scheme-dir> [--check]     # --check: print, write nothing

A Yazi flavor is a directory `<name>.yazi` with `flavor.toml` (the UI: same tables as theme.toml) and `tmtheme.xml` (the syntax colours of the code
preview). Yazi 26.8.15+ picks `[flavor] dark = ... light = ...` by the system appearance. The installer copies the directories into
$XDG_CONFIG_HOME/yazi/flavors and keeps the stable names candy-for-gnome-dark.yazi and candy-for-gnome-light.yazi pointing at the scheme's two (a
dark-only scheme: its dark one for both). Yazi merges the user's theme.toml OVER the flavor, so colour overrides there win.
The table layout and keys are those of the official flavors (yazi-rs/flavors); the filetype rules and icons use Yazi's defaults for shapes (no [icon]
table: the default icons stay). COLOURS: the editor palette of tools/appthemes.py; accent = blue; copied/ok = green, cut/error = red, marked = cyan,
selected/warn = yellow, find = yellow and magenta, permissions: type blue, read yellow, write red, exec green; borders = comment (3:1); text on filled
badges = the editor background on the filled colour (4.5:1). tmtheme.xml = tools/appthemes.py tmtheme (as bat). Marker: `# candy-for-gnome: <scheme>` in
flavor.toml and an XML comment in tmtheme.xml.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import appthemes as A

def flavor(scheme, v):
    c = v.syn; B = c['bg-deep']; surf = v.R['surface'].lower(); hi = v.R['surface_high'].lower(); acc = c['blue']
    f = lambda fg=None, bg=None, **k: '{ ' + ', '.join(([f'fg = "{fg}"'] if fg else []) + ([f'bg = "{bg}"'] if bg else []) + [f'{n} = true' for n in k]) + ' }'
    L = A.header(scheme, 'yazi', v)
    L += ['', '[mgr]', f'cwd = {f(c["cyan"])}', '',
          f'find_keyword  = {f(c["yellow"], bold=1, italic=1, underline=1)}', f'find_position = {f(c["magenta"], bold=1, italic=1)}', '',
          f'marker_copied   = {f(c["green"], c["green"])}', f'marker_cut      = {f(c["red"], c["red"])}',
          f'marker_marked   = {f(c["cyan"], c["cyan"])}', f'marker_selected = {f(c["yellow"], c["yellow"])}', '',
          f'count_copied   = {f(B, c["green"])}', f'count_cut      = {f(B, c["red"])}', f'count_selected = {f(B, c["yellow"])}', '',
          'border_symbol = "│"', f'border_style  = {f(c["comment"])}', '',
          '[tabs]', f'active   = {f(B, acc, bold=1)}', f'inactive = {f(acc, surf)}', '',
          '[mode]', f'normal_main = {f(B, acc, bold=1)}', f'normal_alt  = {f(acc, surf)}',
          f'select_main = {f(B, c["cyan"], bold=1)}', f'select_alt  = {f(c["cyan"], surf)}',
          f'unset_main  = {f(B, c["orange"], bold=1)}', f'unset_alt   = {f(c["orange"], surf)}', '',
          '[status]', f'perm_sep   = {f(c["comment"])}', f'perm_type  = {f(acc)}', f'perm_read  = {f(c["yellow"])}',
          f'perm_write = {f(c["red"])}', f'perm_exec  = {f(c["green"])}', '',
          f'progress_label  = {f(c["fg"], bold=1)}', f'progress_normal = {f(c["green"], hi)}', f'progress_error  = {f(c["yellow"], c["red"])}', '',
          '[pick]', f'border   = {f(acc)}', f'active   = {f(c["magenta"], bold=1)}', 'inactive = {}', '',
          '[input]', f'border   = {f(acc)}', 'title    = {}', 'value    = {}', f'hint     = {f(c["comment"], italic=1)}', 'selected = { reversed = true }', '',
          '[cmp]', f'border = {f(acc)}', '',
          '[tasks]', f'border  = {f(acc)}', 'title   = {}', f'hovered = {f(c["magenta"], bold=1)}', '',
          '[which]', f'border          = {f(acc)}', f'cand            = {f(c["cyan"])}', f'rest            = {f(c["fg-dim"])}',
          f'desc            = {f(c["magenta"])}', 'separator       = "  "', f'separator_style = {f(c["comment"])}', '',
          '[help]', f'on      = {f(c["cyan"])}', f'run     = {f(c["magenta"])}', 'hovered = { reversed = true, bold = true }', f'footer  = {f(c["fg"], surf)}', '',
          '[spot]', f'border   = {f(acc)}', f'title    = {f(acc)}', f'tbl_col  = {f(c["cyan"])}', f'tbl_cell = {f(c["magenta"], hi)}', '',
          '[notify]', f'title_info  = {f(c["green"])}', f'title_warn  = {f(c["yellow"])}', f'title_error = {f(c["red"])}', '',
          '[filetype]', '', 'rules = [',
          f'\t{{ mime = "**/image/*", fg = "{c["cyan"]}" }},', f'\t{{ mime = "**/{{audio,video}}/*", fg = "{c["yellow"]}" }},',
          f'\t{{ mime = "**/application/{{zip,rar,7z*,tar,gzip,xz,zstd,bzip*,lzma,compress,archive,cpio,arj,xar,ms-cab*}}", fg = "{c["magenta"]}" }},',
          f'\t{{ mime = "**/application/{{pdf,doc,rtf}}", fg = "{c["green"]}" }},', f'\t{{ mime = "vfs/{{absent,stale}}", fg = "{c["comment"]}" }},',
          f'\t{{ url = "*", fg = "{c["fg"]}" }},', f'\t{{ url = "*/", fg = "{acc}" }},', ']']
    return '\n'.join(L) + '\n'

def build(d):
    scheme, vs, _ = A.model(d)
    out = {}
    for s, v in vs.items():
        n = A.ident(scheme, s) + '.yazi'
        out[n + '/flavor.toml'] = flavor(scheme, v); out[n + '/tmtheme.xml'] = A.tmtheme(scheme, 'yazi', v)
    return scheme, out

if __name__ == '__main__': A.main(build, 'yazi', __doc__)
