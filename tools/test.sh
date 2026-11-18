#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Full test of the COMMITTED state of this repo (a fresh clone of HEAD, temp directories only, a stand-in gsettings,
# a local fake icon repo): lint, hygiene, regeneration, per-scheme selftest, install/switch/update/remove for every
# scheme and accent, and the icon recipes. Exits non-zero on any failure.
#   tools/test.sh [--rebuild] [--all] [--featured] [--sample N] [scheme ...]
#     Every PER-SCHEME check (hygiene, regeneration, selftest, the GtkSource style check, ptyxis-compare, the install/switch/update/remove loop with
#     every accent) runs for ONE scope; the checks that are not per scheme (lint, scenario tests on fixed samples or fixtures, the repo-wide
#     inventory and asset-layout checks) always run. The scope:
#       --featured (or TEST_SCOPE=featured; what CI passes): the featured schemes only (FEATURED_THEMES in tools/themectl.sh, the starred
#         ones). Nothing else is checked per scheme, so a stale generated file or a broken accent of any other scheme is NOT caught.
#       --all (or TEST_ALL=1; CI: the manual dispatch with full=true only): every scheme.
#       named schemes: those only.
#       none of these (a hand run): hygiene, ptyxis-compare and the style check for every scheme; regeneration, selftest and the loop for the
#         featured schemes, the schemes that differ from origin/main (TEST_BASE overrides; capped at 15) and N more (--sample N, default 10)
#         chosen from the commit hash.
#     --rebuild rebuilds the test image.
# Inside the container it needs git, just, python3 + python3-gobject, GTK 3, GTK 4, gnome-shell (St typelib) and a display
# (tools/test-packages.txt lists them; it re-executes itself under xvfb-run when there is no display).
# Isolation: the suite only runs inside a throwaway container. Run on a host, this script builds a cached test image from
# tools/test.Containerfile (rebuilt automatically when that file or test-packages.txt changes) and re-runs itself in it with the
# repo mounted read-only (podman or docker; CI already runs inside a container). Nothing on the host is touched.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [ ! -f /run/.containerenv ] && [ ! -f /.dockerenv ] && [ -z "${TEST_IN_CONTAINER:-}" ]; then
    rt=$(command -v podman || command -v docker) || { echo "tools/test.sh runs in a container: install podman or docker"; exit 2; }
    tag=$(cat "$root/tools/test.Containerfile" "$root/tools/test-packages.txt" | sha1sum | cut -c1-8)
    img="candy-for-gnome-test:45-$tag"
    args=(); for a in "$@"; do if [ "$a" = --rebuild ]; then "$rt" rmi -f "$img" >/dev/null 2>&1 || true; else args+=("$a"); fi; done
    if ! "$rt" image inspect "$img" >/dev/null 2>&1; then
        echo "building $img (first run downloads about 500 MB)"; "$rt" build -q -t "$img" -f "$root/tools/test.Containerfile" "$root/tools" >/dev/null || exit 2
    fi
    exec "$rt" run --rm --security-opt label=disable -e TEST_IN_CONTAINER=1 -v "$root":/src:ro "$img" /src/tools/test.sh "${args[@]}"
fi
if [ -n "${TEST_IN_CONTAINER:-}" ] || [ -f /run/.containerenv ] || [ -f /.dockerenv ]; then git config --global --add safe.directory '*' 2>/dev/null; fi
if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [ -z "${TEST_UNDER_XVFB:-}" ] && command -v xvfb-run >/dev/null 2>&1; then
    TEST_UNDER_XVFB=1 exec xvfb-run -a "$0" "$@"
fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
chk() { if [ "$1" = ok ]; then pass=$((pass+1)); echo "  PASS $2"; else fail=$((fail+1)); echo "  FAIL $2"; fi; }
git clone -q "$root" "$T/repo" && cd "$T/repo" || { echo "cannot clone $root"; exit 2; }
echo "testing $(git log --oneline -1)"

# ---- stand-ins ------------------------------------------------------------------------------------------------
mkdir -p "$T/bin" "$T/cfg/gtk-3.0" "$T/cfg/gtk-4.0"; LOG="$T/gsettings.log"; : > "$LOG"
cat > "$T/bin/gsettings" <<SH
#!/bin/sh
case "\$1" in
  set) echo "set \$2 \$3 \$4" >> "$LOG" ;;
  reset) echo "reset \$2 \$3" >> "$LOG" ;;
  get) case "\$3" in color-scheme) echo "'prefer-dark'";; accent-color) echo "'slate'";; gtk-theme) echo "'Adwaita'";; icon-theme) echo "'Adwaita'";; esac ;;
  list-schemas) echo org.gnome.shell.extensions.user-theme ;;
esac
SH
chmod +x "$T/bin/gsettings"
# a stand-in dconf over a plain file (DCONF_DB: lines "key<TAB>value"): read, write, list; every recipe that touches Ptyxis settings uses it
export DCONF_DB="$T/dconf.db"; : > "$DCONF_DB"
cat > "$T/bin/dconf" <<'SH'
#!/bin/sh
db="${DCONF_DB:?}"
case "$1" in
  read) awk -F'\t' -v k="$2" '$1==k {v=$2} END {if (v!="") print v}' "$db" ;;
  write) grep -v "^$2	" "$db" > "$db.new" || true; printf '%s\t%s\n' "$2" "$3" >> "$db.new"; mv "$db.new" "$db" ;;
  list) awk -F'\t' -v d="$2" 'index($1,d)==1 {print $1}' "$db" ;;
  reset) grep -v "^$2	" "$db" > "$db.new" || true; mv "$db.new" "$db" ;;
esac
SH
chmod +x "$T/bin/dconf"
unset COLORTERM; export NO_COLOR=1   # no swatches in the pty tests that read the picker text (the swatch tests set their own environment)
export CANDY_PLAIN=1   # the pty tests read the text of the messages: emojis stay off unless the emoji tests unset this themselves
export THEMES_PICKER=builtin THEMES_SWITCH_AFTER_INSTALL=0 THEMES_SWITCH_CHOOSE=0   # tests choose the picker explicitly (a developer machine may have gum) and enable the switch menu after an install only in their own pty tests
export PTYXIS_PALETTES="$T/ptyxis-palettes" GTKSOURCEVIEW_STYLES="$T/gsv-styles" FLATPAK_APPS="$T/var-app" KDE_COLOR_SCHEMES="$T/kde-schemes"
export CANDY_FOR_GNOME_BREW_BIN="$T/nobrew" CANDY_FOR_GNOME_APPS_PATH="$T/noapps"   # no Homebrew bin dir and no PATH search (the container may ship bat): the per-app themes see only what a test points the knobs at
export PATH="$T/bin:$PATH" XDG_CONFIG_HOME="$T/cfg" XDG_STATE_HOME="$T/state" CANDY_FOR_GNOME_CACHE="$T/cache"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# a stand-in flatpak (FLATPAK_DB: the global override's filesystems, one entry per line); only the calls themectl makes. Absent unless a test
# puts $T/fpbin on the PATH, so the other tests behave like a machine without Flatpak
mkdir -p "$T/fpbin"; export FLATPAK_DB="$T/flatpak.db" FLATPAK_GS="$T/flatpak-gs.db"; : > "$FLATPAK_DB"; : > "$FLATPAK_GS"
cat > "$T/fpbin/flatpak" <<'SH'
#!/bin/sh
db="${FLATPAK_DB:?}"
if [ "$1" = info ]; then case " ${FLATPAK_INFO:-} " in *" $2 "*) exit 0 ;; esac; exit 1; fi
if [ "$1" = run ]; then   # flatpak run --command=gsettings APP set|get SCHEMA KEY [VALUE]: the app's own store (FLATPAK_GS lines app,schema,key,value TAB separated); FLATPAK_GS_RO=1 ignores writes
    [ "$2" = --command=gsettings ] || exit 2; app="$3"; shift 3; gs="${FLATPAK_GS:?}"; echo "run $app $*" >> "$gs.calls"
    case "$1" in
      set) [ -n "${FLATPAK_GS_RO:-}" ] || { grep -vF "$app	$2	$3	" "$gs" > "$gs.new" || true; printf '%s\t%s\t%s\t%s\n' "$app" "$2" "$3" "$4" >> "$gs.new"; mv "$gs.new" "$gs"; } ;;
      get) echo "'$(awk -F'\t' -v a="$app" -v s="$2" -v k="$3" '$1==a && $2==s && $3==k {v=$4} END {print v}' "$gs")'" ;;
      reset) [ -n "${FLATPAK_GS_RO:-}" ] || { grep -vF "$app	$2	$3	" "$gs" > "$gs.new" || true; mv "$gs.new" "$gs"; } ;;
    esac; exit 0
fi
[ "$1" = override ] && [ "$2" = --user ] || exit 2
shift 2
for a in "$@"; do case "$a" in
  --show) printf '[Context]\nfilesystems=%s\n' "$(tr '\n' ';' < "$db")"; [ -s "$db.env" ] && { printf '\n[Environment]\n'; cat "$db.env"; } ;;
  --env=*) v="${a#--env=}"; touch "$db.env"; grep -v "^${v%%=*}=" "$db.env" > "$db.env.new" || true; echo "$v" >> "$db.env.new"; mv "$db.env.new" "$db.env" ;;
  --unset-env=*) v="${a#--unset-env=}"; touch "$db.env"; grep -v "^$v=" "$db.env" > "$db.env.new" || true; echo "$v=" >> "$db.env.new"; mv "$db.env.new" "$db.env" ;;
  --filesystem=*) v="${a#--filesystem=}"; grep -qxF "$v" "$db" || echo "$v" >> "$db" ;;
  --nofilesystem=*) v="${a#--nofilesystem=}"; awk -v v="$v" '{p=$0; sub(/:[a-z]+$/,"",p)} p!=v' "$db" > "$db.new"; mv "$db.new" "$db" ;;
esac; done
SH
chmod +x "$T/fpbin/flatpak"
# a fake icon repo (two sets, each with an index.theme), so the icon tests need no network
mkdir -p "$T/icons-src" && (cd "$T/icons-src" && git init -q && for n in Fake-Dark Fake-Light; do mkdir -p $n/apps; printf '[Icon Theme]\nName=%s\nDirectories=apps\n' $n > $n/index.theme; echo x > $n/apps/a.svg; done && git add -A && git commit -q -m init)

# ---- lint and hygiene -----------------------------------------------------------------------------------------
echo "=== lint and hygiene"
for f in tools/*.sh; do bash -n "$f" && chk ok "bash -n $f" || chk fail "bash -n $f"; done
if command -v shellcheck >/dev/null 2>&1; then shellcheck -S error tools/*.sh >/dev/null 2>&1 && chk ok "shellcheck (errors only)" || { chk fail "shellcheck"; shellcheck -S error tools/*.sh | head -20; }; else echo "  skip shellcheck (not installed)"; fi
for f in tools/*.py; do python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$f" && chk ok "parses $f" || chk fail "parses $f"; done
just --dump >/dev/null 2>&1 && chk ok "justfile parses" || chk fail "justfile parses"
want="flatpak-access flatpak-access-remove install-icon install-theme list-icons list-themes remove-icon remove-theme switch-icon switch-theme update-icon update-theme"
got=$(just --summary 2>/dev/null | tr ' ' '\n' | grep -v '^default$' | sort | tr '\n' ' ' | sed 's/ $//')
[ "$got" = "$want" ] && chk ok "public recipes are exactly the twelve (ten theme/icon ones and the two flatpak-access ones)" || chk fail "public recipes differ: $got"
full=0; featured_only=0; nsample=10; named=()
while [ $# -gt 0 ]; do case "$1" in --all) full=1 ;; --featured) featured_only=1 ;; --sample) shift; nsample=${1:?--sample needs a number} ;; *) named+=("$1") ;; esac; shift; done
if [ "${TEST_ALL:-}" = 1 ]; then full=1; fi
if [ "${TEST_SCOPE:-}" = featured ]; then featured_only=1; fi
# Coverage (CLAUDE.md, "CI time and coverage"): see the header. `schemes` is the scope of hygiene, ptyxis-compare and the style check, `cheap_schemes` of
# regeneration and selftest, `loop_schemes` of the install/switch/update/remove loop; `all_schemes` only feeds the fixtures and the repo-wide checks.
all_schemes=$(ls -d themes/*/palette.toml | cut -d/ -f2)
feat=$(sed -n 's/^FEATURED_THEMES="${FEATURED_THEMES-\(.*\)}"$/\1/p' tools/themectl.sh)
if [ ${#named[@]} -gt 0 ]; then schemes="${named[*]}"; loop_schemes="$schemes"; cheap_schemes="$schemes"
elif [ "$full" -eq 1 ]; then schemes="$all_schemes"; loop_schemes="$schemes"; cheap_schemes="$schemes"; echo "coverage: every scheme (--all)"
elif [ "$featured_only" -eq 1 ]; then
    schemes=$(for x in $feat; do [ -f "themes/$x/palette.toml" ] && echo "$x"; done); loop_schemes="$schemes"; cheap_schemes="$schemes"
    echo "coverage: the featured schemes only; every scheme with --all or the manual full CI run"
else
    schemes="$all_schemes"
    changed=$(git -C "$root" diff --name-only "${TEST_BASE:-origin/main}" HEAD 2>/dev/null | grep '^themes/' | cut -d/ -f2 | sort -u | while read -r x; do [ -f "themes/$x/palette.toml" ] && echo "$x"; done)
    sha=$(git rev-parse HEAD)
    pick() { for x in $schemes; do case " $feat " in *" $x "*) continue ;; esac; printf '%s %s\n' "$(printf '%s%s%s' "$1" "$sha" "$x" | sha1sum | cut -c1-12)" "$x"; done | sort | head -n "$2" | awk '{print $2}'; }
    nchg=$(echo $changed | wc -w)
    if [ "$nchg" -gt 15 ]; then changed=$(for x in $changed; do printf '%s %s\n' "$(printf 'chg%s%s' "$sha" "$x" | sha1sum | cut -c1-12)" "$x"; done | sort | head -n 15 | awk '{print $2}'); capped=" (a sample of 15 of $nchg changed schemes)"; else capped=""; fi
    cheap_schemes=$(for x in $feat $changed $(pick loop "$nsample"); do [ -f "themes/$x/palette.toml" ] && echo "$x"; done | awk '!seen[$0]++')
    loop_schemes="$cheap_schemes"
    echo "coverage: featured + changed$capped + rotating slice of $nsample; every scheme with --all or the manual full CI run"
fi
export SCHEMES="$schemes"
echo "regeneration, selftest and the install/switch/update/remove loop run for $(echo $loop_schemes | wc -w) of $(echo $all_schemes | wc -w) schemes: $(echo $loop_schemes)"
for s in $schemes; do
    for d in themes/$s/gtk/*/; do [ -f "$d/LICENSE" ] && chk ok "$d has a LICENSE" || chk fail "$d has no LICENSE"; done
    while IFS= read -r f; do head -12 "$f" | grep -q "Licen[cs]e" && chk ok "licence line in $f" || chk fail "no licence line in header of $f"; done < <(find "themes/$s/gtk" -name '*.css' -not -path '*/assets/*' -not -name 'pad-osd.css')
    if grep -q -i "$s" NOTICE || { grep -q "^$s	" tools/ptyxis-schemes.tsv && grep -q "tools/ptyxis-schemes.tsv" NOTICE; }; then chk ok "NOTICE covers $s"; else chk fail "NOTICE does not cover $s"; fi
done
[ -f LICENSE ] && grep -q "MIT License" LICENSE && chk ok "root LICENSE is MIT" || chk fail "root LICENSE"

# ---- per scheme -----------------------------------------------------------------------------------------------
# selftest and regeneration of every scheme, in parallel (each scheme only touches its own folder); results are collected per scheme
cheap_one() {
    local s=$1 out p f d
    out=$(python3 -I tools/selftest.py "$s" all 2>&1); p=$(printf '%s\n' "$out" | grep -c '^PASS'); f=$(printf '%s\n' "$out" | grep -c '^FAIL')
    { echo "=== $s"; echo "  selftest: $p PASS, $f FAIL"; printf '%s\n' "$out" | grep '^FAIL' | head -5
      echo "COUNT $p $f"
      just generate "$s" >/dev/null 2>&1; d=$(git status --porcelain -- "themes/$s" | grep -vc pycache)
      if [ "$d" -eq 0 ]; then echo "  PASS regeneration is byte-identical to the committed files ($s)"; echo "COUNT 1 0"
      else echo "  FAIL regeneration changed $d files of $s (stock stylesheets drifted or a generated file was edited)"; git status --porcelain -- "themes/$s" | head -3; git checkout -q -- "themes/$s"; echo "COUNT 0 1"; fi; } > "$T/cheap-$s.out"
}
export -f cheap_one; export T LOG CANDY_FOR_GNOME_SKIP_ASSETS=1   # assets are checked once below, not per scheme
mkdir -p "$T/cheap"
printf '%s\n' $cheap_schemes | xargs -P "${TEST_JOBS:-$(nproc)}" -I{} bash -c 'cheap_one {}'
for s in $cheap_schemes; do
    cat "$T/cheap-$s.out" | grep -v '^COUNT'
    while read -r _ p f; do pass=$((pass+p)); fail=$((fail+f)); done < <(grep '^COUNT' "$T/cheap-$s.out")
done
LT=$(mktemp -d -p /dev/shm 2>/dev/null) || LT="$T"   # installed copies of the loop live in memory when possible (hundreds of small files per install)
for s in $loop_schemes; do
    echo "=== loop $s"
    D="$LT/themes-$s"; THEMES_DEST=$D just install-theme "$s" >/dev/null 2>&1
    n=$(ls "$D" 2>/dev/null | wc -l); [ "$n" -ge 1 ] && chk ok "install-theme: $n folders" || chk fail "install-theme produced nothing"
    kdok=1; kdn=0; for f in themes/$s/kde/*; do kdn=$((kdn+1)); [ -f "$KDE_COLOR_SCHEMES/${f##*/}" ] || kdok=0; done
    [ "$kdok" = 1 ] && [ "$kdn" -ge 1 ] && chk ok "install-theme: the KDE color scheme file(s) of $s are installed" || chk fail "KDE color schemes of $s missing after install-theme"
    gt=$(awk -F'"' '/^gtk_name/ {print $2}' "themes/$s/palette.toml")
    [ -f "$D/$gt/gtk-3.0/assets/check-symbolic.svg" ] && [ -f "$D/$gt/gtk-4.0/assets/check-symbolic.svg" ] && [ ! -L "$D/$gt/gtk-3.0/assets" ] && chk ok "installed theme is complete: real assets directories in gtk-3.0 and gtk-4.0" || chk fail "installed $gt lacks its assets"
    for a in $(grep -v '^#' "themes/$s/accents/list" | awk 'NF {print $1}'); do
        : > "$LOG"; THEMES_DEST=$D just switch-theme "$s" "$a" >/dev/null 2>&1; rc=$?
        [ $rc -eq 0 ] && [ "$(grep -c gtk-theme "$LOG")" -ge 1 ] && chk ok "switch-theme $s $a" || chk fail "switch-theme $s $a (rc=$rc)"
    done
    last=$(grep -v '^#' "themes/$s/accents/list" | awk 'NF {print $1}' | tail -1); st=$(grep "^$s=" "$T/state/candy-for-gnome/accents" 2>/dev/null | cut -d= -f2)
    [ "$st" = "$last" ] && chk ok "accent remembered ($st)" || chk fail "accent state '$st' != '$last'"
    h1=$(find "$D" -type f -not -name .candy-for-gnome -exec sha1sum {} + | sort | sha1sum); THEMES_DEST=$D just update-theme >/dev/null 2>&1; h2=$(find "$D" -type f -not -name .candy-for-gnome -exec sha1sum {} + | sort | sha1sum)   # the marker carries updated_at, which moves on purpose
    [ "$h1" = "$h2" ] && chk ok "update-theme keeps the remembered accent" || chk fail "update-theme changed the installed tree"
    THEMES_DEST=$D just remove-theme "$s" >/dev/null 2>&1; [ -z "$(ls -A "$D" 2>/dev/null)" ] && chk ok "remove-theme emptied the set" || chk fail "remove-theme left $(ls "$D" | tr '\n' ' ')"
    kdok=1; for f in themes/$s/kde/*; do [ -e "$KDE_COLOR_SCHEMES/${f##*/}" ] && kdok=0; done
    [ "$kdok" = 1 ] && chk ok "remove-theme removed the KDE color scheme file(s)" || chk fail "KDE color schemes of $s left after remove-theme"
done
[ "$LT" != "$T" ] && rm -rf "${LT:?}"

# ---- shared assets: the repo stores GTK's stock assets once (assets/gtk-3.0, assets/gtk-4.0); installs copy them into each theme ---------
echo "=== shared assets"
python3 -I tools/assets-gen.py --check >/dev/null 2>&1 && chk ok "assets/ match the installed GTK's stock assets" || chk fail "assets/ differ from GTK's stock assets (run just generate)"
[ -z "$(ls -d themes/*/gtk/*/gtk-*/assets 2>/dev/null)" ] && chk ok "no scheme carries its own copy of the assets" || chk fail "per-scheme assets directories exist"

# ---- every scheme: Ptyxis declarations and the inventory (tools/ptyxis-schemes.tsv) ----------------------------------------
echo "=== ptyxis-compare and inventory"
if [ ! -r "${PTYXIS_BIN:-/usr/bin/ptyxis}" ]; then echo "  SKIP ptyxis-compare --check (no Ptyxis binary here; run it locally)"
elif python3 -I tools/ptyxis-compare.py --check $schemes >/dev/null 2>&1; then chk ok "ptyxis-compare --check passes for the schemes in scope"
else chk fail "ptyxis-compare --check failed ($(python3 -I tools/ptyxis-compare.py --check $schemes 2>&1 | grep -iv '^info' | head -3 | tr '\n' ' '))"
fi
inv=$(python3 -I - <<'PY'
import os, csv
rows = list(csv.reader(open('tools/ptyxis-schemes.tsv', encoding='utf-8'), delimiter='\t'))[1:]
have = {d for d in os.listdir('themes') if os.path.exists('themes/' + d + '/scheme.toml')}
ok = {r[0] for r in rows if r[3] in ('built', 'existing')}
bad = [d + ' not in the inventory as built/existing' for d in sorted(have - ok)] + [r[0] + ' listed built/existing but has no folder' for r in rows if r[3] in ('built', 'existing') and r[0] not in have] + [r[0] + ' excluded but has a folder' for r in rows if r[3] == 'excluded' and r[0] in have]
print('; '.join(bad))
PY
)
[ -z "$inv" ] && chk ok "tools/ptyxis-schemes.tsv matches the scheme folders" || chk fail "inventory: $inv"

# ---- featured themes come first in list-theme and the checklists ------------------------------------------------------------
echo "=== featured themes"
fl=$(THEMES_DEST="$T/feat" FEATURED_THEMES="dracula nordic nosuch" tools/themectl.sh themes list | sed 1d | head -2 | awk '{print $2}' | tr '\n' ' ')
[ "$fl" = "dracula nordic " ] && chk ok "FEATURED_THEMES order is the list order (a missing scheme is skipped)" || chk fail "featured order: $fl"
rest=$(THEMES_DEST="$T/feat" FEATURED_THEMES="dracula nordic" tools/themectl.sh themes list | sed 1,3d | awk '{print $1}' | grep -vc '★')
[ "$rest" -ge 1 ] && [ "$(THEMES_DEST="$T/feat" FEATURED_THEMES="dracula nordic" tools/themectl.sh themes list | sed 1,3d | awk '{print $1}' | LC_ALL=C sort -c 2>&1 | wc -l)" -eq 0 ] && chk ok "the other schemes follow alphabetically" || chk fail "rest not alphabetical"

# ---- light-only scheme (bluloco-light): gtk.css only, Shell-Light only, switch works under a dark desktop ----------------------------
echo "=== light-only scheme"
if [ -d bluloco-light ]; then
    LO="$T/themes-lo"; THEMES_DEST=$LO just install-theme bluloco-light >/dev/null 2>&1
    [ -f "$LO/Bluloco-Light/gtk-3.0/gtk.css" ] && [ ! -e "$LO/Bluloco-Light/gtk-3.0/gtk-dark.css" ] && [ -d "$LO/Bluloco-Light-Shell-Light" ] && [ ! -e "$LO/Bluloco-Light-Shell-Dark" ] && chk ok "a light-only scheme ships gtk.css and the Light Shell theme only" || chk fail "light-only layout ($(ls "$LO" | tr '\n' ' '))"
    : > "$LOG"; THEMES_DEST=$LO just switch-theme bluloco-light red >/dev/null 2>&1
    grep -q "Bluloco-Light-Shell-Light" "$LOG" "$DCONF_DB" 2>/dev/null && grep -q "gtk-theme Bluloco-Light" "$LOG" && chk ok "switch-theme sets the light-only Shell theme even when the desktop is dark" || chk fail "light-only switch ($(cat "$LOG" | tr '\n' ';'))"
    THEMES_DEST=$LO just remove-theme bluloco-light >/dev/null 2>&1
fi

# ---- gum picker (stub, forced), no gum, recipe comments ---------------------------------------------------------------------------
echo "=== gum picker"
SB="$T/stubs"; mkdir -p "$SB"
cat > "$SB/gum" <<'SH'
#!/bin/sh
# stub gum: records its arguments (one per line), prints the item arguments that match $GUM_STUB_PICK (ERE), with the featured star removed when GUM_STUB_STRIP=1
# and followed by the heading item when GUM_STUB_HEADING=1; exits $GUM_STUB_EXIT without output when that is set
printf '%s\n' "$@" > "$STUB_LOG"
[ -n "${GUM_STUB_EXIT:-}" ] && exit "$GUM_STUB_EXIT"
[ -n "${GUM_STUB_HEADING:-}" ] && echo "── Featured ───"
for a in "$@"; do
    case "$a" in -*|▸*|◉*|○*) continue ;; esac
    if printf '%s' "$a" | grep -Eq "$GUM_STUB_PICK"; then if [ -n "${GUM_STUB_STRIP:-}" ]; then printf '%s\n' "${a#★ }"; else printf '%s\n' "$a"; fi; fi
done
exit 0
SH
chmod +x "$SB/gum"; export STUB_LOG="$T/stub.log"
nogum="$T/path-nogum"; mkdir -p "$nogum"; for c in sh bash env cat grep sed awk sort head tr cut mktemp rm mkdir cp mv ls find dirname basename git stty tput date cmp printf wc just python3 tee sha1sum; do p2=$(command -v "$c" 2>/dev/null) && ln -sf "$p2" "$nogum/$c"; done
GP="$T/gum-themes"; mkdir -p "$GP"
THEMES_PICKER=gum GUM_STUB_HEADING=1 GUM_STUB_PICK='^(★ )?(nordic|dracula)  ' PATH="$SB:$PATH" THEMES_DEST=$GP tools/themectl.sh themes install </dev/null >/dev/null 2>&1
[ -d "$GP/Nordic-Nord" ] && [ -d "$GP/Dracula" ] && [ "$(find "$GP" -mindepth 1 -maxdepth 1 -not -name 'Nordic*' -not -name 'Dracula*' | wc -l)" -eq 0 ] && chk ok "gum handler (stub): the ticked entries are installed, a returned section heading is ignored" || chk fail "gum install: $(ls "$GP" | tr '\n' ' ')"
grep -qx -- '--no-limit' "$STUB_LOG" && grep -qx -- '◉  ' "$STUB_LOG" && grep -qx -- '○  ' "$STUB_LOG" && grep -qx -- '▸  ' "$STUB_LOG" && ! grep -qx -- '--selected' "$STUB_LOG" && chk ok "gum choose --no-limit with the ◉ ○ ▸ prefixes and nothing preselected for install" || chk fail "gum arguments: $(tr '\n' '|' < "$STUB_LOG")"
grep -qx -- '--cursor.foreground=2' "$STUB_LOG" && grep -qx -- '--selected.foreground=2' "$STUB_LOG" && grep -qx -- '--header.foreground=' "$STUB_LOG" && grep -qx -- '--item.foreground=' "$STUB_LOG" && ! grep -Eq -- '#[0-9a-fA-F]{3,6}|foreground=[0-9]{2,3}$' "$STUB_LOG" && chk ok "gum colors: ANSI palette colors only (cursor and selected 2, header and item the default), no 256-color or hex values" || chk fail "gum colors: $(grep foreground "$STUB_LOG" | tr '\n' ' ')"
grep -q '^──' "$STUB_LOG" && chk fail "gum list has divider rows" || { items=$(grep -E '^(★ )?[a-z0-9-]+  \(GTK' "$STUB_LOG" | head -9 | tr '\n' '|'); case "$items" in "★ nordic  "*"|★ gruvbox-material  "*"|★ everforest  "*"|★ tokyo-night  "*"|★ dracula  "*"|★ fairy-floss  "*"|★ catppuccin  "*"|★ aubergine  "*"|3024  "*) chk ok "gum list: no divider rows; the eight featured come first with their star, then the rest" ;; *) chk fail "gum list order: $items" ;; esac; }
rm -f "$STUB_LOG"; GUM_CHOOSE_CURSOR_FOREGROUND=5 GUM_CHOOSE_HEADER_FOREGROUND=212 THEMES_PICKER=gum GUM_STUB_PICK=zzz PATH="$SB:$PATH" THEMES_DEST=$GP tools/themectl.sh themes install </dev/null >/dev/null 2>&1
! grep -q -- '--cursor.foreground' "$STUB_LOG" && ! grep -q -- '--header.foreground' "$STUB_LOG" && grep -qx -- '--selected.foreground=2' "$STUB_LOG" && chk ok "gum colors the user set in GUM_CHOOSE_* are left alone (no flag overrides them)" || chk fail "user gum colors overridden: $(grep foreground "$STUB_LOG" | tr '\n' ' ')"
rm -rf "$GP"; mkdir -p "$GP"; THEMES_PICKER=gum GUM_STUB_STRIP=1 GUM_STUB_PICK='^(★ )?(tokyo-night|everforest)  ' PATH="$SB:$PATH" THEMES_DEST=$GP tools/themectl.sh themes install </dev/null >/dev/null 2>&1
[ -d "$GP/Everforest" ] && [ -d "$GP/Tokyo-Night" ] && chk ok "gum handler: an entry returned without its star maps back to the scheme id" || chk fail "gum star stripping: $(ls "$GP" | tr '\n' ' ')"
rm -rf "$GP"; mkdir -p "$GP"; out=$(THEMES_PICKER=gum GUM_STUB_EXIT=130 PATH="$SB:$PATH" THEMES_DEST=$GP tools/themectl.sh themes install </dev/null 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "Nothing selected: nothing was ticked. Press x on an entry, then Enter." && [ -z "$(ls -A "$GP")" ] && chk ok "gum with nothing ticked (Esc or ENTER on none): the hint to press x on an entry then Enter, exit 0, nothing installed" || chk fail "gum cancel rc=$rc: $out"
rm -f "$STUB_LOG"; THEMES_PICKER=gum GUM_STUB_PICK=x PATH="$SB:$PATH" THEMES_DEST=$GP tools/themectl.sh themes install dracula </dev/null >/dev/null 2>&1
[ ! -e "$STUB_LOG" ] && [ -d "$GP/Dracula" ] && chk ok "a named scheme skips the picker" || chk fail "named scheme called gum"
THEMES_DEST=$GP tools/themectl.sh themes install nordic </dev/null >/dev/null 2>&1; : > "$LOG"
THEMES_PICKER=gum GUM_STUB_PICK='^(★ )?dracula  ' PATH="$SB:$PATH" THEMES_DEST=$GP tools/themectl.sh themes switch </dev/null >/dev/null 2>&1
grep -q "gtk-theme Dracula" "$LOG" && grep -qx -- '--limit' "$STUB_LOG" && ! grep -qx -- '--no-limit' "$STUB_LOG" && chk ok "switch uses a single-choice gum (--limit 1) and applies the chosen theme" || chk fail "gum switch: $(tr '\n' ';' < "$LOG") / $(tr '\n' '|' < "$STUB_LOG" | cut -c1-200)"
out=$(printf 'q\n' | THEMES_PICKER=gum PATH="$nogum" THEMES_DEST=$GP tools/themectl.sh themes install 2>&1); rc=$?
echo "$out" | grep -q "gum is not on PATH" && echo "$out" | grep -q "Cancelled" && [ $rc -eq 0 ] && chk ok "forced gum but none installed: warns and falls back (no terminal: the numbered list)" || chk fail "no gum rc=$rc: $out"
rm -rf "$GP"
n=$(just --list --unsorted | grep -c '^    [a-z].* # [A-Z]'); [ "$n" -eq 12 ] && just --list --unsorted | grep -q '\[themes\]' && just --list --unsorted | grep -q '\[icons\]' && just --list --unsorted | grep -q '\[flatpak\]' && chk ok "every public recipe has a group and a one-line comment (the ujust menu shows them)" || chk fail "recipe comments: $n of 12"
tools/themectl.sh help | grep -q "install-theme \[name\]" && chk ok "themectl.sh help describes the recipes" || chk fail "themectl help"

# ---- built-in picker: scrolling in a small terminal (pty with a terminal emulator) ----------------------------------------------------
echo "=== picker scrolling"
SCROLL_THEMES="$T/scroll-themes"; mkdir -p "$SCROLL_THEMES"
THEMES_DEST=$SCROLL_THEMES python3 -I tools/pty-scroll-test.py 10 24 > "$T/scroll.out" 2>&1 && chk ok "built-in picker: the cursor row stays on screen and the window scrolls by at most one row per key (10 and 24 rows, filter, resize, Home/End/PgUp/PgDn)" || { chk fail "pty scroll test"; grep -B1 -A12 FAIL "$T/scroll.out" | head -30; }

# ---- collision guard (themes): unrelated folders with our names are never replaced or removed without asking ---------
echo "=== repository documentation is not installed"
NI="$T/noinstall"; mkdir -p "$NI"; THEMES_DEST=$NI just install-theme gruvbox-material </dev/null >/dev/null 2>&1
[ -d "$NI/Gruvbox-Material" ] && [ -z "$(find "$NI" -name 'README.md' -o -name 'palette-*.svg' -o -name scheme.toml -o -name palette.toml | head -1)" ] && chk ok "install-theme copies only the gtk folders: no README.md, palette picture, scheme.toml or palette.toml lands in the destination" || chk fail "documentation was installed: $(find "$NI" -name 'README.md' -o -name 'palette-*.svg' | head -3)"
rm -rf "$NI"
echo "=== collision guard"
G="$T/guard-themes"; mkdir -p "$G/Dracula"; echo mine > "$G/Dracula/mine.txt"; printf '[Desktop Entry]\nName=Dracula\n' > "$G/Dracula/index.theme"
out=$(THEMES_DEST=$G just install-theme dracula </dev/null 2>&1); rc=$?
[ -f "$G/Dracula/mine.txt" ] && [ ! -f "$G/Dracula/.candy-for-gnome" ] && chk ok "install: unrelated folder of the same name left untouched" || chk fail "install replaced an unrelated Dracula"
printf '%s\n' "$out" | grep -q "not installed by candy-for-gnome" && [ $rc -eq 0 ] && chk ok "install: refusal message, other folders still handled (rc=$rc)" || chk fail "install: no refusal message or rc=$rc"
[ -f "$G/Dracula-Shell-Dark/.candy-for-gnome" ] && [ "$(sed -n 's/^name=//p' "$G/Dracula-Shell-Dark/.candy-for-gnome")" = dracula ] && chk ok "install: the other folders were installed with the marker" || chk fail "install: marker missing on Dracula-Shell-Dark"
THEMES_DEST=$G just update-theme </dev/null >/dev/null 2>&1; [ -f "$G/Dracula/mine.txt" ] && chk ok "update: unrelated folder untouched" || chk fail "update replaced an unrelated Dracula"
THEMES_DEST=$G just remove-theme dracula </dev/null >/dev/null 2>&1
[ -f "$G/Dracula/mine.txt" ] && [ ! -e "$G/Dracula-Shell-Dark" ] && chk ok "remove: unrelated folder untouched, our folders removed" || chk fail "remove: wrong result ($(ls "$G" | tr '\n' ' '))"
FORCE=1 THEMES_DEST=$G just install-theme dracula </dev/null >/dev/null 2>&1
[ ! -e "$G/Dracula/mine.txt" ] && [ -f "$G/Dracula/.candy-for-gnome" ] && chk ok "FORCE=1 replaces the unrelated folder and marks it" || chk fail "FORCE=1 did not replace"
echo stale > "$G/Dracula/stale.txt"; out=$(THEMES_DEST=$G just install-theme dracula </dev/null 2>&1)
[ ! -e "$G/Dracula/stale.txt" ] && ! printf '%s\n' "$out" | grep -q "not installed by" && chk ok "a marked folder is replaced silently" || chk fail "marked folder not replaced silently"
L="$T/guard-legacy"; mkdir -p "$L"; cp -a themes/dracula/gtk/Dracula "$L/Dracula"; echo stale > "$L/Dracula/stale.txt"
out=$(THEMES_DEST=$L just install-theme dracula </dev/null 2>&1)
[ ! -e "$L/Dracula/stale.txt" ] && [ -f "$L/Dracula/.candy-for-gnome" ] && ! printf '%s\n' "$out" | grep -q "not installed by" && chk ok "a pre-marker installation (identical index.theme) is adopted" || chk fail "legacy installation not adopted"
O="$T/guard-oldname"; mkdir -p "$O/Other" "$O/Dracula"; cp -a themes/dracula/gtk/Dracula/. "$O/Dracula/"; echo dracula > "$O/Dracula/.gnome-themes"; echo stale > "$O/Dracula/stale.txt"; echo x > "$O/Other/.gnome-themes"
out=$(THEMES_DEST=$O just install-theme dracula </dev/null 2>&1)
[ ! -e "$O/Dracula/stale.txt" ] && [ ! -e "$O/Dracula/.gnome-themes" ] && grep -qx 'schema=1' "$O/Dracula/.candy-for-gnome" && grep -q '^installed_at=' "$O/Dracula/.candy-for-gnome" && ! printf '%s\n' "$out" | grep -qi 'refused\|old project\|leftover\|not installed by' && chk ok "old-name marker: a same-named folder is replaced on install, adopted with the new marker, no question and no message" || chk fail "old-marker folder not replaced/adopted: $out"
[ -f "$O/Other/.gnome-themes" ] && [ ! -e "$O/Other/.candy-for-gnome" ] && ! printf '%s\n' "$out" | grep -q 'Other' && chk ok "old-name marker: an old-marker folder that matches nothing is left alone and not mentioned" || chk fail "unmatched old-marker folder touched or mentioned"
rm -f "$O/Dracula/.candy-for-gnome"; echo dracula > "$O/Dracula/.gnome-themes"; echo stale > "$O/Dracula/stale.txt"
THEMES_DEST=$O just update-theme </dev/null >/dev/null 2>&1
[ ! -e "$O/Dracula/stale.txt" ] && [ ! -e "$O/Dracula/.gnome-themes" ] && grep -qx 'schema=1' "$O/Dracula/.candy-for-gnome" && chk ok "old-name marker: update-theme replaces an old-marker folder of an installed-by-name scheme and adopts it" || chk fail "update-theme did not adopt the old-marker folder"
rm -f "$O/Dracula/.candy-for-gnome"; echo dracula > "$O/Dracula/.gnome-themes"; echo stale > "$O/Dracula/stale.txt"
out=$(THEMES_DEST=$O just remove-theme dracula </dev/null 2>&1); [ ! -e "$O/Dracula" ] && [ -f "$O/Other/.gnome-themes" ] && ! printf '%s\n' "$out" | grep -qi 'refused\|Other' && chk ok "old-name marker: remove-theme removes an old-marker folder of a known scheme and leaves an unmatched one alone, silently" || chk fail "remove-theme with an old-marker folder: $out"
mkdir -p "$O/Dracula"; cp -a themes/dracula/gtk/Dracula/. "$O/Dracula/"; rm -f "$O/Dracula/.candy-for-gnome"; echo dracula > "$O/Dracula/.gnome-themes"
printf '1\n\n' | THEMES_DEST=$O just remove-theme >/dev/null 2>&1; [ ! -e "$O/Dracula" ] && chk ok "old-name marker: the remove checklist lists an old-marker folder of a known scheme" || chk fail "remove checklist did not list the old-marker folder"
mkdir -p "$O/Dracula"; echo mine > "$O/Dracula/mine.txt"
out=$(THEMES_DEST=$O just remove-theme dracula </dev/null 2>&1); [ -f "$O/Dracula/mine.txt" ] && chk ok "old-name marker: a third-party folder (no marker of ours) is still not removed" || chk fail "remove removed a third-party folder"
if command -v script >/dev/null 2>&1; then
    I="$T/guard-ask"; mkdir -p "$I/Dracula"; echo mine > "$I/Dracula/mine.txt"
    printf 'n\n' | script -qec "THEMES_DEST=$I tools/themectl.sh themes install dracula" /dev/null >/dev/null 2>&1
    [ -f "$I/Dracula/mine.txt" ] && chk ok "interactive: answer n keeps the unrelated folder" || chk fail "interactive n replaced the folder"
    printf 'y\n' | script -qec "THEMES_DEST=$I tools/themectl.sh themes install dracula" /dev/null >/dev/null 2>&1
    [ ! -e "$I/Dracula/mine.txt" ] && chk ok "interactive: answer y replaces it" || chk fail "interactive y did not replace"
else echo "  skip interactive guard tests (script not installed)"; fi

# ---- Ghostty themes: generated colours = Ptyxis colours, drift check, install/switch/remove on the config directory ---------------
echo "=== ghostty themes"
cat > "$T/ghcheck.py" <<'PY'
import sys, re, os
sys.path.insert(0, 'tools'); import schemeroles as sr
bad = []
def pal(path):
    t = open(path).read(); g = lambda k: re.search(r'^%s = (#[0-9a-f]{6})$' % k, t, re.M).group(1)
    return g('background'), g('foreground'), [re.search(r'^palette = %d=(#[0-9a-f]{6})$' % i, t, re.M).group(1) for i in range(16)]
for s in ('gruvbox-material', 'dracula', 'nordic', 'solarized'):
    S, roles, _ = sr.load('themes/' + s)
    for v in ('dark', 'light'):
        f = 'themes/%s/ghostty/candy-for-gnome-%s-%s' % (s, s, v)
        if v not in roles:
            if os.path.exists(f): bad.append('%s has a %s file but no %s variant' % (s, v, v))
            continue
        c = sr.slot_colors(S, roles, v)
        for k, n in S[v].get('nudge', {}).items(): c[k] = n['from'].upper()   # the terminal shows the built-in, a nudge only moves the toolkit colour
        bg, fg, p = pal(f)
        if bg != c['Background'].lower() or fg != c['Foreground'].lower() or p != [c['Color%d' % i].lower() for i in range(16)]: bad.append('%s %s differs from the Ptyxis-derived colours' % (s, v))
        if not open(f).read().startswith('# candy-for-gnome: %s\n' % s): bad.append(f + ': marker')
S, roles, _ = sr.load('themes/solarized')
if pal('themes/solarized/ghostty/candy-for-gnome-solarized-dark')[1] != '#839496' or roles['dark']['fg'].lower() == '#839496': bad.append('solarized dark: nudge not reverted to the built-in foreground')
if open('themes/nordic/ghostty/nordic.conf').read().split('\n')[1] != 'theme = dark:candy-for-gnome-nordic-dark,light:candy-for-gnome-nordic-dark': bad.append('nordic.conf (dark-only) pair line')
if open('themes/dracula/ghostty/dracula.conf').read().split('\n')[1] != 'theme = dark:candy-for-gnome-dracula-dark,light:candy-for-gnome-dracula-light': bad.append('dracula.conf pair line')
print('\n'.join(bad)); sys.exit(1 if bad else 0)
PY
out=$(python3 -I "$T/ghcheck.py" 2>&1) && chk ok "ghostty: generated files match the Ptyxis-derived colours (dark, light, dark-only, nudged Solarized), markers, pair lines" || chk fail "ghostty generation: $out"
rm -rf "$T/drift"; mkdir -p "$T/drift/themes"; cp -r tools "$T/drift/"; cp -r themes/nordic "$T/drift/themes/"; echo '# stale' >> "$T/drift/themes/nordic/ghostty/candy-for-gnome-nordic-dark"
python3 -I "$T/drift/tools/selftest.py" nordic ghostty >/dev/null 2>&1 && chk fail "ghostty drift: a stale generated file passed the selftest" || chk ok "ghostty drift: a stale generated file fails the selftest"
GH="$T/ghtest"; rm -rf "$GH" "$T/gdata"; mkdir -p "$GH"; GCFG="$T/cfg/ghostty"; rm -rf "$GCFG"
gt() { XDG_DATA_HOME="$T/gdata" THEMES_DEST="$GH" "$@"; }
out=$(gt just install-theme nordic </dev/null 2>&1; gt just switch-theme nordic </dev/null 2>&1; gt just list-themes </dev/null 2>&1)
[ ! -e "$GCFG" ] && [ ! -e "$T/gdata/candy-for-gnome" ] && ! printf '%s\n' "$out" | grep -q '^Ghostty (' && printf '%s\n' "$out" | grep -q "Ghostty: no config directory" && chk ok "ghostty: no config directory, nothing created, no status line, one note" || chk fail "ghostty: missing config directory not handled"
gt just remove-theme nordic </dev/null >/dev/null 2>&1
mkdir -p "$GCFG/themes"; printf 'font-size = 12\ntheme = something\n' > "$GCFG/config.ghostty"; cp "$GCFG/config.ghostty" "$T/gh-config.orig"
echo mine > "$GCFG/themes/candy-for-gnome-nordic-dark"; echo handmade > "$GCFG/themes/gruvbox-material-dark"
out=$(gt just install-theme nordic </dev/null 2>&1)
[ "$(cat "$GCFG/themes/candy-for-gnome-nordic-dark")" = mine ] && printf '%s\n' "$out" | grep -q "Refused: .*candy-for-gnome-nordic-dark" && chk ok "ghostty: an unmarked theme file of our name is left alone (refusal message)" || chk fail "ghostty: unmarked file replaced or no refusal"
FORCE=1 gt just install-theme nordic </dev/null >/dev/null 2>&1
head -1 "$GCFG/themes/candy-for-gnome-nordic-dark" | grep -qx '# candy-for-gnome: nordic' && [ -f "$T/gdata/candy-for-gnome/ghostty/nordic.conf" ] && [ "$(cat "$GCFG/themes/gruvbox-material-dark")" = handmade ] && chk ok "ghostty: install writes theme file and pair file; other hand-made themes untouched" || chk fail "ghostty install"
out=$(gt just switch-theme nordic </dev/null 2>&1)
[ -L "$GCFG/candy-for-gnome.conf" ] && [ "$(readlink "$GCFG/candy-for-gnome.conf")" = "$T/gdata/candy-for-gnome/ghostty/nordic.conf" ] && cmp -s "$GCFG/config.ghostty" "$T/gh-config.orig" \
  && printf '%s\n' "$out" | grep -qxF '  config-file = ?candy-for-gnome.conf' && printf '%s\n' "$out" | grep -q 'ctrl+shift+,' && chk ok "ghostty: switch links the pair file; without a terminal it prints the include line and the reload key and edits nothing" || chk fail "ghostty switch without a terminal"
gt just list-themes </dev/null 2>&1 | grep -q "^Ghostty (.*theme nordic; include line: not in the config" && chk ok "ghostty: list shows the status line when the directory exists" || chk fail "ghostty status line"
# a regular file (or foreign link) with our link name is never replaced silently
rm "$GCFG/candy-for-gnome.conf"; echo mine > "$GCFG/candy-for-gnome.conf"
out=$(gt just switch-theme nordic </dev/null 2>&1)
[ ! -L "$GCFG/candy-for-gnome.conf" ] && [ "$(cat "$GCFG/candy-for-gnome.conf")" = mine ] && printf '%s\n' "$out" | grep -q "Refused: .*candy-for-gnome.conf" && chk ok "ghostty: a regular file with the link name is left alone without a terminal" || chk fail "ghostty: regular file replaced"
if command -v script >/dev/null 2>&1; then
    printf 'n\n' | XDG_DATA_HOME="$T/gdata" script -qec "THEMES_DEST=$GH tools/themectl.sh themes switch nordic cyan" /dev/null >/dev/null 2>&1
    [ "$(cat "$GCFG/candy-for-gnome.conf")" = mine ] && chk ok "ghostty interactive: answer n keeps the regular file" || chk fail "ghostty interactive n replaced the file"
    printf 'y\nn\n' | XDG_DATA_HOME="$T/gdata" script -qec "THEMES_DEST=$GH tools/themectl.sh themes switch nordic cyan" /dev/null >/dev/null 2>&1
    [ -L "$GCFG/candy-for-gnome.conf" ] && cmp -s "$GCFG/config.ghostty" "$T/gh-config.orig" && chk ok "ghostty interactive: y replaces the file; the include question defaults/answers no and leaves the config alone" || chk fail "ghostty interactive replace"
    printf '\n' | XDG_DATA_HOME="$T/gdata" script -qec "THEMES_DEST=$GH tools/themectl.sh themes switch nordic cyan" /dev/null >/dev/null 2>&1
    cmp -s "$GCFG/config.ghostty" "$T/gh-config.orig" && chk ok "ghostty interactive: an empty answer is no" || chk fail "ghostty: empty answer changed the config"
    printf 'y\n' | XDG_DATA_HOME="$T/gdata" script -qec "THEMES_DEST=$GH tools/themectl.sh themes switch nordic cyan" /dev/null >/dev/null 2>&1
    [ "$(grep -cxF 'config-file = ?candy-for-gnome.conf' "$GCFG/config.ghostty")" = 1 ] && [ "$(head -2 "$GCFG/config.ghostty")" = "$(cat "$T/gh-config.orig")" ] && chk ok "ghostty interactive: y appends exactly the one line, nothing else changes" || chk fail "ghostty: include line not appended as specified"
    out=$(printf 'y\n' | XDG_DATA_HOME="$T/gdata" script -qec "THEMES_DEST=$GH tools/themectl.sh themes switch nordic cyan" /dev/null 2>&1)
    [ "$(grep -cxF 'config-file = ?candy-for-gnome.conf' "$GCFG/config.ghostty")" = 1 ] && ! printf '%s\n' "$out" | grep -q 'Add the line' && chk ok "ghostty: no second question once the line is there" || chk fail "ghostty: asked again or duplicated the line"
    LG="$T/cfg-legacy"; rm -rf "$LG"; mkdir -p "$LG/ghostty"; echo 'font-size = 9' > "$LG/ghostty/config"
    printf 'y\n' | XDG_CONFIG_HOME="$LG" XDG_DATA_HOME="$T/gdata" script -qec "THEMES_DEST=$GH tools/themectl.sh themes switch nordic cyan" /dev/null >/dev/null 2>&1
    [ ! -e "$LG/ghostty/config.ghostty" ] && [ "$(tail -1 "$LG/ghostty/config")" = 'config-file = ?candy-for-gnome.conf' ] && chk ok "ghostty: the legacy file name config is detected and used" || chk fail "ghostty: legacy config not handled"
else echo "  skip interactive ghostty tests (script not installed)"; fi
cp "$GCFG/config.ghostty" "$T/gh-config.after"
out=$(gt just remove-theme nordic </dev/null 2>&1)
[ ! -e "$GCFG/themes/candy-for-gnome-nordic-dark" ] && [ ! -e "$T/gdata/candy-for-gnome/ghostty/nordic.conf" ] && [ ! -L "$GCFG/candy-for-gnome.conf" ] && [ "$(cat "$GCFG/themes/gruvbox-material-dark")" = handmade ] && cmp -s "$GCFG/config.ghostty" "$T/gh-config.after" && chk ok "ghostty: remove deletes only our files and link, never edits the user config" || chk fail "ghostty remove"
rm -rf "$GCFG" "$T/gdata" "$GH" "$T/cfg-legacy"

# ---- per-application themes (Alacritty, Helix, Yazi, kitty, bat, eza, zellij, Claude Code) -------------------------------------------------------
echo "=== app themes"
AB="$T/appbin"; mkdir -p "$AB"; for t in alacritty hx yazi kitty eza zellij claude flatpak; do printf '#!/bin/sh\nexit 0\n' > "$AB/$t"; done; printf '#!/bin/sh\nexit 1\n' > "$AB/flatpak"
printf '#!/bin/sh\ncase "$1" in --config-dir) echo "%s/cfg-apps/bat" ;; cache) echo "cache $*" >> "%s/bat.log" ;; esac\n' "$T" "$T" > "$AB/bat"; chmod +x "$AB"/*
CFGA="$T/cfg-apps"; HA="$T/home-apps"; APD="$T/themes-apps"; BATLOG="$T/bat.log"
ap() { HOME="$HA" XDG_CONFIG_HOME="$CFGA" XDG_DATA_HOME="$T/adata" THEMES_DEST="$APD" "$@"; }
aps() { ap env CANDY_FOR_GNOME_APPS_PATH="$AB" PATH="$AB:$PATH" "$@"; }   # with the stub tools installed
app_reset() {   # fresh configs the way a real setup looks (hand-made themes, a Noctalia-style import list, a regular eza theme, Claude settings)
    rm -rf "$CFGA" "$HA" "$APD" "$T/adata" "$BATLOG"; mkdir -p "$CFGA"/{alacritty,helix,yazi,bat,zellij,eza} "$HA/.claude" "$APD"
    printf '[general]\nimport = [\n    "~/.config/alacritty/themes/gruvbox-material-dark.toml",\n]\n\n[terminal.shell]\nprogram = "/usr/bin/fish"\n' > "$CFGA/alacritty/alacritty.toml"
    printf 'theme = "gruvbox-material"\n\n[editor]\nline-number = "relative"\n' > "$CFGA/helix/config.toml"
    printf '[flavor]\ndark = "gruvbox-material"\n\n[status]\nprogress_label = { bold = true }\n' > "$CFGA/yazi/theme.toml"
    printf -- '--theme=noctalia\n--style=numbers\n' > "$CFGA/bat/config"
    printf 'theme "gruvbox-material-dark"\nthemes {\n    gruvbox-material-dark { }\n}\n' > "$CFGA/zellij/config.kdl"
    printf 'filekinds:\n  normal: {foreground: "#d4be98"}\n' > "$CFGA/eza/theme.yml"
    printf '{"theme": "auto", "permissions": {"allow": []}}\n' > "$HA/.claude/settings.json"
    mkdir -p "$CFGA/helix/themes"; echo handmade > "$CFGA/helix/themes/gruvbox-material.toml"
}
cfg_snapshot() { (cd "$CFGA" && sha1sum alacritty/alacritty.toml helix/config.toml yazi/theme.toml bat/config zellij/config.kdl; [ ! -L eza/theme.yml ] && sha1sum eza/theme.yml 2>/dev/null; sha1sum "$HA/.claude/settings.json"); }
# 1. no supported tool installed: nothing is created, no line in list, no mention
rm -rf "$CFGA" "$HA" "$APD"; mkdir -p "$APD"
out=$(ap just install-theme gruvbox-material </dev/null 2>&1; ap just switch-theme gruvbox-material </dev/null 2>&1; ap just update-theme </dev/null 2>&1; ap just list-themes </dev/null 2>&1; ap just remove-theme gruvbox-material </dev/null 2>&1)
[ ! -e "$CFGA/alacritty" ] && [ ! -e "$CFGA/helix" ] && [ ! -e "$CFGA/yazi" ] && [ ! -e "$CFGA/kitty" ] && [ ! -e "$CFGA/bat" ] && [ ! -e "$CFGA/eza" ] && [ ! -e "$CFGA/zellij" ] && [ ! -e "$HA/.claude" ] \
  && ! printf '%s\n' "$out" | grep -qiE 'alacritty|helix|yazi|kitty|zellij|claude|Not installed' && chk ok "app themes: no supported tool installed: install, switch, update, list and remove create nothing and say nothing" || chk fail "app themes without tools ($out)"
# 2. tools installed (kitty missing): install copies marked files, kitty is skipped and named once in list
app_reset; rm -f "$AB/kitty"
out=$(aps just install-theme gruvbox-material </dev/null 2>&1); lst=$(aps just list-themes </dev/null 2>&1)
ok=1; for f in alacritty/themes/candy-for-gnome-gruvbox-material-dark.toml alacritty/themes/candy-for-gnome-gruvbox-material-light.toml helix/themes/candy-for-gnome-gruvbox-material-dark.toml eza/themes/candy-for-gnome-gruvbox-material-light.yml zellij/themes/candy-for-gnome-gruvbox-material.kdl bat/themes/candy-for-gnome-gruvbox-material-dark.tmTheme yazi/flavors/candy-for-gnome-gruvbox-material-dark.yazi/flavor.toml yazi/flavors/candy-for-gnome-gruvbox-material-light.yazi/tmtheme.xml; do [ -f "$CFGA/$f" ] || { ok=0; echo "missing $f"; }; done
[ $ok = 1 ] && [ ! -e "$CFGA/kitty" ] && [ ! -e "$HA/.claude/themes" ] && [ -s "$BATLOG" ] && [ "$(printf '%s\n' "$lst" | grep -c 'Not installed')" = 1 ] && printf '%s\n' "$lst" | grep -q '^Not installed (skipped): kitty$' && printf '%s\n' "$lst" | grep -q '^Apps themed: alacritty helix yazi bat eza zellij claude$' \
  && chk ok "app themes: install copies the marked files of every installed tool (yazi as directories), rebuilds the bat cache, skips kitty (one list line); Claude Code's file waits for switch" || chk fail "app install ($out / $lst)"
head -1 "$CFGA/zellij/themes/candy-for-gnome-gruvbox-material.kdl" | grep -qx '// candy-for-gnome: gruvbox-material' && grep -qx '<!-- candy-for-gnome: gruvbox-material -->' "$CFGA/bat/themes/candy-for-gnome-gruvbox-material-dark.tmTheme" && head -1 "$CFGA/yazi/flavors/candy-for-gnome-gruvbox-material-dark.yazi/flavor.toml" | grep -qx '# candy-for-gnome: gruvbox-material' && chk ok "app themes: installed files carry the markers (# // XML)" || chk fail "app markers"
# 3. switch without a terminal: links, files, printed lines; no user config line changes
printf '#!/bin/sh\nexit 0\n' > "$AB/kitty"; chmod +x "$AB/kitty"; cfg_snapshot > "$T/apps.before"
out=$(aps just switch-theme gruvbox-material </dev/null 2>&1)
rl() { readlink "$1" 2>/dev/null; }
[ "$(rl "$CFGA/alacritty/themes/candy-for-gnome.toml")" = candy-for-gnome-gruvbox-material-dark.toml ] && [ "$(rl "$CFGA/helix/themes/candy-for-gnome.toml")" = candy-for-gnome-gruvbox-material-dark.toml ] \
  && [ "$(rl "$CFGA/yazi/flavors/candy-for-gnome-dark.yazi")" = candy-for-gnome-gruvbox-material-dark.yazi ] && [ "$(rl "$CFGA/yazi/flavors/candy-for-gnome-light.yazi")" = candy-for-gnome-gruvbox-material-light.yazi ] \
  && [ "$(rl "$CFGA/bat/themes/candy-for-gnome-dark.tmTheme")" = candy-for-gnome-gruvbox-material-dark.tmTheme ] && [ "$(rl "$CFGA/zellij/themes/candy-for-gnome.kdl")" = candy-for-gnome-gruvbox-material.kdl ] \
  && chk ok "app themes: switch links Alacritty, Helix, Yazi, bat and zellij (relative links, variant from the dark system setting)" || chk fail "app links ($(find "$CFGA" -type l | tr '\n' ' '))"
[ "$(rl "$CFGA/kitty/dark-theme.auto.conf")" = themes/candy-for-gnome-gruvbox-material-dark.conf ] && [ "$(rl "$CFGA/kitty/light-theme.auto.conf")" = themes/candy-for-gnome-gruvbox-material-light.conf ] && [ "$(rl "$CFGA/kitty/no-preference-theme.auto.conf")" = themes/candy-for-gnome-gruvbox-material-light.conf ] \
  && chk ok "app themes: kitty gets the three auto files (no-preference carries the light colors)" || chk fail "kitty links"
[ -f "$HA/.claude/themes/candy-for-gnome.json" ] && [ ! -L "$HA/.claude/themes/candy-for-gnome.json" ] && grep -q '"base": "dark"' "$HA/.claude/themes/candy-for-gnome.json" && grep -q '"name": "candy-for-gnome: gruvbox-material dark"' "$HA/.claude/themes/candy-for-gnome.json" && printf '%s\n' "$out" | grep -q 'custom:candy-for-gnome' \
  && chk ok "app themes: Claude Code gets a regular file (dark base) and the /theme instruction; settings.json is not touched" || chk fail "claude file"
[ "$(cat "$CFGA/eza/theme.yml" | head -1)" = 'filekinds:' ] && [ ! -L "$CFGA/eza/theme.yml" ] && printf '%s\n' "$out" | grep -q 'theme.yml.candy-bak' && chk ok "app themes: a regular eza theme.yml is left alone without a terminal (the move-aside command is printed)" || chk fail "eza regular file"
cfg_snapshot > "$T/apps.after"; cmp -s "$T/apps.before" "$T/apps.after" && printf '%s\n' "$out" | grep -qF 'import = [ "' && printf '%s\n' "$out" | grep -qxF '  theme = "candy-for-gnome"' && printf '%s\n' "$out" | grep -qxF '  dark = "candy-for-gnome-dark"' && printf '%s\n' "$out" | grep -qxF -- '  --theme-dark="candy-for-gnome-dark"' && printf '%s\n' "$out" | grep -qxF '  theme_dark "candy-for-gnome-dark"' \
  && chk ok "app themes: without a terminal no user config changes; the exact lines are printed for Alacritty, Helix, Yazi, bat and zellij" || chk fail "app configs changed or lines missing ($out)"
# 4. dark-only scheme: its dark file serves both appearances; the variant of the no-switching tools follows the system colour scheme
aps just install-theme nordic </dev/null >/dev/null 2>&1; aps just switch-theme nordic </dev/null >/dev/null 2>&1
[ "$(rl "$CFGA/yazi/flavors/candy-for-gnome-light.yazi")" = candy-for-gnome-nordic-dark.yazi ] && [ "$(rl "$CFGA/kitty/light-theme.auto.conf")" = themes/candy-for-gnome-nordic-dark.conf ] && [ "$(rl "$CFGA/bat/themes/candy-for-gnome-light.tmTheme")" = candy-for-gnome-nordic-dark.tmTheme ] \
  && chk ok "app themes: a dark-only scheme maps both appearances to its dark file (Yazi, kitty, bat)" || chk fail "dark-only mapping"
aps just switch-theme gruvbox-material </dev/null >/dev/null 2>&1
lb="$T/bin-light-apps"; mkdir -p "$lb"; printf '#!/bin/sh\ncase "$1" in get) case "$3" in color-scheme) echo "\x27prefer-light\x27";; *) echo "\x27x\x27";; esac ;; list-schemas) : ;; esac\n' > "$lb/gsettings"; chmod +x "$lb/gsettings"
ap env CANDY_FOR_GNOME_APPS_PATH="$AB" PATH="$lb:$AB:$PATH" just switch-theme gruvbox-material </dev/null >/dev/null 2>&1
[ "$(rl "$CFGA/alacritty/themes/candy-for-gnome.toml")" = candy-for-gnome-gruvbox-material-light.toml ] && [ "$(rl "$CFGA/helix/themes/candy-for-gnome.toml")" = candy-for-gnome-gruvbox-material-light.toml ] && grep -q '"base": "light"' "$HA/.claude/themes/candy-for-gnome.json" \
  && chk ok "app themes: under a light system color scheme Alacritty, Helix and Claude Code follow with the light file (run switch-theme again after changing the setting)" || chk fail "light variant"
# 5. guard: an unmarked file or a foreign thing under our names is never replaced silently
rm -f "$CFGA/helix/themes/candy-for-gnome-gruvbox-material-dark.toml"; echo mine > "$CFGA/helix/themes/candy-for-gnome-gruvbox-material-dark.toml"
out=$(aps just install-theme gruvbox-material </dev/null 2>&1)
[ "$(cat "$CFGA/helix/themes/candy-for-gnome-gruvbox-material-dark.toml")" = mine ] && printf '%s\n' "$out" | grep -q "Refused: .*helix/themes/candy-for-gnome-gruvbox-material-dark.toml" && chk ok "app themes: an unmarked theme file of our name is left alone (refusal message)" || chk fail "app guard file"
FORCE=1 aps just install-theme gruvbox-material </dev/null >/dev/null 2>&1; head -1 "$CFGA/helix/themes/candy-for-gnome-gruvbox-material-dark.toml" | grep -qx '# candy-for-gnome: gruvbox-material' && chk ok "app themes: FORCE=1 replaces it" || chk fail "app FORCE"
rm -f "$CFGA/alacritty/themes/candy-for-gnome.toml"; echo mine > "$CFGA/alacritty/themes/candy-for-gnome.toml"; out=$(aps just switch-theme gruvbox-material </dev/null 2>&1)
[ ! -L "$CFGA/alacritty/themes/candy-for-gnome.toml" ] && [ "$(cat "$CFGA/alacritty/themes/candy-for-gnome.toml")" = mine ] && printf '%s\n' "$out" | grep -q "Refused: .*alacritty/themes/candy-for-gnome.toml" && chk ok "app themes: a regular file under a managed link name is not replaced without an answer" || chk fail "app guard link"
rm -f "$CFGA/alacritty/themes/candy-for-gnome.toml"
echo '{"name": "mine"}' > "$HA/.claude/themes/candy-for-gnome.json"; out=$(aps just switch-theme gruvbox-material </dev/null 2>&1)
[ "$(cat "$HA/.claude/themes/candy-for-gnome.json")" = '{"name": "mine"}' ] && printf '%s\n' "$out" | grep -q "Refused: .*candy-for-gnome.json" && chk ok "app themes: an unmarked Claude Code theme file of our name is left alone" || chk fail "claude guard"
# 6. interactive: one question per tool, default no, exact edits
if command -v script >/dev/null 2>&1; then
    app_reset; aps just install-theme gruvbox-material </dev/null >/dev/null 2>&1; cfg_snapshot > "$T/apps.before"
    sw() { printf '%s' "$1" | HOME="$HA" XDG_CONFIG_HOME="$CFGA" XDG_DATA_HOME="$T/adata" THEMES_DEST="$APD" CANDY_FOR_GNOME_APPS_PATH="$AB" PATH="$AB:$PATH" script -qec "tools/themectl.sh themes switch gruvbox-material blue" /dev/null > "$T/apps.tty" 2>&1; }
    sw $'n\nn\nn\nn\nn\nn\n'; cfg_snapshot > "$T/apps.after"
    cmp -s "$T/apps.before" "$T/apps.after" && [ -f "$CFGA/eza/theme.yml" ] && [ ! -L "$CFGA/eza/theme.yml" ] && chk ok "app themes interactive: answering n to every question changes no user config" || chk fail "interactive n changed configs"
    sw $'\n\n\n\n\n\n'; cfg_snapshot > "$T/apps.after"; cmp -s "$T/apps.before" "$T/apps.after" && chk ok "app themes interactive: empty answers are no" || chk fail "interactive empty answer"
    sw $'y\ny\ny\ny\ny\ny\n'
    [ "$(cat "$CFGA/alacritty/alacritty.toml")" = "$(printf '[general]\nimport = [\n    "~/.config/alacritty/themes/gruvbox-material-dark.toml",\n    "%s",\n]\n\n[terminal.shell]\nprogram = "/usr/bin/fish"' "$CFGA/alacritty/themes/candy-for-gnome.toml")" ] && chk ok "app themes interactive: Alacritty import array gets exactly one new element after the hand-made one" || chk fail "alacritty edit ($(cat "$CFGA/alacritty/alacritty.toml"))"
    [ "$(cat "$CFGA/helix/config.toml")" = "$(printf 'theme = "candy-for-gnome"\n\n[editor]\nline-number = "relative"')" ] && chk ok "app themes interactive: Helix theme = line replaced, the rest kept" || chk fail "helix edit"
    [ "$(cat "$CFGA/yazi/theme.toml")" = "$(printf '[flavor]\ndark = "candy-for-gnome-dark"\nlight = "candy-for-gnome-light"\n\n[status]\nprogress_label = { bold = true }')" ] && chk ok "app themes interactive: Yazi [flavor] dark replaced and light added in the table" || chk fail "yazi edit ($(cat "$CFGA/yazi/theme.toml"))"
    [ "$(cat "$CFGA/bat/config")" = "$(printf -- '--theme="auto:system"\n--style=numbers\n--theme-dark="candy-for-gnome-dark"\n--theme-light="candy-for-gnome-light"')" ] && chk ok "app themes interactive: bat --theme replaced in place, the two others appended, --style kept" || chk fail "bat edit ($(cat "$CFGA/bat/config"))"
    [ "$(cat "$CFGA/zellij/config.kdl")" = "$(printf 'theme "gruvbox-material-dark"\nthemes {\n    gruvbox-material-dark { }\n}\ntheme_dark "candy-for-gnome-dark"\ntheme_light "candy-for-gnome-light"')" ] && chk ok "app themes interactive: zellij gets theme_dark and theme_light appended; the theme line and themes block stay" || chk fail "zellij edit ($(cat "$CFGA/zellij/config.kdl"))"
    [ -L "$CFGA/eza/theme.yml" ] && [ "$(head -1 "$CFGA/eza/theme.yml.candy-bak")" = 'filekinds:' ] && chk ok "app themes interactive: eza's own theme.yml is moved to theme.yml.candy-bak and replaced by the link" || chk fail "eza move aside"
    cfg_snapshot > "$T/apps.after1"; sw ''; cfg_snapshot > "$T/apps.after2"; cmp -s "$T/apps.after1" "$T/apps.after2" && ! grep -q 'Add\|Set \|Replace' "$T/apps.tty" && chk ok "app themes interactive: nothing is asked again once the lines are there" || chk fail "second run asked or changed ($(cat "$T/apps.tty" | tr -d '\r' | head -5))"
    # Alacritty: a single-line import array and a file without one
    printf '[general]\nimport = [ "a.toml" ]\n' > "$CFGA/alacritty/alacritty.toml"; sw $'y\nn\nn\nn\nn\nn\n'; grep -qx "import = \[ \"a.toml\", \"$CFGA/alacritty/themes/candy-for-gnome.toml\" ]" "$CFGA/alacritty/alacritty.toml" && chk ok "app themes interactive: a single-line import array gets the element appended" || chk fail "alacritty single line ($(cat "$CFGA/alacritty/alacritty.toml"))"
    printf '[font]\nsize = 11\n' > "$CFGA/alacritty/alacritty.toml"; sw $'y\nn\nn\nn\nn\nn\n'; [ "$(cat "$CFGA/alacritty/alacritty.toml")" = "$(printf '[font]\nsize = 11')" ] && grep -q 'Could not edit .* safely' "$T/apps.tty" && chk ok "app themes interactive: no import array to extend: nothing edited, the lines are printed" || chk fail "alacritty no import"
    # remove: marked files and our links go, the user's configs are not edited, the notes name what remains
    app_reset; aps just install-theme gruvbox-material </dev/null >/dev/null 2>&1; sw $'y\ny\ny\ny\ny\ny\n'; echo mine > "$CFGA/helix/themes/candy-for-gnome-other.toml"; cfg_snapshot > "$T/apps.before"
    out=$(aps just remove-theme gruvbox-material </dev/null 2>&1); cfg_snapshot > "$T/apps.after"
    [ -z "$(find "$CFGA" -name 'candy-for-gnome-gruvbox-material*' -o -type l 2>/dev/null)" ] && [ ! -e "$HA/.claude/themes/candy-for-gnome.json" ] && [ -f "$CFGA/helix/themes/candy-for-gnome-other.toml" ] && [ -f "$CFGA/eza/theme.yml.candy-bak" ] && cmp -s "$T/apps.before" "$T/apps.after" && printf '%s\n' "$out" | grep -q 'still has' \
      && chk ok "app themes: remove-theme deletes the marked files, the managed links and the Claude file, leaves unrelated files, never edits a config (and says what still mentions candy-for-gnome)" || chk fail "app remove ($(find "$CFGA" -type l -o -name 'candy-for-gnome-*' | tr '\n' ' ') / $out)"
else echo "  skip interactive app theme tests (script not installed)"; fi
# 7. a scheme whose name starts with another one: removing catppuccin must not take catppuccin-frappe's link
app_reset; aps just install-theme catppuccin </dev/null >/dev/null 2>&1; aps just install-theme catppuccin-frappe </dev/null >/dev/null 2>&1; aps just switch-theme catppuccin-frappe </dev/null >/dev/null 2>&1; aps just remove-theme catppuccin </dev/null >/dev/null 2>&1
[ -L "$CFGA/helix/themes/candy-for-gnome.toml" ] && [ -f "$CFGA/helix/themes/candy-for-gnome-catppuccin-frappe-dark.toml" ] && [ ! -e "$CFGA/helix/themes/candy-for-gnome-catppuccin-dark.toml" ] && [ -L "$CFGA/zellij/themes/candy-for-gnome.kdl" ] && chk ok "app themes: removing catppuccin keeps the links of catppuccin-frappe" || chk fail "prefix scheme link"
# 8. update refreshes our stale files; the Homebrew bin dir counts as installed
echo "# stale" >> "$CFGA/helix/themes/candy-for-gnome-catppuccin-frappe-dark.toml"; aps just update-theme </dev/null >/dev/null 2>&1; grep -q stale "$CFGA/helix/themes/candy-for-gnome-catppuccin-frappe-dark.toml" && chk fail "app update did not refresh" || chk ok "app themes: update-theme refreshes our installed files"
app_reset; BB="$T/brewbin"; mkdir -p "$BB"; printf '#!/bin/sh\nexit 0\n' > "$BB/hx"; chmod +x "$BB/hx"
CANDY_FOR_GNOME_BREW_BIN="$BB" ap just install-theme gruvbox-material </dev/null >/dev/null 2>&1
[ -f "$CFGA/helix/themes/candy-for-gnome-gruvbox-material-dark.toml" ] && [ ! -e "$CFGA/alacritty/themes" ] && chk ok "app themes: a binary only in the Homebrew bin dir counts as installed (Helix), the others stay skipped" || chk fail "brew bin"
# 9. drift: a stale generated file fails the selftest for the app files
rm -rf "$T/drift2"; mkdir -p "$T/drift2/themes"; cp -r tools "$T/drift2/"; cp -r themes/nordic "$T/drift2/themes/"; echo '# stale' >> "$T/drift2/themes/nordic/helix/candy-for-gnome-nordic-dark.toml"
python3 -I "$T/drift2/tools/selftest.py" nordic apps >/dev/null 2>&1 && chk fail "app drift: a stale generated file passed the selftest" || chk ok "app drift: a stale generated file fails the selftest"
rm -rf "$CFGA" "$HA" "$APD" "$T/adata" "$T/drift2"

# ---- Shell theme without the extension's gsettings schema (it is per user: gsettings does not list it) -----------------------
echo "=== shell theme via dconf"
first=$({ printf '%s\n' "${named[@]}"; echo "$all_schemes"; } | grep -vx '' | head -n1 | awk '{print $1}')
mkdir -p "$T/bin2"; DLOG="$T/dconf.log"; : > "$DLOG"
printf '#!/bin/sh\ncase "$1" in set) echo "set $2 $3 $4" >> "%s" ;; get) echo "\x27prefer-dark\x27" ;; list-schemas) : ;; esac\n' "$LOG" > "$T/bin2/gsettings"
printf '#!/bin/sh\n[ "$1" = write ] && echo "write $2 $3" >> "%s"\n' "$DLOG" > "$T/bin2/dconf"
chmod +x "$T/bin2/gsettings" "$T/bin2/dconf"
D="$T/themes-dconf"; PATH="$T/bin2:$PATH" THEMES_DEST=$D just install-theme "$first" >/dev/null 2>&1
PATH="$T/bin2:$PATH" THEMES_DEST=$D just switch-theme "$first" >/dev/null 2>&1
grep -q "write /org/gnome/shell/extensions/user-theme/name" "$DLOG" && chk ok "switch-theme writes the user-theme key with dconf when gsettings lacks the schema" || chk fail "switch-theme did not set the Shell theme (no dconf write)"

# ---- libadwaita file: no confirmation for our own files or when the backup of the original already exists ---------------------
echo "=== libadwaita file replacement"
first=$({ printf '%s\n' "${named[@]}"; echo "$all_schemes"; } | grep -vx '' | head -n1 | awk '{print $1}'); D="$T/themes-la"; CFGLA="$T/cfg-la"; mkdir -p "$CFGLA/gtk-4.0"; accs=$(grep -v '^#' "themes/$first/accents/list" | awk 'NF {print $1}')
a1=$(echo "$accs" | sed -n 1p); a2=$(echo "$accs" | sed -n 2p)
THEMES_DEST=$D just install-theme "$first" >/dev/null 2>&1
sw() { XDG_CONFIG_HOME="$CFGLA" THEMES_DEST=$D just switch-theme "$first" "$1" 2>&1 </dev/null; }
sw "$a1" | grep -q "Installed $CFGLA/gtk-4.0/gtk.css" && chk ok "libadwaita file installed when absent" || chk fail "libadwaita file not installed when absent"
c1=$(sha1sum < "$CFGLA/gtk-4.0/gtk.css"); sw "$a2" | grep -q "Updated $CFGLA/gtk-4.0/gtk.css"; c2=$(sha1sum < "$CFGLA/gtk-4.0/gtk.css")
[ "$c1" != "$c2" ] && chk ok "our own libadwaita file is replaced without a prompt on an accent change" || chk fail "accent change did not replace our own libadwaita file"
echo "/* somebody else's stylesheet */" > "$CFGLA/gtk-4.0/gtk.css"; sw "$a1" | grep -q "left alone" && grep -q "somebody else" "$CFGLA/gtk-4.0/gtk.css" && chk ok "a foreign libadwaita file without a backup is left alone without a terminal" || chk fail "foreign libadwaita file was touched"
echo "/* original */" > "$CFGLA/gtk-4.0/gtk.css.bak"; sw "$a1" >/dev/null; { ! grep -q "somebody else" "$CFGLA/gtk-4.0/gtk.css" && grep -q "original" "$CFGLA/gtk-4.0/gtk.css.bak"; } && chk ok "with a backup present the file is replaced without a prompt and the backup is kept" || chk fail "backup case wrong"

# ---- Ptyxis palettes: ids only (no generated palettes), switch-theme writes the id, cleanup of old marked files -----------------
echo "=== ptyxis palette ids"
[ -z "$(ls -d */ptyxis 2>/dev/null)" ] && ! grep -rlq 'ptyxis = "generated"' --include=scheme.toml . && [ ! -e tools/ptyxis-gen.py ] && chk ok "no generated Ptyxis palettes are left (no */ptyxis directories, no generator, no scheme declares generated)" || chk fail "generated palette leftovers"
if [ -r "${PTYXIS_BIN:-/usr/bin/ptyxis}" ]; then
    out=$(python3 -I tools/ptyxis-compare.py --check 2>/dev/null) && chk ok "ptyxis-compare --check: every declared id exists in the Ptyxis binary and the source declarations hold" || { chk fail "ptyxis ids vs built-ins"; printf '%s\n' "$out" | head -5; }
else echo "  SKIP ptyxis-compare --check on the real built-ins (no Ptyxis binary here; the fixture tests below cover the rules)"; fi
# fixture built-ins (a directory of <id>.palette files is accepted as PTYXIS_BIN): ids differ from names and in case
FIX="$T/pty-ids"; mkdir -p "$FIX"
for i in nord "Everforest" "Catppuccin Mocha" "Catppuccin Latte"; do printf '[Palette]\nName=Name of %s\n' "$i" > "$FIX/$i.palette"; done
# dconf db: three profiles; the default one (a) has no palette key, b has one, c has none
PD="$T/themes-pty"; : > "$DCONF_DB"
printf '%s\t%s\n' /org/gnome/Ptyxis/profile-uuids "['aaa', 'bbb', 'ccc']" /org/gnome/Ptyxis/default-profile-uuid "'aaa'" /org/gnome/Ptyxis/Profiles/bbb/palette "'Old'" /org/gnome/Ptyxis/Profiles/ccc/label "'x'" >> "$DCONF_DB"
# old generated files carry our marker; Kevin's own palette does not (it even mentions candy-for-gnome in a comment)
rm -rf "$PTYXIS_PALETTES"; mkdir -p "$PTYXIS_PALETTES"
mkold() { printf '[Palette]\nName=Old (GNOME Themes)\n# candy-for-gnome: rose-pine\n' > "$PTYXIS_PALETTES/candy-for-gnome-rose-pine.palette"; printf '[Palette]\nName=Old\n# candy-for-gnome: sweet\n' > "$PTYXIS_PALETTES/candy-for-gnome-sweet.palette"; }
printf '[Palette]\nName=mine\n# see candy-for-gnome for the idea\n' > "$PTYXIS_PALETTES/catppuccin-dynamic.palette"
for verb in install-theme update-theme switch-theme remove-theme; do
    THEMES_DEST=$PD PTYXIS_BIN="$FIX" just install-theme everforest </dev/null >/dev/null 2>&1; mkold
    vargs=(); [ "$verb" = update-theme ] || vargs=(everforest)
    out=$(THEMES_DEST=$PD PTYXIS_BIN="$FIX" just "$verb" "${vargs[@]}" </dev/null 2>&1)
    n=$(printf '%s\n' "$out" | grep -c 'Removed old generated Ptyxis palette')
    [ ! -e "$PTYXIS_PALETTES/candy-for-gnome-rose-pine.palette" ] && [ ! -e "$PTYXIS_PALETTES/candy-for-gnome-sweet.palette" ] && [ "$n" = 2 ] && [ -f "$PTYXIS_PALETTES/catppuccin-dynamic.palette" ] && grep -q mine "$PTYXIS_PALETTES/catppuccin-dynamic.palette" && chk ok "$verb deletes the old marked palette files (one line each) and keeps the unmarked one" || chk fail "$verb palette cleanup ($n lines; $(ls "$PTYXIS_PALETTES" | tr '\n' ' '))"
done
THEMES_DEST=$PD just remove-theme everforest </dev/null >/dev/null 2>&1; rm -rf "$PTYXIS_PALETTES"
THEMES_DEST=$PD PTYXIS_BIN="$FIX" just install-theme everforest </dev/null >/dev/null 2>&1; ls "$PTYXIS_PALETTES" >/dev/null 2>&1 && [ -z "$(ls "$PTYXIS_PALETTES")" ] && chk fail "install created palette dir content" || chk ok "install-theme copies no palette file"
# switch-theme writes the ID (not the Name) on the default profile and the one that had a key, reads it back, and finds it among the built-ins
out=$(THEMES_DEST=$PD PTYXIS_BIN="$FIX" just switch-theme everforest </dev/null 2>&1)
[ "$(dconf read /org/gnome/Ptyxis/Profiles/aaa/palette)" = "'Everforest'" ] && [ "$(dconf read /org/gnome/Ptyxis/Profiles/bbb/palette)" = "'Everforest'" ] && [ -z "$(dconf read /org/gnome/Ptyxis/Profiles/ccc/palette)" ] && printf '%s\n' "$out" | grep -q "Ptyxis palette key reads 'Everforest'" && ! printf '%s\n' "$out" | grep -q WARNING && chk ok "switch-theme writes the id on the default and the palette-keyed profile, reads the key back and prints it, no warning" || chk fail "id switch ($(grep palette "$DCONF_DB" | tr '\t\n' '= '))"
# a lower-case id (nord): the id, never the Name 'Nord'
: > "$DCONF_DB"; printf '%s\t%s\n' /org/gnome/Ptyxis/profile-uuids "['aaa']" /org/gnome/Ptyxis/default-profile-uuid "'aaa'" >> "$DCONF_DB"
THEMES_DEST=$PD just install-theme nordic </dev/null >/dev/null 2>&1; THEMES_DEST=$PD just install-theme catppuccin </dev/null >/dev/null 2>&1; THEMES_DEST=$PD PTYXIS_BIN="$FIX" just switch-theme nordic </dev/null >/dev/null 2>&1
[ "$(dconf read /org/gnome/Ptyxis/Profiles/aaa/palette)" = "'nord'" ] && chk ok "nordic writes the id 'nord' (lower case), not the Name" || chk fail "nordic id ($(grep palette "$DCONF_DB" | tr '\t\n' '= '))"
# an id that the installed Ptyxis does not have: warning
mkdir -p "$T/pty-ids-short"; cp "$FIX/nord.palette" "$T/pty-ids-short/"
out=$(THEMES_DEST=$PD PTYXIS_BIN="$T/pty-ids-short" just switch-theme everforest </dev/null 2>&1)
printf '%s\n' "$out" | grep -q "WARNING: 'Everforest' is not a built-in palette id" && chk ok "an id missing from the installed Ptyxis is reported (it would fall back to the default palette)" || chk fail "no warning for an unknown id"
# light/dark: catppuccin has ptyxis (Mocha) and ptyxis_light (Latte); the system colour scheme decides at switch time
gs() { mkdir -p "$T/gs-$1"; printf '#!/bin/sh\ncase "$1" in set) : ;; get) case "$3" in color-scheme) echo "\x27%s\x27";; gtk-theme) echo "\x27%s\x27";; *) echo "\x27x\x27";; esac ;; list-schemas) echo org.gnome.shell.extensions.user-theme ;; esac\n' "$2" "$3" > "$T/gs-$1/gsettings"; chmod +x "$T/gs-$1/gsettings"; }
cat_id() { : > "$DCONF_DB"; printf '%s\t%s\n' /org/gnome/Ptyxis/profile-uuids "['aaa']" /org/gnome/Ptyxis/default-profile-uuid "'aaa'" >> "$DCONF_DB"; PATH="$T/gs-$1:$PATH" THEMES_DEST=$PD PTYXIS_BIN="$FIX" just switch-theme catppuccin </dev/null > "$T/cat.out" 2>&1; dconf read /org/gnome/Ptyxis/Profiles/aaa/palette; }
gs dark prefer-dark Adwaita; gs light prefer-light Adwaita; gs defl default Adwaita; gs defd default Gruvbox-dark
[ "$(cat_id dark)" = "'Catppuccin Mocha'" ] && chk ok "prefer-dark: Catppuccin gets its dark id" || chk fail "prefer-dark id"
[ "$(cat_id light)" = "'Catppuccin Latte'" ] && grep -q 'again after changing between light and dark' "$T/cat.out" && chk ok "prefer-light: the light id, and the output says to run switch-theme again after changing light/dark" || chk fail "prefer-light id"
[ "$(cat_id defl)" = "'Catppuccin Latte'" ] && chk ok "default with a light GTK theme: the light id" || chk fail "default/light id"
[ "$(cat_id defd)" = "'Catppuccin Mocha'" ] && chk ok "default with a dark GTK theme: the dark id" || chk fail "default/dark id"
# no Ptyxis profile at all: a clear note, nothing written
: > "$DCONF_DB"; out=$(THEMES_DEST=$PD PTYXIS_BIN="$FIX" just switch-theme everforest </dev/null 2>&1)
printf '%s\n' "$out" | grep -q "no Ptyxis profile found" && ! grep -q Ptyxis "$DCONF_DB" && chk ok "no Ptyxis settings: note and skip" || chk fail "missing Ptyxis settings not handled"
for s in everforest nordic catppuccin; do THEMES_DEST=$PD just remove-theme $s </dev/null >/dev/null 2>&1; done; rm -rf "$PTYXIS_PALETTES"

# ---- GtkSourceView style schemes: generated files, install/switch/update/remove, Flatpak editors, collision guard ------------------
echo "=== gtksourceview styles"
cat > "$T/gsvcheck.py" <<'PY'
import sys, re, glob, os, xml.etree.ElementTree as ET
sys.path.insert(0, 'tools'); import schemeroles as sr
bad = []
for f in sorted(f for s in os.environ['SCHEMES'].split() for f in glob.glob('themes/' + s + '/gtksourceview/*.xml')):
    scheme = f.split('/')[1]
    try: root = ET.parse(f).getroot()
    except ET.ParseError as e: bad.append('%s: %s' % (f, e)); continue
    sid = root.get('id'); name = root.get('_name') or root.get('name')
    if sid != os.path.basename(f)[:-4] or not re.fullmatch(r'([a-zA-Z0-9_]|-)+', sid) or not name: bad.append(f + ': id/name')
    if 'candy-for-gnome: ' + scheme not in open(f).read(): bad.append(f + ': marker')
    cols = {c.get('name'): c.get('value') for c in root.iter('color')}
    meta = {p.get('name'): p.text for p in root.iter('property')}
    if meta.get('variant') not in ('dark', 'light'): bad.append(f + ': variant')
    for k in ('light-variant', 'dark-variant'):
        if k in meta and not os.path.exists('themes/%s/gtksourceview/%s.xml' % (scheme, meta[k])): bad.append('%s: %s %s does not resolve' % (f, k, meta[k]))
    def val(v): return cols.get(v) if not v.startswith('#') else v
    B, CL = val('bg-deep'), val('bg')
    for s in root.iter('style'):
        for a in ('foreground', 'background', 'line-background'):
            v = s.get(a)
            if v is not None and val(v) is None: bad.append('%s: style %s %s=%s does not resolve' % (f, s.get('name'), a, v))
        fg = s.get('foreground')
        if fg is None or s.get('name') in ('selection',): continue
        need = 3.0 if s.get('name') in ('def:comment', 'def:shebang') else 4.5
        bgs = [val(s.get('background'))] if s.get('background') and s.get('name') not in ('current-line-number',) else [B, CL]
        if s.get('name') in ('search-match', 'bracket-match', 'bracket-mismatch'): bgs = [val(s.get('background'))]
        for b in bgs:
            if sr.contrast(val(fg), b) < need - 0.01: bad.append('%s: %s %.2f < %.1f on %s' % (f, s.get('name'), sr.contrast(val(fg), b), need, b))
    if sr.contrast(cols['fg'], cols['selection']) < 4.5: bad.append(f + ': fg on selection')
print('\n'.join(bad[:15])); sys.exit(1 if bad else 0)
PY
out=$(python3 -I "$T/gsvcheck.py" 2>&1) && chk ok "style schemes: XML parses, id = file name, markers, metadata and every colour reference resolve, syntax colours >= 4.5:1 (comments 3:1) on the editor background and current line, text on selection >= 4.5" || { chk fail "gtksourceview check"; printf '%s\n' "$out" | head -8; }
if python3 -c "import gi; gi.require_version('GtkSource','5')" 2>/dev/null; then
    out=$(python3 -I - <<'PY' 2>&1
import gi, glob, os; gi.require_version('GtkSource', '5'); from gi.repository import GtkSource
m = GtkSource.StyleSchemeManager.new(); m.set_search_path([os.path.abspath('themes/' + s + '/gtksourceview') for s in os.environ['SCHEMES'].split()])
miss = [os.path.basename(f)[:-4] for f in (f for s in os.environ['SCHEMES'].split() for f in glob.glob('themes/' + s + '/gtksourceview/*.xml')) if not m.get_scheme(os.path.basename(f)[:-4])]
print(miss); raise SystemExit(1 if miss else 0)
PY
) && chk ok "GtkSourceView itself loads every generated style scheme" || { chk fail "GtkSourceView could not load: $out"; }
else echo "  skip GtkSourceView load test (typelib not installed)"; fi
rm -rf "$GTKSOURCEVIEW_STYLES" "$FLATPAK_APPS"; PD="$T/themes-gsv"; : > "$DCONF_DB"; : > "$FLATPAK_DB"
printf '%s\t%s\n' /org/gnome/Ptyxis/profile-uuids "['aaa']" >> "$DCONF_DB"
mkdir -p "$FLATPAK_APPS/org.gnome.TextEditor"    # Text Editor: data dir exists; Builder: only known to flatpak
out=$(FLATPAK_INFO="org.gnome.Builder" PATH="$T/fpbin:$PATH" THEMES_DEST=$PD just install-theme gruvbox-material </dev/null 2>&1)
ids="candy-for-gnome-gruvbox-material-dark.xml candy-for-gnome-gruvbox-material-light.xml"; ok=1
for d in "$GTKSOURCEVIEW_STYLES" "$FLATPAK_APPS/org.gnome.TextEditor/data/gtksourceview-5/styles" "$FLATPAK_APPS/org.gnome.Builder/data/gtksourceview-5/styles"; do for f in $ids; do [ -f "$d/$f" ] || ok=0; done; done
[ $ok = 1 ] && chk ok "install-theme copies the style schemes into the user dir and into the Flatpak editors' data dirs (Text Editor by dir, Builder via flatpak info)" || chk fail "gsv install ($(ls "$GTKSOURCEVIEW_STYLES" 2>&1 | tr '\n' ' '))"
out=$(FLATPAK_INFO="org.gnome.Builder" PATH="$T/fpbin:$PATH" THEMES_DEST=$PD just switch-theme gruvbox-material </dev/null 2>&1)
gsread() { awk -F'\t' -v a="$1" -v s="$2" -v k="$3" '$1==a && $2==s && $3==k {v=$4} END {print v}' "$FLATPAK_GS"; }
[ "$(dconf read /org/gnome/TextEditor/style-scheme)" = "'candy-for-gnome-gruvbox-material-dark'" ] && [ "$(gsread org.gnome.Builder org.gnome.builder.editor style-scheme-name)" = "candy-for-gnome-gruvbox-material-dark" ] && [ -z "$(dconf read /org/gnome/builder/editor/style-scheme-name)" ] && printf '%s\n' "$out" | grep -q "Builder (Flatpak) style scheme is now candy-for-gnome-gruvbox-material-dark" && chk ok "switch-theme: Text Editor (not a Flatpak) through host dconf, Builder (Flatpak) inside its sandbox store with a read-back, -dark id while the desktop is dark" || chk fail "gsv switch dark ($(grep -E 'TextEditor|builder' "$DCONF_DB" | tr '\t\n' '= ') / $(tr '\t\n' '= ' < "$FLATPAK_GS"))"
lbin="$T/bin-light"; mkdir -p "$lbin"; printf '#!/bin/sh\ncase "$1" in set) : ;; get) case "$3" in color-scheme) echo "\x27default\x27";; *) echo "\x27x\x27";; esac ;; list-schemas) echo org.gnome.shell.extensions.user-theme ;; esac\n' > "$lbin/gsettings"; chmod +x "$lbin/gsettings"
PATH="$lbin:$PATH" THEMES_DEST=$PD just switch-theme gruvbox-material </dev/null >/dev/null 2>&1
[ "$(dconf read /org/gnome/TextEditor/style-scheme)" = "'candy-for-gnome-gruvbox-material-light'" ] && [ "$(gsread org.gnome.Builder org.gnome.builder.editor style-scheme-name)" = "candy-for-gnome-gruvbox-material-dark" ] && chk ok "light desktop: the -light id for Text Editor; Builder untouched when it is not installed" || chk fail "gsv switch light"
# Flatpak Text Editor: the key goes into the sandbox store (right app, schema, key), read back, host dconf untouched; a mismatch warns; no flatpak does nothing there
: > "$DCONF_DB"; : > "$FLATPAK_GS"; rm -f "$FLATPAK_GS.calls"
out=$(FLATPAK_INFO="org.gnome.TextEditor" PATH="$T/fpbin:$PATH" THEMES_DEST=$PD just switch-theme gruvbox-material </dev/null 2>&1)
[ "$(gsread org.gnome.TextEditor org.gnome.TextEditor style-scheme)" = "candy-for-gnome-gruvbox-material-dark" ] && grep -q "^run org.gnome.TextEditor set org.gnome.TextEditor style-scheme candy-for-gnome-gruvbox-material-dark" "$FLATPAK_GS.calls" && [ -z "$(dconf read /org/gnome/TextEditor/style-scheme)" ] && printf '%s\n' "$out" | grep -q "Text Editor (Flatpak) style scheme is now candy-for-gnome-gruvbox-material-dark" && ! printf '%s\n' "$out" | grep -q "Text Editor style scheme is now" && chk ok "Flatpak Text Editor: set and read back inside the sandbox (org.gnome.TextEditor style-scheme), host dconf not written" || chk fail "flatpak text editor ($out)"
: > "$FLATPAK_GS"; out=$(FLATPAK_GS_RO=1 FLATPAK_INFO="org.gnome.TextEditor" PATH="$T/fpbin:$PATH" THEMES_DEST=$PD just switch-theme gruvbox-material </dev/null 2>&1)
printf '%s\n' "$out" | grep -q "WARNING: Text Editor (Flatpak) style scheme reads" && ! printf '%s\n' "$out" | grep -q "Text Editor (Flatpak) style scheme is now" && chk ok "a read-back that does not match warns and does not claim success" || chk fail "no mismatch warning ($out)"
: > "$FLATPAK_GS"; rm -f "$FLATPAK_GS.calls"
out=$(THEMES_DEST=$PD just switch-theme gruvbox-material </dev/null 2>&1)
[ ! -e "$FLATPAK_GS.calls" ] && [ "$(dconf read /org/gnome/TextEditor/style-scheme)" = "'candy-for-gnome-gruvbox-material-dark'" ] && ! printf '%s\n' "$out" | grep -q "(Flatpak)" && chk ok "no Flatpak: no sandbox call, host dconf is used for Text Editor" || chk fail "no-flatpak editor ($out)"
# GSETTINGS_BACKEND=keyfile: ignored (unset, one note, the stubs still run); unset or another value: no note
: > "$LOG"
out=$(GSETTINGS_BACKEND=keyfile THEMES_DEST=$PD just switch-theme gruvbox-material </dev/null 2>&1)
[ "$(printf '%s\n' "$out" | grep -c 'GSETTINGS_BACKEND=keyfile ignored')" = 1 ] && grep -q "^set org.gnome.desktop.interface gtk-theme" "$LOG" && chk ok "GSETTINGS_BACKEND=keyfile is ignored with one note and the gsettings stub still runs" || chk fail "keyfile note ($out)"
printf '#!/bin/sh\necho "backend=${GSETTINGS_BACKEND:-unset}" >> "%s.env"\ncase "$1" in get) echo "\x27prefer-dark\x27";; esac\n' "$LOG" > "$T/gsenv-gsettings"; mkdir -p "$T/gsenv"; cp "$T/gsenv-gsettings" "$T/gsenv/gsettings"; chmod +x "$T/gsenv/gsettings"; rm -f "$LOG.env"
GSETTINGS_BACKEND=keyfile PATH="$T/gsenv:$PATH" THEMES_DEST=$PD just switch-theme gruvbox-material </dev/null >/dev/null 2>&1
[ -s "$LOG.env" ] && ! grep -qv '^backend=unset$' "$LOG.env" && chk ok "the stub gsettings sees no GSETTINGS_BACKEND when keyfile was set" || chk fail "keyfile still visible to gsettings ($(sort -u "$LOG.env" 2>&1))"
out=$(THEMES_DEST=$PD just switch-theme gruvbox-material </dev/null 2>&1); ! printf '%s\n' "$out" | grep -q 'GSETTINGS_BACKEND' && chk ok "no note when GSETTINGS_BACKEND is unset" || chk fail "note without the variable"
rm -f "$LOG.env"; out=$(GSETTINGS_BACKEND=dconf PATH="$T/gsenv:$PATH" THEMES_DEST=$PD just switch-theme gruvbox-material </dev/null 2>&1)
! printf '%s\n' "$out" | grep -q 'GSETTINGS_BACKEND' && grep -q '^backend=dconf$' "$LOG.env" && chk ok "another value (dconf) is left alone: no note, passed through" || chk fail "dconf value touched"
PATH="$lbin:$PATH" THEMES_DEST=$PD just switch-theme gruvbox-material </dev/null 2>&1 | grep -q "Builder not found" && chk ok "without Builder the skip is announced" || chk fail "no Builder note"
echo "<!-- stale -->" >> "$GTKSOURCEVIEW_STYLES/candy-for-gnome-gruvbox-material-dark.xml"; THEMES_DEST=$PD just update-theme </dev/null >/dev/null 2>&1
grep -q stale "$GTKSOURCEVIEW_STYLES/candy-for-gnome-gruvbox-material-dark.xml" && chk fail "update did not refresh the style scheme" || chk ok "update-theme refreshes the style schemes"
THEMES_DEST=$PD just remove-theme gruvbox-material </dev/null >/dev/null 2>&1
[ -z "$(find "$GTKSOURCEVIEW_STYLES" "$FLATPAK_APPS/org.gnome.TextEditor" -type f 2>/dev/null)" ] && chk ok "remove-theme removes the style schemes everywhere" || chk fail "remove left style schemes: $(find "$GTKSOURCEVIEW_STYLES" "$FLATPAK_APPS" -type f 2>&1 | tr "\n" " ")"
# collision: an unmarked file with our id is kept; dark-only scheme has only the dark id
mkdir -p "$GTKSOURCEVIEW_STYLES"; echo mine > "$GTKSOURCEVIEW_STYLES/candy-for-gnome-fairy-floss-dark.xml"
out=$(THEMES_DEST=$PD just install-theme fairy-floss </dev/null 2>&1)
[ "$(cat "$GTKSOURCEVIEW_STYLES/candy-for-gnome-fairy-floss-dark.xml")" = mine ] && printf '%s\n' "$out" | grep -q "not installed by candy-for-gnome" && chk ok "an unmarked style scheme file is not replaced" || chk fail "gsv collision"
rm -f "$GTKSOURCEVIEW_STYLES/candy-for-gnome-fairy-floss-dark.xml"; THEMES_DEST=$PD just install-theme fairy-floss </dev/null >/dev/null 2>&1
[ -f "$GTKSOURCEVIEW_STYLES/candy-for-gnome-fairy-floss-dark.xml" ] && [ ! -e "$GTKSOURCEVIEW_STYLES/candy-for-gnome-fairy-floss-light.xml" ] && chk ok "a dark-only scheme installs only its -dark style scheme" || chk fail "dark-only gsv"
THEMES_DEST=$PD just remove-theme fairy-floss </dev/null >/dev/null 2>&1; THEMES_DEST=$PD just remove-theme gruvbox-material </dev/null >/dev/null 2>&1; rm -rf "$GTKSOURCEVIEW_STYLES" "$FLATPAK_APPS" "$PTYXIS_PALETTES"

# ---- new-scheme helpers: Ptyxis built-in reader (by id) and the draft scheme.toml writer (fixture built-ins, no real Ptyxis needed) ----
echo "=== new scheme from a Ptyxis palette"
col() { printf 'Background=%s\nForeground=%s\nCursor=%s\n' "$1" "$2" "$3"; for i in $(seq 0 15); do printf 'Color%d=#%02x%02x%02x\n' "$i" $((i*9+40)) $((255-i*8)) $((i*5+90)); done; }
FAKE="$T/fake-ids"; mkdir -p "$FAKE"
{ printf '[Palette]\nName=Fake Night\n'; col '#101820' '#e0e0e0' '#ffffff'; } > "$FAKE/Fake Night.palette"
{ printf '[Palette]\nName=Fake Duo\nPrimary=true\n[Light]\n'; col '#fafafa' '#202020' '#202020'; printf '[Dark]\n'; col '#202030' '#d0d0e0' '#d0d0e0'; } > "$FAKE/Fake Duo.palette"
{ printf '[Palette]\nName=Ros\xc3\xa9 Fake\n'; col '#191724' '#e0def4' '#e0def4'; } > "$FAKE/Rosé Fake.palette"
{ printf '[Palette]\nName=Fake Duo Lower\n'; col '#000000' '#ffffff' '#ffffff'; } > "$FAKE/fake duo.palette"
export PTYXIS_BIN="$FAKE"
[ "$(tools/ptyxis-palette.sh list | tr '\t\n' '= ')" = "Fake Duo=Fake Duo=Light,Dark Fake Night=Fake Night=flat Rosé Fake=Rosé Fake=flat fake duo=Fake Duo Lower=flat " ] && chk ok "ptyxis-palette.sh list: id, Name and sections, including a non-ASCII id and ids that differ only in case" || chk fail "ptyxis-palette.sh list: $(tools/ptyxis-palette.sh list | tr '\t\n' '= ')"
tools/ptyxis-palette.sh show "Rosé Fake" | grep -qx 'Name=Rosé Fake' && python3 -I tools/scheme-from-ptyxis.py zz-rose "Rosé Fake" >/dev/null 2>&1 && grep -q '^bg_deep = "#191724"' zz-rose/scheme.toml && grep -qx 'ptyxis = "Rosé Fake"' zz-rose/scheme.toml && chk ok "non-ASCII ids work in ptyxis-palette.sh show and scheme-from-ptyxis (the draft declares the id)" || chk fail "non-ASCII palette id (Rosé)"
rm -rf zz-rose
tools/ptyxis-palette.sh show "Fake Duo" | grep -q '^\[Dark\]' && tools/ptyxis-palette.sh show "Fake Night" | grep -q '^Color15=' && ! tools/ptyxis-palette.sh show "Fake Night" | grep -q Duo && tools/ptyxis-palette.sh show "fake duo" | grep -q 'Fake Duo Lower' && chk ok "ptyxis-palette.sh show: the id is exact and case-sensitive, one palette, verbatim" || chk fail "ptyxis-palette.sh show"
tools/ptyxis-palette.sh show nothing >/dev/null 2>&1 && chk fail "show of an unknown id succeeded" || chk ok "ptyxis-palette.sh show: unknown id fails"
tools/ptyxis-palette.sh show "FAKE NIGHT" >/dev/null 2>&1 && chk fail "show matched an id case-insensitively" || chk ok "ptyxis-palette.sh show: a Name-style spelling of the wrong case is not an id"
rm -rf zz-fake zz-duo zz-two
out=$(python3 -I tools/scheme-from-ptyxis.py zz-duo "Fake Duo" 2>&1)
python3 -I - <<'PY' && chk ok "scheme-from-ptyxis: a sectioned palette gives dark and light draft variants with the accents, bg_deep, fg, the id, and the TODO list" || chk fail "draft scheme.toml wrong"
import tomllib
S = tomllib.load(open('zz-duo/scheme.toml', 'rb'))
assert S['title'] == 'Zz Duo' and S['gtk_name'] == 'Zz-Duo' and S['shell_name'] == 'Zz-Duo-Shell'
assert S['ptyxis'] == 'Fake Duo' and 'ptyxis_light' not in S and S['dark']['terminal']['source'] == 'Fake Duo'
assert S['dark']['bg_deep'] == '#202030' and S['light']['bg_deep'] == '#fafafa' and S['dark']['fg'] == '#d0d0e0'
assert set(S['dark']['ansi']) == {'red', 'green', 'yellow', 'blue', 'magenta', 'cyan'}
assert S['dark']['ansi']['green'] == '#%02x%02x%02x' % (2 * 9 + 40, 255 - 16, 2 * 5 + 90)
assert 'terminal' in S['dark'] and S['dark']['terminal']['black'] == '#%02x%02x%02x' % (40, 255, 90)
assert open('zz-duo/scheme.toml').read().count('# TODO') >= 6
PY
printf '%s\n' "$out" | grep -q "default_accent: proposed" && chk ok "the TODO list is printed (default_accent proposal with its reason)" || chk fail "TODO list not printed"
python3 -I tools/palette-from-scheme.py zz-duo --check >/dev/null 2>&1 && chk ok "the draft derives a palette.toml (the pipeline accepts it)" || chk fail "palette-from-scheme.py rejects the draft"
out=$(python3 -I tools/scheme-from-ptyxis.py zz-duo "Fake Duo" 2>&1); rc=$?
[ $rc -ne 0 ] && printf '%s\n' "$out" | grep -q "refusing to overwrite" && chk ok "scheme-from-ptyxis refuses to overwrite an existing scheme" || chk fail "overwrite not refused"
python3 -I tools/scheme-from-ptyxis.py zz-fake "Fake Night" >/dev/null 2>&1; grep -q '^\[dark\]' zz-fake/scheme.toml && ! grep -q '^\[light\]' zz-fake/scheme.toml && grep -q "dark only" zz-fake/scheme.toml && chk ok "a flat dark palette gives a dark-only draft" || chk fail "flat palette draft"
python3 -I tools/scheme-from-ptyxis.py zz-two "Fake Night" "Fake Duo" >/dev/null 2>&1; grep -q '^bg_deep = "#fafafa"' zz-two/scheme.toml && grep -q '^bg_deep = "#101820"' zz-two/scheme.toml && grep -qx 'ptyxis = "Fake Night"' zz-two/scheme.toml && grep -qx 'ptyxis_light = "Fake Duo"' zz-two/scheme.toml && chk ok "a second id gives the light variant and ptyxis_light" || chk fail "light palette argument"
rm -rf zz-fake zz-duo zz-two; unset PTYXIS_BIN
# ptyxis-compare: a copy of everforest declares a built-in id; fixture built-ins are made from the scheme's own colours (a directory of <id>.palette files)
# gruvbox-material dark brights differ from the built-in by decision (ptyxis_brights_differ): accepted, but ONLY Color8-15 of the dark variant
GMB="$T/fix-gm"; mkdir -p "$GMB"   # a stand-in for the Ptyxis built-in (flat, dark only: every bright equals its standard colour), CI has no Ptyxis binary
{ printf '[Palette]\nName=Gruvbox Material\nPrimary=true\nForeground=#D4BE98\nBackground=#282828\nCursor=#D4BE98\n'
  i=0; for c in 3C3836 EA6962 A9B665 D8A657 7DAEA3 D3869B 89B482 D4BE98 3C3836 EA6962 A9B665 D8A657 7DAEA3 D3869B 89B482 D4BE98; do printf 'Color%d=#%s\n' "$i" "$c"; i=$((i+1)); done; } > "$GMB/Gruvbox Material.palette"
gmc() { PTYXIS_BIN="$GMB" python3 -I tools/ptyxis-compare.py --check zz-gm 2>/dev/null; }
rm -rf zz-gm; mkdir zz-gm; cp themes/gruvbox-material/scheme.toml zz-gm/
out=$(gmc); [ -z "$out" ] && chk ok "ptyxis-compare: the decided gruvbox-material brights are accepted (and the light variant, which has no built-in, is not compared)" || chk fail "ptyxis-compare rejects the decided brights: $out"
sed -i '/^ptyxis_brights_differ/d' zz-gm/scheme.toml; gmc | grep -q "Color9 .* differs" && chk ok "ptyxis-compare: without ptyxis_brights_differ the brights are reported" || chk fail "brights not reported without the key"
awk '/^\[dark.ansi\]/ {d=1} d && /^green = / && !x {sub(/#[0-9a-f]{6}/, "#a9b666"); x=1} {print}' themes/gruvbox-material/scheme.toml > zz-gm/scheme.toml
gmc | grep -q "Color2 .* differs" && chk ok "ptyxis-compare: any other difference of the scheme (a standard color) is still reported" || chk fail "other difference not reported"
cp themes/gruvbox-material/scheme.toml zz-gm/; sed -i '/^\[dark.terminal\]/,/^\[light.terminal\]/{s/^bright_red = .*/bright_red = "#ea6962"/; s/^bright_green = .*/bright_green = "#a9b665"/; s/^bright_yellow = .*/bright_yellow = "#d8a657"/; s/^bright_blue = .*/bright_blue = "#7daea3"/; s/^bright_magenta = .*/bright_magenta = "#d3869b"/; s/^bright_cyan = .*/bright_cyan = "#89b482"/; s/^bright_black = .*/bright_black = "#3c3836"/; s/^bright_white = .*/bright_white = "#d4be98"/}' zz-gm/scheme.toml
gmc | grep -q "stale" && chk ok "ptyxis-compare: ptyxis_brights_differ with equal brights is reported as stale" || chk fail "stale brights key not reported"
rm -rf zz-gm
mkdir zz-ef && cp themes/everforest/scheme.toml zz-ef/
EVER="$T/fix-ever"; mkdir -p "$EVER"
python3 -I - "$EVER" <<'PY'
import sys; sys.path.insert(0, 'tools'); import schemeroles as sr
S, roles, slots = sr.load('zz-ef')
out = ['[Palette]', 'Name=Everforest Display Name', 'Primary=true']
for slot, variant in slots:
    c = sr.slot_colors(S, roles, variant); out.append('[%s]' % slot.capitalize())
    out += ['%s=%s' % (k, c[k]) for k in ['Foreground', 'Background', 'Cursor'] + ['Color%d' % i for i in range(16)]]
open(sys.argv[1] + '/Everforest.palette', 'w').write('\n'.join(out) + '\n')
PY
cchk() { PTYXIS_BIN="$EVER" python3 -I tools/ptyxis-compare.py --check zz-ef 2>/dev/null; }
out=$(cchk); [ -z "$out" ] && chk ok "ptyxis-compare --check: a declared id that exists passes" || chk fail "ptyxis-compare: valid id rejected ($out)"
PTYXIS_BIN="$EVER" python3 -I tools/ptyxis-compare.py --check zz-ef 2>&1 >/dev/null | grep -q 'built-in id "Everforest" (Light,Dark): roles max dE 0.00' && chk ok "ptyxis-compare --check reports the delta E of each declared id as information" || chk fail "ptyxis-compare: no delta E info"
sed -i 's/^ptyxis = .*/ptyxis = "Everforestt"/' zz-ef/scheme.toml
out=$(cchk); printf '%s\n' "$out" | grep -q 'is not a Ptyxis built-in id' && chk ok "ptyxis-compare --check: a declared id that is not in the binary is flagged" || chk fail "ptyxis-compare: unknown id accepted ($out)"
sed -i 's/^ptyxis = .*/ptyxis = "everforest"/' zz-ef/scheme.toml
out=$(cchk); printf '%s\n' "$out" | grep -q 'did you mean "Everforest"' && chk ok "ptyxis-compare --check: a wrong-case id is flagged with the right one (ids are case-sensitive)" || chk fail "ptyxis-compare: wrong case accepted ($out)"
cp themes/everforest/scheme.toml zz-ef/scheme.toml; sed -i 's/^ptyxis = .*/&\nptyxis_light = "Everforest"/' zz-ef/scheme.toml
out=$(cchk); printf '%s\n' "$out" | grep -q 'covers both modes' && chk ok "ptyxis-compare --check: ptyxis_light next to a sectioned built-in is flagged" || chk fail "ptyxis-compare: ptyxis_light on a sectioned built-in accepted ($out)"
cp themes/everforest/scheme.toml zz-ef/scheme.toml; sed -i '/^ptyxis_reason/d' zz-ef/scheme.toml
out=$(cchk); printf '%s\n' "$out" | grep -q 'ptyxis_reason missing' && chk ok "ptyxis-compare --check: a missing ptyxis_reason is flagged" || chk fail "ptyxis-compare: missing reason accepted"
# two flat built-ins (catppuccin): ptyxis + ptyxis_light
mkdir zz-cat && cp themes/catppuccin/scheme.toml zz-cat/; CAT="$T/fix-cat"; mkdir -p "$CAT"
python3 -I - "$CAT" <<'PY'
import sys; sys.path.insert(0, 'tools'); import schemeroles as sr
S, roles, slots = sr.load('zz-cat')
for variant, pid in (('dark', 'Catppuccin Mocha'), ('light', 'Catppuccin Latte')):
    c = sr.slot_colors(S, roles, variant)
    open('%s/%s.palette' % (sys.argv[1], pid), 'w').write('[Palette]\nName=%s\n' % pid + ''.join('%s=%s\n' % (k, c[k]) for k in ['Foreground', 'Background', 'Cursor'] + ['Color%d' % i for i in range(16)]))
PY
out=$(PTYXIS_BIN="$CAT" python3 -I tools/ptyxis-compare.py --check zz-cat 2>/dev/null); [ -z "$out" ] && chk ok "ptyxis-compare --check: ptyxis + ptyxis_light on two flat built-ins pass" || chk fail "ptyxis-compare: flat pair rejected ($out)"
sed -i 's/^ptyxis_light = .*/ptyxis_light = "Catppuccin Latté"/' zz-cat/scheme.toml
out=$(PTYXIS_BIN="$CAT" python3 -I tools/ptyxis-compare.py --check zz-cat 2>/dev/null); printf '%s\n' "$out" | grep -q 'ptyxis_light = "Catppuccin Latté" is not' && chk ok "ptyxis-compare --check: a bad ptyxis_light id is flagged (UTF-8 output)" || chk fail "ptyxis-compare: bad ptyxis_light accepted ($out)"
rm -rf zz-cat
# ptyxis-compare --check, the source rules: every variant names its source; a listed nudge must be true; a difference from the built-in is information only
cp themes/everforest/scheme.toml zz-ef/scheme.toml
nud() {   # nud <fg hex> <extra nudge lines>: zz-ef/scheme.toml from everforest with the dark fg changed, then a [dark.nudge] table
    cp themes/everforest/scheme.toml zz-ef/scheme.toml
    python3 -I - "$1" "$2" <<'PY'
import sys, re
t = open('zz-ef/scheme.toml', encoding='utf-8').read()
i = t.index('[dark]'); j = t.index('fg = ', i); k = t.index('\n', j)
t = t[:j] + 'fg = "%s"' % sys.argv[1] + t[k:]
if sys.argv[2]: t += '\n[dark.nudge]\n' + sys.argv[2] + '\n'
open('zz-ef/scheme.toml', 'w', encoding='utf-8').write(t)
PY
}
nud '#d6c9ad' ''
out=$(cchk); printf '%s\n' "$out" | grep -q 'not listed in \[dark.nudge\]' && chk ok "ptyxis-compare --check: a colour that differs from the built-in and is not listed as a nudge is flagged" || chk fail "ptyxis-compare: unlisted difference not flagged ($out)"
de=$(python3 -I - <<'PY'
import sys, importlib.util; sys.path.insert(0, 'tools')
spec = importlib.util.spec_from_file_location('pc', 'tools/ptyxis-compare.py'); pc = importlib.util.module_from_spec(spec); spec.loader.exec_module(pc)
print('%.2f' % pc.de('#d6c9ad', '#d3c6aa'))
PY
)
nud '#d6c9ad' "Foreground = { from = \"#d3c6aa\", to = \"#d6c9ad\", de = $de, why = \"fixture: contrast on the window\" }"
out=$(cchk); [ -z "$out" ] && chk ok "ptyxis-compare --check: a listed nudge (right from, to and delta E, with a reason) passes" || chk fail "ptyxis-compare: listed nudge rejected ($out)"
nud '#d6c9ad' "Foreground = { from = \"#d3c6aa\", to = \"#d6c9ad\", de = $de, why = \"x\" }"
out=$(cchk); printf '%s\n' "$out" | grep -q 'has no reason' && chk ok "ptyxis-compare --check: a nudge without a reason is flagged" || chk fail "ptyxis-compare: reasonless nudge accepted"
nud '#ffffff' "Foreground = { from = \"#d3c6aa\", to = \"#ffffff\", de = 21.0, why = \"fixture: far too big\" }"
out=$(cchk); printf '%s\n' "$out" | grep -q 'NUDGE_MAX' && chk ok "ptyxis-compare --check: a nudge above NUDGE_MAX is flagged" || chk fail "ptyxis-compare: oversized nudge accepted ($out)"
nud '#d3c6aa' "Foreground = { from = \"#d3c6aa\", to = \"#d3c6aa\", de = 0.0, why = \"fixture: stale entry\" }"
out=$(cchk); printf '%s\n' "$out" | grep -q 'stale' && chk ok "ptyxis-compare --check: a listed nudge for a colour that no longer differs is flagged (stale)" || chk fail "ptyxis-compare: stale nudge accepted ($out)"
cp themes/everforest/scheme.toml zz-ef/scheme.toml; sed -i '/^source = /d' zz-ef/scheme.toml
out=$(cchk); printf '%s\n' "$out" | grep -q 'exactly one of source' && chk ok "ptyxis-compare --check: a variant without source or no_builtin is flagged" || chk fail "ptyxis-compare: missing source accepted ($out)"
cp themes/everforest/scheme.toml zz-ef/scheme.toml
# a sectioned built-in for a dark-only scheme needs the acceptance flag (Nordic with Nord)
if [ -r "/usr/bin/ptyxis" ] && tools/ptyxis-palette.sh show nord >/dev/null 2>&1; then
    python3 -I tools/ptyxis-compare.py --check nordic >/dev/null 2>&1 && chk ok "ptyxis-compare --check: Nordic on the sectioned nord built-in passes (accepted light section)" || chk fail "ptyxis-compare: nordic"
    mkdir zz-nd && sed '/^ptyxis_light_section_accepted/d' themes/nordic/scheme.toml > zz-nd/scheme.toml
    out=$(python3 -I tools/ptyxis-compare.py --check zz-nd 2>/dev/null); printf '%s\n' "$out" | grep -q 'ptyxis_light_section_accepted' && chk ok "ptyxis-compare --check: a sectioned built-in for a dark-only scheme is refused without the acceptance flag" || chk fail "ptyxis-compare: sectioned built-in accepted for dark-only ($out)"
    rm -rf zz-nd
else echo "  SKIP Nordic/nord checks (no Ptyxis binary here)"; fi
# the built-in is the only source: an "official:" source, builtin_differs and a source that is not the declared id are flagged
cp themes/everforest/scheme.toml zz-ef/scheme.toml; sed -i '0,/^source = .*/s//source = "official: fixture\/repo, verified 2026-11-07"/' zz-ef/scheme.toml
out=$(cchk); printf '%s\n' "$out" | grep -q 'not the id declared for this variant' && chk ok "ptyxis-compare --check: an official-style source (not the declared built-in id) is flagged" || chk fail "ptyxis-compare: official source accepted ($out)"
cp themes/everforest/scheme.toml zz-ef/scheme.toml; sed -i '0,/^source = .*/s//&\nbuiltin_differs = { name = "Everforest", de = 9.9, note = "fixture: official wins" }/' zz-ef/scheme.toml
out=$(cchk); printf '%s\n' "$out" | grep -q 'builtin_differs is gone' && chk ok "ptyxis-compare --check: builtin_differs is flagged (the mechanism is gone)" || chk fail "ptyxis-compare: builtin_differs accepted ($out)"
rm -rf zz-ef
just --summary 2>/dev/null | grep -q new-scheme && chk fail "new-scheme became a public recipe" || chk ok "new-scheme is private (public set unchanged)"
just --justfile justfile --working-directory . new-scheme 2>&1 | grep -qi "usage\|palette" && chk ok "the private recipe runs by name (the passthrough path)" || chk fail "private recipe not runnable by name"

# ---- icons (fake icon repo) -----------------------------------------------------------------------------------
echo "=== icons"
# a second fixture source and a git wrapper that logs every clone, to prove what is cloned and when
mkdir -p "$T/icons-src2" && (cd "$T/icons-src2" && git init -q && mkdir Other-One && printf '[Icon Theme]\nName=Other-One\nDirectories=\n' > Other-One/index.theme && git add -A && git commit -q -m init)
printf 'fake|file://%s/icons-src|top|Fake-Dark Fake-Light\nother|file://%s/icons-src2|top|Other-One\nbroken|file://%s/nonexistent|top|Broken-One\n' "$T" "$T" "$T" > "$T/sources.conf"
export ICON_SOURCES="$T/sources.conf" ICONS_DEST="$T/icons"
REAL_GIT=$(command -v git); GITLOG="$T/git.log"; mkdir -p "$T/gitw"
printf '#!/bin/sh\necho "$*" >> "%s"\nexec "%s" "$@"\n' "$GITLOG" "$REAL_GIT" > "$T/gitw/git"; chmod +x "$T/gitw/git"
rm -rf "$T/cache/icons"; : > "$GITLOG"
out=$(PATH="$T/gitw:$PATH" just list-icons 2>&1)
[ ! -e "$T/cache/icons" ] && ! grep -q . "$GITLOG" && printf '%s\n' "$out" | grep -q Fake-Dark && printf '%s\n' "$out" | grep -q Other-One && chk ok "list-icons works offline: no clone, no cache directory" || chk fail "list-icons cloned or lacked sets"
# no name: the checklist is built from the registry (cache empty, no clone before the choice); q cancels
out=$(printf 'q\n' | PATH="$T/gitw:$PATH" just install-icon 2>&1)
[ ! -e "$T/cache/icons" ] && ! grep -q . "$GITLOG" && printf '%s\n' "$out" | grep -q "Fake-Light" && printf '%s\n' "$out" | grep -q "Other-One" && chk ok "install-icon: checklist shown with an empty cache and no clone before the choice" || chk fail "install-icon cloned before the choice"
# choose set 1 only: just its source is cloned (the checklist lists fake's two sets first)
printf '1\n\n' | PATH="$T/gitw:$PATH" just install-icon >/dev/null 2>&1
[ -d "$ICONS_DEST/Fake-Dark" ] && grep -q "icons-src " "$GITLOG" && ! grep -q "icons-src2\|nonexistent" "$GITLOG" && [ ! -e "$T/cache/icons/other" ] && chk ok "install-icon: only the source of the chosen set was cloned" || chk fail "install-icon cloned unchosen sources"
just remove-icon Fake-Dark >/dev/null 2>&1; rm -rf "$T/cache/icons"; : > "$GITLOG"
# with names: only those sources; a failing source is skipped, the others install
out=$(PATH="$T/gitw:$PATH" just install-icon Other-One 2>&1)
[ -d "$ICONS_DEST/Other-One" ] && ! grep -q "icons-src " "$GITLOG" && ! grep -q nonexistent "$GITLOG" && chk ok "install-icon NAME: only that source cloned" || chk fail "install-icon NAME cloned more"
out=$(PATH="$T/gitw:$PATH" just install-icon Broken-One 2>&1); printf '%s\n' "$out" | grep -q "could not clone broken" && [ ! -e "$ICONS_DEST/Broken-One" ] && chk ok "a failing clone is skipped with a message" || chk fail "failing clone not handled"
printf '1\n4\n\n' | just install-icon >/dev/null 2>&1   # Fake-Dark and Broken-One in one run; the broken one must not stop the other
[ -d "$ICONS_DEST/Fake-Dark" ] && [ ! -e "$ICONS_DEST/Broken-One" ] && chk ok "a failing source does not stop the other chosen sets" || chk fail "failing source blocked the run"
# list, switch and remove never clone (cache wiped, installed sets stay)
rm -rf "$T/cache/icons"; : > "$GITLOG"
PATH="$T/gitw:$PATH" just list-icons >/dev/null 2>&1
printf '1\n' | PATH="$T/gitw:$PATH" just switch-icon >/dev/null 2>&1; PATH="$T/gitw:$PATH" just switch-icon Fake-Dark >/dev/null 2>&1
printf 'q\n' | PATH="$T/gitw:$PATH" just remove-icon >/dev/null 2>&1
[ ! -e "$T/cache/icons" ] && ! grep -q . "$GITLOG" && chk ok "list, switch and remove-icon do not clone" || chk fail "list/switch/remove cloned ($(cat "$GITLOG"))"
for n in Fake-Dark Other-One Fake-Light; do just remove-icon $n >/dev/null 2>&1; done; rm -rf "$T/cache/icons"
# registry versus upstream: one warning per mismatch, install still succeeds
mkdir -p "$T/icons-src3" && (cd "$T/icons-src3" && git init -q && for n in Real-One Extra-One; do mkdir $n; printf '[Icon Theme]\nName=%s\nDirectories=\n' $n > $n/index.theme; done && git add -A && git commit -q -m init)
printf 'drift|file://%s/icons-src3|top|Real-One Ghost-One\n' "$T" > "$T/drift.conf"
out=$(ICON_SOURCES="$T/drift.conf" just install-icon Real-One 2>&1)
printf '%s\n' "$out" | grep -qF "registry says Ghost-One, upstream has no Ghost-One" && printf '%s\n' "$out" | grep -qF "upstream has Extra-One not in the registry" && [ -d "$ICONS_DEST/Real-One" ] && [ "$(printf '%s\n' "$out" | grep -c '^warning:')" = 2 ] && chk ok "registry mismatches: one warning line each, install carries on" || chk fail "registry mismatch warnings"
ICON_SOURCES="$T/drift.conf" just remove-icon Real-One >/dev/null 2>&1; rm -rf "$T/cache/icons"
printf 'fake|file://%s/icons-src|top|Fake-Dark Fake-Light\n' "$T" > "$T/sources.conf"
just list-icons 2>&1 | grep -q Fake-Dark && chk ok "list-icons shows the sets" || chk fail "list-icons"
just install-icon Fake-Dark >/dev/null 2>&1; [ -d "$ICONS_DEST/Fake-Dark" ] && chk ok "install-icon" || chk fail "install-icon"
m="$ICONS_DEST/Fake-Dark/.candy-for-gnome"; ia=$(sed -n 's/^installed_at=//p' "$m")
grep -qx 'schema=1' "$m" && grep -qx 'kind=icon' "$m" && grep -qx 'name=Fake-Dark' "$m" && grep -qx 'folder=Fake-Dark' "$m" && grep -q '^source=file://' "$m" && grep -Eq '^source_commit=[0-9a-f]{40}$' "$m" && grep -Eq '^installed_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$m" && grep -q '^updated_at=' "$m" && grep -q '^installer=' "$m" && chk ok "marker: an icon install writes the key=value marker (schema, kind, name, folder, source, source_commit, installed_at, updated_at, installer)" || chk fail "icon marker: $(cat "$m")"
sleep 1; just update-icon </dev/null >/dev/null 2>&1
[ "$(sed -n 's/^installed_at=//p' "$m")" = "$ia" ] && [ "$(sed -n 's/^updated_at=//p' "$m")" != "$ia" ] && chk ok "marker: update keeps installed_at and moves updated_at" || chk fail "marker update times: $(cat "$m")"
echo "Fake-Dark" > "$m"; just remove-icon Fake-Dark </dev/null >/dev/null 2>&1; [ ! -e "$ICONS_DEST/Fake-Dark" ] && chk ok "marker: a legacy one-line marker is still ours (remove-icon works)" || chk fail "legacy marker remove"
just install-icon Fake-Dark </dev/null >/dev/null 2>&1; echo "Fake-Dark" > "$m"; just update-icon </dev/null >/dev/null 2>&1
grep -qx 'schema=1' "$m" && grep -qx 'name=Fake-Dark' "$m" && chk ok "marker: a legacy marker is upgraded to key=value by the next update, the name kept" || chk fail "legacy upgrade: $(cat "$m")"
out=$(printf '\n' | just install-icon 2>&1); ! printf '%s\n' "$out" | grep -q '\[x\]' && printf '%s\n' "$out" | grep -q 'Nothing selected' && chk ok "install-icon: nothing is pre-ticked even with a set installed; Enter alone installs nothing" || chk fail "install-icon preselection: $out"
: > "$LOG"; just switch-icon Fake-Dark >/dev/null 2>&1; grep -q "icon-theme Fake-Dark" "$LOG" && chk ok "switch-icon" || chk fail "switch-icon"
(cd "$T/icons-src" && echo y > Fake-Dark/apps/b.svg && git add -A && git commit -q -m more)
just update-icon >/dev/null 2>&1; [ -f "$ICONS_DEST/Fake-Dark/apps/b.svg" ] && chk ok "update-icon picks up the new upstream commit" || chk fail "update-icon"
just install-icon Fake-Dark </dev/null >/dev/null 2>&1; rm -f "$ICONS_DEST/Fake-Dark/.candy-for-gnome"; echo Fake-Dark > "$ICONS_DEST/Fake-Dark/.gnome-themes"; echo stale > "$ICONS_DEST/Fake-Dark/stale.txt"
just update-icon </dev/null >/dev/null 2>&1; [ ! -e "$ICONS_DEST/Fake-Dark/stale.txt" ] && [ ! -e "$ICONS_DEST/Fake-Dark/.gnome-themes" ] && grep -qx 'schema=1' "$ICONS_DEST/Fake-Dark/.candy-for-gnome" && chk ok "old-name marker: update-icon replaces an old-marker icon folder and adopts it" || chk fail "update-icon did not adopt the old-marker folder"
echo Fake-Dark > "$ICONS_DEST/Fake-Dark/.gnome-themes"; rm -f "$ICONS_DEST/Fake-Dark/.candy-for-gnome"; mkdir -p "$ICONS_DEST/Stray"; echo x > "$ICONS_DEST/Stray/.gnome-themes"
out=$(just remove-icon Fake-Dark </dev/null 2>&1); [ ! -e "$ICONS_DEST/Fake-Dark" ] && [ -f "$ICONS_DEST/Stray/.gnome-themes" ] && ! printf '%s\n' "$out" | grep -qi 'refused\|Stray' && chk ok "old-name marker: remove-icon removes an old-marker icon folder and leaves an unmatched one alone" || chk fail "remove-icon old-marker: $out"; rm -rf "$ICONS_DEST/Stray"
just install-icon Fake-Dark </dev/null >/dev/null 2>&1
just remove-icon Fake-Dark >/dev/null 2>&1; [ ! -d "$ICONS_DEST/Fake-Dark" ] && chk ok "remove-icon" || chk fail "remove-icon"

# collision guard (icons): an unrelated Fake-Light is left alone, a pre-marker copy of Fake-Dark is adopted
mkdir -p "$ICONS_DEST/Fake-Light"; echo mine > "$ICONS_DEST/Fake-Light/mine.txt"
just install-icon Fake-Light </dev/null >/dev/null 2>&1; just update-icon </dev/null >/dev/null 2>&1; just remove-icon Fake-Light </dev/null >/dev/null 2>&1
[ -f "$ICONS_DEST/Fake-Light/mine.txt" ] && chk ok "icons: unrelated folder untouched by install, update and remove" || chk fail "icons: unrelated Fake-Light was touched"
FORCE=1 just install-icon Fake-Light </dev/null >/dev/null 2>&1; [ ! -e "$ICONS_DEST/Fake-Light/mine.txt" ] && [ -f "$ICONS_DEST/Fake-Light/.candy-for-gnome" ] && chk ok "icons: FORCE=1 replaces and marks" || chk fail "icons: FORCE=1"
cp -a "$T/icons-src/Fake-Dark" "$ICONS_DEST/Fake-Dark"; rm -rf "$ICONS_DEST/Fake-Dark/.git"; echo stale > "$ICONS_DEST/Fake-Dark/stale.txt"
just install-icon Fake-Dark </dev/null >/dev/null 2>&1; [ ! -e "$ICONS_DEST/Fake-Dark/stale.txt" ] && [ -f "$ICONS_DEST/Fake-Dark/.candy-for-gnome" ] && chk ok "icons: a pre-marker installation is adopted" || chk fail "icons: legacy not adopted"
just remove-icon Fake-Dark </dev/null >/dev/null 2>&1; just remove-icon Fake-Light </dev/null >/dev/null 2>&1

# root layout (Conflux): the repo root is the set; top-level @2x symlinks stay relative links, upstream scripts and docs stay out
mkdir -p "$T/icons-root" && (cd "$T/icons-root" && git init -q && mkdir -p apps images .github && printf '[Icon Theme]\nName=Rooty\nInherits=hicolor,Adwaita\nDirectories=apps\n' > index.theme \
    && echo x > apps/a.svg && echo x > images/shot.png && echo x > preview.png && echo r > README.md && echo l > LICENSE && echo c > CREDITS.md && echo c > CONTRIBUTING.md && echo g > .gitignore \
    && printf '#!/bin/sh\ntouch "$0.ran"\n' > update.sh && chmod +x update.sh && ln -s apps 'apps@2x' && git add -A && git commit -q -m init)
printf 'rooty|file://%s/icons-root|root|Rooty\n' "$T" > "$T/root.conf"
out=$(ICON_SOURCES="$T/root.conf" just install-icon Rooty 2>&1); R="$ICONS_DEST/Rooty"
[ -f "$R/index.theme" ] && [ -f "$R/apps/a.svg" ] && [ -f "$R/.candy-for-gnome" ] && ! printf '%s\n' "$out" | grep -q '^warning:' && chk ok "root layout: the repo root is installed as the set, marked, no registry warning" || chk fail "root layout install"
[ -L "$R/apps@2x" ] && [ "$(readlink "$R/apps@2x")" = apps ] && [ -f "$R/apps@2x/a.svg" ] && chk ok "root layout: top-level @2x symlinks stay relative symlinks" || chk fail "root layout: symlink lost"
[ -f "$R/LICENSE" ] && [ -f "$R/CREDITS.md" ] && [ ! -e "$R/update.sh" ] && [ ! -e "$R/images" ] && [ ! -e "$R/preview.png" ] && [ ! -e "$R/README.md" ] && [ ! -e "$R/CONTRIBUTING.md" ] && [ ! -e "$R/.gitignore" ] && [ ! -e "$R/.git" ] && [ ! -e "$R/.github" ] && [ ! -e "$T/cache/icons/rooty/update.sh.ran" ] && chk ok "root layout: LICENSE and CREDITS kept; update.sh, images, previews, docs and git files left out, update.sh never run" || chk fail "root layout: wrong file set ($(ls -A "$R" | tr '\n' ' '))"
mkdir -p "$T/icons-tp"; ICONS_DEST="$T/icons-tp"; mkdir -p "$ICONS_DEST/Rooty"; echo mine > "$ICONS_DEST/Rooty/mine.txt"
ICON_SOURCES="$T/root.conf" just install-icon Rooty </dev/null >/dev/null 2>&1; ICON_SOURCES="$T/root.conf" just remove-icon Rooty </dev/null >/dev/null 2>&1
[ -f "$ICONS_DEST/Rooty/mine.txt" ] && chk ok "root layout: a same-named third-party folder is left alone" || chk fail "root layout: third-party folder touched"
ICONS_DEST="$T/icons"; ICON_SOURCES="$T/root.conf" just remove-icon Rooty >/dev/null 2>&1; [ ! -e "$R" ] && chk ok "root layout: remove-icon removes the marked copy" || chk fail "root layout: remove"
# script-t layout (WhiteSur): a fake install.sh that takes -d DIR -n NAME -t VARIANT, builds <name><variant>{,-light,-dark} and links the
# light/dark folders to the base one; a bare variant, -t all and -a/-b/-p must never be passed
mkdir -p "$T/icons-ws" && (cd "$T/icons-ws" && git init -q && cat > install.sh <<'WSE'
#!/usr/bin/env bash
set -eo pipefail
echo "$*" >> "$(dirname "$0")/args.log"
dest=; name=WhiteSur; theme=; V=('' -purple -pink -red -orange -yellow -green -grey -nord)
while [ "$#" -gt 0 ]; do case "$1" in
    -d) dest="$2"; shift 2 ;; -n) name="$2"; shift 2 ;;
    -t) shift; case "$1" in
        default) theme="${V[0]}" ;;
        purple) theme="${V[1]}" ;;
        pink) theme="${V[2]}" ;;
        red) theme="${V[3]}" ;;
        orange) theme="${V[4]}" ;;
        yellow) theme="${V[5]}" ;;
        green) theme="${V[6]}" ;;
        grey) theme="${V[7]}" ;;
        nord) theme="${V[8]}" ;;
        *) echo "bad variant $1"; exit 1 ;; esac; shift ;;
    *) echo "ERROR: Unrecognized installation option '$1'."; exit 1 ;; esac; done
for c in '' -light -dark; do
    d="$dest/$name$theme$c"; mkdir -p "$d/apps"; printf '[Icon Theme]\nName=%s\nDirectories=apps\n' "$name$theme$c" > "$d/index.theme"
    if [ -z "$c" ]; then echo x > "$d/apps/a.svg"; else ln -s "../../$name$theme/apps/a.svg" "$d/apps/a.svg"; fi
done
WSE
    chmod +x install.sh && git add -A && git commit -q -m init)
V9="standard purple pink red orange yellow green grey nord"
printf 'WhiteSur|file://%s/icons-ws|script-t|%s\n' "$T" "$V9" > "$T/ws.conf"
WSD="$T/icons-wsd"; mkdir -p "$WSD"; rm -rf "$T/cache/icons/WhiteSur"
out=$(ICON_SOURCES="$T/ws.conf" ICONS_DEST="$WSD" just list-icons 2>&1)
[ "$(printf '%s\n' "$out" | grep -c 'WhiteSur')" -eq 9 ] && printf '%s\n' "$out" | grep -q 'WhiteSur-nord' && [ ! -e "$T/cache/icons/WhiteSur" ] && chk ok "script-t: list-icons shows the nine WhiteSur sets from the registry without cloning" || chk fail "script-t: list-icons ($(printf '%s' "$out" | grep -c WhiteSur))"
out=$(ICON_SOURCES="$T/ws.conf" ICONS_DEST="$WSD" just install-icon WhiteSur 2>&1)
WA="$T/cache/icons/WhiteSur/args.log"
[ -d "$WSD/WhiteSur" ] && [ -d "$WSD/WhiteSur-dark" ] && [ -d "$WSD/WhiteSur-light" ] && [ ! -e "$WSD/WhiteSur-purple" ] && [ -f "$WSD/WhiteSur-dark/.candy-for-gnome" ] && chk ok "script-t: the standard set is the three folders, marked, and no other variant" || chk fail "script-t: standard install ($out)"
[ -f "$WSD/WhiteSur-dark/apps/a.svg" ] && [ -L "$WSD/WhiteSur-dark/apps/a.svg" ] && chk ok "script-t: the dark and light folders keep their relative links to the base folder" || chk fail "script-t: links lost"
grep -Eq -- '^-d /.* -n WhiteSur -t default$' "$WA" && ! grep -Eq -- ' -t all| -a| -b| -p' "$WA" && chk ok "script-t: standard runs -t default with -n WhiteSur in a temp dir, never -t all, -a, -b or -p" || chk fail "script-t: arguments ($(cat "$WA" 2>/dev/null))"
ICON_SOURCES="$T/ws.conf" ICONS_DEST="$WSD" just install-icon WhiteSur-nord >/dev/null 2>&1
n=0; for f in WhiteSur WhiteSur-dark WhiteSur-light WhiteSur-nord WhiteSur-nord-dark WhiteSur-nord-light; do [ -d "$WSD/$f" ] && n=$((n+1)); done
tail -1 "$WA" | grep -Eq -- ' -n WhiteSur -t nord$' && [ "$n" -eq 6 ] && chk ok "script-t: a color variant installs next to the standard set (-t nord)" || chk fail "script-t: nord ($n)"
ICON_SOURCES="$T/ws.conf" ICONS_DEST="$WSD" just remove-icon WhiteSur >/dev/null 2>&1
[ ! -e "$WSD/WhiteSur" ] && [ ! -e "$WSD/WhiteSur-light" ] && [ -d "$WSD/WhiteSur-nord" ] && [ -d "$WSD/WhiteSur-nord-dark" ] && chk ok "script-t: remove-icon WhiteSur removes its three folders and keeps WhiteSur-nord" || chk fail "script-t: remove"
out=$(ICON_SOURCES="$T/ws.conf" ICONS_DEST="$WSD" just remove-icon WhiteSur-nord 2>&1); [ -z "$(ls -A "$WSD")" ] && ! printf '%s\n' "$out" | grep -q 'Refused' && chk ok "script-t: remove-icon WhiteSur-nord leaves nothing behind" || chk fail "script-t: leftovers ($(ls -A "$WSD"))"
mkdir -p "$WSD/WhiteSur-dark"; echo mine > "$WSD/WhiteSur-dark/mine.txt"
ICON_SOURCES="$T/ws.conf" ICONS_DEST="$WSD" just install-icon WhiteSur </dev/null >/dev/null 2>&1
[ -f "$WSD/WhiteSur-dark/mine.txt" ] && [ ! -e "$WSD/WhiteSur-dark/.candy-for-gnome" ] && chk ok "script-t: a same-named third-party folder is left alone without a terminal" || chk fail "script-t: third-party folder touched"
rm -rf "${WSD:?}"/*
# verify_source: a registry variant missing from install.sh and a missing install.sh are warned about, never fatal
printf 'WhiteSur|file://%s/icons-ws|script-t|%s teal\n' "$T" "$V9" > "$T/ws2.conf"; rm -rf "$T/cache/icons/WhiteSur"
out=$(ICON_SOURCES="$T/ws2.conf" ICONS_DEST="$WSD" just install-icon WhiteSur 2>&1)
printf '%s\n' "$out" | grep -q 'warning: WhiteSur: registry says teal, upstream has no teal' && [ -d "$WSD/WhiteSur" ] && ! printf '%s\n' "$out" | grep -q 'registry says purple' && chk ok "script-t: verify_source warns about a variant install.sh lacks, and the install still works" || chk fail "script-t: verify_source ($out)"
rm -rf "${WSD:?}"/* "$T/cache/icons/WhiteSur"
# the shipped registry declares WhiteSur with the nine colors
reg=$(grep '^WhiteSur|' tools/icon-sources.conf)
[ "$reg" = "WhiteSur|https://github.com/vinceliuice/WhiteSur-icon-theme.git|script-t|$V9" ] && chk ok "registry: the WhiteSur line (script-t, nine colors)" || chk fail "registry: WhiteSur line ($reg)"
out=$(ICON_SOURCES="$PWD/tools/icon-sources.conf" CANDY_FOR_GNOME_CACHE="$T/cache2" just list-icons 2>&1)
[ "$(printf '%s\n' "$out" | grep -c 'WhiteSur')" -eq 9 ] && [ ! -e "$T/cache2/icons" ] && chk ok "list-icons with the shipped registry shows the nine WhiteSur sets without cloning" || chk fail "list-icons lacks WhiteSur"
# the shipped registry declares Conflux as a root source and every icon command knows it without a clone
reg=$(grep '^conflux|' tools/icon-sources.conf)
[ "$reg" = "conflux|https://github.com/MoshiurRahmanAdib/Conflux-Icon-Theme.git|root|Conflux" ] && chk ok "registry: the conflux line (root layout, name Conflux)" || chk fail "registry: conflux line ($reg)"
out=$(ICON_SOURCES="$PWD/tools/icon-sources.conf" CANDY_FOR_GNOME_CACHE="$T/cache2" just list-icons 2>&1)
printf '%s\n' "$out" | grep -q 'Conflux' && [ ! -e "$T/cache2/icons" ] && chk ok "list-icons with the shipped registry shows Conflux without cloning" || chk fail "list-icons lacks Conflux"

# ---- KDE color schemes and qtct palettes  ----------------------------------------------------------------
echo "=== kde colors and qtct palettes"
KT="$T/themes-kde"; KG="$XDG_CONFIG_HOME/kdeglobals"; rm -rf "$KT" "$KDE_COLOR_SCHEMES" "$XDG_CONFIG_HOME/qt6ct" "$XDG_CONFIG_HOME/qt5ct" "$KG" "$KG.bak"
sel() { sed -n '/^\[Colors:Selection\]/,/^$/p' "$1" | sed -n 's/^BackgroundNormal=//p'; }   # the Selection background of a .colors or kdeglobals file
kdef=$(sel themes/gruvbox-material/kde/candy-for-gnome-gruvbox-material-dark.colors)
out=$(THEMES_DEST=$KT just install-theme gruvbox-material </dev/null 2>&1)
[ -f "$KDE_COLOR_SCHEMES/candy-for-gnome-gruvbox-material-dark.colors" ] && [ -f "$KDE_COLOR_SCHEMES/candy-for-gnome-gruvbox-material-light.colors" ] && [ ! -e "$XDG_CONFIG_HOME/qt6ct" ] && [ ! -e "$XDG_CONFIG_HOME/qt5ct" ] && chk ok "kde: install copies both variants into color-schemes and creates no qt5ct/qt6ct directory" || chk fail "kde install ($out)"
printf '[General]\nColorScheme=noctalia\nName=noctalia\nfont=Mine,10\n\n[Colors:Window]\nBackgroundNormal=1,2,3\n' > "$KG"; cp "$KG" "$T/kg.orig"
out=$(THEMES_DEST=$KT just switch-theme gruvbox-material </dev/null 2>&1)
cmp -s "$KG" "$T/kg.orig" && printf '%s\n' "$out" | grep -q "Left .*kdeglobals alone" && chk ok "kde: a kdeglobals not written by candy-for-gnome (Noctalia) is left alone with a message and how to hand it over" || chk fail "kde foreign kdeglobals touched ($out)"
out=$(FORCE=1 THEMES_DEST=$KT just switch-theme gruvbox-material </dev/null 2>&1)
head -1 "$KG" | grep -qx '# candy-for-gnome: gruvbox-material' && cmp -s "$KG.bak" "$T/kg.orig" && grep -qx 'font=Mine,10' "$KG" && grep -qx 'ColorScheme=candy-for-gnome-gruvbox-material-dark' "$KG" && ! grep -q noctalia "$KG" && [ "$(grep -c '^\[Colors:Window\]' "$KG")" = 1 ] && [ "$(sel "$KG")" = "$kdef" ] && printf '%s\n' "$out" | grep -qF "To undo: cp $KG.bak $KG" && chk ok "kde: FORCE=1 (or y) takes the file over: backup kept, our groups and ColorScheme in, other lines kept, undo line printed" || chk fail "kde takeover ($(cat "$KG"))"
out=$(THEMES_DEST=$KT just switch-theme gruvbox-material red </dev/null 2>&1)
[ "$(sel "$KG")" != "$kdef" ] && [ "$(sel "$KG")" = "$(sel "$KDE_COLOR_SCHEMES/candy-for-gnome-gruvbox-material-dark.colors")" ] && grep -qx 'font=Mine,10' "$KG" && [ "$(grep -c '^\[Colors:Window\]' "$KG")" = 1 ] && chk ok "kde: our own kdeglobals is refreshed without a question, the chosen accent is the Selection color, other lines stay" || chk fail "kde ours merge ($(sel "$KG"))"
mkdir -p "$XDG_CONFIG_HOME/qt6ct"
THEMES_DEST=$KT just install-theme gruvbox-material </dev/null >/dev/null 2>&1
q="$XDG_CONFIG_HOME/qt6ct/colors/candy-for-gnome-gruvbox-material-dark.conf"
[ -f "$q" ] && [ ! -e "$XDG_CONFIG_HOME/qt5ct" ] && head -1 "$q" | grep -qx '# candy-for-gnome: gruvbox-material' && [ "$(grep '^active_colors=' "$q" | tr ',' '\n' | wc -l)" = 22 ] && ! grep -qi '#7daea3' "$q" && grep -qi '#ea6962' "$q" && chk ok "qtct: palettes are written only where the config directory exists, 22 colors per palette, the chosen accent applied" || chk fail "qtct ($(head -8 "$q" 2>&1))"
# a scheme folder without kde/ and qtct/ (a fixture) installs and writes nothing of the KDE kind
cp -r themes/monokai themes/zz-nokde; rm -rf themes/zz-nokde/kde themes/zz-nokde/qtct
cp "$KG" "$T/kg.before"; out=$(THEMES_DEST=$KT just switch-theme zz-nokde </dev/null 2>&1); rm -rf themes/zz-nokde
! ls "$KDE_COLOR_SCHEMES" | grep -q 'zz-nokde' && cmp -s "$KG" "$T/kg.before" && chk ok "kde: a scheme folder without kde/ installs and writes nothing (kdeglobals unchanged)" || chk fail "kde: scheme without kde/ wrote files ($out)"
THEMES_DEST=$KT just install-theme gruvbox-material </dev/null >/dev/null 2>&1; THEMES_DEST=$KT just switch-theme gruvbox-material </dev/null >/dev/null 2>&1
out=$(THEMES_DEST=$KT just remove-theme gruvbox-material </dev/null 2>&1)
[ ! -e "$KDE_COLOR_SCHEMES/candy-for-gnome-gruvbox-material-dark.colors" ] && [ ! -e "$q" ] && grep -qx 'font=Mine,10' "$KG" && ! grep -q 'Colors:Window\|ColorScheme' "$KG" && cmp -s "$KG.bak" "$T/kg.orig" && chk ok "kde: remove-theme deletes our files, strips our groups from kdeglobals (other lines and the backup stay)" || chk fail "kde remove ($(cat "$KG" 2>&1 | head -5))"
rm -rf "$KT" "$KDE_COLOR_SCHEMES" "$XDG_CONFIG_HOME/qt6ct" "$KG" "$KG.bak"

# ---- switch-theme: the checklist of targets (all rows ticked), THEMES_TARGETS, --yes ----------------------------------------------
echo "=== switch targets checklist"
if command -v script >/dev/null 2>&1; then
    ST="$T/themes-sw"; KG="$XDG_CONFIG_HOME/kdeglobals"; rm -rf "$ST" "$KDE_COLOR_SCHEMES" "$KG" "$KG.bak" "$XDG_CONFIG_HOME/qt6ct" "$XDG_CONFIG_HOME/ghostty"; mkdir -p "$XDG_CONFIG_HOME/ghostty"
    THEMES_DEST=$ST just install-theme gruvbox-material </dev/null >/dev/null 2>&1
    swp() { THEMES_SWITCH_CHOOSE=1 THEMES_DEST=$ST script -qec "tools/themectl.sh themes switch gruvbox-material $2" /dev/null < <(printf "$1") 2>&1 | tr '\r' '\n'; }   # swp KEYS ARGS: the screen text of a pty run
    : > "$LOG"; out=$(swp '\n' blue)
    printf '%s\n' "$out" | grep -q "Apply gruvbox-material to" && ! printf '%s\n' "$out" | grep -q "skipped:" && printf '%s\n' "$out" | grep -q "GTK theme is now" && [ "$(grep -c gtk-theme "$LOG")" -ge 1 ] && head -1 "$KG" | grep -qx '# candy-for-gnome: gruvbox-material' && [ -L "$XDG_CONFIG_HOME/ghostty/candy-for-gnome.conf" ] && chk ok "switch checklist: every row is ticked, Enter applies all of them (GTK, Shell, kdeglobals, Ghostty), no skipped line" || chk fail "all-ticked switch ($out)"
    rm -rf "$KG" "$XDG_CONFIG_HOME/qt6ct"; : > "$LOG"; out=$(swp ' \n' blue)
    printf '%s\n' "$out" | grep -q "skipped: GTK theme" && printf '%s\n' "$out" | grep -qF "THEMES_TARGETS=gtk just switch-theme gruvbox-material blue --yes" && ! printf '%s\n' "$out" | grep -q "GTK theme is now" && [ "$(grep -c gtk-theme "$LOG")" = 0 ] && printf '%s\n' "$out" | grep -q "Shell theme is now" && [ -f "$KG" ] && chk ok "one row unticked (SPACE): that target is skipped with its apply-later command, all others are applied" || chk fail "one unticked ($out)"
    rm -rf "$KG"; : > "$LOG"; out=$(swp 'q' blue)
    printf '%s\n' "$out" | grep -q "Cancelled. Nothing was applied; run just switch-theme gruvbox-material again" && [ ! -e "$KG" ] && [ "$(grep -c theme "$LOG")" = 0 ] && ! printf '%s\n' "$out" | grep -q " is now " && chk ok "Esc/q: nothing applied, exit 0, how to run it again" || chk fail "cancel ($out)"
    # no checklist: a non-terminal run, --yes in a terminal, THEMES_TARGETS
    : > "$LOG"; out=$(THEMES_SWITCH_CHOOSE=1 THEMES_DEST=$ST just switch-theme gruvbox-material blue </dev/null 2>&1)
    ! printf '%s\n' "$out" | grep -q "Apply gruvbox-material to\|skipped:" && printf '%s\n' "$out" | grep -q "GTK theme is now" && [ -f "$KG" ] && chk ok "no terminal: no checklist, everything applied as before (THEMES_SWITCH_CHOOSE=1 does not force one)" || chk fail "non-terminal path ($out)"
    rm -rf "$KG"; : > "$LOG"; out=$(THEMES_TARGETS=kde THEMES_DEST=$ST just switch-theme gruvbox-material blue </dev/null 2>&1)
    [ -f "$KG" ] && ! printf '%s\n' "$out" | grep -q "GTK theme is now" && [ "$(grep -c theme "$LOG")" = 0 ] && printf '%s\n' "$out" | grep -q "skipped: GTK theme" && chk ok "THEMES_TARGETS=kde applies only the kde row, without a question" || chk fail "THEMES_TARGETS ($out)"
    THEMES_DEST=$ST just remove-theme gruvbox-material </dev/null >/dev/null 2>&1; rm -rf "$ST" "$KDE_COLOR_SCHEMES" "$KG" "$KG.bak" "$XDG_CONFIG_HOME/ghostty"
else echo "  skip switch checklist tests (script not installed)"; fi
# generated KDE and qtct files are committed and in sync for EVERY scheme (selftest checks their content per scheme in scope; the other generators
# are covered by the regeneration above); the two generators are fast, so one pass over all schemes
for d in themes/*/; do python3 -I tools/kde-gen.py "${d%/}" >/dev/null; python3 -I tools/qtct-gen.py "${d%/}" >/dev/null; done
[ -z "$(git status --porcelain -- 'themes/*/kde' 'themes/*/qtct')" ] && chk ok "kde and qtct files of every scheme are in sync with their generators" || chk fail "kde/qtct files are stale: $(git status --porcelain -- 'themes/*/kde' 'themes/*/qtct' | head -3 | tr '\n' ' ')"

# ---- Flatpak access: grant after a y, record only what was added, undo only that ------------------------------------------------
echo "=== flatpak access"
FS="$T/themes-fp"; FI="$T/icons-fp"; fpst="$XDG_STATE_HOME/candy-for-gnome/flatpak-overrides"; rm -f "$fpst"
export FP_PATH="$T/fpbin:$PATH"
fpshow() { sort "$FLATPAK_DB" | tr '\n' ' '; }
fpall() { printf '%s\n' xdg-config/gtk-3.0:ro xdg-config/gtk-4.0:ro xdg-data/icons:ro '~/.themes:ro' xdg-config/kdeglobals:ro xdg-data/color-schemes:ro | sort | tr '\n' ' '; }   # every filesystem entry candy-for-gnome manages
fpa() { PATH="$FP_PATH" THEMES_DEST=$FS ICONS_DEST=$FI "$@"; }
: > "$FLATPAK_DB"; rm -f "$FLATPAK_DB.env"
# the theme and icon commands never change or ask anything about Flatpak; switch-theme prints one hint line while entries are missing
out=$( { fpa just install-theme fairy-floss </dev/null; fpa just update-theme </dev/null; fpa just install-icon Fake-Dark </dev/null; fpa just remove-icon Fake-Dark </dev/null; fpa just remove-theme fairy-floss </dev/null; } 2>&1)
[ ! -s "$FLATPAK_DB" ] && [ ! -e "$FLATPAK_DB.env" ] && [ ! -e "$fpst" ] && ! printf '%s\n' "$out" | grep -qiE "override|sandbox|flatpak-access|Flatpak access" && chk ok "install, update and remove (themes and icons) print and change nothing about Flatpak" || chk fail "theme commands touched or mentioned Flatpak ($out)"
fpa just install-theme fairy-floss </dev/null >/dev/null 2>&1
out=$(fpa just switch-theme fairy-floss </dev/null 2>&1)
[ ! -s "$FLATPAK_DB" ] && [ ! -e "$FLATPAK_DB.env" ] && [ ! -e "$fpst" ] && [ "$(printf '%s\n' "$out" | grep -c 'flatpak-access')" = 1 ] && printf '%s\n' "$out" | grep -qF "Flatpak apps cannot see your themes yet: run just flatpak-access" && chk ok "switch-theme without a terminal: exactly one hint line, the override untouched" || chk fail "switch hint ($out)"
# flatpak-access without a terminal: nothing changes, the exact command and its undo are printed
out=$(fpa just flatpak-access </dev/null 2>&1)
[ ! -s "$FLATPAK_DB" ] && [ ! -e "$fpst" ] && printf '%s\n' "$out" | grep -qF "flatpak override --user --filesystem=xdg-config/gtk-3.0:ro --filesystem=xdg-config/gtk-4.0:ro --filesystem=xdg-data/icons:ro --filesystem=~/.themes:ro --filesystem=xdg-config/kdeglobals:ro --filesystem=xdg-data/color-schemes:ro --env=QT_QPA_PLATFORMTHEME=kde" && printf '%s\n' "$out" | grep -qF -- "--unset-env=QT_QPA_PLATFORMTHEME" && chk ok "flatpak-access, no terminal: override untouched, exact command (KDE entries and the lowercase variable) and its undo printed" || chk fail "flatpak-access no terminal ($out)"
if command -v script >/dev/null 2>&1; then
    # a pre-existing entry; answer n, then y; a pty switch never asks
    echo "xdg-config/gtk-4.0:ro" > "$FLATPAK_DB"
    printf 'y\n' | fpa script -qec "tools/themectl.sh themes switch fairy-floss magenta" /dev/null > "$T/fp.out" 2>&1
    [ "$(fpshow)" = "xdg-config/gtk-4.0:ro " ] && ! grep -q "Apply this" "$T/fp.out" && chk ok "switch-theme in a terminal does not ask about Flatpak either" || chk fail "switch asked or changed Flatpak"
    printf 'n\n' | fpa script -qec "tools/themectl.sh flatpak access" /dev/null > "$T/fp.out" 2>&1
    [ "$(fpshow)" = "xdg-config/gtk-4.0:ro " ] && [ ! -e "$fpst" ] && grep -q "Apply this" "$T/fp.out" && chk ok "flatpak-access, answer n: nothing granted or recorded" || chk fail "flatpak n case ($(fpshow))"
    printf 'y\n' | fpa script -qec "tools/themectl.sh flatpak access" /dev/null >/dev/null 2>&1
    [ "$(fpshow)" = "$(fpall)" ] && grep -qx 'QT_QPA_PLATFORMTHEME=kde' "$FLATPAK_DB.env" && chk ok "flatpak-access, answer y: the missing entries and QT_QPA_PLATFORMTHEME=kde (lowercase) were granted" || chk fail "flatpak y grant ($(fpshow))"
    [ "$(sort "$fpst" | tr '\n' ' ')" = "$(printf '%s\n' xdg-config/gtk-3.0:ro xdg-data/icons:ro '~/.themes:ro' xdg-config/kdeglobals:ro xdg-data/color-schemes:ro env:QT_QPA_PLATFORMTHEME | sort | tr '\n' ' ')" ] && chk ok "only what flatpak-access added is recorded (the pre-existing entry is not)" || chk fail "record: $(tr '\n' ' ' < "$fpst" 2>/dev/null)"
    printf 'y\n' | fpa script -qec "tools/themectl.sh flatpak access" /dev/null > "$T/fp.out" 2>&1
    grep -q "already has everything" "$T/fp.out" && ! grep -q "Apply this" "$T/fp.out" && chk ok "second run: nothing missing, no question" || chk fail "second run asked"
    out=$(fpa just switch-theme fairy-floss </dev/null 2>&1)
    ! printf '%s\n' "$out" | grep -q "flatpak-access" && chk ok "once everything is granted switch-theme prints no hint" || chk fail "hint although granted"
    # undo: no terminal prints the commands, n keeps, y removes exactly the recorded entries
    out=$(fpa just flatpak-access-remove </dev/null 2>&1)
    printf '%s\n' "$out" | grep -qF "flatpak override --user --nofilesystem=xdg-config/gtk-3.0 --nofilesystem=xdg-data/icons --nofilesystem=~/.themes" && printf '%s\n' "$out" | grep -qF -- "--unset-env=QT_QPA_PLATFORMTHEME" && ! printf '%s\n' "$out" | grep -q "nofilesystem=xdg-config/gtk-4.0" && printf '%s\n' "$out" | grep -q "negations" && [ "$(fpshow)" = "$(fpall)" ] && [ -s "$fpst" ] && chk ok "flatpak-access-remove, no terminal: the undo for exactly the recorded entries (and what flatpak leaves behind) printed, nothing removed" || chk fail "undo no-terminal case ($out)"
    printf 'n\n' | fpa script -qec "tools/themectl.sh flatpak remove" /dev/null >/dev/null 2>&1
    [ "$(fpshow)" = "$(fpall)" ] && [ -s "$fpst" ] && chk ok "flatpak-access-remove, answer n: access and record stay" || chk fail "undo n case"
    printf 'y\n' | fpa script -qec "tools/themectl.sh flatpak remove" /dev/null >/dev/null 2>&1
    [ "$(fpshow)" = "xdg-config/gtk-4.0:ro " ] && [ ! -e "$fpst" ] && grep -qx 'QT_QPA_PLATFORMTHEME=' "$FLATPAK_DB.env" && chk ok "flatpak-access-remove, answer y: exactly the recorded entries are removed (the pre-existing one stays, the variable is unset), record cleared" || chk fail "undo y case ($(fpshow))"
    out=$(fpa just flatpak-access-remove </dev/null 2>&1); printf '%s\n' "$out" | grep -q "Nothing recorded" && chk ok "flatpak-access-remove with no record says so" || chk fail "remove without record ($out)"
    # nox case: everything already set by hand: nothing missing, nothing recorded or changed
    fpall | tr ' ' '\n' | grep -v '^$' > "$FLATPAK_DB"; echo 'QT_QPA_PLATFORMTHEME=kde' > "$FLATPAK_DB.env"; rm -f "$fpst"
    out=$(fpa just flatpak-access </dev/null 2>&1)
    printf '%s\n' "$out" | grep -q "already has everything" && [ ! -e "$fpst" ] && [ "$(fpshow)" = "$(fpall)" ] && chk ok "entries and the variable already present (set by hand): seen as done, nothing recorded or changed" || chk fail "present entries not recognized ($out)"
    # a different value (uppercase KDE forces Breeze Dark): reported, never changed
    echo 'QT_QPA_PLATFORMTHEME=KDE' > "$FLATPAK_DB.env"
    out=$(fpa just flatpak-access </dev/null 2>&1)
    printf '%s\n' "$out" | grep -q "sets QT_QPA_PLATFORMTHEME=KDE" && [ "$(cat "$FLATPAK_DB.env")" = "QT_QPA_PLATFORMTHEME=KDE" ] && chk ok "another value of the variable is reported and left alone" || chk fail "other variable value ($out)"
else echo "  skip flatpak prompt tests (script not installed)"; fi
rm -rf "$FS" "$FI" "$fpst"; : > "$FLATPAK_DB"; rm -f "$FLATPAK_DB.env"

# ---- checklist UI (pty): SPACE toggles, ENTER confirms, q cancels, preselection shown ---------------------------
echo "=== checklist (pty)"
cat > "$T/ptyrun.py" <<'PY'
import os, pty, select, sys, time, fcntl, termios, struct, re
keys = {'down': b'\x1b[B', 'up': b'\x1b[A', 'space': b' ', 'enter': b'\r', 'esc': b'\x1b', 'slash': b'/', 'bs': b'\x7f'}
seq = sys.argv[1].split(','); cmd = sys.argv[2:]
pid, fd = pty.fork()
if pid == 0: os.execvp(cmd[0], cmd)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 50, 140, 0, 0))
out = b''; i = 0; last = time.time(); t0 = last
while time.time() - t0 < 30:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try: d = os.read(fd, 8192)
        except OSError: break
        if not d: break
        out += d; last = time.time()
    elif i < len(seq) and time.time() - last > 0.3:
        os.write(fd, keys.get(seq[i], seq[i].encode())); i += 1; last = time.time()
    elif i >= len(seq) and time.time() - last > 5: break
# never wait forever for a child that is still reading the terminal: give it a moment, then kill it
import signal
try:
    done, _ = os.waitpid(pid, os.WNOHANG)
    if not done:
        time.sleep(1.0); done, _ = os.waitpid(pid, os.WNOHANG)
    if not done:
        os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
except ChildProcessError: pass
sys.stdout.write(re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', out.decode(errors='replace')))
PY
pty() { python3 -I "$T/ptyrun.py" "$@"; }
n_inst() { ls -d "$1"/*/ 2>/dev/null | wc -l; }
PD="$T/pty-themes"; mkdir -p "$PD"
out=$(THEMES_DEST=$PD pty q tools/themectl.sh themes install)
echo "$out" | grep -q '\[ \]' && ! echo "$out" | grep -q '\[x\]' && chk ok "themes checklist starts with every box off" || chk fail "themes checklist has a preselected box"
echo "$out" | grep -q 'SPACE toggles' && chk ok "checklist hint says SPACE toggles" || chk fail "checklist hint"
[ "$(n_inst "$PD")" -eq 0 ] && echo "$out" | grep -q Cancelled && chk ok "q cancels, nothing installed" || chk fail "q did not cancel"
THEMES_DEST=$PD pty n,down,space,enter tools/themectl.sh themes install >/dev/null
first_sc=$(sed -n 's/^FEATURED_THEMES="${FEATURED_THEMES-\(.*\)}"$/\1/p' tools/themectl.sh | awk '{print $2}'); gname=$(awk -F'"' '/^gtk_name/ {print $2}' "themes/$first_sc/palette.toml")
[ -d "$PD/$gname" ] && chk ok "none, down, SPACE ticks one entry, ENTER installs it ($first_sc)" || chk fail "space did not tick the second entry"
PF="$T/pty-filter"; mkdir -p "$PF"
THEMES_DEST=$PF pty slash,D,R,A,C,enter,space,enter tools/themectl.sh themes install >/dev/null
[ -d "$PF/Dracula" ] && [ -z "$(find "$PF" -mindepth 1 -maxdepth 1 -not -name 'Dracula*')" ] && chk ok "checklist filter: / then DRAC (any case) narrows the list, SPACE ticks the shown entry, only dracula installed" || chk fail "filter install: $(ls "$PF" | tr '\n' ' ')"
rm -rf "$PF"; mkdir -p "$PF"
THEMES_DEST=$PF pty space,slash,d,r,a,c,enter,space,slash,esc,enter tools/themectl.sh themes install >/dev/null
[ -d "$PF/Dracula" ] && [ -d "$PF/Nordic-Nord" ] && chk ok "filter: a tick made before filtering survives it, and Esc shows the full list again" || chk fail "filter keeps ticks: $(ls "$PF" | tr '\n' ' ')"
out=$(THEMES_DEST=$PF pty slash,z,z,z,q tools/themectl.sh themes install); echo "$out" | grep -q 'filter: zzz' && chk ok "a filter without a match shows an empty list" || chk fail "no-match filter"
PD2="$T/pty-themes2"; mkdir -p "$PD2"; out=$(THEMES_DEST=$PD2 pty enter tools/themectl.sh themes install)
[ "$(n_inst "$PD2")" -eq 0 ] && echo "$out" | grep -q 'Nothing selected' && chk ok "ENTER alone (empty selection) installs nothing and says so" || chk fail "enter alone installed $(n_inst "$PD2")"
THEMES_DEST=$PD2 tools/themectl.sh themes install "$first_sc" >/dev/null 2>&1
[ "$(n_inst "$PD2")" -ge 1 ] && chk ok "a named scheme installs without the checklist" || chk fail "named install failed"
out=$(THEMES_DEST=$PD pty down,enter tools/themectl.sh themes switch "$first_sc")
echo "$out" | grep -q 'current' && chk ok "accent submenu marks the current accent" || chk fail "accent submenu: no (current) mark"
grep -q "^$first_sc=" "$XDG_STATE_HOME/candy-for-gnome/accents" && chk ok "accent chosen in the submenu is remembered" || chk fail "accent not remembered"

# ---- switch menu after install-theme / install-icon (terminal only; stub gum) --------------------------------------------------------------
echo "=== switch after install"
AP="$T/after-themes"; mkdir -p "$AP"; THEMES_DEST=$AP just install-theme dracula >/dev/null 2>&1
gumpty() { THEMES_SWITCH_AFTER_INSTALL=1 THEMES_PICKER=gum PATH="$SB:$PATH" pty enter "$@"; }
rm -f "$STUB_LOG"; : > "$LOG"; out=$(GUM_STUB_PICK='^(★ )?nordic  ' THEMES_DEST=$AP gumpty tools/themectl.sh themes install nordic)
firsts=$(grep -E '^(★ )?[a-z-]+  \(GTK' "$STUB_LOG" | head -2 | tr '\n' '|')
case "$firsts" in "★ nordic  "*"|★ dracula  "*) chk ok "install-theme NAME on a terminal opens the switch menu: installed themes only, the just-installed one first" ;; *) chk fail "after-install list: $firsts" ;; esac
grep -q "gtk-theme Nordic-Nord" "$LOG" && chk ok "choosing in that menu runs the switch path (GTK theme set)" || chk fail "after-install switch: $(tr '\n' ';' < "$LOG")"
! grep -q '^──' "$STUB_LOG" && grep -q 'Switch to which theme now' "$STUB_LOG" && chk ok "the menu has no divider rows and a clear title" || chk fail "after-install menu content"
rm -f "$STUB_LOG"; out=$(GUM_STUB_EXIT=130 THEMES_DEST=$AP gumpty tools/themectl.sh themes install nordic)
printf '%s' "$out" | tr -d '\r' | grep -q "To switch later: just switch-theme nordic" && chk ok "Esc in the menu skips switching and prints how to switch later" || chk fail "after-install cancel: $(printf '%s' "$out" | tail -3)"
rm -f "$STUB_LOG"; GUM_STUB_PICK='nordic' THEMES_DEST=$AP THEMES_PICKER=gum PATH="$SB:$PATH" THEMES_SWITCH_AFTER_INSTALL=1 tools/themectl.sh themes install nordic </dev/null >/dev/null 2>&1
[ ! -e "$STUB_LOG" ] && chk ok "no terminal: no switch menu" || chk fail "menu opened without a terminal"
rm -f "$STUB_LOG"; GUM_STUB_PICK='nordic' THEMES_DEST=$AP THEMES_PICKER=gum PATH="$SB:$PATH" THEMES_SWITCH_AFTER_INSTALL=0 pty enter tools/themectl.sh themes install nordic >/dev/null
[ ! -e "$STUB_LOG" ] && chk ok "THEMES_SWITCH_AFTER_INSTALL=0 turns the menu off" || chk fail "env switch ignored"
out=$(GUM_STUB_EXIT=130 THEMES_DEST=$AP gumpty tools/themectl.sh themes install | tr -d '\r')
printf '%s' "$out" | grep -q "Nothing selected" && ! printf '%s' "$out" | grep -q "Switch to which" && chk ok "nothing selected or installed: no switch menu" || chk fail "menu after an empty install"
IP="$T/after-icons"; mkdir -p "$IP"; rm -rf "$T/cache/icons"; ICONS_DEST=$IP just install-icon Fake-Dark >/dev/null 2>&1
rm -f "$STUB_LOG"; : > "$LOG"; GUM_STUB_PICK='^Fake-Light  ' ICONS_DEST=$IP gumpty tools/themectl.sh icons install Fake-Light >/dev/null
firsts=$(grep -E '^[A-Za-z-]+  \(' "$STUB_LOG" | head -2 | sed 's/  (.*//' | tr '\n' '|')
[ "$firsts" = "Fake-Light|Fake-Dark|" ] && grep -q "icon-theme Fake-Light" "$LOG" && chk ok "install-icon NAME on a terminal opens the switch-icon menu (just-installed first) and the choice runs the switch path" || chk fail "icon after-install: $firsts / $(tr '\n' ';' < "$LOG")"
rm -f "$STUB_LOG"; out=$(GUM_STUB_EXIT=130 ICONS_DEST=$IP gumpty tools/themectl.sh icons install Fake-Light | tr -d '\r')
printf '%s' "$out" | grep -q "To switch later: just switch-icon Fake-Light" && chk ok "icons: Esc skips and prints just switch-icon NAME" || chk fail "icon cancel: $(printf '%s' "$out" | tail -3)"
rm -rf "$AP" "$IP"

# ---- marker metadata (themes) ---------------------------------------------------------------------------------------------------------------
echo "=== marker metadata"
app_reset; aps just install-theme gruvbox-material </dev/null >/dev/null 2>&1
gf=""; for d in "$APD"/*/; do d=${d%/}; case "$d" in *Shell*) ;; *) [ -n "$gf" ] || gf=${d##*/} ;; esac; done; mm="$APD/$gf/.candy-for-gnome"
grep -qx 'schema=1' "$mm" && grep -qx 'kind=theme' "$mm" && grep -qx 'name=gruvbox-material' "$mm" && grep -qx "folder=$gf" "$mm" && grep -Eq '^source_commit=[0-9a-f]{40}$' "$mm" && grep -q '^installed_at=' "$mm" && grep -q '^source=' "$mm" && chk ok "marker: a theme install writes the key=value marker (name = the scheme)" || chk fail "theme marker: $(cat "$mm")"
ia=$(sed -n 's/^installed_at=//p' "$mm"); sleep 1; aps just install-theme gruvbox-material </dev/null >/dev/null 2>&1
[ "$(sed -n 's/^installed_at=//p' "$mm")" = "$ia" ] && [ "$(sed -n 's/^updated_at=//p' "$mm")" != "$ia" ] && chk ok "marker: installing again keeps installed_at and moves updated_at" || chk fail "theme marker times"
echo gruvbox-material > "$mm"; aps just update-theme </dev/null >/dev/null 2>&1; grep -qx 'name=gruvbox-material' "$mm" && grep -qx 'schema=1' "$mm" && chk ok "marker: a legacy one-line theme marker is upgraded by update-theme" || chk fail "theme legacy upgrade: $(cat "$mm")"
echo gruvbox-material > "$mm"; aps just remove-theme gruvbox-material </dev/null >/dev/null 2>&1; [ ! -e "$APD/$gf" ] && chk ok "marker: remove-theme works on a legacy marker" || chk fail "theme legacy remove"
aps just install-theme gruvbox-material </dev/null >/dev/null 2>&1; aps just remove-theme gruvbox-material </dev/null >/dev/null 2>&1; [ ! -e "$APD/$gf" ] && chk ok "marker: remove-theme works on the new format" || chk fail "theme new remove"

# ---- missing config files are created with only the theme lines; existing ones are never edited without a yes -----------------------------------
echo "=== created configs"
app_reset; rm -f "$CFGA/alacritty/alacritty.toml" "$CFGA/helix/config.toml" "$CFGA/yazi/theme.toml" "$CFGA/bat/config" "$CFGA/zellij/config.kdl"; mkdir -p "$CFGA/ghostty"
aps just install-theme gruvbox-material </dev/null >/dev/null 2>&1
out=$(aps just switch-theme gruvbox-material blue </dev/null 2>&1)
body() { grep -v '^[#/]' "$1"; }
[ "$(body "$CFGA/alacritty/alacritty.toml")" = "$(printf '[general]\nimport = [ "%s" ]' "$CFGA/alacritty/themes/candy-for-gnome.toml")" ] && chk ok "created: alacritty.toml holds only the import" || chk fail "created alacritty: $(cat "$CFGA/alacritty/alacritty.toml" 2>&1)"
[ "$(body "$CFGA/helix/config.toml")" = 'theme = "candy-for-gnome"' ] && chk ok "created: Helix config.toml holds only the theme line" || chk fail "created helix"
[ "$(body "$CFGA/yazi/theme.toml")" = "$(printf '[flavor]\ndark = "candy-for-gnome-dark"\nlight = "candy-for-gnome-light"')" ] && chk ok "created: Yazi theme.toml holds only the [flavor] table" || chk fail "created yazi"
[ "$(body "$CFGA/bat/config")" = "$(printf -- '--theme="auto:system"\n--theme-dark="candy-for-gnome-dark"\n--theme-light="candy-for-gnome-light"')" ] && chk ok "created: bat config holds only the three theme lines" || chk fail "created bat"
[ "$(body "$CFGA/zellij/config.kdl")" = "$(printf 'theme_dark "candy-for-gnome-dark"\ntheme_light "candy-for-gnome-light"')" ] && chk ok "created: zellij config.kdl holds only theme_dark and theme_light" || chk fail "created zellij"
[ "$(body "$CFGA/ghostty/config.ghostty")" = 'config-file = ?candy-for-gnome.conf' ] && chk ok "created: Ghostty config.ghostty holds only the include line" || chk fail "created ghostty"
head -1 "$CFGA/helix/config.toml" | grep -q 'created by candy-for-gnome' && printf '%s\n' "$out" | grep -q "Created .*config.toml" && chk ok "created: a header comment names candy-for-gnome and one line per file says it was created" || chk fail "created header/message"
snap=$(cat "$CFGA"/alacritty/alacritty.toml "$CFGA"/helix/config.toml "$CFGA"/yazi/theme.toml "$CFGA"/bat/config "$CFGA"/zellij/config.kdl "$CFGA"/ghostty/config.ghostty | sha1sum)
out=$(aps just switch-theme gruvbox-material blue </dev/null 2>&1)
[ "$(cat "$CFGA"/alacritty/alacritty.toml "$CFGA"/helix/config.toml "$CFGA"/yazi/theme.toml "$CFGA"/bat/config "$CFGA"/zellij/config.kdl "$CFGA"/ghostty/config.ghostty | sha1sum)" = "$snap" ] && ! printf '%s\n' "$out" | grep -q "Created " && chk ok "created: a second run changes nothing and creates nothing" || chk fail "created configs not idempotent"
aps just switch-theme Adwaita </dev/null >/dev/null 2>&1; [ "$(cat "$CFGA"/alacritty/alacritty.toml "$CFGA"/helix/config.toml "$CFGA"/yazi/theme.toml "$CFGA"/bat/config "$CFGA"/zellij/config.kdl "$CFGA"/ghostty/config.ghostty | sha1sum)" = "$snap" ] && [ -L "$CFGA/helix/themes/candy-for-gnome.toml" ] && readlink "$CFGA/helix/themes/candy-for-gnome.toml" | grep -q adwaita && chk ok "created: the Adwaita revert still works with the created files (links retargeted, files untouched)" || chk fail "adwaita with created configs"
app_reset; aps just install-theme gruvbox-material </dev/null >/dev/null 2>&1; cfg_snapshot > "$T/cc.before"; aps just switch-theme gruvbox-material blue </dev/null >/dev/null 2>&1; cfg_snapshot > "$T/cc.after"
cmp -s "$T/cc.before" "$T/cc.after" && chk ok "existing configs are not edited without a yes (no terminal: the lines are only printed)" || chk fail "existing config changed"

# ---- Adwaita (GNOME default): switch-theme Adwaita / switch-icon Adwaita --------------------------------------------------------------------
echo "=== adwaita"
links_of() { find "$CFGA" -type l -printf '%p -> %l\n' | sort; }
app_reset; aps just install-theme gruvbox-material </dev/null >/dev/null 2>&1
: > "$LOG"; : > "$DCONF_DB"; printf '%s\t%s\n' /org/gnome/Ptyxis/profile-uuids "['aaa', 'bbb']" /org/gnome/Ptyxis/default-profile-uuid "'aaa'" /org/gnome/Ptyxis/Profiles/aaa/palette "'x'" /org/gnome/Ptyxis/Profiles/bbb/label "'y'" >> "$DCONF_DB"
printf '%s\n' '{"name": "mine"}' > "$T/adw-note"
aps just switch-theme gruvbox-material blue </dev/null >/dev/null 2>&1
snap_a="$(cfg_snapshot)"; links_a="$(links_of)"
[ -n "$links_a" ] && printf '%s\n' "$links_a" | grep -q 'gruvbox-material' && [ -f "$HA/.claude/themes/candy-for-gnome.json" ] && chk ok "adwaita setup: a scheme is switched in, links and the Claude Code file exist" || chk fail "adwaita setup"
: > "$LOG"; adw_out=$(aps just switch-theme Adwaita </dev/null 2>&1); adw_rc=$?
[ "$adw_rc" -eq 0 ] && chk ok "switch-theme Adwaita succeeds without a name picker or accent question" || chk fail "adwaita rc $adw_rc: $adw_out"
grep -q "set org.gnome.desktop.interface gtk-theme Adwaita" "$LOG" && ! grep -q "color-scheme" "$LOG" && chk ok "adwaita: GTK theme set to Adwaita, the light/dark preference is not touched" || chk fail "adwaita gtk: $(tr '\n' ';' < "$LOG")"
grep -q "reset org.gnome.shell.extensions.user-theme name" "$LOG" && chk ok "adwaita: the User Themes shell theme key is reset" || chk fail "adwaita shell key"
! grep -q '^/org/gnome/Ptyxis/Profiles/aaa/palette' "$DCONF_DB" && grep -q '^/org/gnome/Ptyxis/profile-uuids' "$DCONF_DB" && chk ok "adwaita: the Ptyxis palette key of the profile is reset (other keys stay)" || chk fail "adwaita ptyxis"
[ ! -e "$CFGA/gtk-4.0/gtk.css" ] || { ! grep -q libadwaita-gen.py "$CFGA/gtk-4.0/gtk.css"; } && chk ok "adwaita: the generated libadwaita file is gone" || chk fail "adwaita libadwaita file"
[ "$(cfg_snapshot)" = "$snap_a" ] && chk ok "adwaita: no user config changed (checksums of Alacritty, Helix, Yazi, bat, zellij, eza and Claude settings)" || chk fail "adwaita changed a user config"
bad=0; while IFS= read -r l; do tgt="${l##* -> }"; lnk="${l%% -> *}"; case "$tgt" in *adwaita*) [ -e "$(dirname "$lnk")/$tgt" ] || bad=1 ;; *) bad=1 ;; esac; done < <(links_of)
[ "$bad" -eq 0 ] && [ -n "$(links_of)" ] && chk ok "adwaita: every managed link points at an existing neutral file of the repo" || { chk fail "adwaita links: $(links_of)"; }
for want in "alacritty/themes/candy-for-gnome.toml -> candy-for-gnome-adwaita-dark.toml" "helix/themes/candy-for-gnome.toml -> candy-for-gnome-adwaita-dark.toml" "yazi/flavors/candy-for-gnome-light.yazi -> candy-for-gnome-adwaita-dark.yazi" "bat/themes/candy-for-gnome-dark.tmTheme -> candy-for-gnome-adwaita-dark.tmTheme" "zellij/themes/candy-for-gnome.kdl -> candy-for-gnome-adwaita.kdl" "kitty/no-preference-theme.auto.conf -> themes/candy-for-gnome-adwaita-dark.conf"; do
    links_of | grep -qF -- "$want" && chk ok "adwaita link: $want" || { [ "${want%%/*}" = kitty ] && [ ! -d "$CFGA/kitty" ] && chk ok "adwaita link: kitty has no config here (skipped)" || chk fail "adwaita link missing: $want"; }
done
[ ! -e "$HA/.claude/themes/candy-for-gnome.json" ] && [ -f "$HA/.claude/settings.json" ] && chk ok "adwaita: the Claude Code theme file is removed (it carried our marker), settings.json stays" || chk fail "adwaita claude"
[ ! -L "$CFGA/eza/theme.yml" ] && chk ok "adwaita: eza's own regular theme.yml is not touched (no managed link there)" || chk fail "adwaita eza"
printf '%s\n' "$adw_out" | grep -q "neutral" && chk ok "adwaita: the output names the retargeted tools" || chk fail "adwaita output: $adw_out"
links_b="$(links_of)"; aps just switch-theme Adwaita </dev/null >/dev/null 2>&1; [ "$(links_of)" = "$links_b" ] && [ "$(cfg_snapshot)" = "$snap_a" ] && chk ok "adwaita: running it twice changes nothing more (idempotent)" || chk fail "adwaita not idempotent"
aps just switch-theme adwaita </dev/null >/dev/null 2>&1 && chk ok "adwaita: the name is accepted in any case" || chk fail "adwaita lower case"
aps just switch-theme gruvbox-material blue </dev/null >/dev/null 2>&1
[ "$(links_of)" = "$links_a" ] && [ "$(cfg_snapshot)" = "$snap_a" ] && [ -f "$HA/.claude/themes/candy-for-gnome.json" ] && chk ok "adwaita: switch-theme <scheme> points every link back and restores the Claude Code file (reversible)" || chk fail "adwaita not reversible: $(links_of)"
# a libadwaita file of the user's own kept as .bak comes back, an unrelated gtk.css is left alone
printf '/* mine */\n' > "$CFGA/gtk-4.0/gtk.css.bak"; aps just switch-theme gruvbox-material blue </dev/null >/dev/null 2>&1; aps just switch-theme Adwaita </dev/null >/dev/null 2>&1
grep -q "mine" "$CFGA/gtk-4.0/gtk.css" && [ -f "$CFGA/gtk-4.0/gtk.css.bak" ] && chk ok "adwaita: the user's own gtk.css (kept as .bak) is put back, the backup stays" || chk fail "adwaita gtk.css backup"
printf '/* unrelated */\n' > "$CFGA/gtk-4.0/gtk.css"; aps just switch-theme Adwaita </dev/null 2>&1 | grep -q "left alone" && grep -q unrelated "$CFGA/gtk-4.0/gtk.css" && chk ok "adwaita: a gtk.css not generated by candy-for-gnome is left alone" || chk fail "adwaita foreign gtk.css"
# without any managed link nothing is created
app_reset; aps just install-theme gruvbox-material </dev/null >/dev/null 2>&1; rm -rf "$CFGA/alacritty/themes" "$CFGA/helix/themes/candy-for-gnome*"
aps just switch-theme Adwaita </dev/null >/dev/null 2>&1; [ -z "$(links_of)" ] && [ ! -e "$CFGA/zellij/themes/candy-for-gnome-adwaita.kdl" ] && chk ok "adwaita: tools without a managed link get no new link and no neutral file" || chk fail "adwaita created files: $(links_of)"
# listing and the icon switch
aps just list-themes </dev/null 2>&1 | head -1 | grep -q "Adwaita (GNOME default)" && chk ok "list-themes: Adwaita (GNOME default) is the first row" || chk fail "list-themes first row"
out=$(just list-icons </dev/null 2>&1 | head -1); case "$out" in *"Adwaita (GNOME default)"*) chk ok "list-icons: Adwaita (GNOME default) is the first row" ;; *) chk fail "list-icons first row: $out" ;; esac
: > "$LOG"; mkdir -p "$T/adw-icons"; ICONS_DEST="$T/adw-icons" just switch-icon Adwaita </dev/null >/dev/null 2>&1
grep -q "set org.gnome.desktop.interface icon-theme Adwaita" "$LOG" && [ -z "$(ls -A "$T/adw-icons")" ] && chk ok "switch-icon Adwaita sets the icon theme and installs or removes no folder" || chk fail "switch-icon Adwaita: $(tr '\n' ';' < "$LOG")"
# the picker: Adwaita is the first entry of the switch menu (built-in picker, numbered list without a terminal)
out=$(printf "1\n" | just switch-theme 2>&1); printf '%s' "$out" | grep -q "1) Adwaita (GNOME default)" && chk ok "the switch-theme list offers Adwaita (GNOME default) first" || chk fail "switch menu: $(printf '%s' "$out" | head -4)"

# ---- grouped icon menus: family, then colour, then style (stub gum with a queue of answers) -----------------------------------------------------
echo "=== icon families"
GQ="$T/gum-queue"; GC="$T/gum-calls"; GSB="$T/gum-seq"; mkdir -p "$GSB"
cat > "$GSB/gum" <<'SH'
#!/bin/sh
# stub gum for the grouped menus: every call is appended to $GUMCALLS (CALL, then its arguments), the answer is the first line of the queue $GUMQ
# (an ERE; all item arguments that match are printed), and the line is consumed
printf 'CALL\n' >> "$GUMCALLS"; printf '%s\n' "$@" >> "$GUMCALLS"
pat=$(head -1 "$GUMQ"); sed -i 1d "$GUMQ"
[ -n "$pat" ] || exit 0
for a in "$@"; do case "$a" in -*|▸*|◉*|○*) continue ;; esac; if printf '%s' "$a" | grep -Eq "$pat"; then printf '%s\n' "$a"; fi; done
exit 0
SH
chmod +x "$GSB/gum"
printf 'solo|file:///nonexistent|root|Solo\ncol|file:///nonexistent|script|standard blue red\nmulti|file:///nonexistent|top|Multi Multi-Dark\n' > "$T/fam.conf"
FD="$T/fam-icons"
fam_reset() { rm -rf "$FD"; mkdir -p "$FD"; local f; for f in Solo Col Col-dark Col-light Col-blue Col-blue-dark Multi Multi-Dark; do mkdir -p "$FD/$f"; : > "$FD/$f/.candy-for-gnome"; done; : > "$GC"; : > "$LOG"; }
famrun() {   # famrun ANSWER... -- ARGS: queue the answers, run themectl icons ARGS with the stub gum forced
    local a; : > "$GQ"; while [ "$1" != -- ]; do printf '%s\n' "$1" >> "$GQ"; shift; done; shift
    GUMQ="$GQ" GUMCALLS="$GC" THEMES_PICKER=gum PATH="$GSB:$PATH" ICON_SOURCES="$T/fam.conf" ICONS_DEST="$FD" tools/themectl.sh icons "$@" </dev/null 2>&1
}
calls_n() { grep -c '^CALL$' "$GC"; }
fam_reset; famrun '^Col' '^blue' '^dark' -- switch >/dev/null
grep -q "icon-theme Col-blue-dark" "$LOG" && [ "$(calls_n)" -eq 3 ] && chk ok "switch-icon: family, then colour, then style picks the style folder (Col-blue-dark)" || chk fail "switch families: $(tr '\n' ';' < "$LOG") calls $(calls_n)"
c1=$(awk '/^CALL$/ {n++} n==1' "$GC" | grep -v '^CALL$' | grep -E '^(Adwaita|Solo|Col|Multi)' | sed 's/  (current)$//' | tr '\n' '|')
[ "$c1" = "Adwaita (GNOME default)|Solo|Col|Multi|" ] && chk ok "the family picker lists Adwaita (GNOME default) first, then only families with an installed set" || chk fail "family list: $c1"
c2=$(awk '/^CALL$/ {n++} n==2' "$GC" | grep -v '^CALL$' | grep -E '^(default|blue|red)' | tr '\n' '|'); c3=$(awk '/^CALL$/ {n++} n==3' "$GC" | grep -v '^CALL$' | grep -E '^(standard|dark|light)' | tr '\n' '|')
[ "$c2" = "default|blue|" ] && [ "$c3" = "standard|dark|" ] && chk ok "the colour picker lists only installed colours (default first), the style picker only installed styles" || chk fail "colour/style lists: $c2 / $c3"
! awk '/^CALL$/ {n++} n>=1' "$GC" | grep -qE '(✅|🎨|🔄|❗|🧹|❌|🟡|🔁)' && chk ok "no emoji inside the pickers" || chk fail "emoji in a picker"
fam_reset; famrun '^Solo' -- switch >/dev/null
grep -q "icon-theme Solo" "$LOG" && [ "$(calls_n)" -eq 1 ] && chk ok "a family with one installed set switches without a second menu" || chk fail "solo family: calls $(calls_n)"
fam_reset; famrun '^Multi' '^Multi-Dark' -- switch >/dev/null
grep -q "icon-theme Multi-Dark" "$LOG" && [ "$(calls_n)" -eq 2 ] && chk ok "a family of plain sets lists its installed sets as the second step" || chk fail "multi family: $(tr '\n' ';' < "$LOG") calls $(calls_n)"
fam_reset; famrun '^Adwaita' -- switch >/dev/null
grep -q "icon-theme Adwaita" "$LOG" && [ "$(calls_n)" -eq 1 ] && chk ok "Adwaita (GNOME default) in the family picker switches at once" || chk fail "adwaita in family picker"
fam_reset; : > "$GQ"; out=$(famrun -- switch Col-blue-dark); grep -q "icon-theme Col-blue-dark" "$LOG" && [ "$(calls_n)" -eq 0 ] && chk ok "switch-icon <style folder name> switches directly and skips every menu" || chk fail "direct style name: $out"
fam_reset; famrun -- switch Col-dark >/dev/null; grep -q "icon-theme Col-dark" "$LOG" && chk ok "switch-icon <set>-dark works when the three folders of a script set exist (the Tela-dark case)" || chk fail "Col-dark direct"
fam_reset; famrun -- switch Col-light >/dev/null; grep -q "icon-theme Col-light" "$LOG" && chk ok "switch-icon <set>-light works as a direct name" || chk fail "Col-light direct"
fam_reset; out=$(famrun -- switch Nosuch); printf '%s' "$out" | grep -q "is not an icon set here" && chk ok "the error says 'an icon set' (and 'a theme' for themes)" || chk fail "article: $out"
fam_reset; famrun -- switch Multi-Dark >/dev/null; grep -q "icon-theme Multi-Dark" "$LOG" && [ "$(calls_n)" -eq 0 ] && chk ok "switch-icon <set name> skips the menus" || chk fail "direct set name"
out=$(famrun -- switch Col-red); printf '%s' "$out" | grep -q "not installed" && chk ok "a colour that is not installed is refused as before" || chk fail "uninstalled colour: $out"
fam_reset; out=$(printf '2\n' | ICON_SOURCES="$T/fam.conf" ICONS_DEST="$FD" just switch-icon 2>&1)
grep -q "icon-theme Solo" "$LOG" && printf '%s' "$out" | grep -q "1) Adwaita (GNOME default)" && printf '%s' "$out" | grep -q "Col-blue" && chk ok "without a terminal the flat numbered list is unchanged (every installed set, Adwaita first)" || chk fail "numbered list: $out"
fam_reset; famrun '(Col|Multi)$' '(default|blue|red)$' 'Multi$' -- install >/dev/null; cat "$GC" > "$T/fam-install.calls"
c1=$(awk '/^CALL$/ {n++} n==1' "$GC" | grep -v '^CALL$' | grep -E '^(✓ )?(Solo|Col|Multi)$' | tr '\n' '|'); c2=$(awk '/^CALL$/ {n++} n==2' "$GC" | grep -v '^CALL$' | grep -E '^(✓ )?(default|blue|red)$' | tr '\n' '|'); c3=$(awk '/^CALL$/ {n++} n==3' "$GC" | grep -v '^CALL$' | grep -E '^(✓ )?Multi(-Dark)?$' | tr '\n' '|')
! grep -qx -- '--selected' "$GC" && [ "$c1" = "✓ Solo|✓ Col|✓ Multi|" ] && [ "$c2" = "✓ default|✓ blue|red|" ] && [ "$c3" = "✓ Multi|✓ Multi-Dark|" ] && [ "$(calls_n)" -eq 3 ] && chk ok "install-icon: families first, then the colours (no style rows) and the sets of each ticked family, installed ones marked, nothing pre-ticked" || chk fail "install lists: $c1 / $c2 / $c3 ($(calls_n))"
fam_reset; rm -rf "$FD"/Solo; famrun '^Solo$' -- install | grep -q "Skipping Solo" && [ "$(calls_n)" -eq 1 ] && chk ok "install-icon: a one-set family installs from the first step alone" || chk fail "solo install"
fam_reset; famrun '^(Col|Solo)( |$)' '^blue' -- remove >/dev/null
[ ! -e "$FD/Solo" ] && [ ! -e "$FD/Col-blue" ] && [ ! -e "$FD/Col-blue-dark" ] && [ -d "$FD/Col" ] && [ -d "$FD/Col-dark" ] && [ -d "$FD/Multi" ] && [ "$(calls_n)" -eq 2 ] && chk ok "remove-icon: families, then the installed colours of a ticked family; only the ticked ones go" || chk fail "remove grouped: $(ls "$FD" | tr '\n' ' ') calls $(calls_n)"
fam_reset; famrun -- remove Col-blue >/dev/null; [ ! -e "$FD/Col-blue" ] && [ -d "$FD/Col" ] && [ "$(calls_n)" -eq 0 ] && chk ok "remove-icon <name> skips the menus" || chk fail "direct remove"
rm -rf "$FD"

# ---- colour swatches in the pickers (truecolor terminal only; checked in a pty with the raw bytes) ----------------------------------------------
echo "=== swatches"
cat > "$T/swpty.py" <<'PY'
import os, pty, select, sys, time, fcntl, termios, struct, re, json
# swpty.py ROWS COLS KEYS(comma list of q|enter|down|x|text) ENV(json) CMD...: run in a pty, print the raw output
rows, cols = int(sys.argv[1]), int(sys.argv[2]); seq = sys.argv[3].split(','); env = dict(os.environ); env.update(json.loads(sys.argv[4])); cmd = sys.argv[5:]
keys = {'down': b'\x1b[B', 'enter': b'\r', 'q': b'q', 'x': b'x'}
for k in [k for k, v in json.loads(sys.argv[4]).items() if v is None]: env.pop(k, None)
pid, fd = pty.fork()
if pid == 0: os.execvpe(cmd[0], cmd, env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
out = b''; i = 0; last = time.time(); t0 = last
while time.time() - t0 < 25:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try: d = os.read(fd, 8192)
        except OSError: break
        if not d: break
        out += d; last = time.time()
    elif i < len(seq) and time.time() - last > 0.4: os.write(fd, keys.get(seq[i], seq[i].encode())); i += 1; last = time.time()
    elif i >= len(seq) and time.time() - last > 3: break
try: os.kill(pid, 9)
except Exception: pass
sys.stdout.buffer.write(out)
PY
swp() { python3 -I "$T/swpty.py" "$@"; }
cat > "$T/sgrrow.py" <<'PY'
import sys, re
# sgrrow.py MODE EXPECTED_CELLS...: read the raw picker output, take the LAST cursor row (it starts with ESC[7m>) and simulate its SGR state per cell.
# Each expected cell is "R,G,B" (a swatch cell: reverse off, that background); the label cells after them must have reverse on. MODE row = cursor row, plain = the last
# non-cursor row that has a swatch (must be "  " + swatch blocks + " " + label without any reverse video).
mode = sys.argv[1]; want = [tuple(int(v) for v in c.split(',')) for c in sys.argv[2:]]
raw = sys.stdin.buffer.read().decode('utf-8', 'replace')
rows = [r for r in raw.split('\n')]
tok = re.compile(r'\x1b\[([0-9;]*)m|(.)', re.S)
def cells(row):
    rev = False; bg = None; out = []
    for m in tok.finditer(row):
        if m.group(2) is not None:
            out.append((m.group(2), rev, bg)); continue
        a = [int(x) if x else 0 for x in m.group(1).split(';')]; i = 0
        while i < len(a):
            if a[i] == 0: rev = False; bg = None
            elif a[i] == 7: rev = True
            elif a[i] == 27: rev = False
            elif a[i] == 48 and a[i+1:i+2] == [2]: bg = tuple(a[i+2:i+5]); i += 4
            elif a[i] == 49: bg = None
            i += 1
    return out
cur = [r for r in rows if '\x1b[7m>' in r]
if mode == 'row':
    c = cells(cur[-1].split('\x1b[K', 1)[-1]) if cur else []
    txt = ''.join(x[0] for x in c)
    i = txt.index('>') + 1; cs = c[i:]
    while cs and cs[0][0] == ' ' and cs[0][2] is None and not cs[0][1] and False: cs.pop(0)
    # skip a checklist mark such as "[ ] " (highlighted text), then the swatch cells
    j = 0
    while j < len(cs) and cs[j][2] is None: j += 1
    sw = cs[j:j + 2 * len(want)]
    ok = len(sw) == 2 * len(want) and all((not sw[2*k][1]) and sw[2*k][2] == want[k] and (not sw[2*k+1][1]) and sw[2*k+1][2] == want[k] for k in range(len(want)))
    label = cs[j + 2 * len(want):]
    ok = ok and len(label) > 3 and all(x[1] and x[2] is None for x in label[:3])
    print('OK' if ok else 'BAD %r' % [(x[0], x[1], x[2]) for x in cs[:12]])
else:
    cand = [r for r in rows if re.search(r'\x1b\[48;2;', r) and '\x1b[7m' not in r and r.lstrip('\r\x1b[K').startswith('  ') or False]
    ok = bool(cand) and all('\x1b[7m' not in r and '\x1b[27m' not in r for r in cand[-2:])
    print('OK' if ok else 'BAD')
PY
SWD="$T/sw-themes"; mkdir -p "$SWD"
raw=$(THEMES_DEST=$SWD swp 30 80 q '{"COLORTERM":"truecolor","TERM":"xterm-256color","NO_COLOR":null,"CANDY_PLAIN":"1"}' tools/themectl.sh themes install | tr -d '\r')
printf '%s' "$raw" | grep -qF $'\e[48;2;46;52;64m  \e[0m' && printf '%s' "$raw" | grep -qF $'\e[48;2;136;192;208m  \e[0m' && chk ok "swatches: the theme list shows the scheme background and its default accent before each entry (nordic 2E3440 + 88C0D0)" || chk fail "theme swatches missing"
[ "$(printf '%s' "$raw" | python3 -I "$T/sgrrow.py" row 46,52,64 136,192,208)" = OK ] && chk ok "swatches: on the highlighted checklist row both squares of the pair (background and accent) keep their colors and the label is highlighted" || chk fail "cursor row pair: $(printf '%s' "$raw" | python3 -I "$T/sgrrow.py" row 46,52,64 136,192,208)"
raw=$(THEMES_DEST=$SWD swp 30 80 q '{"COLORTERM":null,"TERM":"xterm-256color","NO_COLOR":null,"CANDY_PLAIN":"1"}' tools/themectl.sh themes install | tr -d '\r'); ! printf '%s' "$raw" | grep -qF $'48;2;' && chk ok "swatches: no COLORTERM, no swatches" || chk fail "swatches without COLORTERM"
raw=$(THEMES_DEST=$SWD swp 30 80 q '{"COLORTERM":"truecolor","TERM":"xterm-256color","NO_COLOR":"1","CANDY_PLAIN":"1"}' tools/themectl.sh themes install | tr -d '\r'); ! printf '%s' "$raw" | grep -qF $'48;2;' && chk ok "swatches: NO_COLOR set, no swatches" || chk fail "swatches with NO_COLOR"
raw=$(COLORTERM=truecolor THEMES_DEST=$SWD tools/themectl.sh themes list </dev/null 2>&1; printf 'q\n' | COLORTERM=truecolor THEMES_DEST=$SWD tools/themectl.sh themes install 2>&1); ! printf '%s' "$raw" | grep -qF $'48;2;' && chk ok "swatches: never in list output or the numbered no-terminal fallback" || chk fail "swatches in plain output"
raw=$(THEMES_DEST=$SWD swp 12 40 q '{"COLORTERM":"truecolor","TERM":"xterm-256color","NO_COLOR":null,"CANDY_PLAIN":"1"}' tools/themectl.sh themes install | tr -d '\r' | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g'); wmax=$(printf '%s\n' "$raw" | python3 -I -c 'import sys; print(max([len(l.rstrip("\n")) for l in sys.stdin] or [0]))')
[ "$wmax" -le 40 ] && chk ok "swatches: rows are cut by visible width (no row wider than the 40-column terminal, widest $wmax)" || chk fail "swatch row too wide: $wmax"
# the accent submenu and the icon colour picker
rm -rf "$SWD"; mkdir -p "$SWD"; THEMES_DEST=$SWD tools/themectl.sh themes install nordic >/dev/null 2>&1
raw=$(THEMES_DEST=$SWD swp 30 80 q '{"COLORTERM":"truecolor","TERM":"xterm-256color","NO_COLOR":null,"CANDY_PLAIN":"1"}' tools/themectl.sh themes switch nordic | tr -d '\r')
printf '%s' "$raw" | grep -qF $'\e[48;2;191;97;106m  \e[0m' && chk ok "swatches: the accent submenu shows each accent colour (nordic red BF616A)" || chk fail "accent swatches missing"
[ "$(printf '%s' "$raw" | python3 -I "$T/sgrrow.py" row 136,192,208)" = OK ] && chk ok "swatches: on the highlighted row the swatch keeps its color (cyan 88C0D0, reverse video off at the swatch) and the label is highlighted" || chk fail "cursor row swatch: $(printf '%s' "$raw" | python3 -I "$T/sgrrow.py" row 136,192,208)"
[ "$(printf '%s' "$raw" | python3 -I "$T/sgrrow.py" plain)" = OK ] && chk ok "swatches: rows without the cursor are drawn as before (no reverse video around the swatch)" || chk fail "non-cursor row changed"
FD2="$T/sw-icons"; mkdir -p "$FD2"/{Col,Col-dark,Col-light,Col-blue,Col-blue-dark,Col-blue-light}; for d in "$FD2"/*; do : > "$d/.candy-for-gnome"; done
raw=$(ICON_SOURCES="$T/fam.conf" ICONS_DEST="$FD2" swp 30 80 down,enter,q '{"COLORTERM":"truecolor","TERM":"xterm-256color","NO_COLOR":null,"CANDY_PLAIN":"1","THEMES_PICKER":"builtin"}' tools/themectl.sh icons switch | tr -d '\r')
printf '%s' "$raw" | grep -qF $'\e[48;2;52;152;219m  \e[0m' && chk ok "swatches: the icon color picker shows the variant color (blue), the plain default only a blank" || chk fail "icon color swatches missing"
# gum: the escapes inside an item are drawn, the selection comes back WITHOUT them (as gum 2.0.2 does, checked), and the lookup still finds the entry
GSB2="$T/gum-strip"; mkdir -p "$GSB2"
cat > "$GSB2/gum" <<'SH'
#!/bin/sh
printf 'CALL\n' >> "$GUMCALLS"; printf '%s\n' "$@" >> "$GUMCALLS"
pat=$(head -1 "$GUMQ"); sed -i 1d "$GUMQ"
for a in "$@"; do case "$a" in -*|▸*|◉*|○*) continue ;; esac; if printf '%s' "$a" | grep -Eq "$pat"; then printf '%s\n' "$a" | sed 's/\x1b\[[0-9;]*m//g'; fi; done
SH
chmod +x "$GSB2/gum"
: > "$LOG"; : > "$GC"; printf '%s\n' 'Col' 'blue$' 'dark$' > "$GQ"
swp 30 80 '' '{"COLORTERM":"truecolor","TERM":"xterm-256color","NO_COLOR":null,"CANDY_PLAIN":"1","THEMES_PICKER":"gum","PATH":"'"$GSB2:$PATH"'","GUMQ":"'"$GQ"'","GUMCALLS":"'"$GC"'","ICON_SOURCES":"'"$T/fam.conf"'","ICONS_DEST":"'"$FD2"'"}' tools/themectl.sh icons switch >/dev/null 2>&1
grep -qF $'\e[48;2;52;152;219m' "$GC" && grep -q "icon-theme Col-blue-dark" "$LOG" && chk ok "swatches with gum: the item carries the escapes, the stripped selection still maps back to the entry (Col-blue-dark chosen)" || chk fail "gum swatches: $(tr '\n' ';' < "$LOG") $(grep -c 48 "$GC")"
rm -rf "$FD2" "$SWD"

# ---- message emojis (terminal only; CANDY_FORCE_EMOJI exists for this test) ------------------------------------------------------------------
echo "=== message emojis"
EMO=(✅ 🎨 🔄 ❗ 🧹 ❌ 🟡 🔁)
has_emoji() { local e; for e in "${EMO[@]}"; do case "$1" in *"$e"*) return 0 ;; esac; done; return 1; }
strip_emoji() { local e s=""; for e in "${EMO[@]}"; do s="$s|$e"; done; sed -E "s/^(${s#|}) //"; }
EM="$T/emoji-themes"
emo_run() {   # emo_run <mode> : install, switch (explicit accent), remove of nordic from a clean state; mode plain|force|<env words>
    rm -rf "$EM" "$XDG_CONFIG_HOME/gtk-4.0" "$XDG_STATE_HOME/candy-for-gnome"; mkdir -p "$XDG_CONFIG_HOME/gtk-4.0"
    env "$@" THEMES_DEST="$EM" tools/themectl.sh themes install nordic </dev/null 2>&1
    env "$@" THEMES_DEST="$EM" tools/themectl.sh themes switch nordic cyan </dev/null 2>&1
    env "$@" THEMES_DEST="$EM" tools/themectl.sh themes switch nordic nosuchaccent </dev/null 2>&1
    env "$@" THEMES_DEST="$EM" tools/themectl.sh themes remove nordic </dev/null 2>&1
}
plain_out=$(emo_run TERM=xterm-256color)          # CANDY_PLAIN=1 from the suite environment
has_emoji "$plain_out" && chk fail "captured output (CANDY_PLAIN=1) contains an emoji" || chk ok "captured output has no emoji"
cap_out=$(emo_run -u CANDY_PLAIN TERM=xterm-256color)   # captured, not a terminal, no force
has_emoji "$cap_out" && chk fail "captured output (not a terminal) contains an emoji" || chk ok "output that is not a terminal has no emoji, even without CANDY_PLAIN"
[ "$cap_out" = "$plain_out" ] && chk ok "captured output is identical with and without CANDY_PLAIN" || chk fail "captured output differs by CANDY_PLAIN"
force_out=$(emo_run -u CANDY_PLAIN CANDY_FORCE_EMOJI=1 TERM=xterm-256color)
has_emoji "$force_out" && chk ok "forced mode prints emojis" || chk fail "forced mode printed no emoji"
[ "$(printf '%s\n' "$force_out" | strip_emoji)" = "$plain_out" ] && chk ok "with the emoji prefixes removed, the forced output equals the plain output byte for byte" || { chk fail "forced output text differs from plain"; diff <(printf '%s\n' "$force_out" | strip_emoji) <(printf '%s\n' "$plain_out") | head -8; }
badn=$(printf '%s\n' "$force_out" | grep -c -E '^(✅|🎨|🔄|❗|🧹|❌|🟡|🔁) (✅|🎨|🔄|❗|🧹|❌|🟡|🔁)'); [ "$badn" -eq 0 ] && chk ok "never two emojis on one line" || chk fail "double emoji on $badn line(s)"
for want in "✅ Installed Nordic-Nord" "🎨 GTK theme is now Nordic-Nord." "🎨 Accent: cyan." "🔁 Restart GTK apps to pick up the new theme." "🧹 Removed $EM/Nordic-Nord" "❌ 'nosuchaccent' is not an accent of nordic"; do
    printf '%s\n' "$force_out" | grep -qF -- "$want" && chk ok "forced: '$want'" || chk fail "forced: missing '$want'"
done
printf '%s\n' "$force_out" | grep -E '^(✅|🎨|🔄|❗|🧹|❌|🟡|🔁) ' | grep -q 'Shell theme is now' && chk ok "forced: the Shell theme line carries 🎨" || chk fail "forced: Shell theme line"
printf '%s\n' "$force_out" | grep -E '^ ' | grep -qE '(✅|🎨|🔄|❗|🧹|❌|🟡|🔁)' && chk fail "an indented continuation line carries an emoji" || chk ok "indented and data lines carry no emoji"
off=$(emo_run -u CANDY_PLAIN CANDY_FORCE_EMOJI=1 CANDY_PLAIN=1 TERM=xterm-256color); has_emoji "$off" && chk fail "CANDY_PLAIN=1 did not switch emojis off" || chk ok "CANDY_PLAIN=1 switches emojis off (even when forced)"
off=$(emo_run -u CANDY_PLAIN CANDY_FORCE_EMOJI=1 NO_EMOJI=1 TERM=xterm-256color); has_emoji "$off" && chk fail "NO_EMOJI=1 did not switch emojis off" || chk ok "a non-empty NO_EMOJI switches emojis off"
off=$(emo_run -u CANDY_PLAIN CANDY_FORCE_EMOJI=1 NO_EMOJI= TERM=xterm-256color); has_emoji "$off" && chk ok "an empty NO_EMOJI keeps the emojis (non-empty only, as NO_COLOR)" || chk fail "an empty NO_EMOJI switched emojis off"
off=$(emo_run -u CANDY_PLAIN CANDY_FORCE_EMOJI=1 TERM=dumb); has_emoji "$off" && chk fail "TERM=dumb did not switch emojis off" || chk ok "TERM=dumb switches emojis off"
# a real pseudo-terminal: stdout is a terminal, so no force is needed; stderr lines are tested on their own stream
rm -rf "$EM" "$XDG_CONFIG_HOME/gtk-4.0"; mkdir -p "$XDG_CONFIG_HOME/gtk-4.0"
pty_out=$(env -u CANDY_PLAIN THEMES_DEST="$EM" TERM=xterm-256color script -qec "tools/themectl.sh themes install nordic" /dev/null </dev/null 2>&1 | tr -d '\r')
printf '%s\n' "$pty_out" | grep -q '^✅ Installed Nordic-Nord' && chk ok "pty: stdout on a terminal gets the emoji without any force" || chk fail "pty: no emoji on a terminal: $(printf '%s' "$pty_out" | head -3)"
pty_out=$(env -u CANDY_PLAIN THEMES_DEST="$EM" NO_EMOJI=1 TERM=xterm-256color script -qec "tools/themectl.sh themes install nordic" /dev/null </dev/null 2>&1 | tr -d '\r')
has_emoji "$pty_out" && chk fail "pty: NO_EMOJI ignored on a terminal" || chk ok "pty: NO_EMOJI keeps a terminal plain"
err_tty=$(env -u CANDY_PLAIN THEMES_DEST="$EM" TERM=xterm-256color bash -c 'tools/themectl.sh themes switch nordic nosuchaccent 2>&1 >/dev/null' </dev/null)
has_emoji "$err_tty" && chk fail "stderr that is captured got an emoji" || chk ok "stderr that is not a terminal gets no emoji"
rm -rf "$EM"

echo; echo "TOTAL: $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
