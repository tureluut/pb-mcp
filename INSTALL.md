# Installing purebasic-mcp-pb (binary distribution)

This bundle is self-contained: one MCP server executable plus the companion
agent skill. No Node, no npx, no installer. The binary is `pbmcp.exe` on
Windows, `pbmcp` on Linux.

    pbmcp[.exe]                    the MCP server (stdio, JSON-RPC 2.0)
    index.json                     docs index (swap for another index-*.json)
    skills/purebasic/SKILL.md      companion agent skill (recommended)
    README.md                      full documentation
    INSTALL.md                     this file

Verify what you deployed (server, protocol, PureBasic and docs-index
versions) at any time:

    pbmcp[.exe] version            CLI report, exit 0

or ask the agent to call its `pb_version` tool once connected.

## 1. Requirements

- **Windows or Linux** (the server spawns the platform's native PureBasic
  compiler).
- **PureBasic installed** — required for `pb_check` / `pb_run`. Found via:
  - Windows: `PUREBASIC_HOME`, `Program Files (x86)`, `Program Files`,
    `C:\PureBasic`, or `%LOCALAPPDATA%\Programs\PureBasic`
  - Linux: `PUREBASIC_HOME`, `~/purebasic`, `/opt/purebasic`,
    `/usr/local/purebasic`, or `pbcompiler` on `PATH`
- **Linux caveat**: the official PureBasic Linux compiler needs
  **glibc ≥ 2.38** (Ubuntu 24.04 or newer, Debian 13+, current Fedora/Arch).
  On older distros the server itself still runs (build it from source with
  `bash build.sh`), but the compiler tools need a runnable compiler.
- No Node.js needed — a prebuilt docs index ships in the bundle.

## 2. Point your MCP client at pbmcp

pi — `~/.pi/agent/mcp.json` (Windows: `\\` escapes; Linux: plain POSIX path):

```json
{
  "mcpServers": {
    "purebasic-pb": {
      "command": "C:\\path\\to\\dist\\pbmcp.exe",
      "args": [],
      "exposure": "direct"
    }
  }
}
```

Claude Desktop — `%APPDATA%\Claude\claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "purebasic-pb": {
      "command": "C:\\path\\to\\dist\\pbmcp.exe"
    }
  }
}
```

Cursor — `~/.cursor/mcp.json`, same `{"command": ..., "args": []}` shape under
`"mcpServers"`. On Linux the command is e.g. `/home/you/dist/pbmcp`. Restart
the client after editing.

## 3. Docs index (optional)

The bundle ships a ready `index.json`; the docs tools
(`pb_docs_search` / `pb_command`) answer from it out of the box.

To switch to a different PureBasic help version, get the matching
`index-<version>.json` (built once with Node from the official online docs —
see the build recipe in `README.md`) and drop it next to the binary. The
newest `index*.json` in the exe's directory wins; old versions keep working.

Without any index the server still starts and `pb_check` / `pb_run` work —
only the docs tools answer with a build hint.

## 4. Install the companion skill (recommended)

The server tools work without it, but the skill is what stops an agent from
hallucinating Visual Basic syntax into `.pb` files and teaches correct tool
use (`pb_check` after each coherent edit batch, console-only `pb_run`,
portable relative includes). Install the complete folder — `SKILL.md` plus
`references/` — not just `SKILL.md`; the entry point links its references.

pi — copy into the agent skills directory:

    # Windows
    xcopy /E /I skills\purebasic "%USERPROFILE%\.pi\agent\skills\purebasic"
    # Linux
    cp -r skills/purebasic ~/.pi/agent/skills/purebasic

Claude Code — copy to `~/.claude/skills/purebasic/`. Other clients: drop the
`purebasic/` folder wherever the client discovers skill folders.

## 5. Environment variables (all optional)

| Variable                     | Purpose                                                                |
| ---------------------------- | ---------------------------------------------------------------------- |
| `PUREBASIC_HOME`             | Compiler install dir (overrides discovery)                             |
| `PUREBASIC_MCP_INDEX`        | Pin an explicit docs index file (overrides exe-dir/embedded discovery) |
| `PUREBASIC_MCP_METRICS`      | Redirect the JSONL metrics file                                        |
| `PUREBASIC_MCP_NO_METRICS=1` | Disable metrics writes                                                 |

The metrics file defaults to `<cache>/purebasic-mcp/metrics.jsonl`, where
`<cache>` is `%LOCALAPPDATA%` on Windows and `${XDG_CACHE_HOME:-~/.cache}`
on Linux.

## Troubleshooting

- **"PureBasic compiler not found"** — set `PUREBASIC_HOME` to the install
  root (Windows: the folder containing `Compilers\pbcompiler.exe`; Linux:
  the folder containing `compilers/pbcompiler`) and restart the client.
- **Linux: `undefined reference to __wrap_memcpy` when a program is checked
  or run** — PB 6.41 + modern binutils link-order bug: the generated link
  line references `__wrap_memcpy` (from `--wrap=memcpy` in
  `libpbmimalloc.a`) before the provider (`systembase.a`) is seen. Put a gcc
  wrapper on `PATH` that re-appends the archive, e.g. `~/bin/gcc`:

  ```bash
  #!/bin/bash
  fix=0; sysbase=""
  for a in "$@"; do
    case "$a" in --wrap=memcpy|*-Wl,--wrap=memcpy*) fix=1 ;; esac
    case "$a" in *compilers/systembase.a) sysbase="$a" ;; esac
  done
  if [ -n "$fix" ]; then
    [ -z "$sysbase" ] && sysbase="${PUREBASIC_HOME%/}/compilers/systembase.a"
    exec /usr/bin/gcc "$@" "$sysbase"
  fi
  exec /usr/bin/gcc "$@"
  ```

  The wrapper must be on the `PATH` **of the MCP client process** — the
  server's compiler spawns inherit it. Trivial programs link fine unwrapped;
  bigger ones do not (code-dependent), so don't clear this by hello-world
  alone.
- **Docs tools answer with an index hint** — no usable index found; drop an
  `index-<version>.json` next to the binary or set `PUREBASIC_MCP_INDEX`.
- **Index out of date after a PureBasic upgrade** — build the matching
  `index-<version>.json` (see `README.md`) and drop it next to the binary;
  it is selected automatically (newest by mtime), and old versions keep
  working.

---

Written by **Tureluut** — [www.tureluut.be](https://www.tureluut.be).
**Free to use.**
