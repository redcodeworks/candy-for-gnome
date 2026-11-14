#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate a scheme's bat themes (<scheme>/bat/candy-for-gnome-<scheme>-{dark,light}.tmTheme).

  python3 -I tools/bat-gen.py <scheme-dir> [--check]     # --check: print, write nothing

bat (0.25+) takes TextMate themes only and has --theme-dark / --theme-light with --theme="auto:system" (bat decides light or dark from the terminal's
colour query, not from GNOME). The installer copies the files into `$(bat --config-dir)/themes/`, keeps the stable names candy-for-gnome-dark.tmTheme
and candy-for-gnome-light.tmTheme pointing at the scheme's two files, and runs `bat cache --build`. COLOURS and scope mapping: tools/appthemes.py (the
editor palette, as the GtkSourceView styles: keywords magenta, storage red, strings green, numbers orange, types yellow, functions blue, operators and
escapes cyan, preprocessor purple, comments the comment colour in italics). A dark-only scheme has only the dark file. Marker: an XML comment.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import appthemes as A

def build(d):
    scheme, vs, _ = A.model(d)
    return scheme, {A.ident(scheme, s) + '.tmTheme': A.tmtheme(scheme, 'bat', v) for s, v in vs.items()}

if __name__ == '__main__': A.main(build, 'bat', __doc__)
