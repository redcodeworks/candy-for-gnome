# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# KDE color schemes and qt5ct/qt6ct palettes for themectl.sh (sourced, not run). The model in one sentence: for each scheme the generators
# (tools/kde-gen.py, tools/qtct-gen.py) write a KDE `.colors` scheme and a qtct palette per variant from the same roles as the other generators, and
# switch-theme installs the chosen variant where KDE and Qt apps look (the live ~/.config/kdeglobals, color-schemes/, the qtct colors dirs).
# PILOT: only the schemes that have <scheme>/kde (today the featured ones, see QT_SCOPE in tools/appthemes.py) take part; every function does nothing for
# another scheme, so extending it is a generator change only.
# Rules (the repo's marker rules): files carry `# candy-for-gnome: <scheme>` on their first line; a same-named file without it is never replaced silently
# (pty_may_touch: prompt, FORCE=1, or refusal). ~/.config/kdeglobals is a user file KDE apps also write: it is created when absent, MERGED when ours
# (marker, or a ColorScheme=candy-for-gnome-* line, because KDE may rewrite the file and drop comments), and otherwise (for example written by Noctalia's
# template) left alone unless the user answers y or FORCE=1; then the old one is kept as kdeglobals.bak. Only the color groups, [WM] and the keys
# ColorScheme, Name, ColorSchemeHash and [KDE] contrast are ever touched; every other line stays. qtct palettes are written only where the qt5ct/qt6ct
# config directory exists (nothing is created for software that is not there) and qt5ct.conf/qt6ct.conf are never edited (a hint prints).
kde_dir="${KDE_COLOR_SCHEMES:-${XDG_DATA_HOME:-$HOME/.local/share}/color-schemes}"
kde_globals="${KDEGLOBALS:-$cfg/kdeglobals}"
kde_has() { [ -n "$(ls "$(sdir "$1")/kde" 2>/dev/null)" ]; }   # does scheme $1 take part in the pilot
kde_variant() {   # kde_variant SCHEME: dark or light by the system colour scheme; the other one when the scheme has only that variant
    local w o=light; w=$(pty_mode); [ "$w" = light ] && o=dark
    if [ -e "$(sdir "$1")/kde/candy-for-gnome-$1-$w.colors" ]; then echo "$w"; else echo "$o"; fi
}
kde_hex2rgb() { local h="${1#\#}"; printf '%d,%d,%d' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"; }
kde_accent() {    # kde_accent FILE SCHEME VARIANT: put the remembered accent into an installed copy (the default accent's value is replaced)
    local f="$1" s="$2" v="$3" ca i d="" n="" dh nh
    ca=$(current_accent "$s"); load_accents "$s"; [ -n "$ca" ] && [ "$ca" != "$acc_default" ] || return 0
    for i in "${!acc_names[@]}"; do
        if [ "$v" = light ] && [ "${acc_light[i]}" != - ]; then dh="${acc_light[i]}"; else dh="${acc_dark[i]}"; fi
        [ "${acc_names[i]}" = "$acc_default" ] && d="$dh"; [ "${acc_names[i]}" = "$ca" ] && n="$dh"
    done
    [ -n "$d" ] && [ -n "$n" ] && [ "$d" != "$n" ] || return 0
    case "$f" in
        *.colors) sed -i "s/=$(kde_hex2rgb "$d")\$/=$(kde_hex2rgb "$n")/" "$f" ;;
        *) sed -i -E "s/${d}([^0-9a-fA-F]|\$)/${n}\\1/g" "$f" ;;
    esac
}
kde_targets() {   # kde_targets SCHEME: "<source>|<destination>" of every file to install: color-schemes always, qtct palettes where qt5ct/qt6ct has a config dir
    local s="$1" f q
    kde_has "$s" || return 0
    for f in "$(sdir "$s")"/kde/*.colors; do echo "$f|$kde_dir/$(basename "$f")"; done
    for q in qt5ct qt6ct; do
        [ -d "$cfg/$q" ] || continue
        for f in "$(sdir "$s")"/qtct/*.conf; do echo "$f|$cfg/$q/colors/$(basename "$f")"; done
    done
    return 0
}
kde_put() { local src="$1" dst="$2" s="$3" v; mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; v="${src##*-}"; v="${v%%.*}"; kde_accent "$dst" "$s" "$v"; }
kde_install() {   # install-theme and the first step of switch-theme
    local s="$1" src dst n=0
    kde_has "$s" || return 0
    while IFS='|' read -r src dst; do
        pty_may_touch "$s" Replace "$dst" || continue
        kde_put "$src" "$dst" "$s"; n=$((n+1))
    done < <(kde_targets "$s")
    [ "$n" -eq 0 ] || echo "Installed $n KDE color scheme and qtct palette file(s) of $s ($kde_dir, qt5ct/qt6ct colors)."
    return 0
}
kde_ours_globals() { [ -f "$kde_globals" ] && { head -n1 "$kde_globals" | grep -qE '^# candy-for-gnome: [A-Za-z0-9._-]+[[:space:]]*$' || grep -qE '^ColorScheme=candy-for-gnome-' "$kde_globals"; }; }
kde_globals_scheme() { sed -n 's/^ColorScheme=candy-for-gnome-\(.*\)-\(dark\|light\)[[:space:]]*$/\1/p' "$kde_globals" 2>/dev/null | head -n1; }
kde_merge() {   # kde_merge MODE SCHEME COLORS_FILE: write kdeglobals (apply: our groups replaced, everything else kept; strip: ours removed). Writes through the file.
    local mode="$1" s="$2" new="${3:-/dev/null}" tmp; tmp=$(mktemp)
    awk -v mode="$mode" -v marker="# candy-for-gnome: $s" '
        function wholesale(g) { return g ~ /^ColorEffects:/ || g ~ /^Colors:/ || g == "WM" }
        function managed(g, k) { return (g == "General" && (k == "ColorScheme" || k == "Name" || k == "ColorSchemeHash")) || (g == "KDE" && k == "contrast") }
        function emit(g,   i) { for (i = 1; i <= nk[g]; i++) { print keys[g, i]; last = keys[g, i] } }
        BEGIN { if (mode == "apply") print marker }
        FILENAME == ARGV[1] {
            if ($0 ~ /^\[.*\]$/) { ng = substr($0, 2, length($0) - 2); if (wholesale(ng)) { order[++no] = ng; blk[ng] = $0 "\n" } next }
            if (ng == "") next
            if (wholesale(ng)) { blk[ng] = blk[ng] $0 "\n"; next }
            k = $0; sub(/=.*/, "", k); if (managed(ng, k)) { keys[ng, ++nk[ng]] = $0 }
            next }
        FNR == 1 && $0 ~ /^# candy-for-gnome: / { next }
        /^\[.*\]$/ { g = substr($0, 2, length($0) - 2); skip = wholesale(g)
            if (!skip) { if (last != "" && last !~ /^#/) print ""; print; last = $0; seen[g] = 1; if (mode == "apply" && (g == "General" || g == "KDE")) emit(g) } next }
        skip { next }
        { k = $0; sub(/=.*/, "", k); if (g != "" && managed(g, k)) next; print; last = $0 }
        END { if (mode != "apply") exit
              if (!seen["General"] && nk["General"]) { if (last != "" && last !~ /^#/) print ""; print "[General]"; last = "[General]"; emit("General") }
              if (!seen["KDE"] && nk["KDE"]) { if (last != "" && last !~ /^#/) print ""; print "[KDE]"; last = "[KDE]"; emit("KDE") }
              if (last != "" && last !~ /^#/) print ""
              for (i = 1; i <= no; i++) printf "%s", blk[order[i]] }
    ' "$new" "$kde_globals" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    if [ "$mode" = strip ] && ! grep -qE '^[[:space:]]*[^#[:space:]]' "$tmp"; then rm -f "$kde_globals" "$tmp"; echo "Removed $kde_globals (nothing but our colors was in it)."; return 0; fi
    cat "$tmp" > "$kde_globals" && rm -f "$tmp"
}
kde_switch() {    # switch-theme: make the installed color scheme the live one, hint for qtct
    local s="$1" v c f q n ask=n
    kde_has "$s" || return 0
    v=$(kde_variant "$s"); c="$kde_dir/candy-for-gnome-$s-$v.colors"
    if ! pty_ours "$s" "$c"; then echo "KDE colors not applied: $c is missing or not ours (run install-theme $s first)."; return 0; fi
    mkdir -p "$(dirname "$kde_globals")"
    if [ ! -e "$kde_globals" ]; then
        : > "$kde_globals"; kde_merge apply "$s" "$c" && echo "Created $kde_globals with the colors of $s ($v). To undo: just remove-theme $s (or delete the file)."
    elif kde_ours_globals; then
        kde_merge apply "$s" "$c" && echo "Updated $kde_globals with the colors of $s ($v). To undo: just remove-theme $s"
    else
        if [ "${FORCE:-}" = 1 ]; then ask=y
        elif [ "$tty_in" = 1 ]; then
            read -r -u 3 -p "$kde_globals was not written by candy-for-gnome (for example by Noctalia's KDE template, which rewrites it again later). Replace its color groups with the theme's? The old file is kept as kdeglobals.bak. [y/N] " ask || ask=n
        fi
        case "$ask" in
            [yY]*) cp -L --backup=numbered "$kde_globals" "$kde_globals.bak" && kde_merge apply "$s" "$c" \
                       && echo "Replaced the color groups in $kde_globals with the colors of $s ($v). To undo: cp $kde_globals.bak $kde_globals" ;;
            *) echo "Left $kde_globals alone: it was not written by candy-for-gnome, so KDE and Kirigami apps keep its colors. To hand it over, turn off the program that writes it (Noctalia: its KDE template) and run switch-theme in a terminal and answer y (or FORCE=1)." >&2 ;;
        esac
    fi
    for q in qt5ct qt6ct; do
        [ -d "$cfg/$q" ] || continue
        f="$cfg/$q/colors/candy-for-gnome-$s-$v.conf"; [ -e "$f" ] || continue
        echo "Next: in $q (Appearance, Palette: Custom) pick candy-for-gnome-$s-$v, or set color_scheme_path=$f and custom_palette=true under [Appearance] in $cfg/$q/$q.conf (not edited here)."
    done
    echo "Restart KDE and Qt apps to pick up the colors (they read kdeglobals when they start)."
    return 0
}
kde_refresh() {   # update-theme: refresh the installed copies that are ours, and kdeglobals when it names this scheme
    local s="$1" src dst v
    kde_has "$s" || return 0
    while IFS='|' read -r src dst; do
        if [ -e "$dst" ] && pty_ours "$s" "$dst"; then kde_put "$src" "$dst" "$s"; fi
    done < <(kde_targets "$s")
    if kde_ours_globals && [ "$(kde_globals_scheme)" = "$s" ]; then
        v=$(sed -n 's/^ColorScheme=candy-for-gnome-.*-\(dark\|light\)[[:space:]]*$/\1/p' "$kde_globals" | head -n1)
        [ -f "$kde_dir/candy-for-gnome-$s-$v.colors" ] && kde_merge apply "$s" "$kde_dir/candy-for-gnome-$s-$v.colors"
    fi
    return 0
}
kde_unglobals() {   # kde_unglobals [SCHEME]: strip our groups from kdeglobals (only when ours, and only for SCHEME when given)
    kde_ours_globals || return 0
    [ -z "${1:-}" ] || [ "$(kde_globals_scheme)" = "$1" ] || return 0
    kde_merge strip "${1:-x}" && { [ ! -e "$kde_globals" ] || echo "Removed the candy-for-gnome colors from $kde_globals (other settings kept)."; }
    [ ! -e "$kde_globals.bak" ] || echo "Note: $kde_globals.bak still holds the file as it was before candy-for-gnome (restore: cp $kde_globals.bak $kde_globals)."
    return 0
}
kde_remove() {    # remove-theme: marked files of this scheme, and our colors in kdeglobals when it names this scheme
    local s="$1" src dst
    kde_has "$s" || return 0
    kde_unglobals "$s"
    while IFS='|' read -r src dst; do
        [ -e "$dst" ] || continue
        if pty_ours "$s" "$dst"; then rm -f "$dst"; echo "Removed $dst"; else echo "Left $dst alone (not installed by candy-for-gnome)." >&2; fi
    done < <(kde_targets "$s")
    return 0
}
