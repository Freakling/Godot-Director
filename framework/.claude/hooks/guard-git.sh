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
exit 0
