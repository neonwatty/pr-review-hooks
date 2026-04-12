#!/usr/bin/env bash
#
# Regression tests for hooks/enforce-pr-review.sh.
#
# Each test feeds a JSON PreToolUse payload to the hook on stdin and asserts
# the hook either allows (exit 0, no stdout) or blocks (exit 0, JSON stdout
# with permissionDecision "deny"). The hook never non-zero-exits on valid
# payloads — it signals a block via stdout JSON, following the PreToolUse
# contract. A non-zero exit is a harness-visible crash, not an allow.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hook="$here/enforce-pr-review.sh"

pass=0
fail=0
failures=()

run_case() {
  local name=$1 expect=$2 payload=$3
  local out status
  out=$("$hook" <<< "$payload" 2>&1)
  status=$?

  local got
  if (( status != 0 )); then
    got="crash"
  elif [[ -z "$out" ]]; then
    got="allow"
  elif jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<< "$out" >/dev/null 2>&1; then
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
run_case "non-Bash tool (Read)"                    allow '{"tool_name":"Read","tool_input":{"file_path":"x"}}'
# Pins the early `tool_name == Bash` gate: a non-Bash tool with a command-shaped
# input field must not trip the regex.
run_case "non-Bash tool with .command field"       allow '{"tool_name":"Write","tool_input":{"command":"gh pr create"}}'

echo
echo "Unrelated Bash commands (must allow)"
run_case "ls"                                      allow "$(json_payload 'ls -la')"
run_case "git status"                              allow "$(json_payload 'git status')"
run_case "gh pr list"                              allow "$(json_payload 'gh pr list')"
run_case "gh pr view"                              allow "$(json_payload 'gh pr view 42')"
run_case "gh help pr create"                       allow "$(json_payload 'gh help pr create')"
run_case "gh issue create"                         allow "$(json_payload 'gh issue create --title foo --body bar')"

echo
echo "Real gh pr create invocations (must block)"
run_case "direct gh pr create"                     block "$(json_payload 'gh pr create --title foo --body bar')"
run_case "gh pr create with extra whitespace"      block "$(json_payload 'gh   pr   create --title foo')"
# --help with any tail is pathological input Claude would never send; pinned
# only to document that the broad match is intentional.
run_case "gh pr create --help"                     block "$(json_payload 'gh pr create --help')"
run_case "cd subdir && gh pr create"               block "$(json_payload 'cd subdir && gh pr create --title foo')"
run_case "semicolon-chained gh pr create"          block "$(json_payload 'true; gh pr create --title foo')"
run_case "piped gh pr create"                      block "$(json_payload 'echo foo | gh pr create --title foo')"

echo
echo "Sentinel bypass (must allow)"
run_case "gh pr create with trailing sentinel"     allow "$(json_payload 'gh pr create --title foo --body bar # reviewed')"
run_case "sentinel followed by trailing spaces"    allow "$(json_payload 'gh pr create --title foo --body bar # reviewed  ')"

echo
echo "Sentinel misuse (must still block)"
run_case "sentinel mid-command, not trailing"      block "$(json_payload 'gh pr create # reviewed --title foo')"
run_case "no space before hash"                    block "$(json_payload 'gh pr create --title foo#reviewed')"
# Sentinel must be lowercase. A future "be lenient" tweak that adds case-
# insensitivity would silently open a bypass; pin the whole security model.
run_case "capitalized Reviewed"                    block "$(json_payload 'gh pr create --title foo # Reviewed')"
run_case "uppercase REVIEWED"                      block "$(json_payload 'gh pr create --title foo # REVIEWED')"
# Sentinel-looking text inside --body of a REAL invocation must still block.
# Protects the `$` end-anchor on the sentinel regex against a drive-by edit.
run_case "sentinel text inside --body literal"     block "$(json_payload $'gh pr create --title foo --body "note: # reviewed in prose"')"

echo
echo "False positives — literal phrase inside quoted argument to another command (must allow)"
# The case that bit us during dogfooding: a git commit whose message body
# quotes the blocked phrase. Before the fix, any command string containing
# `gh pr create` anywhere was blocked regardless of statement boundaries.
run_case "git commit message quoting gh pr create" allow "$(json_payload $'git commit -m "docs: explain gh pr create behavior"')"
run_case "echo with quoted phrase"                 allow "$(json_payload $'echo "gh pr create is blocked by the hook"')"
run_case "grep with literal phrase"                allow "$(json_payload $'grep -n "gh pr create" README.md')"
# This test EXERCISES the line-start case: the HEREDOC body begins a line
# with `gh pr create` directly. An earlier version of the fix had newline in
# the boundary class, which caused this exact shape to still block. The test
# is the reason newline was removed from the boundary class.
run_case "HEREDOC body with phrase at line start" allow "$(json_payload $'git commit -m "$(cat <<\'EOF\'\nDocs update\n\ngh pr create is now better documented.\nEOF\n)"')"
# Markdown-style inline-code backticks in a commit body look identical to
# shell command-substitution backticks in the raw tool_input.command string.
# The hook cannot distinguish them, so backtick is deliberately excluded from
# the boundary class — at the cost of not catching the legacy backtick-form
# command substitution `gh pr create`, which Claude never uses anyway.
run_case "markdown backticks around phrase"        allow "$(json_payload $'git commit -m "phrase \\`gh pr create\\` here"')"
# Commit/PR body describing `$(gh pr create)` in prose must not trigger.
# Open paren is NOT a boundary for this reason — see the boundary-class
# comment in hooks/enforce-pr-review.sh.
run_case 'prose mentioning $(gh pr create)'        allow "$(json_payload $'git commit -m "the $(gh pr create) form is not used"')"

echo
echo "Internal-error fail-closed (hook must emit deny instead of crashing)"
# Malformed JSON input: real jq is available but can't parse. The hook should
# detect the parse failure and emit the internal-error deny, not crash.
run_case "malformed JSON input"                    block "this is not JSON"
run_case "empty stdin"                             block ""
run_case "truncated JSON payload"                  block '{"tool_name":"Bash","tool_input":'

# Missing jq: use a shim directory prepended to PATH that contains a fake
# jq which exits non-zero. The shim is only visible to the hook's subshell;
# the harness keeps using the real jq for its own assertions.
shim_dir=$(mktemp -d)
trap 'rm -rf "$shim_dir"' EXIT
cat > "$shim_dir/jq" <<'SHIM'
#!/bin/sh
exit 1
SHIM
chmod +x "$shim_dir/jq"

run_case_broken_jq() {
  local name=$1 expect=$2 payload=$3
  local out status
  out=$(PATH="$shim_dir:$PATH" "$hook" <<< "$payload" 2>&1)
  status=$?

  local got
  if (( status != 0 )); then
    got="crash"
  elif [[ -z "$out" ]]; then
    got="allow"
  elif jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<< "$out" >/dev/null 2>&1; then
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

run_case_broken_jq "jq missing, real PR-create payload"  block "$(json_payload 'gh pr create --title foo')"
run_case_broken_jq "jq missing, unrelated Bash command"  block "$(json_payload 'ls -la')"

echo
echo "Known limitations — documented gaps where the hook does NOT block"
# These cases are intentional misses, pinned as allow-tests so any future
# tweak to the regex boundary class is a deliberate choice, not an accident.
# See the `Known limitations` comment block in hooks/enforce-pr-review.sh.
run_case "env-var prefix: FOO=bar gh pr create"    allow "$(json_payload 'GH_TOKEN=x gh pr create --title foo')"
run_case "shell keyword: if ...; then gh pr create" allow "$(json_payload 'if true; then gh pr create --title foo; fi')"
# Command-substitution form: real shell use, not a false positive. Pinned as
# an allow-test rather than a false-positive case because it IS a legitimate
# real invocation the hook could in principle want to catch — we're just
# saying the ambiguity with prose is too expensive to enforce it.
run_case "command substitution: \$(gh pr create)"  allow "$(json_payload 'cd sub && $(gh pr create --title foo)')"

echo
printf '\n%s passed, %s failed\n' "$pass" "$fail"
if (( fail > 0 )); then
  printf '\nFailing cases:\n'
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
