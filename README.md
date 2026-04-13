# pr-review-hooks

A single PreToolUse hook for [Claude Code](https://docs.claude.com/en/docs/claude-code) that forces
the [`pr-review-toolkit`](https://github.com/anthropics/claude-code) plugin to run before Claude can
open a pull request. The goal is to make rigorous pre-PR review the path of least resistance: when
Claude tries, the hook blocks the call and hands Claude a reason string telling it exactly what to
do — run the toolkit, address findings, then re-issue the same command with a trailing sentinel.

## Scope and limitations

This is **a friction-adding nudge for Claude Code on your own projects**, not a bypass-proof review
gate. The difference matters before you install it.

**What it does well:**

- Intercepts every PR-create invocation shape Claude actually emits (bare, `cd subdir && ...`,
  `;`-chained, piped) and forces the toolkit to run first.
- Fails closed on error: missing `jq`, malformed payloads, and unexpected command types all emit a
  hardcoded deny rather than crashing and silently disabling the gate.
- Stateless: no session files, no cross-invocation bookkeeping. Drop the script and settings block
  into any repo and it works.
- Tested: 39 regression cases in `hooks/test.sh`, wired into CI via `.github/workflows/test.yml`.

**What it does NOT do:**

- **Not a security control.** The `# reviewed` sentinel is honor-system. A determined or adversarial
  agent can bypass it today by chaining a separate command — the hook works because Claude follows
  the block-message instructions, not because bash enforces anything.
- **`gh`-specific.** No coverage of `glab`, direct `git push`, web-UI PRs, or any non-`gh` path.
- **Claude-specific response format.** Other coding agents need different wiring.
- **Requires the `pr-review-toolkit` plugin.** Without it the block fires but the remediation
  instruction is a dead end.
- **Bash-dependent.** Windows needs Git Bash or WSL.

**Known regex gaps:** each of these is pinned as an allow-test in `hooks/test.sh` so any future
"fix" is a deliberate choice.

- Env-var prefix: `GH_TOKEN=x gh pr create ...`
- Shell keyword bodies: `if true; then gh pr create ...; fi`
- Command substitution: `$(gh pr create ...)` and the legacy backtick form

Claude essentially never uses these forms for PR creation.

## How it works

1. **PreToolUse hook on `Bash`.** Every `Bash` tool call is piped to `hooks/enforce-pr-review.sh` as a
   JSON payload on stdin.
2. **Filter.** The hook exits `0` (allow) for anything that isn't a real PR-create invocation.
3. **Block.** For a matching command, the hook emits a `permissionDecision: "deny"` JSON object with
   a detailed reason. Claude Code shows that reason to the model, so Claude knows exactly what to do
   next. The exact text of the block message lives in `hooks/enforce-pr-review.sh` — read it there
   rather than duplicating it here.
4. **Escape hatch.** If the command ends in the literal trailing shell comment ` # reviewed`, the
   hook allows it through. This is Claude's signal that the toolkit has actually been run and
   findings addressed.

## Install

### Option A — project-local (recommended for trying it out)

Clone the repo and use the in-repo `.claude/settings.json`, which points at
`$CLAUDE_PROJECT_DIR/hooks/enforce-pr-review.sh`. The repo dogfoods itself — the first PR you try to
open on it will be blocked until you run `/pr-review-toolkit:review-pr`.

```sh
git clone <this-repo>
cd pr-review-hooks
chmod +x hooks/enforce-pr-review.sh
# Open this directory in Claude Code. The project-local .claude/settings.json
# is picked up automatically.
```

### Option B — global install

Copy the script into your user hooks directory and merge the `hooks` block from `settings.json` (at
the repo root) into `~/.claude/settings.json`.

```sh
mkdir -p "$HOME/.claude/hooks"
cp hooks/enforce-pr-review.sh "$HOME/.claude/hooks/"
chmod +x "$HOME/.claude/hooks/enforce-pr-review.sh"
```

## Requirements

- `bash`
- `jq` (used to parse the hook payload and emit the deny JSON)
- Claude Code with the `pr-review-toolkit` plugin installed (the hook's reason string references
  `/pr-review-toolkit:review-pr`)

## Testing the hook directly

The hook reads JSON from stdin, so you can exercise it from the shell without launching Claude Code.
Allow paths produce silent exit 0 with no output; only blocks print JSON:

```sh
# block: prints deny JSON, exit 0
echo '{"tool_name":"Bash","tool_input":{"command":"gh pr create --title foo"}}' \
  | ./hooks/enforce-pr-review.sh

# allow: silent exit 0, no output
echo '{"tool_name":"Bash","tool_input":{"command":"gh pr create --title foo # reviewed"}}' \
  | ./hooks/enforce-pr-review.sh
```

For full coverage, run `./hooks/test.sh` (39 cases, also runs on every PR via CI).

## Troubleshooting

### `jq: command not found`

The hook uses `jq` to parse the PreToolUse payload. Without it, the hook emits a fail-closed deny
JSON on every `Bash` call with a clear install message — not a crash. Install it:

```sh
brew install jq          # macOS
sudo apt-get install jq  # Debian/Ubuntu
```

### `gh pr create --help` is also blocked

The hook treats `gh pr create --help` as a real PR-create invocation and blocks it. Do not reach
for the `# reviewed` sentinel to unblock it — that trains bypass behavior. Instead, run
`gh help pr create` (the token order keeps it out of the hook's regex) or read the docs at
<https://cli.github.com/manual/gh_pr_create>.

### The hook doesn't seem to fire at all

Symptom: the PR-create command runs without being blocked and no reason is shown. The script is on
disk but Claude Code never calls it. Two common causes:

1. **Project-local install but the repo isn't open in Claude Code.** The project-local
   `.claude/settings.json` is only picked up when you open the repo directory *in Claude Code*.
2. **Global install but the `hooks` block was never merged into `~/.claude/settings.json`.** Copying
   the script into `~/.claude/hooks/` isn't enough — Claude Code only runs hooks that are *declared*
   in a settings file.

Fastest wiring test: run the help variant in Claude Code. If you see the block reason, the hook is
wired. If `gh` prints help, it isn't. (The help catch is intentional — see above.)

### The sentinel looks right but the command is still blocked

The sentinel is a trailing shell comment with a specific shape — whitespace, `#`, whitespace, the
literal word `reviewed`, end of command. Four ways to get it wrong:

- **Whitespace before the `#` is required.** `...--body bar#reviewed` is rejected.
- **Whitespace between `#` and `reviewed` is required.** `...--body bar #reviewed` is rejected.
- **The sentinel must be trailing.** Putting it before any flag or argument is rejected — it goes at
  the very end of the command line.
- **Lowercase only.** `# Reviewed` and `# REVIEWED` are rejected. The exact form is deliberate: it
  acts as a small ritual that signals intentionality. A case-insensitive match would let the
  sentinel feel "close enough," eroding the honor-system contract.

Canonical form: ` # reviewed` with single spaces and nothing after it.
