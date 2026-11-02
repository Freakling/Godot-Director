#!/usr/bin/env bash
# Godot Director prototypes · framework-owned: replaced on upgrade.
#
# The git steps of .godot-director/procedures/prototype.md. A prototype is a git worktree beside the game, on
# its own proto/<name> branch, where a change is tried outside the loop; the harvest turns it into items.
#   bash tools/prototype.sh start <name>    the worktree ../<game folder>-proto-<name> on a new branch
#                                           proto/<name> from main (no upstream), the saved Godot path copied
#                                           there, tools/setup-clone.sh run there, and its PROTOTYPE.md (the
#                                           notes) written from the template and committed.
#                                           It refuses, creating nothing, unless main has the hooks and this script
#                                           committed, this clone's pre-commit and pre-push hooks (the ones in
#                                           core.hooksPath when it is set, else in .git/hooks) run the committed
#                                           .githooks/ ones, whoever wrote them, and gitleaks is on PATH: they
#                                           are a prototype's only gates. gitleaks is optional everywhere else.
#                                           When origin/main (as last fetched) is ahead of main, it stops first
#                                           and creates nothing (exit 5); --as-is starts from main as it is
#   bash tools/prototype.sh list            each proto/ branch, its worktree and its commits since main, and any of
#                                           its gate files (hooks, guard and settings, this script, setup-clone,
#                                           the gitleaks allowlist and rules) that differ from main's
#   bash tools/prototype.sh harvest <name>  what the harvest reads: the commits, the files changed since main and
#                                           the diff command, the gate files that differ from main's, the
#                                           worktree's uncommitted changes and its PROTOTYPE.md; changes nothing
#   bash tools/prototype.sh remove <name>   git worktree remove, never forced. The branch stays: it is never
#                                           merged, so deleting it (git branch -D) discards its commits, and the
#                                           human runs that
#   bash tools/prototype.sh here            whether this checkout is a prototype: a linked worktree on a proto/
#                                           branch with PROTOTYPE.md at its root (exit 0), or not (exit 1). The
#                                           pre-commit and Stop hooks skip the check only when it is
# A name is lowercase letters, digits and dashes, such as quick-add. start, harvest and remove run in the main
# session's checkout, not in a prototype. This never pushes, merges or deletes a branch.
# Exit codes: 0 = done · 1 = refused or failed (the reason is printed) · 4 = started, but setup-clone or the
# first commit needs attention (above) · 5 = origin/main is ahead of main, nothing created

set -u
cd "$(dirname "$0")/.." || exit 1
cmd="${1:-}"; name="${2:-}"; as_is="${3:-}"
nl=$'\n'

say() { echo "prototype: $*"; }
refuse() { echo "prototype: $*" >&2; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || refuse "not a git repository"

branch="$(git symbolic-ref --short -q HEAD 2>/dev/null)"

abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }
is_prototype() { # this checkout: a linked worktree, on a proto/ branch, with PROTOTYPE.md at its root
  case "$branch" in proto/*) ;; *) why="it isn't on a proto/ branch"; return 1 ;; esac
  [ -f PROTOTYPE.md ] || { why="it has no PROTOTYPE.md at its root"; return 1; }
  local gd gc
  gd="$(abs_dir "$(git rev-parse --git-dir 2>/dev/null)")"; gc="$(abs_dir "$(git rev-parse --git-common-dir 2>/dev/null)")"
  [ -n "$gd" ] && [ -n "$gc" ] && [ "$gd" != "$gc" ] || { why="it isn't a linked worktree"; return 1; }
  return 0
}
# The files that gate a prototype's commits and pushes: the hooks, the guard and settings, this script and
# setup-clone, and the gitleaks allowlist and rules. The Edit and Write guard keeps a prototype session out of
# them, so harvest and list name any that differ from main's.
gate_paths=".githooks .claude tools/prototype.sh tools/setup-clone.sh .gitleaksignore .gitleaks.toml"
gate_diffs() { # <branch> <worktree, or empty>: the gate files that differ from main's, committed or not, one per line
  {
    git diff --name-only "main...$1" -- $gate_paths 2>/dev/null
    if [ -n "$2" ] && [ -d "$2" ]; then git -C "$2" status --porcelain --ignored -- $gate_paths 2>/dev/null | sed 's/^...//'; fi
  } | awk 'NF && !seen[$0]++'
}
# What to add to a hook that isn't ours so that it runs ours. A pre-push hook reads the pushed refs on stdin
# once, so a hook that already reads them (Git LFS's does) must pass them on from a copy.
add_for() { # <hook>
  case "$1" in
    pre-push) printf '%s' $'refs="$(cat)"; printf \'%s\\n\' "$refs" | bash .githooks/pre-push "$@" || exit 1  (then give the rest of that hook its input from $refs: printf \'%s\\n\' "$refs" | <its other commands>)' ;;
    *) printf '%s' 'bash .githooks/pre-commit || exit 1' ;;
  esac
}
worktree_of() { # the folder of the worktree that has branch $1 checked out, if any
  git worktree list --porcelain | awk -v ref="refs/heads/$1" '
    /^worktree / { wt = substr($0, 10) }
    $0 == "branch " ref { print wt; exit }'
}
has_branch() { git show-ref --verify --quiet "refs/heads/$1"; }
need_main() { has_branch main || refuse "no main branch to start from or compare with"; }
need_main_session() {
  is_prototype && refuse "this checkout is the prototype ${branch#proto/}: run this in the main session"
  return 0
}
need_name() {
  case "$name" in
    ""|-*|*-|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*|list|harvest|remove|here)
      refuse "'$name' isn't a prototype name: lowercase letters, digits and dashes, such as quick-add (not list, harvest, remove or here)" ;;
  esac
}
need_prototype() {
  has_branch "proto/$name" || refuse "there is no prototype $name (no branch proto/$name); list shows the prototypes"
}
need_gates() { # a prototype's only gates are the hooks and gitleaks, so start refuses without them
  local hooks_dir hook f hp top msg="" missing=""
  for f in .githooks/pre-commit .githooks/pre-push tools/prototype.sh; do
    git cat-file -e "main:$f" 2>/dev/null || missing="$missing $f"
  done
  [ -z "$missing" ] || refuse "main has no committed$missing: commit the Godot Director upgrade on main first"
  # The hooks that run are the ones in core.hooksPath, else in this clone's hooks folder (shared by its
  # worktrees); each has to run the committed one of the same name, whoever wrote it. With core.hooksPath set
  # to .githooks, git runs the committed hooks directly.
  hp="$(git config --get core.hooksPath 2>/dev/null)"
  if [ "${hp%/}" != ".githooks" ]; then
    if [ -n "$hp" ]; then
      top="$(git rev-parse --show-toplevel 2>/dev/null)"
      case "$hp" in /*|?:*) hooks_dir="$hp" ;; *) hooks_dir="$top/$hp" ;; esac   # relative to the repository top
    else
      hooks_dir="$(git rev-parse --git-path hooks)"
    fi
    for hook in pre-commit pre-push; do
      grep -qs "[.]githooks/$hook" "$hooks_dir/$hook" && continue
      if [ -z "$hp" ] && [ ! -f "$hooks_dir/$hook" ]; then
        msg="$msg$nl  $hooks_dir/$hook is missing: run bash tools/setup-clone.sh here, which installs it"
      else
        msg="$msg$nl  $hooks_dir/$hook doesn't run .githooks/$hook: add this to it${hp:+ (create the file if it is missing)}: $(add_for "$hook")"
      fi
    done
    [ -z "$msg" ] || refuse "a prototype's commits have no gate but Godot Director's hooks and gitleaks, and the hooks that run here${hp:+ (core.hooksPath=$hp)} don't all call them:$msg"
  fi
  command -v gitleaks >/dev/null 2>&1 \
    || refuse "gitleaks isn't on PATH, and a prototype's commits have no other secrets gate (elsewhere it is optional): install it (winget install gitleaks, brew install gitleaks, or https://github.com/gitleaks/gitleaks#installing), then start again"
}

case "$cmd" in
  start)
    need_name; need_main_session; need_main
    case "$as_is" in ""|--as-is) ;; *) refuse "start takes a name and, optionally, --as-is" ;; esac
    need_gates
    # The main worktree (git lists it first): prototypes sit beside it, whichever checkout runs this.
    top="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
    top="${top:-$(pwd)}"
    path="$(dirname "$top")/$(basename "$top")-proto-$name"
    has_branch "proto/$name" && refuse "the branch proto/$name already exists: pick another name, or harvest that prototype"
    [ -e "$path" ] && refuse "the folder $path already exists: pick another name"
    behind="$(git rev-list --count main..origin/main 2>/dev/null)"
    if [ "${behind:-0}" -gt 0 ] && [ -z "$as_is" ]; then
      say "origin/main has $behind commit(s) that main doesn't (as last fetched), so nothing was created."
      say "Bring main up to date first (git pull --ff-only, on main), or start from main as it is: bash tools/prototype.sh start $name --as-is"
      exit 5
    fi
    git worktree add --no-track -b "proto/$name" "$path" main || refuse "git worktree add failed (above)"
    status=0
    # tools/godot_bin.local is gitignored, so the worktree doesn't have it: setup-clone finds Godot from the
    # path this checkout saved, where it can.
    if [ -f tools/godot_bin.local ] && [ -d "$path/tools" ]; then cp tools/godot_bin.local "$path/tools/godot_bin.local" 2>/dev/null; fi
    if [ -f "$path/tools/setup-clone.sh" ]; then
      (cd "$path" && bash tools/setup-clone.sh) || { status=4; say "setup-clone needs attention in $path (above)"; }
    else
      status=4; say "main has no tools/setup-clone.sh, so no setup ran in $path"
    fi
    cat > "$path/PROTOTYPE.md" <<EOF
# Prototype: $name

This folder is a prototype, on the branch \`proto/$name\`, started from \`main\` at \`$(git rev-parse --short main)\` on $(date +%Y-%m-%d). A session in a checkout that \`bash tools/prototype.sh here\` calls a prototype (a linked worktree on a \`proto/\` branch with this file at its root) is a prototype session: read \`.godot-director/procedures/prototype.md\` › In a prototype session before any work. It is tried outside the loop and never pushed or merged: the harvest, in the main session, turns what is worth keeping into GDD changes, decisions, user stories (in a game that uses them) and items that are built from main. Keep notes here as you go; the harvest reads them.

## What we're trying
<!-- The idea in your words, and what would make it feel right. -->

## How it felt
<!-- As you go: what worked, what didn't, what surprised you. -->

## What to keep
<!-- What the real build should take from this, and what to leave behind. -->
EOF
    if ! { git -C "$path" add PROTOTYPE.md && git -C "$path" commit -q -m "proto: start the $name prototype" -- PROTOTYPE.md; }; then
      status=4; say "couldn't commit PROTOTYPE.md in $path (above): commit it in the prototype session"
    fi
    say "started: the worktree $path on the branch proto/$name"
    exit "$status"
    ;;
  list)
    found=0
    for br in $(git for-each-ref --format='%(refname:short)' refs/heads/proto/); do
      found=1
      wt="$(worktree_of "$br")"
      n="?"; has_branch main && n="$(git rev-list --count "main..$br" 2>/dev/null)"
      echo "$br · ${wt:-no worktree} · $n commit(s) since main"
      gates="$(has_branch main && gate_diffs "$br" "$wt" | tr '\n' ' ')"
      [ -z "${gates%% }" ] || echo "  gate files that differ from main's: ${gates% }"
    done
    [ "$found" -eq 1 ] || say "no prototypes (no proto/ branches)"
    exit 0
    ;;
  harvest)
    need_name; need_main_session; need_prototype; need_main
    wt="$(worktree_of "proto/$name")"
    say "proto/$name · worktree ${wt:-none}"
    echo "--- commits since main (git log --oneline main..proto/$name)"
    git log --oneline "main..proto/$name"
    echo "--- files changed (git diff --stat main...proto/$name); read the diff with: git diff main...proto/$name"
    git diff --stat "main...proto/$name"
    gates="$(gate_diffs "proto/$name" "$wt")"
    if [ -n "$gates" ]; then
      echo "--- gate files that differ from main's: the hooks, the guard and settings, this script, setup-clone and the gitleaks allowlist and rules gate a prototype's commits and pushes, and only the human changes them. Look at them first, and take none forward unchanged"
      printf '%s\n' "$gates"
    fi
    notes=""
    if [ -n "$wt" ] && [ -d "$wt" ]; then
      dirty="$(git -C "$wt" status --porcelain)"
      if [ -n "$dirty" ]; then
        echo "--- uncommitted in the worktree, so not in the diff"
        printf '%s\n' "$dirty"
      fi
      [ -f "$wt/PROTOTYPE.md" ] && notes="$(cat "$wt/PROTOTYPE.md")"
    fi
    [ -n "$notes" ] || notes="$(git show "proto/$name:PROTOTYPE.md" 2>/dev/null)"
    echo "--- PROTOTYPE.md"
    printf '%s\n' "${notes:-(none)}"
    exit 0
    ;;
  remove)
    need_name; need_main_session; need_prototype
    wt="$(worktree_of "proto/$name")"
    if [ -n "$wt" ] && [ -d "$wt" ]; then
      git worktree remove "$wt" \
        || refuse "git worktree remove failed (above); uncommitted changes are the usual cause, or an editor, a game or a session still using the folder. $wt is left in place; never force it"
      say "removed the worktree $wt"
    elif [ -n "$wt" ]; then
      git worktree prune && say "the folder $wt was already gone; pruned git's record of it"
    else
      say "proto/$name has no worktree"
    fi
    say "the branch proto/$name stays, with its commits. A prototype is never merged, so deleting it takes git branch -D, which discards them: the human runs that, in a terminal in the game folder: git branch -D proto/$name"
    exit 0
    ;;
  here)
    if is_prototype; then say "this checkout is the prototype ${branch#proto/}"; exit 0; fi
    say "this checkout isn't a prototype: $why"
    exit 1
    ;;
  *)
    sed -n '6,32p' "$0"
    exit 1
    ;;
esac
