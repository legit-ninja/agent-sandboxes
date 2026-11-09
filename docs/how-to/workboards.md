# Coordinate sessions with a shared workboard

[← Documentation](../index.md)

A **workboard** lets several sessions work as a team: different agents (Claude,
Codex, Grok, OpenCode, Copilot) and different roles (developer, tester,
reviewer, ...) take tasks off one shared, file-based board and hand them on.
The board itself is the [agent-workboards](https://github.com/legit-ninja/agent-workboards)
project. This page covers the sandbox side: mounting it.

```bash
sandbox run --agent opencode --tier 2 --repo ~/clones/app-opencode \
  --board ~/agent-workboards --role developer,tester,gate
sandbox run --agent claude --tier 2 --repo ~/clones/app-claude \
  --board ~/agent-workboards --role code-reviewer,security
sandbox run --agent codex --tier 2 --repo ~/clones/app-codex \
  --board ~/agent-workboards --role quality-reviewer
```

Each session starts with one message the operator wrote: *run `/workboard/bin/wb boot`*.
That prints the agent's rules (`AGENTS.md`), its persona(s) and the work waiting
for its roles. From then on the agent claims tasks with `wb claim` and finishes them
with `wb done`. (Grok has no "first message" launch form yet. For Grok sessions
the banner prints the line to paste.)

## What gets mounted

| In the pod | From | Mode | Holds |
|---|---|---|---|
| `/workboard` | `--board <DIR>` (your agent-workboards checkout) | **read-only** | rules, personas, the `wb` CLI, gate scripts, `orchestrator/board.toml` |
| `/workboard-state` | `--board-state <DIR>` (default `~/.sandbox/board`) | read-write, **shared** | tasks, verdicts, notes, git bundles, activity log |

The pod also gets `WB_HOME`, `WB_STATE`, `WB_AGENT` (the `--agent`), `WB_SESSION`
(the session id), `WB_ROLE` (`--role`, if given) and `WB_HOST_STATE` (the state's
host path, used by `wb export`).

- **`--role`** is a comma list of persona names from the board's `.ai/personas/`,
  plus `gate` (runs the deterministic checks stage). Without it the agent takes the
  default roles for its agent in the board config.
- **`--board-state`**: every session given the same directory shares one board.
  Use a different directory per team or project to keep boards apart.
- Profiles can carry these too: `board:`, `board_state:`, `role:`
  (see [Profiles](profiles-and-overlays.md)).

## Set up the board (once, on the host)

```bash
git clone https://github.com/legit-ninja/agent-workboards ~/agent-workboards
cp ~/agent-workboards/orchestrator/board.example.toml ~/agent-workboards/orchestrator/board.toml
# edit pools/agents/roles if you like, then create a project and a first task:
~/agent-workboards/bin/wb init-project app --base main
~/agent-workboards/bin/wb new app "Add rate limiting" --body-file spec.md --labels api
```

**Give each session its own clone** of the project (`git clone ~/repos/app
~/clones/app-claude`, and so on). Do not use `git worktree add`: a linked worktree's
`.git` points outside the mount and doesn't work in the pod. Code moves between
sessions as git bundles in the board state, so the clones never need to push to
each other. When a task reaches `approved`, `wb export <id>` prints the
`git fetch` that brings its branch into your real repo for review and merge.

## Several roles in one session

- **Interactive:** pass several roles (`--role developer,tester`). The agent claims
  whatever is next for any of them, and each packet says which persona applies.
- **Autonomous:** inside the session, `wb work --roles developer,tester --loop`
  runs the agent's own CLI headless, one persona per task. It uses the
  `[agents.<name>]` command lines in the board config.
- **Native subagents:** `wb subagents --format claude --out ~/.claude/agents`
  (or `--format opencode --out ~/.config/opencode/agent`) turns every persona into a
  subagent the main agent can delegate to. Those directories sit in the agent-home,
  which persists across sessions of that agent.

## Security notes (read before sharing a board)

The two mounts are split by trust on purpose:

- **The definition is read-only.** Personas, `AGENTS.md`, the `wb` CLI and the gate
  scripts are instructions that *every* agent on the board loads or runs. If an agent
  could edit them, it could rewrite another agent's persona or weaken the checks
  stage. `--board` must not overlap any `--repo`, because a writable workspace over
  it would defeat the read-only mount. It must also not contain files the sandbox
  masks as secrets (`.env`, ...).
- **The state is a deliberate cross-session channel.** Anything one session writes
  there, every other session on that board can read. That includes sessions running
  other vendors' models. The sandbox keeps each session's network and filesystem
  isolation, but the board is a path for data and prompt injection between sessions
  that you opt into. So:
  - `--board` is **refused on Tier 3**. A session holding infra credentials must not
    have a write path to other sessions.
  - Treat everything in the state as **untrusted, agent-written data**: task text,
    notes, verdicts and bundles. `AGENTS.md` tells agents the same. Board verdicts
    are coordination signals, not approvals. Review an approved branch yourself
    before merging. Fetching a bundle runs no hooks and imports no config, but the
    code in it is still agent-written.
  - The state dir must not overlap your home directory or sensitive paths:
    `~/.ssh`, `~/.aws`, `~/.kube`, `~/.config`, `~/.sandbox/{secrets,logs,agent-home,...}`,
    or the agent-sandboxes checkout. The sandbox refuses those.
  - `events.jsonl` in the state is a convenience log written by agents. It is **not**
    an audit record. The session audit log records which board each session mounted
    (`workboard` event; `board*` keys in `session.json`).
- **Identity is cooperative.** `WB_AGENT` and `WB_ROLE` are set by the operator, but an
  agent can change its own shell environment. The board's role and pool checks
  organize honest agents. They are not an authorization boundary between sessions.

## Platform notes

- **Linux / WSL:** both mounts are host directories. All sessions share the state
  directly, and claims use atomic renames.
- **macOS:** `--board` must be under your home directory (read through the VM's home
  share). The state lives **inside the VM** at
  `/var/lib/sandbox/board/<basename of --board-state>`. It is VM-local so every pod
  sees the same directory; the per-session workspace copies would split it. To use
  `wb` from the Mac side, run it in the VM, for example:
  `limactl shell sandbox-vm -- env WB_STATE=/var/lib/sandbox/board/board python3 ~/agent-workboards/bin/wb status`.
  Or run a planner session and let it manage the board.
- **Resume:** `sandbox resume` reattaches to a running board session normally. It
  will not *recreate* a torn-down one. It prints the full `sandbox run ... --board ...`
  command instead, so the board paths are re-validated.
