#!/usr/bin/env bash
# Godot Director git guard · Claude Code PreToolUse hook on Bash · framework-owned: replaced on upgrade.
#
# Permission rules match how a command starts, so `git commit -m x --no-verify` or
# `git push origin main --force` would slip past them. This hook looks at the whole command and
# blocks what .godot-director/rules.md › Git reserves for the human. It pattern-matches the text,
# so it's a strong safety net, not a guarantee. It starts no other processes (it runs on every
# Bash call).
#
# It also blocks the commands that hang or run past five minutes (an empty Python heredoc, an
# unbounded wait loop, a Godot run without `timeout`, a sleep over 280 seconds); see Hangs below.
#
# It also blocks the git flags that write a file, read a file outside the repository or run a
# configured command (--output, --no-index, --ext-diff, commit -F and --file), because the allow
# rules in settings.json let `git diff *`, `git log *`, `git show *` and `git commit *` run with
# any flag. See the section "git: flags that write a file" at the end.

IFS= read -r -d '' input || true
re='"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
[[ $input =~ $re ]] || exit 0
raw="${BASH_REMATCH[1]}"                       # still JSON-escaped: \" for "

# Hangs. A command that never returns, or that runs past five minutes, wastes the turn: the prompt
# cache expires after five minutes, so the next turn rewrites the whole context. These checks run
# for every command (Bash and Monitor), before the git checks, and skip a git commit, whose
# message may mention any of these words.
hang() {
  echo "Godot Director: blocked: $1" >&2
  exit 2
}
# has_timeout <text>: the text holds `timeout N` (N seconds, or Ns, or Nm) with N from 1 to 280.
has_timeout() {
  local t="$1" n
  while [[ $t =~ (^|[^[:alnum:]_./-])timeout[[:space:]]+([0-9]+)([sm]?)([[:space:]]|$) ]]; do
    n=$((10#${BASH_REMATCH[2]}))
    [[ ${BASH_REMATCH[3]} == m ]] && n=$((n * 60))
    ((n >= 1 && n <= 280)) && return 0
    t="${t#*"${BASH_REMATCH[0]}"}"
  done
  return 1
}
if [[ ! $raw =~ (^|[^[:alnum:]_./-])git[[:space:]]+commit ]]; then
  # (1) An empty heredoc fed to Python: `python3 - <<'EOF'` followed at once by `EOF`. Python then
  # waits for console input on Windows and never returns. In $raw a newline is the two characters \n.
  if [[ $raw == *'<<'* ]]; then
    pyre='(^|[^[:alnum:]_./-])(python3?|py)(\.exe)?[[:space:]]+-[[:space:]]*<<-?[[:space:]]*(\\"|'"'"')?([A-Za-z_][A-Za-z0-9_]*)(\\"|'"'"')?([^\\]|\\[^n])*\\n(\\t| )*'
    rest="$raw"
    while [[ $rest =~ $pyre ]]; do
      delim="${BASH_REMATCH[5]}"
      rest="${rest#*"${BASH_REMATCH[0]}"}"
      if [[ $rest =~ ^"$delim"(\\t|\ )*(\\n|$) ]]; then
        hang "Python reads an empty heredoc here, waits for console input on Windows and never returns. To test whether Python is installed, run \`python3 --version\`; to run code, put it in the heredoc body."
      fi
    done
  fi
  # (2) Loops that wait on something with sleep.
  if [[ $raw == *sleep* && $raw =~ (^|[^[:alnum:]_./-])(until|while)[[:space:]] ]]; then
    pre="${raw%%"${BASH_REMATCH[0]}"*}"
    if [[ $raw == *.output* && $raw != *'exited with code'* && $raw != *'[killed]'* ]]; then
      hang "this loop reads a background command's tasks/<id>.output without waiting for its end marker. Claude Code appends \`[exited with code N]\` or \`[killed]\` when the command ends: loop until the output contains one of them, under \`timeout 240\`, or just wait for the completion notice of a run_in_background command."
    fi
    if [[ $raw != *'exited with code'* && $raw != *'[killed]'* ]] && ! has_timeout "$pre"; then
      hang "an until or while loop with sleep needs a time limit that keeps it inside the five-minute prompt cache: \`timeout 240 bash -c 'until ...; do sleep 5; done'\`. For a background command, wait for its completion notice instead of polling."
    fi
  fi
  # (3) A direct Godot run without a time limit: a scratch script that fails to compile keeps Godot
  # running until it is killed. tools/check.sh, tools/autoplay.sh and tools/ui_capture.sh cap their
  # own runs and carry none of these flags.
  gflag='(^|[[:space:]])--(headless|script|import)([[:space:]=]|\\|$)'
  if [[ $raw =~ $gflag ]]; then
    gre='GODOT_BIN|godot_bin\.local|[Gg]odot_v[^[:space:]]*\.exe|(^|[/[:space:]\\"'"'"'])godot(\.exe)?([[:space:]\\"'"'"']|$)'
    if [[ $raw =~ $gre ]]; then
      [[ $raw =~ $gflag ]]
      pre="${raw%%"${BASH_REMATCH[0]}"*}"
      has_timeout "$pre" || hang "a direct Godot run needs a time limit of 280 seconds or less: \`timeout 120 \"\$G\" --headless --path . --script x.gd\`. A scratch script that fails to compile keeps Godot running until it is killed. \`bash tools/check.sh\`, \`bash tools/autoplay.sh\` and \`bash tools/ui_capture.sh\` cap their own runs."
    fi
  fi
  # (4) A sleep past the five-minute prompt cache.
  sre='(^|[^[:alnum:]_./-])sleep[[:space:]]+([0-9]+)([smhd]?)'
  t="$raw"
  while [[ $t =~ $sre ]]; do
    n=$((10#${BASH_REMATCH[2]}))
    case "${BASH_REMATCH[3]}" in m) n=$((n * 60)) ;; h) n=$((n * 3600)) ;; d) n=$((n * 86400)) ;; esac
    ((n > 280)) && hang "sleep $n is longer than 280 seconds. A wait past five minutes lets the prompt cache expire, so the next turn rewrites the whole context. Wait for a run_in_background completion notice, or sleep 280 or less."
    t="${t#*"${BASH_REMATCH[0]}"}"
  done
fi

[[ $raw =~ (^|[^[:alnum:]_./-])git([[:space:]]|$) ]] || exit 0

# `code` is the command with quoted strings blanked, so a commit message can't trip a flag test.
code="$raw"
dq='\\"([^\\]|\\[^"])*\\"'
while [[ $code =~ $dq ]]; do code="${code/"${BASH_REMATCH[0]}"/ Q }"; done
sq="'[^']*'"
while [[ $code =~ $sq ]]; do code="${code/"${BASH_REMATCH[0]}"/ Q }"; done

block() {
  echo "Godot Director: blocked: $1. If it's really needed, ask the human to run it." >&2
  exit 2
}
seg='[^;&|]*'   # stays within one command of a compound command line

shopt -s nocasematch   # git config keys are case-insensitive
[[ $raw =~ core\.hookspath ]] && block "changing core.hooksPath switches the pre-commit hook off"
shopt -u nocasematch
[[ $raw =~ --no-veri ]] && block "--no-verify skips the project check"
[[ $code =~ commit${seg}[[:space:]]-[a-mo-zA-Z]*n[a-zA-Z]*([[:space:]]|$) ]] && block "git commit -n skips the project check"
[[ $code =~ push${seg}[[:space:]](--force|--force-with-lease|--force-if-includes|-[a-zA-Z]*f[a-zA-Z]*)([[:space:]=]|$) ]] && block "force-push rewrites shared history"
[[ $code =~ push${seg}[[:space:]]\+[^[:space:]] ]] && block "a +refspec force-pushes"
[[ $code =~ reset${seg}[[:space:]]--ha ]] && block "git reset --hard discards uncommitted work"
[[ $code =~ clean${seg}[[:space:]](-[a-zA-Z]*f|--force) ]] && block "git clean -f deletes untracked files"
[[ $code =~ (checkout|switch)${seg}[[:space:]](-f|--force|--discard-changes)([[:space:]]|$) ]] && block "this discards uncommitted changes"
[[ $code =~ (checkout|restore)${seg}[[:space:]](--[[:space:]]+)?\.([[:space:]]|$) ]] && block "this discards every uncommitted change"
[[ $code =~ stash[[:space:]]+(drop|clear) ]] && block "this deletes stashed work"
[[ $code =~ branch${seg}[[:space:]]-D([[:space:]]|$) ]] && block "git branch -D deletes unmerged work"

# --- git: flags that write a file, read outside the repository or run a configured command --------
# settings.json allows `git diff *`, `git log *`, `git show *` and `git commit *` without a prompt,
# so every flag after them runs without one too. These turn them into a file write (--output), a
# read of any file on the machine (--no-index; a `git diff` of a path outside the repository, which
# git treats as --no-index; commit -F and --file) or the run of a configured command (--ext-diff).
# The command is read as the shell hands it to git: '--output=x', "--output"=x and --out\put=x are
# the flag, while a flag named inside a quoted message or a heredoc body is not. Variables and
# $(...) outside quotes are not expanded, so this is a text match like the rest.
nl=$'\n'; bs='\'; sq1="'"
real="${raw//\\\\/$'\x01'}"; real="${real//\\\"/\"}"; real="${real//\\n/$nl}"
real="${real//\\t/ }"; real="${real//\\r/}"; real="${real//$'\x01'/$bs}"

# Cut out the heredoc bodies (git commit -F - <<'EOF' ...). A quoted delimiter makes the body plain
# text; an unquoted one expands $(...) and backticks, so a body with those stays.
hre='(^|[^<])<<-?[[:space:]]*(\\?["'"'"']?)([A-Za-z_][A-Za-z0-9_]*)'
gtext=""; delim=""; hquote=""; body=""
while IFS= read -r line || [ -n "$line" ]; do
  if [ -n "$delim" ]; then
    if [ "${line#"${line%%[![:space:]]*}"}" = "$delim" ]; then
      delim=""
      [[ -n $hquote || ( $body != *'$('* && $body != *'`'* ) ]] || gtext+="$body"
      body=""
    else body+="$line$nl"; fi
    continue
  fi
  gtext+="$line$nl"
  [[ $line =~ $hre ]] && { delim="${BASH_REMATCH[3]}"; hquote="${BASH_REMATCH[2]}"; }
done <<<"$real"
gtext+="$body"   # a heredoc that never closes keeps its text: a false block beats a miss

# Walk the quoted strings from the left. One that is a flag by itself ('--output=x') or sits inside
# a word (--out"put"=x) is unquoted so the flag shows; any other is message text and is blanked.
# A "..." holding $(...) or backticks runs a command, so its text stays and is read again.
qre='^(([^"'$sq1'\\]|\\.)*)("(([^"\\]|\\.)*)"|'$sq1'([^'$sq1']*)'$sq1')'
glued='^[^[:space:];&|<>)]'
gcode=""; rest="$gtext"
while [[ $rest =~ $qre ]]; do
  pre="${BASH_REMATCH[1]}"; quoted="${BASH_REMATCH[3]}"; rest="${rest:${#BASH_REMATCH[0]}}"
  inner="${quoted:1:${#quoted}-2}"
  if [[ $pre == *'$' && $pre != *'\$' ]]; then   # $'...' and $"...": drop the $
    pre="${pre%?}"
    [[ $quoted == "'"* && $inner =~ \\[xuU0-7] ]] && block "ANSI-C quoting with a numeric escape (\$'\\055') can spell any flag past this check"
  fi
  pre="${pre//\\$nl/}"; pre="${pre//\\/}"        # outside quotes a backslash only escapes the next character
  gcode+="$pre"
  word="${gcode##*[[:space:];&|]}"               # the word so far
  if [[ $inner =~ ^--?[A-Za-z] ]]; then gcode+="$inner"
  elif [[ $inner != *[[:space:]]* && ( -n $word || $rest =~ $glued ) ]]; then gcode+="$inner"
  elif [[ -n $word && $word =~ ^--[^=]*$ ]]; then gcode+="$inner"
  elif [[ $quoted == '"'* && ( $inner == *'$('* || $inner == *'`'* ) ]]; then rest="$inner $rest"
  else gcode+=" Q "; fi
done
rest="${rest//\\$nl/}"; rest="${rest//\\/}"; gcode+="${rest//[\"$sq1]/}"   # a quote left over never closes
gcode="${gcode//$nl/;}"; gcode="${gcode//>&/> }"; gcode="${gcode//&>/> }"

gitre='(^|[^[:alnum:]_./-])git[[:space:]]'
gitflag() { [[ $gcode =~ $gitre($seg[[:space:]])?$1 ]]; }
gitflag '--output([[:space:]=;&|]|$)' && block "--output writes a file to any path, such as one a later command runs"
gitflag '--no-index([[:space:]=;&|]|$)' && block "--no-index reads any file on the machine"
gitflag '--ext' && block "--ext-diff runs a configured external command"

# Per command: git commit -F and --file read any file (the message may come from stdin: -F -), and a
# git diff of a path outside the repository reads it too. The subcommand is the first word after git
# that isn't an option, so `git log --grep commit -F` is not a commit.
outre='^(/|~|[A-Za-z]:|\$[A-Za-z_{])|(^|/)\.\.(/|$)'
brackets='[(){}`]'
IFS=';&|' read -r -d '' -a gsegs <<<"$gcode" || true
for gs in "${gsegs[@]}"; do
  gs="${gs//$brackets/ }"
  read -ra w <<<"$gs"
  n=${#w[@]}; k=0
  while ((k < n)) && [[ ${w[k]} != git ]]; do ((k++)); done
  ((k++))
  while ((k < n)); do
    case ${w[k]} in -C|-c) ((k += 2)) ;; -*) ((k++)) ;; *) break ;; esac
  done
  case ${w[k]:-} in
    commit)
      for ((k++; k < n; k++)); do
        a="${w[k]}"
        if [[ $a =~ ^-[aeinopqsvz]*F(.*)$ ]]; then v="${BASH_REMATCH[1]:-${w[k+1]:-}}"
        elif [[ $a =~ ^--fil(e?)(=(.*))?$ ]]; then
          if [[ -n ${BASH_REMATCH[2]} ]]; then v="${BASH_REMATCH[3]}"; else v="${w[k+1]:-}"; fi
        else continue; fi
        [[ $v == - ]] || block "git commit -F and --file read any file on the machine; give the message on stdin: git commit -F - <<'EOF'"
      done ;;
    diff)
      for ((k++; k < n; k++)); do
        [[ ${w[k]} == -* ]] && continue
        [[ ${w[k]} =~ $outre ]] && block "git diff of a path outside the repository reads any file on the machine"
      done ;;
  esac
done

exit 0
