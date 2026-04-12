#!/usr/bin/env bash
#
# Regression tests for hooks/enforce-pr-review.sh.
#
# Each test feeds a JSON PreToolUse payload to the hook on stdin and asserts
# the hook either allows (exit 0, no stdout) or blocks (exit 0, JSON stdout
# with permissionDecision "deny"). The hook never non-zero-exits on valid
# payloads — it signals a block via stdout JSON, following the PreToolUse
# contract.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hook="$here/enforce-pr-review.sh"

pass=0
fail=0
failures=()

run_case() {
  local name=$1 expect=$2 payload=$3
  local out
  out=$("$hook" <<< "$payload" || true)

  local got
  if [[ -z "$out" ]]; then
    got="allow"
  elif grep -q '"permissionDecision": "deny"' <<< "$out"; then
    got="block"
  else
    got="unknown"
  fi

  if [[ "$got" == "$expect" ]]; then
    printf '  \033[32mPASS\033[0m  %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  \033[31mFAIL\033[0m  %s (expected %s, got %s)\n' "$name" "$expect" "$got"
    fail=$((fail + 1))
    failures+=("$name")
  fi
}

json_payload() {
  local cmd=$1
  jq -nc --arg cmd "$cmd" '{tool_name: "Bash", tool_input: {command: $cmd}}'
}

echo "Non-Bash payloads (must allow)"
run_case "non-Bash tool (Read)" allow '{"tool_name":"Read","tool_input":{"file_path":"x"}}'

echo
echo "Unrelated Bash commands (must allow)"
run_case "ls"                       allow "$(json_payload 'ls -la')"
run_case "git status"               allow "$(json_payload 'git status')"
run_case "gh pr list"               allow "$(json_payload 'gh pr list')"
run_case "gh pr view"               allow "$(json_payload 'gh pr view 42')"
run_case "gh help pr create"        allow "$(json_payload 'gh help pr create')"
run_case "gh issue create"          allow "$(json_payload 'gh issue create --title foo --body bar')"

echo
echo "Real gh pr create invocations (must block)"
run_case "direct gh pr create"                     block "$(json_payload 'gh pr create --title foo --body bar')"
run_case "gh pr create with extra whitespace"      block "$(json_payload 'gh   pr   create --title foo')"
run_case "gh pr create --help (intentional match)" block "$(json_payload 'gh pr create --help')"
run_case "cd subdir && gh pr create"               block "$(json_payload 'cd subdir && gh pr create --title foo')"
run_case "semicolon-chained gh pr create"          block "$(json_payload 'true; gh pr create --title foo')"
run_case "piped gh pr create"                      block "$(json_payload 'echo foo | gh pr create --title foo')"

echo
echo "Sentinel bypass (must allow)"
run_case "gh pr create with trailing sentinel"     allow "$(json_payload 'gh pr create --title foo --body bar # reviewed')"
run_case "gh pr create with sentinel and CRLF"     allow "$(json_payload 'gh pr create --title foo --body bar # reviewed  ')"

echo
echo "False positives — literal phrase inside quoted argument to another command (must allow)"
# This is the case that bit us during dogfooding: a git commit whose message
# body quotes the blocked phrase. Before the fix, this was blocked because the
# regex scanned the whole command string without regard for statement boundaries.
run_case "git commit message quoting gh pr create" allow "$(json_payload $'git commit -m "docs: explain gh pr create behavior"')"
run_case "echo with quoted phrase"                 allow "$(json_payload $'echo "gh pr create is blocked by the hook"')"
run_case "grep with literal phrase"                allow "$(json_payload $'grep -n "gh pr create" README.md')"
run_case "HEREDOC body containing the phrase"      allow "$(json_payload $'git commit -m "$(cat <<\'EOF\'\ndocs: note gh pr create behavior\nEOF\n)"')"
# Markdown-style inline-code backticks in a commit body look identical to
# shell command-substitution backticks in the raw tool_input.command string.
# The hook cannot distinguish them, so backtick is deliberately excluded from
# the boundary class — at the cost of not catching the legacy backtick-form
# command substitution `gh pr create`, which Claude never uses anyway.
run_case "markdown backticks around phrase"        allow "$(json_payload $'git commit -m "phrase \\`gh pr create\\` here"')"
run_case 'subshell $(gh pr create) via && chain'  block "$(json_payload 'cd sub && $(gh pr create --title foo)')"

echo
echo "Sentinel misuse (must still block — sentinel must be trailing)"
run_case "sentinel mid-command, not trailing"      block "$(json_payload 'gh pr create # reviewed --title foo')"
run_case "no space before hash"                    block "$(json_payload 'gh pr create --title foo#reviewed')"

echo
printf '\n%s passed, %s failed\n' "$pass" "$fail"
if (( fail > 0 )); then
  printf '\nFailing cases:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
