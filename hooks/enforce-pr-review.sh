#!/usr/bin/env bash
#
# PreToolUse hook: intercepts `gh pr create` and forces Claude to run the
# pr-review-toolkit's full review command first.
#
# Why PreToolUse (not PostToolUse):
# The pr-review-toolkit's own docs say "Run early: Before creating PR, not
# after." Blocking at PreToolUse matches that philosophy — Claude sees the
# block reason, runs /pr-review-toolkit:review-pr, addresses findings, then
# re-attempts `gh pr create`.
#
# Why no state file:
# Determinism comes from the command shape. Every PR is created with some
# form of `gh pr create`, and the hook fires on every Bash tool call before
# execution. The "has the review run yet?" question is answered by a magic
# token Claude must append to the command on the second attempt:
#
#     gh pr create --title "..." --body "..."         # blocked
#     gh pr create --title "..." --body "..." # reviewed   # allowed
#
# The token is a shell comment (`# reviewed`) so it's harmless to `gh`, which
# only sees the command line up to the comment. Claude reads the block reason,
# which tells it exactly what to do: run the review, then re-issue the command
# with `# reviewed` appended.
#
# This keeps the hook completely stateless: no session marker, no Stop safety
# net, no UserPromptSubmit hook, no cross-hook coordination.

set -euo pipefail

input=$(cat)

tool_name=$(jq -r '.tool_name // ""' <<< "$input")
[[ "$tool_name" == "Bash" ]] || exit 0

command=$(jq -r '.tool_input.command // ""' <<< "$input")
[[ "$command" =~ gh[[:space:]]+pr[[:space:]]+create ]] || exit 0

# Escape hatch: Claude has run the review and is re-attempting.
#
# The token must appear as a TRAILING shell comment on the command line — i.e.
# preceded by whitespace and anchored to the end of the command string. This
# avoids false positives from the literal text "# reviewed" showing up inside
# a PR body HEREDOC, a markdown heading in --body, etc.
if [[ "$command" =~ [[:space:]]#[[:space:]]+reviewed[[:space:]]*$ ]]; then
  exit 0
fi

# Block and tell Claude exactly what to do.
jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: (
      "This `gh pr create` is blocked until the pr-review-toolkit has run on the staged changes.\n\n" +
      "Required steps (in order):\n" +
      "1. Run the full toolkit review on the current diff:\n" +
      "     /pr-review-toolkit:review-pr all\n" +
      "   This auto-dispatches every applicable specialized agent:\n" +
      "   code-reviewer, pr-test-analyzer, comment-analyzer,\n" +
      "   silent-failure-hunter, type-design-analyzer, code-simplifier.\n" +
      "2. Address every Critical issue and every Important issue the review surfaces.\n" +
      "   Re-run targeted reviews after fixes to verify (e.g. `/pr-review-toolkit:review-pr errors`).\n" +
      "3. Re-issue the SAME `gh pr create` command with the literal shell comment ` # reviewed`\n" +
      "   appended to the end of the command line. The trailing comment is how this hook\n" +
      "   knows the review has been completed.\n\n" +
      "Do not skip the review. Do not append `# reviewed` without actually running it."
    )
  }
}'

exit 0
