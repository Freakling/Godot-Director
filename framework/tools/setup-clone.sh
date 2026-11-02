#!/usr/bin/env bash
# Godot Director per-clone setup · framework-owned: replaced on upgrade.
#
#   bash tools/setup-clone.sh [path to Godot]              Godot path + pre-commit and pre-push hooks
#   bash tools/setup-clone.sh --skip-hook [path to Godot]  only the Godot path
#
# Run it once in every new clone or worktree; running it again is harmless.
# 1. Finds Godot 4.5+ (the given path, the saved one, $GODOT_BIN, PATH, then the usual install
#    folders) and saves it as the first line of tools/godot_bin.local (gitignored, per machine).
# 2. Installs small pre-commit and pre-push hooks in .git/hooks that run the committed .githooks/pre-commit
#    and .githooks/pre-push. Other hooks, such as Git LFS's, keep working; an existing hook of somebody else's
#    is never overwritten: one that already runs ours is left alone, and one that doesn't gets the line to
#    add printed (exit 4). The same for the hooks in a core.hooksPath folder. The hooks are installed even
#    when step 1 finds no Godot: they fail closed (a commit that needs the check is blocked until Godot is
#    found, and a prototype is never pushed).
# Exit codes: 0 = done · 3 = no suitable Godot found (the hooks are installed all the same) ·
# 4 = done, but a hook needs your attention.

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
godot=""; version=""; exit_code=0
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
  exit_code=3
else
  if [ "$(saved)" != "$godot" ]; then printf '%s\n' "$godot" > tools/godot_bin.local; fi
  echo "setup: Godot $version: $godot (saved in tools/godot_bin.local)"
fi

# --- 2. pre-commit and pre-push hooks -----------------------------------------------------------
# Installed even when no Godot was found (exit 3 above): the hooks fail closed, so a commit that needs the
# check is blocked until Godot is found, rather than going through with no hook at all. Worktrees share
# them, prototypes too.
done_with() { [ "$exit_code" -ne 0 ] && exit "$exit_code"; exit "$1"; }
# What to add to a hook that isn't ours so that it runs ours. A pre-push hook reads the pushed refs on stdin
# once, so a hook that already reads them (Git LFS's does) must pass them on from a copy.
add_for() { # <hook>
  case "$1" in
    pre-push) printf '%s' $'refs="$(cat)"; printf \'%s\\n\' "$refs" | bash .githooks/pre-push "$@" || exit 1  (then give the rest of that hook its input from $refs: printf \'%s\\n\' "$refs" | <its other commands>)' ;;
    *) printf '%s' 'bash .githooks/pre-commit || exit 1' ;;
  esac
}
[ "$skip_hook" -eq 1 ] && done_with 0
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "setup: not a git repository, so no pre-commit or pre-push hook."
  done_with 4
fi
hooks_path="$(git config --get core.hooksPath)"
if [ "${hooks_path%/}" = ".githooks" ]; then
  # Godot Director 1.x setups: .githooks/pre-commit and .githooks/pre-push already run, but other hooks (Git LFS) don't.
  echo "setup: core.hooksPath=.githooks runs the pre-commit and pre-push hooks directly. To keep other hooks such as"
  echo "       Git LFS working, run 'git config --unset core.hooksPath' yourself, then run this again."
  done_with 0
elif [ -n "$hooks_path" ]; then
  # Another hook manager's folder (husky): its pre-commit and pre-push hooks have to run ours. A relative
  # path is relative to the repository top.
  case "$hooks_path" in /*|?:*) hp_dir="$hooks_path" ;; *) hp_dir="$(git rev-parse --show-toplevel)/$hooks_path" ;; esac
  need=""
  for name in pre-commit pre-push; do
    grep -qs "[.]githooks/$name" "$hp_dir/$name" || need="$need $name"
  done
  if [ -z "$need" ]; then
    echo "setup: this clone uses core.hooksPath=$hooks_path, and its pre-commit and pre-push hooks run .githooks/pre-commit and .githooks/pre-push."
    done_with 0
  fi
  echo "setup: this clone uses core.hooksPath=$hooks_path (e.g. husky), and these hooks there don't run Godot Director's .githooks/ ones:$need"
  for name in $need; do
    echo "       Add this to $hooks_path/$name (create the file if it is missing): $(add_for "$name")"
  done
  done_with 4
fi
# Each hook is a small shim that runs the committed one, so an upgrade needs no new setup. Worktrees
# share the shims: git's hooks folder is the main clone's.
hooks_dir="$(git rev-parse --git-path hooks)"
mkdir -p "$hooks_dir"
hook_status=0
for name in pre-commit pre-push; do
  hook="$hooks_dir/$name"
  # A hook installed by 2.x, under the old name Claude4Godot, is replaced too (until 4.0). Somebody else's
  # hook that already runs the committed one (Git LFS's pre-push, chained) is left as it is.
  if [ -f "$hook" ] && ! grep -qE "Godot Director|Claude4Godot" "$hook"; then
    if grep -qs "[.]githooks/$name" "$hook"; then
      echo "setup: $hook already runs .githooks/$name; left as it is"
      continue
    fi
    echo "setup: $hook already exists and doesn't run .githooks/$name."
    echo "       Add this to it: $(add_for "$name")"
    hook_status=4
    continue
  fi
  printf '%s\n' '#!/usr/bin/env bash' \
    "# Godot Director: runs the project's committed $name hook. Installed by tools/setup-clone.sh." \
    'root="$(git rev-parse --show-toplevel)" || exit 1' \
    "[ -f \"\$root/.githooks/$name\" ] || exit 0" \
    "exec bash \"\$root/.githooks/$name\" \"\$@\"" > "$hook"
  chmod +x "$hook"
  echo "setup: $name hook installed ($hook)"
done
done_with "$hook_status"
