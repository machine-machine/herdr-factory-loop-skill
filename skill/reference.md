# herdr — full CLI & Socket reference (v0.6.9, protocol 13)

Companion to [SKILL.md](SKILL.md). Verbatim flag lists from `herdr <group> --help` + the published docs.

## Environment variables
| Var | Purpose |
|-----|---------|
| `HERDR_CONFIG_PATH` | Override config file path |
| `HERDR_SESSION` | Select named session for CLI commands |
| `HERDR_SOCKET_PATH` | Override socket path (low-level) |
| `HERDR_LOG` | Log filter, e.g. `herdr=debug` |
| `HERDR_DISABLE_SOUND` | Disable sound playback |

Socket resolution order: explicit `--session` → `HERDR_SOCKET_PATH` → `HERDR_SESSION` → default `~/.config/herdr/herdr.sock`. Named sessions: `~/.config/herdr/sessions/<name>/herdr.sock`.

Custom-command keybindings receive: `HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`, `HERDR_ACTIVE_WORKSPACE_ID`, `HERDR_ACTIVE_TAB_ID`, `HERDR_ACTIVE_PANE_ID`, `HERDR_ACTIVE_PANE_CWD`.

---

## CLI

### Launch / status / lifecycle
```
herdr                                   launch or attach default session (INTERACTIVE — avoid in scripts)
herdr --session <name>                  launch/attach named session
herdr --remote <host> [--session N]     SSH attach to remote herdr server
herdr --remote <host> --remote-keybindings <local|server>
herdr --remote <host> --handoff         attach with live handoff
herdr --no-session                      monolithic single-process mode
herdr --default-config                  print default config.toml and exit
herdr --version | -V
herdr status [server|client]
herdr update [--handoff]
herdr channel show | set <stable|preview>
herdr config <subcommand>               e.g. herdr config reset-keys
```

### Server
```
herdr server                            run headless server
herdr server stop
herdr server reload-config              apply reloadable config without restart
herdr server agent-manifests [--json]   show active detection manifests
herdr server update-agent-manifests [--json]
herdr server reload-agent-manifests
```

### Sessions
```
herdr session list [--json]
herdr session attach <name>
herdr session stop   <name> [--json]
herdr session delete <name> [--json]
```

### Workspaces
```
herdr workspace list
herdr workspace create [--cwd PATH] [--label TEXT] [--focus|--no-focus]
herdr workspace get   <workspace_id>
herdr workspace focus <workspace_id>
herdr workspace rename <workspace_id> <label>
herdr workspace close <workspace_id>
```

### Tabs
```
herdr tab list [--workspace <workspace_id>]
herdr tab create [--workspace <workspace_id>] [--cwd PATH] [--label TEXT] [--focus|--no-focus]
herdr tab get   <tab_id>
herdr tab focus <tab_id>
herdr tab rename <tab_id> <label>
herdr tab close <tab_id>
```

### Worktrees (git)
```
herdr worktree list   [--workspace ID | --cwd PATH] [--json]
herdr worktree create [--workspace ID | --cwd PATH] [--branch NAME] [--base REF] [--path PATH] [--label TEXT] [--focus|--no-focus] [--json]
herdr worktree open   [--workspace ID | --cwd PATH] (--path PATH | --branch NAME) [--label TEXT] [--focus|--no-focus] [--json]
herdr worktree remove --workspace ID [--force] [--json]
```
Default checkout root (config `[worktrees].directory`): `~/.herdr/worktrees/<repo>/<branch-slug>`.

### Panes — layout
```
herdr pane list [--workspace <workspace_id>]
herdr pane get  <pane_id>
herdr pane layout   [--pane ID|--current]
herdr pane neighbor --direction left|right|up|down [--pane ID|--current]
herdr pane edges    [--pane ID|--current]
herdr pane focus    --direction left|right|up|down [--pane ID|--current]
herdr pane resize   --direction left|right|up|down [--amount FLOAT] [--pane ID|--current]
herdr pane zoom     [<pane_id>|--pane ID|--current] [--toggle|--on|--off]
herdr pane rename   <pane_id> <label>|--clear
herdr pane split    [<pane_id>|--pane ID|--current] --direction right|down [--ratio FLOAT] [--cwd PATH] [--focus|--no-focus]
herdr pane swap     --direction left|right|up|down [--pane ID|--current]
herdr pane swap     --source-pane ID --target-pane ID
herdr pane close    <pane_id>
```

### Panes — I/O
```
herdr pane read <pane_id> [--source visible|recent|recent-unwrapped|detection] [--lines N] [--format text|ansi] [--ansi]
herdr pane send-text <pane_id> <text>          # literal text, NO Enter
herdr pane send-keys <pane_id> <key> [key ...] # key names: Enter, Esc, Tab, Up, ctrl+c, …
herdr pane run       <pane_id> <command>       # command text PLUS Enter
```
`--source`: `visible` = current screen; `recent` = recent scrollback (wrapped); `recent-unwrapped` = unwrapped long lines; `detection` = the buffer slice used for agent detection.

### Panes — agent authority reporting
```
herdr pane report-agent   <pane_id> --source ID --agent LABEL --state idle|working|blocked|unknown
                                     [--message TEXT] [--custom-status TEXT] [--seq N]
                                     [--agent-session-id ID] [--agent-session-path PATH]
herdr pane report-agent-session <pane_id> --source ID --agent LABEL [--seq N] [--agent-session-id ID] [--agent-session-path PATH]
herdr pane release-agent  <pane_id> --source ID --agent LABEL [--seq N]
herdr pane report-metadata <pane_id> --source ID [--agent LABEL] [--applies-to-source ID]
                                     [--title TEXT|--clear-title] [--display-agent TEXT|--clear-display-agent]
                                     [--custom-status TEXT|--clear-custom-status]
                                     [--state-label STATUS=TEXT] [--clear-state-labels] [--seq N] [--ttl-ms N]
```
`--seq N` orders concurrent reports (higher wins). `report-metadata` changes display only, not authority.

### Agents
```
herdr agent list
herdr agent get    <target>
herdr agent read   <target> [--source visible|recent|recent-unwrapped] [--lines N] [--format text|ansi] [--ansi]
herdr agent send   <target> <text>             # literal text (no Enter); settle ~1s before send-keys Enter
herdr agent rename <target> <name>|--clear
herdr agent focus  <target>
herdr agent wait   <target> --status idle|working|blocked|unknown [--timeout MS]
herdr agent attach <target> [--takeover]       # INTERACTIVE
herdr agent start  <name> [--cwd PATH] [--workspace ID] [--tab ID] [--split right|down] [--focus|--no-focus] -- <argv...>
herdr agent explain <target> [--json|--verbose]
herdr agent explain --file PATH --agent LABEL [--json|--verbose]
```
`<target>` resolves: terminal id → unique agent name → detected/reported label → legacy pane id.
`agent explain` shows *why* herdr classified an agent's state (manifest match / hook) — use to debug misdetection.

### Waits
```
herdr wait output       <pane_id> --match <text> [--source visible|recent|recent-unwrapped] [--lines N] [--timeout MS] [--regex] [--raw]
herdr wait agent-status <pane_id> --status idle|working|blocked|done|unknown [--timeout MS]
```

### Notifications
```
herdr notification show <title> [--body TEXT]
        [--position top-left|top-right|bottom-left|bottom-right]
        [--sound none|done|request]
```

### Integrations
```
herdr integration install   <pi|omp|claude|codex|copilot|droid|kimi|opencode|kilo|hermes|qodercli|cursor>
herdr integration uninstall <same set>
herdr integration status [--outdated-only]
```

### Terminal (direct attach)
```
herdr terminal attach <terminal_id> [--takeover]   # INTERACTIVE; detach ctrl+b q; literal ctrl+b = ctrl+b ctrl+b
```

---

## Socket API

Transport: **newline-delimited JSON** over Unix domain socket. One JSON object per line.

Request: `{"id":"req_1","method":"<area>.<verb>","params":{…}}`
Success: `{"id":"req_1","result":{"type":"…", …}}`
Error:   `{"id":"req_1","error":{"code":"not_found","message":"pane not found"}}`

Connect (one-shot): `printf '%s\n' '<json>' | nc -U ~/.config/herdr/herdr.sock`
Persistent (events): keep the socket open and read lines as they arrive (e.g. `socat - UNIX-CONNECT:~/.config/herdr/herdr.sock`).

### Methods by area
| Area | Methods |
|------|---------|
| Server | `ping`, `server.stop`, `server.reload_config`, `server.agent_manifests`, `server.reload_agent_manifests` |
| Workspace | `workspace.create`, `.list`, `.get`, `.focus`, `.rename`, `.close` |
| Tab | `tab.create`, `.list`, `.get`, `.focus`, `.rename`, `.close` |
| Pane | `pane.split`, `.swap`, `.zoom`, `.layout`, `.neighbor`, `.edges`, `.focus_direction`, `.resize`, `.list`, `.get`, `.rename`, `.send_text`, `.send_keys`, `.send_input`, `.read`, `.report_agent`, `.report_agent_session`, `.report_metadata`, `.clear_agent_authority`, `.release_agent`, `.close`, `.wait_for_output` |
| Agent | `agent.list`, `.get`, `.read`, `.explain`, `.send`, `.rename`, `.focus`, `.start` |
| Events | `events.subscribe`, `events.wait` |
| Worktree | `worktree.list`, `.create`, `.open`, `.remove` |
| Integration | `integration.install`, `integration.uninstall` |
| Notification | `notification.show` |

### Payload examples
Ping:
```json
{"id":"1","method":"ping","params":{}}            → {"id":"1","result":{"type":"pong"}}
```
Report agent state:
```json
{"id":"r1","method":"pane.report_agent","params":{"pane_id":"1-1","source":"custom:docs","agent":"docs-bot","state":"working","message":"building","custom_status":"indexing"}}
```
Report session identity (for restore):
```json
{"id":"r2","method":"pane.report_agent_session","params":{"pane_id":"1-1","source":"herdr:codex","agent":"codex","agent_session_id":"…"}}
```
Subscribe to blocked transitions:
```json
{"id":"sub","method":"events.subscribe","params":{"subscriptions":[{"type":"pane.agent_status_changed","pane_id":"1-1","agent_status":"blocked"}]}}
```
Notify:
```json
{"id":"n","method":"notification.show","params":{"title":"build failed","body":"api","position":"top-left","sound":"request"}}
→ {"id":"n","result":{"type":"notification_show","shown":true,"reason":"shown"}}
```
`notification.show` reasons: `shown`, `disabled`, `rate_limited`, `no_foreground_client`, `busy`.

Workspace event types: `workspace.created`, `.updated`, `.renamed`, `.closed`, `.focused`. Pane event: `pane.agent_status_changed`.

### pane_info shape (returned by `pane.get`, `agent.list`, etc.)
```json
{"type":"pane_info","pane":{
  "pane_id":"1-1","terminal_id":"term_abc123","workspace_id":"1","tab_id":"1-1",
  "focused":true,"agent":"claude","agent_status":"working","revision":42,
  "cwd":"…","foreground_cwd":"…",
  "agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"<uuid>"}}}
```
Semantic states everywhere: `working`, `blocked`, `idle`, `done`, `unknown`.

---

## Agent detection internals
- Two authority sources: **lifecycle hooks** (installed integration, authoritative & exclusive when active) vs **screen manifests** (TOML rules over the bottom-buffer snapshot — heuristic).
- Bundled manifests auto-update from herdr.dev. Local overrides: `~/.config/herdr/agent-detection/<agent>.toml`.
- `blocked` is only set on a recognized visible approval/question/permission UI (deliberately strict).
- `herdr agent explain <target> --verbose` shows the matched rule/hook for debugging.

## Config keys (config.toml) — orchestration-relevant subset
```toml
[session]
resume_agents_on_restore = true     # restart supported agents into native sessions after herdr restart
[worktrees]
directory = "~/.herdr/worktrees"
[experimental]
pane_history = true                 # persist pane output across server restarts (may contain secrets)
allow_nested = false                # block herdr-in-herdr (enable only for testing)
```
Full default dump: `herdr --default-config`. Reload after edits: `herdr server reload-config`.
