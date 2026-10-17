#!/usr/bin/env bash
# Godot Director per-clone setup · framework-owned: replaced on upgrade.
#
#   bash tools/setup-clone.sh [path to Godot]              Godot path + pre-commit hook
#   bash tools/setup-clone.sh --skip-hook [path to Godot]  only the Godot path
#
# Run it once in every new clone or worktree; running it again is harmless.
# 1. Finds Godot 4.5+ (the given path, the saved one, $GODOT_BIN, PATH, then the usual install
#    folders) and saves it as the first line of tools/godot_bin.local (gitignored, per machine).
# 2. Installs a small pre-commit hook in .git/hooks that runs the committed .githooks/pre-commit.
#    Other hooks, such as Git LFS's, keep working; an existing pre-commit is never overwritten.
# Exit codes: 0 = done · 3 = no suitable Godot found · 4 = done, but the hook needs your attention.

set -u
cd "$(dirname "$0")/.." || exit 1
skip_hook=0; given=""
for arg in "$@"; do
  case "$arg" in --skip-hook) skip_hook=1 ;; *) given="$arg" ;; esac
done

version_of() { "$1" --headless --version 2>/dev/null </dev/null | tr -d '\r' | grep -E '^[0-9]+\.[0-9]+' | tail -n 1; }
new_enough() { # new_enough <version>
  local major="${1%%.*}" rest="${1#*.}" minor
  minor="${rest%%.*}"
  case "$major$minor" in ''|*[!0-9]*) return 1 ;; esac
  [ "$major" -gt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -ge 5 ]; }
}
saved() {
  [ -f tools/godot_bin.local ] || return 0
  LC_ALL=C tr -d '\000\376\377' < tools/godot_bin.local | awk 'NR == 1 { sub(/^\357\273\277/, ""); sub(/[ \t\r]+$/, ""); print; exit }'
}
candidates() { # one path per line, most likely first
  [ -n "$given" ] && { echo "$given"; return; }
  saved
  [ -n "${GODOT_BIN:-}" ] && echo "$GODOT_BIN"
  local name dir
  for name in godot4 godot Godot; do command -v "$name" 2>/dev/null; done
  local dirs="/c/Tools $HOME/Tools $HOME/Downloads $HOME/Desktop $HOME/Applications /Applications /opt $HOME/.local/bin /usr/local/bin"
  if [ -n "${LOCALAPPDATA:-}" ] && command -v cygpath >/dev/null 2>&1; then
    dirs="$dirs $(cygpath -u "$LOCALAPPDATA")/Programs"
  fi
  local find_cmd=find sort_cmd=sort   # not Windows' find.exe / sort.exe
  [ -x /usr/bin/find ] && find_cmd=/usr/bin/find
  [ -x /usr/bin/sort ] && sort_cmd=/usr/bin/sort
  for dir in $dirs "/c/Program Files" "/c/Program Files (x86)/Steam/steamapps/common" "$HOME/scoop/apps"; do
    [ -d "$dir" ] || continue
    # Console builds first on Windows (they print to the terminal); newest names first.
    "$find_cmd" "$dir" -maxdepth 4 \( -iname 'godot*console*.exe' -o -path '*Godot*.app/Contents/MacOS/Godot' \) 2>/dev/null | "$sort_cmd" -r
    "$find_cmd" "$dir" -maxdepth 4 -type f \( \( -iname 'godot*.exe' ! -iname '*console*' \) -o -iname 'godot_v4*linux*' \) 2>/dev/null | "$sort_cmd" -r
  done
}

# --- 1. Godot -----------------------------------------------------------------------------------
godot=""; version=""
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  command -v "$candidate" >/dev/null 2>&1 || [ -x "$candidate" ] || continue
  found="$(version_of "$candidate")"
  if new_enough "$found"; then godot="$candidate"; version="$found"; break; fi
  echo "setup: skipping $candidate (version '${found:-unknown}', need 4.5 or newer)"
done <<EOF
$(candidates)
EOF
if [ -z "$godot" ]; then
  echo "setup: no Godot 4.5 or newer found. Pass its path: bash tools/setup-clone.sh \"C:/Tools/Godot/Godot_v4.x_console.exe\""
  exit 3
fi
if [ "$(saved)" != "$godot" ]; then printf '%s\n' "$godot" > tools/godot_bin.local; fi
echo "setup: Godot $version: $godot (saved in tools/godot_bin.local)"

# --- 2. pre-commit hook -------------------------------------------------------------------------
[ "$skip_hook" -eq 1 ] && exit 0
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "setup: not a git repository, so no pre-commit hook."
  exit 4
fi
hooks_path="$(git config --get core.hooksPath)"
if [ "${hooks_path%/}" = ".githooks" ]; then
  # Godot Director 1.x setups: .githooks/pre-commit already runs, but other hooks (Git LFS) don't.
  echo "setup: core.hooksPath=.githooks runs the pre-commit hook directly. To keep other hooks such as"
  echo "       Git LFS working, run 'git config --unset core.hooksPath' yourself, then run this again."
  exit 0
elif [ -n "$hooks_path" ]; then
  echo "setup: this clone uses core.hooksPath=$hooks_path (e.g. husky)."
  echo "       Add this line to its pre-commit hook: bash .githooks/pre-commit || exit 1"
  exit 4
fi
hooks_dir="$(git rev-parse --git-path hooks)"
hook="$hooks_dir/pre-commit"
# A hook installed by 2.x, under the old name Claude4Godot, is replaced too (until 4.0).
if [ -f "$hook" ] && ! grep -qE "Godot Director|Claude4Godot" "$hook"; then
  echo "setup: $hook already exists and isn't Godot Director's."
  echo "       Add this line to it: bash .githooks/pre-commit || exit 1"
  exit 4
fi
mkdir -p "$hooks_dir"
cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
# Godot Director: runs the project's committed pre-commit hook. Installed by tools/setup-clone.sh.
root="$(git rev-parse --show-toplevel)" || exit 1
[ -f "$root/.githooks/pre-commit" ] || exit 0
exec bash "$root/.githooks/pre-commit" "$@"
HOOK
chmod +x "$hook"
echo "setup: pre-commit hook installed ($hook)"
exit 0
