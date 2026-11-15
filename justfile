# SPDX-License-Identifier: MIT
# candy-for-gnome: terminal-inspired GNOME themes (one directory per scheme under themes/) and icon sets from several icon repos
# (tools/icon-sources.conf). Run `just` for the list; every recipe is a thin call into tools/themectl.sh. Needs just, bash, git.

[private]
default:
    @just --list --unsorted

# Themes: the directories under themes/ of this repo, installed into ~/.themes (THEMES_DEST)

# List the available themes (a check mark = installed)
[group('themes')]
list-themes:
    @tools/themectl.sh themes list

# Install a theme (name optional: pick from a list)
[group('themes')]
install-theme name="":
    @tools/themectl.sh themes install "{{name}}"

# Refresh the installed themes from this repo
[group('themes')]
update-theme:
    @tools/themectl.sh themes update

# Remove an installed theme (name optional: pick from a list)
[group('themes')]
remove-theme name="":
    @tools/themectl.sh themes remove "{{name}}"

# Use a theme for GTK, Shell and libadwaita (name, accent optional)
[group('themes')]
switch-theme name="" accent="":
    @tools/themectl.sh themes switch "{{name}}" "{{accent}}"

# Icons: sets of the repos in tools/icon-sources.conf (Papirus, Gruvbox Plus, Zafiro, candy, Tela, Fluent, Conflux, WhiteSur; ICONS_URL replaces the papirus URL), listed from the registry without cloning; the sources of the chosen sets are cloned into ~/.cache/candy-for-gnome/icons and the sets installed into ~/.local/share/icons (ICONS_DEST)

# List the available icon sets (a check mark = installed)
[group('icons')]
list-icons:
    @tools/themectl.sh icons list

# Install an icon set (name optional: pick from a list)
[group('icons')]
install-icon name="":
    @tools/themectl.sh icons install "{{name}}"

# Refresh the installed icon sets from their sources
[group('icons')]
update-icon:
    @tools/themectl.sh icons update

# Remove an installed icon set (name optional: pick from a list)
[group('icons')]
remove-icon name="":
    @tools/themectl.sh icons remove "{{name}}"

# Use an icon set (name optional: pick from a list)
[group('icons')]
switch-icon name="":
    @tools/themectl.sh icons switch "{{name}}"

# Development: regenerate one scheme (or all) from its scheme.toml: palette tables, GTK3, GTK4 and GNOME Shell CSS from the toolkits' own stock stylesheets, the libadwaita file, the accent maps and the GtkSourceView style schemes and the Ghostty themes (needs python3-gobject, GTK 3, GTK 4 and gnome-shell)
[private]
generate theme="all":
    #!/usr/bin/env bash
    set -euo pipefail
    export PYTHONDONTWRITEBYTECODE=1
    if [ "{{theme}}" = all ]; then schemes=$(for f in themes/*/scheme.toml; do basename "$(dirname "$f")"; done); else schemes="{{theme}}"; fi
    [ -n "${CANDY_FOR_GNOME_SKIP_ASSETS:-}" ] || python3 -I tools/assets-gen.py
    for s in $schemes; do
        echo "== $s"; d="themes/$s"
        python3 -I tools/palette-from-scheme.py "$d"
        name=$(awk -F'"' '/^gtk_name/ {print $2}' "$d/palette.toml"); title=$(awk -F'"' '/^title/ {print $2}' "$d/palette.toml")
        acc=$(mktemp -d)
        python3 -I tools/gtk3-theme-gen.py --palette="$d/palette.toml" --out="$d/gtk/$name/gtk-3.0" --accent-dir="$acc"
        python3 -I tools/gtk4-theme-gen.py --palette="$d/palette.toml" --out="$d/gtk/$name/gtk-4.0" --accent-dir="$acc"
        python3 -I tools/shell-theme-gen.py --palette="$d/palette.toml" --out="$d/gtk" --accent-dir="$acc"
        python3 -I tools/libadwaita-gen.py --palette="$d/palette.toml" --out="$d/libadwaita/gtk.css" --accent-dir="$acc"
        printf '[Desktop Entry]\nType=X-GNOME-Metatheme\nName=%s\nComment=%s recolour of GTK'"'"'s own stock stylesheets (gtk-3.0 from GTK3 Adwaita, gtk-4.0 from GTK4 Default); libadwaita apps use the user-level libadwaita/gtk.css\n' "$name" "$title" > "$d/gtk/$name/index.theme"
        for g in "$d"/gtk/*/; do [ -f "$g/LICENSE" ] || cp themes/gruvbox-material/gtk/Gruvbox-Material/LICENSE "$g/LICENSE"; done
        python3 -I tools/accent-maps-gen.py "$d" "$acc"
        python3 -I tools/gtksourceview-gen.py "$d"
        python3 -I tools/ghostty-gen.py "$d"
        python3 -I tools/alacritty-gen.py "$d" >/dev/null
        python3 -I tools/helix-gen.py "$d" >/dev/null
        python3 -I tools/yazi-gen.py "$d" >/dev/null
        python3 -I tools/kitty-gen.py "$d" >/dev/null
        python3 -I tools/bat-gen.py "$d" >/dev/null
        python3 -I tools/eza-gen.py "$d" >/dev/null
        python3 -I tools/zellij-gen.py "$d" >/dev/null
        python3 -I tools/claude-gen.py "$d" >/dev/null
        python3 -I tools/palette-svg-gen.py "$d" >/dev/null
        python3 -I tools/theme-readme-gen.py "$d" >/dev/null
        rm -rf "$acc"
    done

# Development: contrast, structure, parse, accent-map and probe checks of a generated scheme (needs python3-gobject, GTK 3, GTK 4 and gnome-shell)
[private]
test theme="gruvbox-material":
    PYTHONDONTWRITEBYTECODE=1 python3 -I tools/selftest.py {{theme}}

# Development: start a new scheme from a built-in Ptyxis palette (ids: tools/ptyxis-palette.sh list): writes a DRAFT <scheme-dir>/scheme.toml and prints the decisions left (the build-scheme skill has the whole walk-through)
[private]
new-scheme dir palette light="":
    #!/usr/bin/env bash
    set -euo pipefail
    light="{{light}}"
    python3 -I tools/scheme-from-ptyxis.py "themes/{{dir}}" "{{palette}}" ${light:+"$light"}
    echo
    echo "Next: resolve the TODOs in themes/{{dir}}/scheme.toml, then run:"
    echo "  just generate {{dir}} && just test {{dir}} (optionally tools/test.sh {{dir}}; CI on the pull request is the test)"
    echo "and add the credit to NOTICE and the scheme to the list in README.md (see .claude/skills/build-scheme/SKILL.md)."

# Development: build schemes from the Ptyxis built-in palettes listed (status todo) in tools/ptyxis-schemes.tsv, or the named ones: draft, finalize, generate, check; a failing one is removed and recorded as excluded (python3 -I tools/bulk-scheme.py status|inventory for the rest)
[private]
bulk-scheme *args:
    python3 -I tools/bulk-scheme.py build {{args}}
