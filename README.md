# pr-review-hooks

A single PreToolUse hook for [Claude Code](https://docs.claude.com/en/docs/claude-code) that forces the
[`pr-review-toolkit`](https://github.com/anthropics/claude-code) plugin to run before Claude is allowed to
execute `gh pr create`.

The goal: make rigorous pre-PR review the path of least resistance. When Claude tries to open a PR, the hook
blocks the call and hands Claude a reason string telling it exactly what to do — run the toolkit, address
findings, then re-issue the same `gh pr create` command with a trailing sentinel.

## Scope and limitations

This hook is **a friction-adding nudge for Claude Code on your own projects**, not a bypass-proof PR
review gate. It's worth understanding what that means before you install it.

### What it does well

- Intercepts the `gh pr create` invocation shapes Claude actually emits (bare, `cd subdir && ...`,
  `;`-chained, piped) and forces the toolkit to run first.
- **Fails closed** when things go wrong: if `jq` is missing or the PreToolUse payload is malformed, the
  hook emits a hardcoded deny JSON on every Bash call with a clear explanation, rather than crashing
  and silently disabling the gate.
- **Stateless.** No session files, no cross-invocation bookkeeping, no Stop-hook safety net. Drop the
  script and settings block into any repo and it works.
- **Tested.** `hooks/test.sh` pins 39 regression cases covering every shape the hook is expected to
  block, allow, or reject — including sentinel misuse, documented known limitations, and the
  fail-closed internal-error paths (malformed payloads, unexpected `.tool_input.command` types,
  broken jq). Wired into CI via `.github/workflows/test.yml`.

### What it does NOT do

- **Not a security control.** The sentinel is an honor-system signal. A determined or adversarial agent
  can bypass the check today by chaining any command after a real PR-create invocation — e.g.
  `gh pr create ...; echo done # reviewed`. The hook works *because Claude follows the block-message
  instructions*, not because bash enforces anything.
- **`gh`-specific.** No coverage of `glab` (GitLab), direct `git push` that opens PRs via server-side
  hooks, web-UI PR creation, or any other path to a pull request. The hook is invisible to non-`gh`
  flows.
- **Claude-specific block-message format.** The hook emits a PreToolUse JSON structure that matches
  Claude Code's hook contract. Other coding agents with different contracts need different wiring.
- **Requires the `pr-review-toolkit` plugin installed on Claude Code.** The block message points Claude
  at `/pr-review-toolkit:review-pr all`; without that plugin, the block still fires but the remediation
  instruction is a dead end.
- **Bash-dependent.** Windows users need Git Bash or WSL.

### Known regex gaps

Each of these is pinned as an allow-test in `hooks/test.sh` so any future "fix" is a deliberate choice
rather than a drive-by regex tweak:

- Env-var prefix form: `GH_TOKEN=x gh pr create ...`
- Shell keyword bodies: `if true; then gh pr create ...; fi`
- Command substitution forms: `$(gh pr create ...)` and the legacy backtick form

Claude essentially never uses any of these for PR creation. If it ever does, the fallback is the same
as any other edge case — the user asks Claude to append ` # reviewed` after actually running the
review.

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

## Troubleshooting

### `jq: command not found`

The hook uses `jq` to parse the PreToolUse payload and to emit the deny response. Without it,
`set -euo pipefail` causes the hook to exit non-zero and every `Bash` tool call fails. Install it with
your package manager:

```sh
brew install jq          # macOS
sudo apt-get install jq  # Debian/Ubuntu
```

### `gh pr create --help` is also blocked

The hook treats `gh pr create --help` as a `gh pr create` invocation and blocks it. That's intentional
— no variant should slip through — but it means reading help that way doesn't work.

**Do not** reach for the `# reviewed` sentinel here. The sentinel is an honor-system signal that the
toolkit review has actually run on the staged diff; using it just to unblock `--help` trains both humans
and agents to treat it as a generic bypass and defeats the purpose of the hook.

Two workarounds:

- Run `gh help pr create`. Same help output; the `help` token between `gh` and `pr` keeps it out of the
  hook's regex.
- Read the docs on the web: <https://cli.github.com/manual/gh_pr_create>.

### The hook doesn't seem to fire at all

Symptom: `gh pr create` runs successfully in Claude Code without ever being blocked, and no reason string
is shown. This almost always means the hook isn't registered with the Claude Code harness — the script
can be sitting on disk, executable, with perfectly valid contents, and still do nothing because Claude
Code never calls it.

Two common causes:

1. **Project-local install (Option A) but the repo isn't open in Claude Code.** The project-local
   `.claude/settings.json` is only picked up when you open the repo directory *in Claude Code*. Running
   `claude` from a sibling directory, or working in a worktree that doesn't inherit the settings file,
   both leave the hook unwired.
2. **Global install (Option B) but the `hooks` block was never merged into `~/.claude/settings.json`.**
   Copying `hooks/enforce-pr-review.sh` into `~/.claude/hooks/` isn't enough on its own — Claude Code
   only runs hooks that are *declared* in a settings file. The `PreToolUse` block from the template
   `settings.json` in this repo has to be merged (by hand) into your user settings.

The fastest way to check whether the hook is wired is to lean on the intentional `--help` catch above:
run `gh pr create --help` in Claude Code. If the hook is wired, you'll see the block reason. If the hook
is *not* wired, `gh` will happily print its help text. It's a free, zero-side-effect wiring test.

If you need a second signal, the hook still works correctly when invoked directly from the shell (see
[Testing the hook directly](#testing-the-hook-directly) below). If the shell-level test passes but
Claude Code doesn't block, the hook itself is fine — the gap is in the settings wiring.

### The sentinel looks right but the command is still blocked

The hook recognizes the sentinel as a trailing shell comment with a specific shape: whitespace, then
`#`, then whitespace, then the literal word `reviewed`, optionally followed by trailing whitespace, at
the end of the command. It's stricter than it looks, and the failure mode is always the same — the hook
emits the same deny reason string a second time, even though you think you appended the sentinel
correctly. Four things to check:

- **Whitespace before the `#`.** `...--body bar#reviewed` is rejected because there's no whitespace
  between `bar` and `#`. Canonical form: `... --body bar # reviewed`.
- **Whitespace between `#` and `reviewed`.** `... --body bar #reviewed` (no space after `#`) is rejected.
  Canonical form: `... --body bar # reviewed`.
- **The sentinel has to be *trailing*.** `gh pr create # reviewed --title foo` is rejected. See
  [Why a trailing shell comment?](#why-a-trailing-shell-comment) above for the rationale — put the
  sentinel after every flag and argument, as the last thing on the command line.
- **Lowercase only.** `# Reviewed` and `# REVIEWED` are both rejected. The hook matches the literal
  lowercase word `reviewed`, not a case-insensitive variant. That's deliberate: the exact form acts as
  a small ritual that signals intentionality — a user or LLM that types `# Reviewed` (natural English
  capitalization) and gets bypassed has treated the sentinel as "close enough," which quietly erodes
  the honor-system contract the whole hook depends on. The test suite pins lowercase-only as a hard
  contract (`hooks/test.sh` has explicit `# Reviewed` and `# REVIEWED` must-block cases).

Canonical form: ` # reviewed` with a single leading space, a single space between `#` and `reviewed`,
and nothing after it.

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
