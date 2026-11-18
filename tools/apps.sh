# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Per-application themes for themectl.sh (sourced, not run): Alacritty, Helix, Yazi, kitty, bat, eza, zellij and Claude Code.
# The prebuilt files live in <scheme>/<app>/ (tools/<app>-gen.py); this file installs, refreshes and removes them, and `switch-theme` points each tool at the scheme.
# The rules, the same for every app:
#   * An app counts as INSTALLED when its binary is on PATH or in the Homebrew bin dir (CANDY_FOR_GNOME_BREW_BIN, default /home/linuxbrew/.linuxbrew/bin).
#     A tool that is not installed is skipped silently everywhere (install, update, switch, remove) and nothing is created for it; `list-themes`
#     prints one line naming the skipped ones.
#   * Installed files carry the marker of the other generated files (`# candy-for-gnome: <scheme>`, `// ...` for KDL, an XML comment for tmTheme, the `name`
#     field for JSON); a same-named file without it is never overwritten (same guard as the rest of the installer: prompt, FORCE=1, or refusal).
#   * Tools without light/dark switching of their own (Alacritty, Helix, eza, Claude Code) follow the variant chosen at switch time from the system colour
#     scheme (pty_mode, as for Ptyxis); Yazi, kitty, bat and zellij get both variants and choose by themselves. A dark-only scheme uses its dark file for both.
#   * Managed links are relative links created only when the name is free or already ours (the target contains `candy-for-gnome-`).
#   * The tool's own config is edited only after ONE question per tool (default no; without a terminal the exact lines are printed and nothing is edited),
#     only the lines named in the question change, and remove-theme never edits a user config (it prints what may be deleted).
app_cur=""; app_scheme=""
app_names=(alacritty helix yazi kitty bat eza zellij claude)
app_brew="${CANDY_FOR_GNOME_BREW_BIN:-/home/linuxbrew/.linuxbrew/bin}"
app_exe() { case "$1" in helix) echo hx ;; *) echo "$1" ;; esac; }
app_bin() {   # the path of an app's binary: on PATH (CANDY_FOR_GNOME_APPS_PATH, a test knob, replaces the PATH search), else in the Homebrew bin dir
    local e p d; e=$(app_exe "$1")
    if [ -n "${CANDY_FOR_GNOME_APPS_PATH+x}" ]; then
        local IFS=:; for d in $CANDY_FOR_GNOME_APPS_PATH; do [ -x "$d/$e" ] && { echo "$d/$e"; return 0; }; done
    elif p=$(command -v "$e" 2>/dev/null); then echo "$p"; return 0; fi
    [ -x "$app_brew/$e" ] && { echo "$app_brew/$e"; return 0; }
    return 1
}
app_present() { app_bin "$1" >/dev/null; }
app_dir() {   # the config directory of an app
    case "$1" in
        alacritty) echo "$cfg/alacritty" ;; helix) echo "$cfg/helix" ;; yazi) echo "${YAZI_CONFIG_HOME:-$cfg/yazi}" ;;
        kitty) echo "${KITTY_CONFIG_DIRECTORY:-$cfg/kitty}" ;; eza) echo "${EZA_CONFIG_DIR:-$cfg/eza}" ;; zellij) echo "${ZELLIJ_CONFIG_DIR:-$cfg/zellij}" ;;
        claude) echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ;;
        bat) "$(app_bin bat)" --config-dir 2>/dev/null || echo "${BAT_CONFIG_DIR:-$cfg/bat}" ;;
    esac
}
app_sub() { case "$1" in yazi) echo flavors ;; *) echo themes ;; esac; }   # where the per-scheme files go inside the config directory
app_files() { local f; for f in "$(sdir "$2")/$1"/*; do [ -e "$f" ] && basename "$f"; done; return 0; }   # generated item names of scheme $2 for app $1
app_targets() {   # app_targets APP SCHEME: "<source>|<destination>" for every installed per-scheme file (Claude Code has none: its file is written at switch time)
    local a="$1" s="$2" d f; [ "$a" = claude ] && return 0
    d=$(app_dir "$a") || return 0
    for f in $(app_files "$a" "$s"); do echo "$(sdir "$s")/$a/$f|$d/$(app_sub "$a")/$f"; done; return 0
}
app_ours() { pty_ours "$1" "$2"; }   # pty_ours understands the # // and XML markers and directories (flavor.toml)
app_link_ours() { [ -L "$1" ] && case "$(readlink "$1")" in *candy-for-gnome-*) return 0 ;; esac; return 1; }
app_ask() { local a; if [ "$tty_in" = 1 ]; then read -r -u 3 -p "$1 [y/N] " a || a=n; case "$a" in [yY]*) return 0 ;; esac; fi; return 1; }
app_tilde() { case "$1" in "$HOME"/*) echo "~/${1#"$HOME"/}" ;; *) echo "$1" ;; esac; }
app_write() { cat "$2" > "$1" && rm -f "$2"; }   # write through the file (a user config may itself be a link), keeping its inode and mode
app_pick() {      # app_pick APP SCHEME EXT WANT: WANT (dark|light) when the scheme has that variant, else the other (dark-only / light-only schemes)
    local other=light; [ "$4" = light ] && other=dark
    if [ -e "$(sdir "$2")/$1/candy-for-gnome-$2-$4.$3" ]; then echo "$4"; else echo "$other"; fi
}
app_bat_cache() { local b; b=$(app_bin bat) && "$b" cache --build >/dev/null 2>&1 || true; }

# ---- install, refresh, remove -----------------------------------------------------------------------------------------------------
app_install() {   # app_install SCHEME: copy the per-scheme files of every installed app (collision guard as for the Ghostty files)
    local s="$1" a src dst n
    for a in "${app_names[@]}"; do
        app_present "$a" || continue
        sw_on "app:$a" || continue
        n=0
        while IFS='|' read -r src dst; do
            pty_may_touch "$s" Replace "$dst" || continue
            mkdir -p "$(dirname "$dst")"
            if [ -d "$src" ]; then rm -rf "$dst"; cp -r "$src" "$dst"; else cp "$src" "$dst"; fi
            n=$((n+1))
        done < <(app_targets "$a" "$s")
        if [ "$n" -gt 0 ]; then echo "[$a] installed $s"; [ "$a" != bat ] || app_bat_cache; fi
    done
    return 0
}
app_refresh() {   # update-theme: refresh only files that exist and are ours; Claude Code's switch-time file too
    local s="$1" a src dst did
    for a in "${app_names[@]}"; do
        app_present "$a" || continue
        did=0
        while IFS='|' read -r src dst; do
            if [ -e "$dst" ] && app_ours "$s" "$dst"; then
                if [ -d "$src" ]; then rm -rf "$dst"; cp -r "$src" "$dst"; else cp "$src" "$dst"; fi; did=1
            fi
        done < <(app_targets "$a" "$s")
        [ "$a" != bat ] || [ "$did" = 0 ] || app_bat_cache
    done
    if app_present bat && bat_repair "$(app_dir bat)/config"; then echo "[bat] updated config: --theme auto:system is macOS-only, now --theme auto"; fi
    claude_refresh "$s"
    return 0
}
app_link_targets_scheme() {   # exact names only: catppuccin must not claim a link that points at catppuccin-frappe
    case "$(basename "$(readlink "$1")")" in "candy-for-gnome-$2-dark."*|"candy-for-gnome-$2-light."*|"candy-for-gnome-$2.kdl") return 0 ;; esac; return 1
}
app_remove() {    # remove-theme: marked files, and managed links that point at this scheme; the user's configs are never edited
    local s="$1" a src dst d l rn
    for a in "${app_names[@]}"; do
        app_present "$a" || continue
        rn=0
        while IFS='|' read -r src dst; do
            [ -e "$dst" ] || continue
            if app_ours "$s" "$dst"; then rm -rf "$dst"; rn=$((rn+1)); else echo "Left $dst alone (not installed by candy-for-gnome)." >&2; fi
        done < <(app_targets "$a" "$s")
        while IFS='|' read -r l _; do
            if app_link_ours "$l" && app_link_targets_scheme "$l" "$s"; then rm -f "$l"; rn=$((rn+1)); fi
        done < <(app_links "$a" "$s" dark light)
        if [ "$rn" -gt 0 ]; then echo "[$a] removed $s"; fi
        [ "$a" != bat ] || app_bat_cache
        d=$(app_dir "$a"); app_note_config "$a" "$d"
    done
    claude_remove "$s"
    return 0
}
app_note_config() {   # after a removal: say which user config files still mention us (they are never edited)
    local a="$1" d="$2" f
    case "$a" in alacritty) f="$d/alacritty.toml" ;; helix) f="$d/config.toml" ;; yazi) f="$d/theme.toml" ;; bat) f="$d/config" ;; zellij) f="$d/config.kdl" ;; *) return 0 ;; esac
    [ -f "$f" ] && grep -n 'candy-for-gnome' "$f" 2>/dev/null | grep -v '^[0-9]*:[[:space:]]*\(#\|//\)' | head -3 | sed "s|^|$a: $f still has (delete when you like, nothing was edited) line |" >&2 || true
    return 0
}

# ---- links: app_links APP SCHEME WANT...: "<link path>|<relative target>" for the managed links of an app --------------------------------------
app_links() {
    local a="$1" s="$2" d v dk lt; shift 2; d=$(app_dir "$a")
    case "$a" in
        alacritty) v=$(app_pick alacritty "$s" toml "$(pty_mode)"); echo "$d/themes/candy-for-gnome.toml|candy-for-gnome-$s-$v.toml" ;;
        helix) v=$(app_pick helix "$s" toml "$(pty_mode)"); echo "$d/themes/candy-for-gnome.toml|candy-for-gnome-$s-$v.toml" ;;
        eza) v=$(app_pick eza "$s" yml "$(pty_mode)"); echo "$d/theme.yml|themes/candy-for-gnome-$s-$v.yml" ;;
        zellij) echo "$d/themes/candy-for-gnome.kdl|candy-for-gnome-$s.kdl" ;;
        yazi) dk=$(app_pick yazi "$s" yazi dark); lt=$(app_pick yazi "$s" yazi light)
              echo "$d/flavors/candy-for-gnome-dark.yazi|candy-for-gnome-$s-$dk.yazi"; echo "$d/flavors/candy-for-gnome-light.yazi|candy-for-gnome-$s-$lt.yazi" ;;
        bat) dk=$(app_pick bat "$s" tmTheme dark); lt=$(app_pick bat "$s" tmTheme light)
             echo "$d/themes/candy-for-gnome-dark.tmTheme|candy-for-gnome-$s-$dk.tmTheme"; echo "$d/themes/candy-for-gnome-light.tmTheme|candy-for-gnome-$s-$lt.tmTheme" ;;
        kitty) dk=$(app_pick kitty "$s" conf dark); lt=$(app_pick kitty "$s" conf light)
               echo "$d/dark-theme.auto.conf|themes/candy-for-gnome-$s-$dk.conf"; echo "$d/light-theme.auto.conf|themes/candy-for-gnome-$s-$lt.conf"
               echo "$d/no-preference-theme.auto.conf|themes/candy-for-gnome-$s-$lt.conf" ;;
    esac
    return 0
}
app_link() {      # app_link LINK TARGET: create or retarget a managed link; a name that exists and is not ours is asked about (default no) or refused
    local link="$1" tgt="$2" a err
    if { [ ! -e "$link" ] && [ ! -L "$link" ]; } || app_link_ours "$link"; then
        if ! err=$(mkdir -p "$(dirname "$link")" 2>&1 && ln -sfn "$tgt" "$link" 2>&1); then
            tfail "app:$app_cur" "$app_cur" "$(basename "$link")" "ln -sfn $tgt $link" "$err" "$(retry_cmd "app:$app_cur" "$app_scheme" "${accent_pick:-}")"; return 1
        fi
        return 0
    fi
    if [ "${FORCE:-}" = 1 ]; then a=y
    elif [ "$tty_in" = 1 ]; then read -r -u 3 -p "$link exists and was not created by candy-for-gnome. Replace it with a link to the theme? [y/N] " a || a=n
    else echo "Refused: $link exists and was not created by candy-for-gnome; left alone (FORCE=1 replaces it, or run in a terminal to be asked)." >&2; return 1; fi
    case "$a" in [yY]*) rm -rf "$link"; ln -s "$tgt" "$link" ;; *) echo "Left $link alone." >&2; return 1 ;; esac
}
app_ready() {     # app_ready APP SCHEME: the installed copy exists and is ours
    local first; first=$(app_targets "$1" "$2" | head -n1 | cut -d'|' -f2)
    if [ -z "$first" ] || ! app_ours "$2" "$first"; then echo "$1 theme not applied: the installed copy of $2 is missing or not ours (run install-theme $2 first)."; return 1; fi
    return 0
}
app_create() {    # app_create FILE COMMENT_PREFIX LINES: the config file does not exist, so write it with ONLY the theme lines (no consent needed: nothing of the user's is touched); never overwrites
    local f="$1" c="$2" txt="$3"
    [ ! -e "$f" ] && [ ! -L "$f" ] || return 1
    mkdir -p "$(dirname "$f")"
    ( set -o noclobber; printf '%s created by candy-for-gnome: only the theme lines below. Edit freely; switch-theme never changes lines you edit.\n%s\n' "$c" "$txt" > "$f" ) 2>/dev/null || return 1
}
app_offer() {     # app_offer FILE QUESTION PRINT_TEXT EDIT_FUNCTION: ask once (tty), edit on yes; else print the lines to add yourself
    local file="$1" q="$2" txt="$3" fn="$4"
    if [ "$tty_in" = 1 ]; then
        if app_ask "$q"; then
            if "$fn" "$file"; then return 0; fi
            echo "Could not edit $file safely. Make this change yourself:"
        else echo "Left $file alone. To use the theme, make this change yourself:"; fi
    else echo "Not editing $file without a terminal. To use the theme, make this change yourself:"; fi
    printf '%s\n' "$txt" | sed 's/^/  /'
    return 0
}

# ---- per-app edits of the user's config (each prints nothing, returns 3 when it cannot do the edit safely) -----------------------------------------
al_edit() {       # append the import to an existing `import = [...]` array (single line, or one element per line)
    awk -v P="$al_path" '
        { L[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) if (L[i] ~ /^[ \t]*import[ \t]*=[ \t]*\[/) { st = i; break }
            if (!st) exit 3
            if (L[st] ~ /\][ \t]*$/ && L[st] !~ /#/) {
                pre = substr(L[st], 1, index(L[st], "[")); rest = substr(L[st], index(L[st], "[") + 1); sub(/\][ \t]*$/, "", rest); gsub(/[ \t]+$/, "", rest); sub(/,$/, "", rest)
                if (rest ~ /^[ \t]*$/) L[st] = pre " \"" P "\" ]"; else L[st] = pre rest ", \"" P "\" ]"
            } else if (L[st] ~ /\[[ \t]*$/) {
                for (j = st + 1; j <= NR; j++) if (L[j] ~ /^[ \t]*\][ \t]*$/) break
                if (j > NR) exit 3
                k = j - 1; while (k > st && L[k] ~ /^[ \t]*(#.*)?$/) k--
                ind = "    "; if (k > st) { match(L[k], /^[ \t]*/); ind = substr(L[k], 1, RLENGTH); if (L[k] ~ /#/) exit 3; if (L[k] !~ /,[ \t]*$/) L[k] = L[k] "," }
                for (n = NR; n >= j; n--) L[n + 1] = L[n]; L[j] = ind "\"" P "\","; NR++
            } else exit 3
            for (i = 1; i <= NR; i++) print L[i]
        }' "$1" > "$1.candy-tmp" || { rm -f "$1.candy-tmp"; return 3; }
    app_write "$1" "$1.candy-tmp"
}
hx_edit() {       # replace the top-level theme = line, or add one at the top of the file
    local f="$1"
    if grep -qE '^\[theme\]' "$f"; then return 3; fi
    if awk 'BEGIN { top = 1 } /^[ \t]*\[/ { top = 0 } top && /^[ \t]*theme[ \t]*=/ { found = 1 } END { exit found ? 0 : 1 }' "$f"; then
        awk 'BEGIN { top = 1; done = 0 } /^[ \t]*\[/ { top = 0 } top && !done && /^[ \t]*theme[ \t]*=/ { print "theme = \"candy-for-gnome\""; done = 1; next } { print }' "$f" > "$f.candy-tmp"
    else { echo 'theme = "candy-for-gnome"'; cat "$f"; } > "$f.candy-tmp"; fi
    app_write "$f" "$f.candy-tmp"
}
yz_edit() {       # set dark and light inside the [flavor] table (replace in place; a missing key goes next to the other, or right after the header), or add the table at the top
    local f="$1"
    if ! grep -qE '^[[:space:]]*\[flavor\][[:space:]]*(#.*)?$' "$f"; then { printf '[flavor]\ndark = "candy-for-gnome-dark"\nlight = "candy-for-gnome-light"\n\n'; cat "$f"; } > "$f.candy-tmp"
    else
        awk '
            { L[NR] = $0 }
            END {
                DK = "dark = \"candy-for-gnome-dark\""; LT = "light = \"candy-for-gnome-light\""
                for (i = 1; i <= NR; i++) if (L[i] ~ /^[ \t]*\[flavor\][ \t]*(#.*)?$/) { st = i; break }
                for (e = st + 1; e <= NR; e++) if (L[e] ~ /^[ \t]*\[/) break
                for (i = st + 1; i < e; i++) { if (L[i] ~ /^[ \t]*dark[ \t]*=/) d = 1; if (L[i] ~ /^[ \t]*light[ \t]*=/) l = 1 }
                for (i = 1; i <= NR; i++) {
                    if (i > st && i < e && L[i] ~ /^[ \t]*dark[ \t]*=/) { print DK; if (!l) { print LT; l = 2 }; continue }
                    if (i > st && i < e && L[i] ~ /^[ \t]*light[ \t]*=/) { if (!d) print DK; print LT; continue }
                    print L[i]
                    if (i == st && !d && !l) { print DK; print LT }
                }
            }' "$f" > "$f.candy-tmp"
    fi
    app_write "$f" "$f.candy-tmp"
}
bat_repair() {    # bat_repair FILE: candy's old line --theme="auto:system" (macOS only, bat on Linux warns and falls back to its default) becomes --theme="auto"; only that exact line, and only in a file that also has candy's own dark line
    local f="$1"
    [ -f "$f" ] && grep -qxF -- '--theme="auto:system"' "$f" && grep -qxF -- '--theme-dark="candy-for-gnome-dark"' "$f" || return 1
    sed 's/^--theme="auto:system"$/--theme="auto"/' "$f" > "$f.candy-tmp" && app_write "$f" "$f.candy-tmp"
}
bat_edit() {      # replace --theme / --theme-dark / --theme-light lines in place, append the missing ones
    awk '
        BEGIN { t = "--theme=\"auto\""; dk = "--theme-dark=\"candy-for-gnome-dark\""; lt = "--theme-light=\"candy-for-gnome-light\"" }
        /^[ \t]*--theme=/ { if (!a) print t; a = 1; next }
        /^[ \t]*--theme-dark=/ { if (!b) print dk; b = 1; next }
        /^[ \t]*--theme-light=/ { if (!c) print lt; c = 1; next }
        { print }
        END { if (!a) print t; if (!b) print dk; if (!c) print lt }' "$1" > "$1.candy-tmp"
    app_write "$1" "$1.candy-tmp"
}
zj_edit() {       # replace theme_dark / theme_light nodes in place, append the missing ones
    awk '
        BEGIN { dk = "theme_dark \"candy-for-gnome-dark\""; lt = "theme_light \"candy-for-gnome-light\"" }
        /^[ \t]*theme_dark[ \t]/ { if (!b) print dk; b = 1; next }
        /^[ \t]*theme_light[ \t]/ { if (!c) print lt; c = 1; next }
        { print }
        END { if (!b) print dk; if (!c) print lt }' "$1" > "$1.candy-tmp"
    app_write "$1" "$1.candy-tmp"
}

# ---- switch: one function per app -------------------------------------------------------------------------------------------------------
app_ok() { echo "[$1] updated $2 with $3"; }   # the one success line of an app
app_links_apply() {   # app_links_apply APP SCHEME: create or retarget every managed link; returns 1 when one was refused
    local l t rc=0
    while IFS='|' read -r l t; do app_link "$l" "$t" || rc=1; done < <(app_links "$1" "$2")
    return $rc
}
alacritty_switch() {
    local s="$1" d f; d=$(app_dir alacritty); f="$d/alacritty.toml"
    app_ready alacritty "$s" && app_links_apply alacritty "$s" || return 0
    app_ok alacritty candy-for-gnome.toml "$s"
    al_path=$(app_tilde "$d/themes/candy-for-gnome.toml"); export al_path
    if [ -f "$f" ] && grep -qE '^[^#]*candy-for-gnome\.toml' "$f"; then :
    elif [ -f "$f" ]; then
        app_offer "$f" "Add \"$al_path\" to the import list of $f so Alacritty loads the theme (no other line is touched; a later import overrides these colors)?" \
"[general]
import = [ \"$al_path\" ]   # add this element to your existing import list; keep it AFTER other color imports" al_edit
    else app_create "$f" '#' "$(printf '[general]\nimport = [ "%s" ]' "$al_path")" || { echo "Alacritty: could not create $f. To use the theme, add to your Alacritty config:"; printf '  [general]\n  import = [ "%s" ]\n' "$al_path"; }; fi
}
helix_switch() {
    local s="$1" d f; d=$(app_dir helix); f="$d/config.toml"
    app_ready helix "$s" && app_links_apply helix "$s" || return 0
    app_ok helix candy-for-gnome.toml "$s"
    if [ -f "$f" ] && grep -qE '^[ \t]*theme[ \t]*=[ \t]*"candy-for-gnome"' "$f"; then :
    elif [ -f "$f" ]; then
        local cur; cur=$(awk 'BEGIN { top = 1 } /^[ \t]*\[/ { top = 0 } top && /^[ \t]*theme[ \t]*=/ { sub(/^[ \t]*theme[ \t]*=[ \t]*/, ""); print; exit }' "$f")
        app_offer "$f" "$( [ -n "$cur" ] && echo "Replace the line 'theme = $cur' in $f with 'theme = \"candy-for-gnome\"'?" || echo "Add 'theme = \"candy-for-gnome\"' at the top of $f?" )" \
'theme = "candy-for-gnome"' hx_edit
    else app_create "$f" '#' 'theme = "candy-for-gnome"' || { echo "Helix: could not create $f. To use the theme, put this line in your Helix config:"; echo '  theme = "candy-for-gnome"'; }; fi
}
yazi_switch() {
    local s="$1" d f; d=$(app_dir yazi); f="$d/theme.toml"
    app_ready yazi "$s" && app_links_apply yazi "$s" || return 0
    app_ok yazi flavors "$s"
    if [ -f "$f" ] && grep -qE '^[[:space:]]*dark[[:space:]]*=[[:space:]]*"candy-for-gnome-dark"' "$f" && grep -qE '^[[:space:]]*light[[:space:]]*=[[:space:]]*"candy-for-gnome-light"' "$f"; then :
    elif [ -f "$f" ]; then
        app_offer "$f" "Set dark = \"candy-for-gnome-dark\" and light = \"candy-for-gnome-light\" in the [flavor] table of $f (an existing dark/light line is replaced; nothing else changes)?" \
'[flavor]
dark = "candy-for-gnome-dark"
light = "candy-for-gnome-light"' yz_edit
    else app_create "$f" '#' "$(printf '[flavor]\ndark = "candy-for-gnome-dark"\nlight = "candy-for-gnome-light"')" || { echo "Yazi: could not create $f. To use the flavor, create it with:"; printf '  [flavor]\n  dark = "candy-for-gnome-dark"\n  light = "candy-for-gnome-light"\n'; }; fi
}
kitty_switch() {
    local s="$1"
    app_ready kitty "$s" && app_links_apply kitty "$s" || return 0
    app_ok kitty theme.auto.conf "$s"
}
bat_switch() {
    local s="$1" d f; d=$(app_dir bat); f="$d/config"
    app_ready bat "$s" && app_links_apply bat "$s" || return 0
    app_bat_cache
    app_ok bat themes "$s"
    bat_repair "$f" || true
    if [ -f "$f" ] && grep -qxF -- '--theme-dark="candy-for-gnome-dark"' "$f" && grep -qxF -- '--theme-light="candy-for-gnome-light"' "$f" && grep -qxF -- '--theme="auto"' "$f"; then :
    elif [ -f "$f" ]; then
        app_offer "$f" "Set --theme=\"auto\", --theme-dark=\"candy-for-gnome-dark\" and --theme-light=\"candy-for-gnome-light\" in $f (an existing --theme line is replaced; nothing else changes)?" \
'--theme="auto"
--theme-dark="candy-for-gnome-dark"
--theme-light="candy-for-gnome-light"' bat_edit
    else app_create "$f" '#' "$(printf -- '--theme="auto"\n--theme-dark="candy-for-gnome-dark"\n--theme-light="candy-for-gnome-light"')" || { echo "bat: could not create $f. To use the themes, create it with:"; printf '  --theme="auto"\n  --theme-dark="candy-for-gnome-dark"\n  --theme-light="candy-for-gnome-light"\n'; }; fi
}
eza_switch() {
    local s="$1" d t a v l; d=$(app_dir eza); l="$d/theme.yml"
    app_ready eza "$s" || return 0
    v=$(app_pick eza "$s" yml "$(pty_mode)"); t="themes/candy-for-gnome-$s-$v.yml"
    if [ -e "$l" ] && [ ! -L "$l" ]; then   # a regular file: move it aside only after an explicit yes
        if [ -e "$l.candy-bak" ] || [ -L "$l.candy-bak" ]; then echo "Refused: $l is your own file and $l.candy-bak already exists; left alone." >&2; return 0; fi
        a=n; if [ "${FORCE:-}" = 1 ]; then a=y; elif [ "$tty_in" = 1 ]; then read -r -u 3 -p "$l is your own file. Move it aside as theme.yml.candy-bak and link the theme in its place? [y/N] " a || a=n; fi
        case "$a" in
            [yY]*) mv "$l" "$l.candy-bak"; echo "Moved your $l to $l.candy-bak (undo: mv $l.candy-bak $l)." ;;
            *) echo "Left $l alone. To use the theme: mv $l $l.candy-bak && ln -s $t $l"; return 0 ;;
        esac
    fi
    app_link "$l" "$t" || return 0
    app_ok eza theme.yml "$s"
    [ -z "${EZA_COLORS:-}${LS_COLORS:-}" ] || echo "Note: EZA_COLORS or LS_COLORS is set in this shell and overrides parts of theme.yml."
}
zellij_switch() {
    local s="$1" d f; d=$(app_dir zellij); f="$d/config.kdl"
    app_ready zellij "$s" && app_links_apply zellij "$s" || return 0
    app_ok zellij candy-for-gnome.kdl "$s"
    if [ -f "$f" ] && grep -qE '^[ \t]*theme_dark[ \t]+"candy-for-gnome-dark"' "$f" && grep -qE '^[ \t]*theme_light[ \t]+"candy-for-gnome-light"' "$f"; then :
    elif [ -f "$f" ]; then
        app_offer "$f" "Set theme_dark \"candy-for-gnome-dark\" and theme_light \"candy-for-gnome-light\" in $f (existing theme_dark / theme_light lines are replaced; your theme line and themes block stay)?" \
'theme_dark "candy-for-gnome-dark"
theme_light "candy-for-gnome-light"' zj_edit
    else app_create "$f" '//' "$(printf 'theme_dark "candy-for-gnome-dark"\ntheme_light "candy-for-gnome-light"')" || { echo "zellij: could not create $f. To use the themes, add to your zellij config:"; printf '  theme_dark "candy-for-gnome-dark"\n  theme_light "candy-for-gnome-light"\n'; }; fi
}
claude_ours() { [ -f "$1" ] && grep -q '"name": "candy-for-gnome: ' "$1"; }
claude_scheme_of() { sed -n 's/.*"name": "candy-for-gnome: \([^ "]*\) .*/\1/p' "$1" | head -n1; }
claude_variant_of() { sed -n 's/.*"name": "candy-for-gnome: [^ "]* \([a-z]*\)".*/\1/p' "$1" | head -n1; }
claude_switch() {
    local s="$1" d dst src v a err; d=$(app_dir claude); dst="$d/themes/candy-for-gnome.json"
    v=$(pty_mode); [ -f "$troot/$s/claude/$s-$v.json" ] || { [ "$v" = dark ] && v=light || v=dark; }   # a dark-only scheme has only the dark file
    src="$troot/$s/claude/$s-$v.json"
    [ -f "$src" ] || { echo "Claude Code theme not applied: $s has no generated theme."; return 0; }
    if [ -e "$dst" ] && ! claude_ours "$dst"; then
        a=n; if [ "${FORCE:-}" = 1 ]; then a=y; elif [ "$tty_in" = 1 ]; then read -r -u 3 -p "$dst exists and was not installed by candy-for-gnome. Replace it? [y/N] " a || a=n
        else echo "Refused: $dst exists and was not installed by candy-for-gnome; left alone (FORCE=1 replaces it, or run in a terminal to be asked)." >&2; return 0; fi
        case "$a" in [yY]*) ;; *) echo "Left $dst alone." >&2; return 0 ;; esac
    fi
    if ! err=$(mkdir -p "$d/themes" 2>&1 && cp "$src" "$dst" 2>&1); then tfail "app:claude" claude candy-for-gnome.json "copy $src to $dst" "$err" "$(retry_cmd app:claude "$s" "${accent_pick:-}")"; return 0; fi
    app_ok claude candy-for-gnome.json "$s"
    if [ -f "$d/settings.json" ] && grep -qE '"theme"[[:space:]]*:[[:space:]]*"custom:candy-for-gnome"' "$d/settings.json"; then :
    else echo "[claude] pick it once with /theme (custom:candy-for-gnome); $d/settings.json is never edited here"; fi
}
claude_refresh() {   # update: rewrite the switch-time file when it is ours and belongs to this scheme
    local s="$1" d dst v; app_present claude || return 0
    d=$(app_dir claude); dst="$d/themes/candy-for-gnome.json"
    claude_ours "$dst" && [ "$(claude_scheme_of "$dst")" = "$s" ] || return 0
    v=$(claude_variant_of "$dst"); [ -f "$troot/$s/claude/$s-$v.json" ] && cp "$troot/$s/claude/$s-$v.json" "$dst"
    return 0
}
claude_remove() {
    local s="$1" d dst; app_present claude || return 0
    d=$(app_dir claude); dst="$d/themes/candy-for-gnome.json"
    if claude_ours "$dst" && [ "$(claude_scheme_of "$dst")" = "$s" ]; then rm -f "$dst"; echo "[claude] removed $s"
        if [ -f "$d/settings.json" ] && grep -q 'custom:candy-for-gnome' "$d/settings.json"; then echo "Claude Code: $d/settings.json still selects custom:candy-for-gnome (not edited); pick another theme with /theme." >&2; fi
    fi
    return 0
}
claude_adwaita() {   # the theme file is a regular copy made by the installer: delete it only when it carries our marker; settings.json is never touched
    local d dst; d=$(app_dir claude); dst="$d/themes/candy-for-gnome.json"
    claude_ours "$dst" || return 0
    rm -f "$dst"; echo "Removed $dst (Claude Code uses its own theme again)"
    if [ -f "$d/settings.json" ] && grep -q 'custom:candy-for-gnome' "$d/settings.json"; then echo "Claude Code: $d/settings.json still selects custom:candy-for-gnome (not edited); pick another theme with /theme." >&2; fi
    return 0
}
app_adwaita() {   # switch-theme Adwaita: for every installed app that has a MANAGED link, copy the neutral files of adwaita/ and retarget the links (nothing is created or asked, no user config is edited)
    local a l t src dst any
    for a in "${app_names[@]}"; do
        app_present "$a" || continue
        if [ "$a" = claude ]; then claude_adwaita; continue; fi
        any=0; while IFS='|' read -r l t; do if app_link_ours "$l"; then any=1; fi; done < <(app_links "$a" adwaita)
        [ "$any" = 1 ] || continue
        while IFS='|' read -r src dst; do
            pty_may_touch adwaita Replace "$dst" || continue
            mkdir -p "$(dirname "$dst")"
            if [ -d "$src" ]; then rm -rf "$dst"; cp -r "$src" "$dst"; else cp "$src" "$dst"; fi
        done < <(app_targets "$a" adwaita)
        while IFS='|' read -r l t; do if app_link_ours "$l"; then ln -sfn "$t" "$l"; fi; done < <(app_links "$a" adwaita)
        [ "$a" != bat ] || app_bat_cache
        echo "$a is now neutral (its managed link points at a neutral file of this repo, so $a uses its own defaults; switch-theme <scheme> points it back)."
    done
    return 0
}
app_switch() {    # app_switch SCHEME: every installed app
    local s="$1" a
    app_scheme="$s"
    for a in "${app_names[@]}"; do if app_present "$a" && sw_on "app:$a"; then app_cur="$a"; "${a}_switch" "$s"; fi; done
    return 0
}
apps_status() {   # for list-themes: nothing when no supported app is installed; else one line with the themed apps and one naming the skipped ones
    local a p=() n=()
    for a in "${app_names[@]}"; do if app_present "$a"; then p+=("$a"); else n+=("$a"); fi; done
    [ "${#p[@]}" -gt 0 ] || return 0
    echo "Apps themed: ${p[*]}"
    [ "${#n[@]}" -eq 0 ] || echo "Not installed (skipped): ${n[*]}"
    return 0
}
