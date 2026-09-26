# Configuration

Every setting is a command-line flag or an environment variable. Flags go in the `args` array of your MCP config; environment variables go in its `env` object.

## Flags

| Flag | What it does |
| --- | --- |
| `--dtd-uri <uri>` | The Dart Tooling Daemon to use. Without it, the server finds one in the standard discovery directory. |
| `--no-auto-discover-dtd` | Don't look for a Tooling Daemon at startup. |
| `--data-dir <dir>` | Where `captures.db` lives. Default: `~/Library/Application Support/flutter_network_mcp` on macOS, `$XDG_DATA_HOME/flutter_network_mcp` or `~/.local/share/flutter_network_mcp` on Linux. |
| `--no-persist` | Keep captures in memory only; nothing is written to disk. |
| `--capabilities <list>` | Only enable these tool groups: `http`, `sockets`, `websockets`, `logs`, `alerts`, `search`, `sessions`, `sql`, `admin`. Status, attach and detach are always on. |
| `--disable <list>` | Enable every group except these. Can't be combined with `--capabilities`. |
| `--auto-attach <patterns>` | Attach automatically to apps whose name contains one of these (comma-separated, case-insensitive). |
| `--auto-attach-deny <patterns>` | Never auto-attach apps whose name contains one of these. |

## Environment variables

The names used to start with `FLUTTER_NETWORK_MCP_`. Those still work: each is read as its `GLINT_NETWORK_` equivalent when the new name isn't set, and `network_status` lists any old names it finds so you can rename them.

### Capture and storage

| Variable | Default | What it does |
| --- | --- | --- |
| `GLINT_NETWORK_DATA_DIR` | see `--data-dir` | Same as `--data-dir`. |
| `GLINT_NETWORK_NO_PERSIST` | off | Same as `--no-persist`. |
| `GLINT_NETWORK_STORE_SECRETS` | off | Keep the values of secret headers (authorization, cookies, API keys, plus any added with `redacted_headers`) in the database for local replay. Off stores them as `<redacted>`. |
| `GLINT_NETWORK_CAPTURE_ALLOW` | empty | Only store requests whose host and path match one of these comma-separated patterns. |
| `GLINT_NETWORK_MAX_DB_BYTES` | 2 GB | Size cap for `captures.db`; the oldest bodies, then logs, then sessions are dropped to stay under it. `0` or `off` disables it. |
| `GLINT_NETWORK_POLL_MS` | 2000 | How often captured traffic is read from the app (50 to 60000). |
| `GLINT_NETWORK_LOG_BUFFER` | 2000 | Log records kept in memory per session (50 to 20000). `GLINT_NETWORK_LOG_BUFFER_SIZE` is an alias. |
| `GLINT_NETWORK_ALERT_RETENTION_DAYS` | 14 | Alerts from sessions that are no longer attached expire after this many days. `0` keeps them. |
| `GLINT_NETWORK_NO_MIGRATION_BACKUP` | off | Skip the automatic copy (`captures.db.pre-v<N>.bak`) made before a schema upgrade. The copy is kept 14 days, and a newer one replaces it. |

### Connecting to apps

| Variable | Default | What it does |
| --- | --- | --- |
| `GLINT_NETWORK_DTD_URI` | none | Same as `--dtd-uri`. |
| `GLINT_NETWORK_AUTO_DISCOVER_DTD` | true | `false` is the same as `--no-auto-discover-dtd`. |
| `GLINT_NETWORK_AUTO_ATTACH` | none | Same as `--auto-attach`. |
| `GLINT_NETWORK_AUTO_ATTACH_DENY` | none | Same as `--auto-attach-deny`. |
| `GLINT_NETWORK_AUTO_ATTACH_POLL_MS` | 5000 | How often auto-attach looks for new apps (1000 to 60000). |
| `GLINT_NETWORK_MAX_ATTACH` | 8 | Most apps attached at once (1 to 32). |
| `GLINT_NETWORK_NO_AUTO_MIGRATE` | off | Don't follow an attached app to its new VM address after a hot restart. |
| `GLINT_NETWORK_MIGRATE_POLL_MS` | 5000 | How often that check runs (1000 to 60000). |
| `GLINT_NETWORK_RPC_TIMEOUT_MS` | 10000 | Deadline for each call into the app's VM (at least 1000). |
| `GLINT_NETWORK_TOOL_TIMEOUT_MS` | 20000 | Deadline for each tool call (2000 to 120000). |

### Tool groups

| Variable | What it does |
| --- | --- |
| `GLINT_NETWORK_CAPABILITIES` | Same as `--capabilities`. |
| `GLINT_NETWORK_DISABLE` | Same as `--disable`. |

### Telemetry and startup messages

| Variable | What it does |
| --- | --- |
| `GLINT_NETWORK_TELEMETRY=on` | Share anonymous usage summaries and crash reports. Off unless set; see [telemetry.md](telemetry.md). |
| `GLINT_NETWORK_NO_TELEMETRY=true` | Never share anything. |
| `GLINT_NETWORK_NO_USAGE=true` | Stop recording tool usage locally, and never share it. |
| `GLINT_NETWORK_USAGE_GAP_MS` | Idle time after which a new usage turn starts (default 60000). |
| `GLINT_NETWORK_NO_UPDATE_CHECK=true` | Don't check for a newer version at startup. |
| `GLINT_NETWORK_NO_JIT_NUDGE=true` | Don't print the hint about running `glint_network install` for faster startup. |
