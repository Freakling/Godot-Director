#!/usr/bin/env bash
# Godot Director user stories · framework-owned: replaced on upgrade.
#
# Whether the user stories in design/user-stories.md are due for validation (.godot-director/procedures/design.md
# › Validate the stories). They are optional: a game keeps them only when AGENTS.md › Project rules says
# `- User stories: on`. With `off`, or no such line, this says they are off and is never due.
#   bash tools/stories.sh --due    due when the stories were never validated (Last validated: never), or after
#                                  [stories] every in tools/check.cfg (default 10) built items (commits whose subject
#                                  ends in "(T<n>)" or "(B<n>)", or that and a squash merge's " (#<pr>)") since the
#                                  commit on the file's Last validated line; by its date when that commit isn't in
#                                  this history. Not due while the file has no stories.
# Exit codes: 0 = it printed its line · 3 = couldn't run

set -u
cd "$(dirname "$0")/.." || exit 3
mode="${1:-}"
stories="design/user-stories.md"
EVERY_DEFAULT=10
tab=$'\t'

# cfg_value <section> <key>: a value from tools/check.cfg, without quotes or a trailing comment (as in tools/check.sh).
cfg_value() {
  [ -f tools/check.cfg ] || return 0
  awk -v section="[$1]" -v key="$2" '{ sub(/\r$/, "") }
    /^\[/ { inside = ($0 == section); next }
    inside && $0 ~ "^[ \t]*" key "[ \t]*=" { v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]*;.*$/, "", v)
      gsub(/"/, "", v); sub(/[ \t]+$/, "", v); print v; exit }' tools/check.cfg
}

[ "$mode" = "--due" ] || { echo "usage: bash tools/stories.sh --due"; exit 3; }

# The project rule: the first "- User stories: <on|off>" line of AGENTS.md, as its first word in lower
# case. HTML comments are cut out first, across lines too (the seed's examples of project rules sit in
# one), so a note after the value (<!-- ... -->) leaves the rule. The key may be bold (**User stories:**).
setting=""
if [ -f AGENTS.md ]; then
  setting="$(awk '{ sub(/\r$/, ""); line = $0; out = ""
    while (line != "") {
      if (incomment) {
        p = index(line, "-->"); if (!p) break
        line = substr(line, p + 3); incomment = 0
      } else {
        p = index(line, "<!--"); if (!p) { out = out line; break }
        out = out substr(line, 1, p - 1); line = substr(line, p + 4); incomment = 1
      }
    }
    l = tolower(out)
    if (l ~ /^[ \t]*[-*][ \t]+(\*\*)?user stories(\*\*)?:/) { sub(/^[^:]*:(\*\*)?[ \t]*/, "", l); sub(/[^a-z].*$/, "", l); print l; exit }
  }' AGENTS.md)"
fi
case "$setting" in
  on) ;;
  off) echo "stories: not due: user stories are off (AGENTS.md › Project rules: User stories: off)"; exit 0 ;;
  '') echo "stories: not due: user stories are off (AGENTS.md › Project rules has no User stories line)"; exit 0 ;;
  *) echo "stories: not due: user stories are off (AGENTS.md › Project rules: User stories: $setting, which isn't on or off)"; exit 0 ;;
esac

# Built items: commit subjects ending in "(T<n>)" or "(B<n>)", also with a squash merge's " (#<pr>)" after it.
ITEM_RE='\((T|B)[0-9]+\)( \(#[0-9]+\))?$'
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "stories: couldn't count: not a git repository"; exit 3; }
[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ] \
  && echo "stories: note: this is a shallow clone, so items before its oldest commit aren't counted"
every="$(cfg_value stories every)"
case "$every" in
  ''|*[!0-9]*|0) [ -n "$every" ] && echo "stories: note: [stories] every = $every isn't a whole number of 1 or more; using $EVERY_DEFAULT"
                 every="$EVERY_DEFAULT" ;;
esac
if [ ! -f "$stories" ]; then
  echo "stories: not due: no stories yet (no $stories), [stories] every = $every"
  exit 0
fi
# One pass over the file: the stories (table rows whose first cell is an ID, US-<n>; a game's own
# US-<prefix><n> IDs count too), the unconfirmed ones, whether there is a Last validated line, and its value.
info="$(awk '{ sub(/\r$/, "") }
  /^\|[ \t]*US-[A-Za-z0-9]+[ \t]*\|/ { total++; if (tolower($0) ~ /\|[ \t]*unconfirmed[ \t]*\|/) unconfirmed++ }
  !have && /\*\*Last validated:\*\*/ { v = $0; sub(/.*\*\*Last validated:\*\*[ \t]*/, "", v); sub(/[ \t]+$/, "", v); validated = v; have = 1 }
  END { printf "%d\t%d\t%d\t%s\n", total, unconfirmed, have, validated }' "$stories")"
IFS="$tab" read -r total unconfirmed have_line validated <<EOF
$info
EOF
if [ "$total" -eq 0 ]; then
  echo "stories: not due: no stories yet in $stories, [stories] every = $every"
  exit 0
fi
summary="$total stories, $unconfirmed unconfirmed"
day=""; commit=""
day_re='([0-9]{4}-[0-9]{2}-[0-9]{2})'
commit_re='`([0-9a-fA-F]{7,40})`'
[[ $validated =~ $day_re ]] && day="${BASH_REMATCH[1]}"
[[ $validated =~ $commit_re ]] && commit="${BASH_REMATCH[1]}"
if [ -n "$commit" ] && git cat-file -e "$commit^{commit}" 2>/dev/null; then
  count="$(git log --format=%s "$commit..HEAD" | grep -cE "$ITEM_RE")"
  since="the last validation (${day:-no date}, commit $commit)"
elif [ -n "$day" ]; then
  count="$(git log --format=%s --since="${day}T00:00:00" | grep -cE "$ITEM_RE")"
  if [ -n "$commit" ]; then since="the last validation ($day, by its date: its commit isn't in this history)"
  else since="the last validation ($day, by its date: the line names no commit)"; fi
else
  if [ "$have_line" -eq 0 ]; then why="$stories has no Last validated line"; else why="Last validated: ${validated:-(empty)}"; fi
  echo "stories: due: never validated ($why), $summary, [stories] every = $every"
  exit 0
fi
if [ "$count" -ge "$every" ]; then
  echo "stories: due: built items since $since: $count, [stories] every = $every; $summary"
else
  echo "stories: not due: built items since $since: $count, [stories] every = $every; $summary"
fi
exit 0
