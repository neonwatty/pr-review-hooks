# pr-review-hooks

A single PreToolUse hook for [Claude Code](https://docs.claude.com/en/docs/claude-code) that forces the
[`pr-review-toolkit`](https://github.com/anthropics/claude-code) plugin to run before Claude is allowed to
execute `gh pr create`.

The goal: make rigorous pre-PR review the path of least resistance. When Claude tries to open a PR, the hook
blocks the call and hands Claude a reason string telling it exactly what to do — run the toolkit, address
findings, then re-issue the same `gh pr create` command with a trailing sentinel.

## How it works

1. **PreToolUse hook on `Bash`.** Every `Bash` tool call is passed to `hooks/enforce-pr-review.sh` on stdin
   as a JSON payload.
2. **Filter.** The hook exits `0` (allow) for anything that isn't `gh pr create`.
3. **Block.** For a matching command, the hook emits a `permissionDecision: "deny"` JSON object with a
   detailed `permissionDecisionReason`. Claude Code shows that reason to the model as the block message, so
   Claude knows precisely what the hook expects next.
4. **Escape hatch.** If the command ends in the literal trailing shell comment ` # reviewed`, the hook
   allows it through. This is the signal from Claude that it has run `/pr-review-toolkit:review-pr` and
   addressed the findings. The sentinel is a shell comment, so `gh` ignores it entirely.

The hook is **completely stateless**: no session files, no Stop hook, no cross-invocation bookkeeping. All
of the state lives in the shape of the command being executed.

### Why a trailing shell comment?

- It's a no-op to `gh` — the shell strips comments before argv is built, so the command runs identically.
- It's visible to the hook, which sees the raw command string.
- It's anchored to the **end** of the command, so it can't collide with `# reviewed` text appearing inside a
  PR body HEREDOC or a markdown heading in `--body`.

## Install

### Option A — project-local (recommended for trying it out)

Clone this repo and use the in-repo `.claude/settings.json`, which points at
`$CLAUDE_PROJECT_DIR/hooks/enforce-pr-review.sh`. The repo dogfoods itself: the first PR you try to open on
the repo will be blocked until you run `/pr-review-toolkit:review-pr`.

```sh
git clone <this-repo>
cd pr-review-hooks
chmod +x hooks/enforce-pr-review.sh
# Open this directory in Claude Code. The project-local .claude/settings.json
# is picked up automatically.
```

### Option B — global install

Copy the script into your user hooks directory and merge the `hooks` block from the root `settings.json`
into `~/.claude/settings.json`.

```sh
mkdir -p "$HOME/.claude/hooks"
cp hooks/enforce-pr-review.sh "$HOME/.claude/hooks/"
chmod +x "$HOME/.claude/hooks/enforce-pr-review.sh"
# Then merge settings.json -> ~/.claude/settings.json by hand.
```

Option B uses the `$HOME/.claude/hooks/enforce-pr-review.sh` path baked into the root `settings.json`.
Option A uses `$CLAUDE_PROJECT_DIR/hooks/enforce-pr-review.sh` from `.claude/settings.json`.

## Requirements

- `bash`
- `jq` (used to parse the hook payload and emit the deny JSON)
- Claude Code with the `pr-review-toolkit` plugin installed (the hook's reason string references
  `/pr-review-toolkit:review-pr`)

## What Claude sees when blocked

```
This `gh pr create` is blocked until the pr-review-toolkit has run on the staged changes.

Required steps (in order):
1. Run the full toolkit review on the current diff:
     /pr-review-toolkit:review-pr all
   This auto-dispatches every applicable specialized agent:
   code-reviewer, pr-test-analyzer, comment-analyzer,
   silent-failure-hunter, type-design-analyzer, code-simplifier.
2. Address every Critical issue and every Important issue the review surfaces.
   Re-run targeted reviews after fixes to verify (e.g. `/pr-review-toolkit:review-pr errors`).
3. Re-issue the SAME `gh pr create` command with the literal shell comment ` # reviewed`
   appended to the end of the command line. The trailing comment is how this hook
   knows the review has been completed.

Do not skip the review. Do not append `# reviewed` without actually running it.
```

## Testing the hook directly

The hook reads JSON from stdin, so you can exercise it from the shell:

```sh
# allowed — unrelated command
echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
  | ./hooks/enforce-pr-review.sh

# blocked — gh pr create without the sentinel
echo '{"tool_name":"Bash","tool_input":{"command":"gh pr create --title foo --body bar"}}' \
  | ./hooks/enforce-pr-review.sh

# allowed — gh pr create with trailing sentinel
echo '{"tool_name":"Bash","tool_input":{"command":"gh pr create --title foo --body bar # reviewed"}}' \
  | ./hooks/enforce-pr-review.sh
```

## Layout

```
pr-review-hooks/
├── .claude/
│   └── settings.json          # project-local, uses $CLAUDE_PROJECT_DIR (dogfoods this repo)
├── hooks/
│   └── enforce-pr-review.sh   # the hook itself
├── settings.json              # drop-in template for global install (~/.claude/settings.json)
└── README.md
```
