# Coordinate sessions with a shared workboard

[← Documentation](../index.md)

A **workboard** lets several sessions work as a team: different agents (Claude,
Codex, Grok, OpenCode, Copilot) and different roles (developer, tester,
reviewer, ...) take tasks off one shared, file-based board and hand them on.
The board itself is the [agent-workboards](https://github.com/legit-ninja/agent-workboards)
project. This page covers the sandbox side: mounting it.

```bash
sandbox run --agent opencode --tier 2 --repo ~/clones/app-opencode \
  --board ~/agent-workboards --role developer,tester,gate --name Eng
sandbox run --agent claude --tier 2 --repo ~/clones/app-claude \
  --board ~/agent-workboards --role code-reviewer,security --name Rev
sandbox run --agent codex --tier 2 --repo ~/clones/app-codex \
  --board ~/agent-workboards --role quality-reviewer --name QA
```

`--name` is the board name. It is sanitized (slashes become hyphens, then 2-32
characters starting with a letter) and exported into the pod as `WB_NAME`. `wb boot`
registers or reclaims that name; agents must not pick a different one. **The same
`--name` is the intended restart:** a later `sandbox run` with the same `--name` and
the same `--agent` reclaims the name (as long as the previous session has no live
claims), even though the sandbox session id is new. Sub-agents inherit `WB_NAME`
and `WB_SESSION` from the lead and share that name.

Each session starts with one message the operator wrote, prefixed with the name
when `--name` is set (`[Eng] run /workboard/bin/wb boot` …), so the CLI title is
identifiable. Claude Code is also launched with `-n <name>` (the documented session
display-name flag). OpenCode `--title` is not passed: it is documented on
`opencode run` but was not verified for the interactive TUI `--prompt` path.
That prints the agent's rules (`AGENTS.md`), its persona(s) and the work waiting
for its roles. From then on the agent claims tasks with `wb claim` and finishes them
with `wb done`. (The first message is wired for Claude, Codex, OpenCode and Copilot.
For Grok it isn't wired yet, so the banner prints the line to paste.)

## What gets mounted

| In the pod | From | Mode | Holds |
|---|---|---|---|
| `/workboard` | `--board <DIR>` (your agent-workboards checkout) | **read-only** | rules, personas, the `wb` CLI, gate scripts, `orchestrator/board.toml` |
| `/workboard-state` | `--board-state <DIR>` (default `~/.sandbox/board`) | read-write, **shared** | tasks, verdicts, notes, git bundles, activity log |

The pod also gets `WB_HOME`, `WB_STATE`, `WB_AGENT` (the `--agent`), `WB_SESSION`
(the session id), `WB_NAME` (the sanitized `--name`, if it is a valid board name),
`WB_ROLE` (`--role`, if given) and `WB_HOST_STATE` (the state's
host path, used by `wb export`).

On **Tier 3** the state is different; see [Tier 3: read-only state and the
broker](#tier-3-read-only-state-and-the-broker).

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

## Tier 3: read-only state and the broker

A Tier 3 session holds infra credentials, so it never gets write access to the
shared state. You can pass `--os-cloud` (or `--infra-token` /
`--infra-kubeconfig`) together with `--board`; those are session infra
credentials, not profile `secrets:`. It gets:

| In the pod | From | Mode |
|---|---|---|
| `/workboard` | `--board` | read-only |
| `/workboard-state` | `--board-state` | **read-only** |
| `/workboard-outbox` | `~/.sandbox/board-outbox/<session>` | read-write, **private** to this session |

and `WB_OUTBOX`, `WB_ACCESS=restricted` and `WB_TIER=3`. At launch the sandbox also
writes `~/.sandbox/board-outbox/<session>.json`, which records the session's agent,
`--role` list, tier and state dir. That file is **not** mounted.

Inside the pod `wb` works as usual for the agent, with the board's **restricted
access**. It sees only tasks it can claim and the ones it holds. Writes go as
request files into the outbox: `claim`, `heartbeat`, `note`, `done`, `release`,
`block`. On the host, run the broker next to your sessions:

```bash
~/agent-workboards/bin/wb broker            # state: board_root / $WB_STATE; outboxes: ~/.sandbox/board-outbox
```

The broker:

- **Takes the session's identity and roles from the host-side `.json` file**, not
  from the pod's environment or the request.
- **Applies only those operations, restricted:** the session claims what its roles
  may claim, and acts only on its own claims. `done` follows the stage's configured
  route.
- **Caps and redacts free text** (notes, verdict summaries, findings, block and
  release reasons). Text matching secret patterns is redacted before anything reaches
  the shared state: cloud keys, GitHub/GitLab/Slack/OpenAI-style tokens, bearer
  tokens, kubeconfig credentials, private keys, JWTs, `token=`/`password=` pairs,
  IPs, and the board's `[redaction]` domains.
- **Checks code bundles without running git:** the bundle must carry exactly the
  task's branch, stay under a size cap, and is refused for stages that don't hand on
  code.
- Ignores outboxes whose identity names another state dir, and never follows
  symlinks in the outbox.

If the broker isn't running, the agent's `wb` times out with a message saying so,
withdraws its request, and nothing changes.

What remains: a Tier 3 session can still put information into the text and code it
hands on. Redaction catches well-known secret formats, not deliberate encoding. Use
Tier 3 board sessions for roles whose output you review anyway, and keep
infra-credential sessions on their own `--board-state` when you can.

Outboxes and identity files are kept after a session ends. Remove old ones from
`~/.sandbox/board-outbox/` when you no longer need them.

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

- **The definition is read-only.** Personas, `AGENTS.md` and the `wb` CLI are
  instructions and code that *every* agent on the board loads or runs. The read-only
  mount stops an agent from rewriting what *another* agent will run. It does not
  make the board's verdicts trustworthy: see the state notes below. `--board` must
  not overlap any `--repo` of the same session, and the sandbox refuses that. It
  can't see your *other* sessions, so never also pass the workboards checkout (or a
  parent of it) as another session's `--repo`. The definition is **not**
  secret-scanned (only files the sandbox masks, such as `.env`, are refused), so
  keep credentials out of it, `board.toml` included.
- **The state is a deliberate cross-session channel.** Anything one session writes
  there, every other session on that board can read. That includes sessions running
  other vendors' models. The sandbox keeps each session's network and filesystem
  isolation, but the board is a path for data and prompt injection between sessions
  that you opt into. So:
  - On **Tier 3** the state is mounted read-only and writes go through the
    operator's `wb broker` ([above](#tier-3-read-only-state-and-the-broker)), so a
    session holding infra credentials has no direct write path to other sessions.
    `--board` is still **refused with a profile that injects `secrets:`**.
    Tier 3 infra flags (`--infra-token`, `--infra-kubeconfig`, `--os-cloud`)
    are not profile secrets and **are** allowed with `--board`; see
    [Tier 3 Infra Credentials](tier3-infra-credentials.md#openstack).
  - What remains, by design: every agent can read **its own login**: the OAuth token
    in its agent-home, or OpenCode's API key in its environment. On a shared board, a
    compromised or prompt-injected agent can pass that to the other sessions, and from
    there to another vendor's model. Only share a board between sessions whose
    logins you are willing to expose to each other. Use separate `--board-state`
    dirs otherwise.
  - Treat everything in the state as **untrusted, agent-written data**: task text,
    notes, verdicts and bundles. `AGENTS.md` tells agents the same. Board verdicts
    are coordination signals, not approvals. Review an approved branch yourself
    before merging. Fetching a bundle runs no hooks and imports no config, but the
    code in it is still agent-written.
  - The board verdicts and stage order are **cooperative**. Any session can write any
    file in the state, so it can skip the checks stage or forge a reviewer's `pass`.
    The gate scripts being read-only stops an agent from weakening the *gate*, not
    from going around it.
  - `wb` never follows a symlink inside the state dir, and it ignores task files
    whose names aren't plain ids. So planting `events.jsonl -> ~/.bashrc` or
    `todo/x.md -> ~/.ssh/id_rsa` doesn't make *your* host-side `wb status`/`new`/`show`
    (or another session's `wb`) write or read outside the board. Still, on the host
    use `wb` only to manage the board (`init-project`, `new`, `status`, `show`,
    `unblock`, `export`). `wb work` and `wb run-gate` run agent-written code. Run
    those **only inside a sandbox**.
  - The state dir must not overlap your home directory or sensitive paths:
    `~/.ssh`, `~/.aws`, `~/.kube`, `~/.config`, `~/.sandbox/{secrets,logs,agent-home,...}`,
    or the agent-sandboxes checkout. The sandbox refuses those.
  - `events.jsonl` in the state is a convenience log written by agents. It is **not**
    an audit record. The session audit log records which board each session mounted
    (`workboard` event; `board*` keys in `session.json`).
- **Identity is cooperative** on Tier 1/2. `WB_AGENT` and `WB_ROLE` are set by the
  operator, but an agent can change its own shell environment. The board's role and
  pool checks organize honest agents. They are not an authorization boundary between
  sessions. On Tier 3 the broker takes identity from the host-side file, so there it
  is enforced.

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
  Tier 3 outboxes are VM-local too (`/var/lib/sandbox/board-outbox/<session>`, owned
  by the pod uid), so run `wb broker` in the VM as root or uid 1000:
  `limactl shell sandbox-vm -- sudo env WB_STATE=/var/lib/sandbox/board/board python3 ~/agent-workboards/bin/wb broker --outbox-root /var/lib/sandbox/board-outbox`.
  (Unverified on a live macOS install.)
- **Resume:** `sandbox resume` reattaches to a running board session normally. It
  will not *recreate* a torn-down one. It prints the full `sandbox run ... --board ...`
  command instead, so the board paths are re-validated.
