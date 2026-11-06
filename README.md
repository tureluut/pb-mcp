# purebasic-mcp-pb

A native [PureBasic](https://www.purebasic.com/) implementation of a
[Model Context Protocol](https://modelcontextprotocol.io) server that gives
coding agents first-class PureBasic support: documentation search, real
compiler syntax checks, and compile-and-run verification — all from a single
native binary (`pbmcp.exe` on Windows, `pbmcp` on Linux) with no runtime
dependencies (no Node, no npx).

- MCP handshake p50 **27.6 ms**, RSS **15.6 MB** (Windows, verified 8/8 protocol cases on 6.40)
- MCP handshake p50 **1.4 ms**, RSS **19.7 MB**, `pb_check` median 529 ms (Linux/WSL2, PB 6.41, 8 MB index)
- Author: **Tureluut** — [www.tureluut.be](https://www.tureluut.be)
- License: **MIT** (see [LICENSE](LICENSE))

## Tools

| Tool             | Description                                                                                                                                                                                                        |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `pb_docs_search` | Search the PureBasic command reference. Returns command names, library, and one-line summaries. Optional `library` filter, `limit` (1–25, default 10).                                                              |
| `pb_command`     | Full documentation for one command: exact syntax, parameters, return value, remarks, example, supported OS, related commands. Also resolves reference-page titles (Compiler Directives, Includes, migration guides, UserGuide) to their full-text URL.                                                        |
| `pb_check`       | Syntax-check a `.pb` file with the **real compiler** (~350 ms). Returns structured errors with line numbers, high-confidence hints on common beginner errors, and always-on best-practice notes (missing `EnableExplicit`, `Global` inside procedures, `Goto`/`Gosub`). The file's project tree is staged to a bounded temporary workspace (see [Project staging](#project-staging)); originals are never modified.                                                                                                     |
| `pb_run`         | Compile and run a console program, capturing stdout. Accepts `args[]` and `timeoutMs` (default 15000, max 60000). Console programs only; the program runs inside the staged copy with the entry file's directory as its working directory, so relative resources and executable-relative DLLs come from the copied project. Generated files are ephemeral and removed with the workspace. |
| `pb_version`     | Report the server version, MCP protocol version, detected PureBasic compiler version + install path, and the docs-index version + build date + entry counts. Takes no arguments.                                     |

The docs tools answer from a docs index built by the repo's Node tooling
(see [Build from source](#build-from-source-including-the-json-index)).
The compiler tools (`pb_check`, `pb_run`) work without an index.

## Requirements

- **Windows or Linux** (the server spawns the platform's native PureBasic compiler)
- **PureBasic installed** — needed for `pb_check` / `pb_run`. Discovery order:
  - Windows: `PUREBASIC_HOME` → `Program Files (x86)` → `Program Files` →
    `C:\PureBasic` → `%LOCALAPPDATA%\Programs\PureBasic`
  - Linux: `PUREBASIC_HOME` → `~/purebasic` → `/opt/purebasic` →
    `/usr/local/purebasic` → `pbcompiler` on `PATH`
- **Node.js** — only to (re)build the docs index; the tooling lives in `tools/`.
  A prebuilt `index-*.json` or an embedded index needs no Node at all.
- **Linux note**: the official PureBasic Linux compiler is a glibc ≥ 2.38
  binary (Ubuntu 24.04+); on older distros use the compiler your distro can
  run. If linking fails with `undefined reference to __wrap_memcpy`, see the
  gcc wrapper note in `INSTALL.md` (PB 6.41 + modern binutils).

## Build from source (including the JSON index)

Follow these steps once to produce a self-contained `pbmcp.exe` with the docs
index baked in. The order matters: the index builder shells out to
`pbmcp.exe scan`, so the exe must exist before the index is built.

1. **Install prerequisites** — Windows, [PureBasic](https://www.purebasic.com/)
   6.40 x64 (found via `PUREBASIC_HOME` or the default per-user install
   location), and [Node.js](https://nodejs.org/) 18+.
2. **Get the source** — clone or download this repository and open a shell in
   its root.
3. **First build** (from the placeholder index in `src/pbdocs-index.json`):

       build.cmd

   One command: a UTF-8 BOM lint over `src/*.pb`, then a 6.40 `/CONSOLE`
   compile to `pbmcp.exe`.
4. **Build the docs index JSON** from the official online documentation
   (~2000 pages, one-time):

       node tools/fetch-online-docs.mjs tmp/online-docs
       node tools/build-online-index.mjs tmp/online-docs --out src/pbdocs-index.json --pb-version 6.40

   To embed a specific PureBasic help version, pass that version to
   `--pb-version` and name the output `index-<version>.json` instead.
5. **Rebuild with the index embedded** — `src/docs_index.pb` bakes
   `src/pbdocs-index.json` into the binary via `IncludeBinary`, so:

       build.cmd

   The embedding adds ~2 MB. Prefer a small exe? Skip this step and instead
   drop the JSON next to the exe as `index-<version>.json`; the server loads
   the newest `index*.json` in its directory by mtime, and a drop-in file
   overrides the embedded one.
6. **Verify and package**:

       pbmcp.exe version          # shows server, protocol, PureBasic and docs-index versions + entry counts
       node test/run_tests.mjs    # full acceptance suite (optional)
       make-dist.cmd              # assemble the self-contained dist\ bundle (optional)
Build options:

    build.cmd check      authoritative 6.40 /CHECK on the real tree

### Linux

The same tree builds natively on Linux (PureBasic 6.x for Linux x64 + gcc
for linking; bash):

    bash build.sh            # lint + compile to ./pbmcp  (--thread: REQUIRED on Linux)
    bash build.sh check      # --check on the real tree (authoritative syntax gate)
    bash make-dist.sh        # assemble the self-contained dist/ bundle

The only deliberate difference from `build.cmd`: the Linux compile passes
`--thread`. The non-TS runtime heap-corrupts when the docs-index preload
thread runs concurrently with main-thread runtime use — measured, see
`PORTING-LINUX.md`. The Windows build stays non-TS, and for the same
reason its serve mode defaults the docs-index preload **off**: the index
loads lazily on the first docs call (`PBMCP_PRELOAD=1` force-enables the
background preload; known heap-corruption hazard — same note). Compiler
discovery matches the table above; `PBMCP_OUT` overrides the output path
on both OSes.

## Project staging

Both compiler tools accept an optional `projectRoot` (absolute, or relative
to the server's startup directory). The entry `file` keeps its usual
interpretation; the root only selects what gets staged:

- **Default root** — the entry file's parent directory.
- **Explicit root** — pass `projectRoot` when the project reaches outside
  the entry's directory, e.g. a parent-relative include:

        myproject/
          common.pbi          shared with the sibling below
          gui/window.pb       XIncludeFile "../common.pbi"
          src/main.pb

  `pb_check { file: "myproject/gui/window.pb", projectRoot: "myproject" }`
  stages the whole tree, so `../common.pbi` resolves like a native build.
- **What is copied** — the complete tree (sources, `.pbi`, DLLs/shared
  libraries, libraries, resources, data, empty directories), preserving
  relative paths. Only VCS metadata (`.git`, `.hg`, `.svn`) is excluded.
- **Limits** — 10,000 entries, 256 MiB of regular-file bytes, nesting depth
  64, 15 s staging time. Exceeding one returns an actionable error; narrow
  the root.
- **Links are rejected** — symbolic links on Linux and junctions/reparse
  points on Windows (including dangling ones) fail staging instead of being
  followed. Stage regular files only.
- **Execution moves into the copy** — `pb_run` compiles beside the staged
  entry file and runs with that directory as cwd, so executable-relative DLL
  placement (`GetPathPart(ProgramFilename())`) works as in a native build.
  Files the program writes are ephemeral: they live in the workspace and are
  deleted with it. Nothing is copied back — migrate outputs explicitly if
  you relied on the old write-into-the-source-tree behavior.
- **External dependencies** — anything outside the root (SDK DLLs, data on
  another drive) must be moved/vendored inside the root or encompassed by a
  larger explicit root. Staging is not a sandbox: absolute paths still reach
  the originals, so only trusted code should be run.

## HTTP transport

    pbmcp http --port 6817 --auth-file /secure/path/auth.json

- **Endpoint** — `http://127.0.0.1:<port>/mcp` (default port 6817; any
  integer 1–65000). HTTP requires a credential verifier file on every
  invocation and binds `127.0.0.1` only. No anonymous or non-loopback backend
  mode exists. See [INSTALL.md](INSTALL.md#3-optional-authenticated-http-and-https-gateway)
  for secure token provisioning and the canonical Caddy HTTPS gateway.
- **Authentication/profile** — each request needs a manually provisioned
  `Authorization: Bearer <token>` header. Default HTTP exposes only
  `pb_docs_search` and `pb_command`; `--allow-compiler-tools` explicitly
  enables `pb_check`, `pb_run` and `pb_version` for every configured client.
  That opt-in is for trusted clients on an isolated host, not a sandbox.
  HTTP credentials are preconfigured bearer authentication, not MCP OAuth or
  authorization discovery. Native clients must support a manual auth header;
  browser/CORS access is unsupported. A VPN or SSH tunnel is safer than public
  exposure.
- **Protocol** — MCP `2025-11-25`, stateless Streamable HTTP: one JSON-RPC
  message per POST, `application/json` results, `202` for notifications and
  responses. No sessions, no SSE streaming, no server-to-client requests.
  Clients send `Accept: application/json, text/event-stream` and, after
  initialization, `MCP-Protocol-Version: 2025-11-25`.
- **stdio is unchanged** — the default mode keeps speaking MCP
  `2025-03-26` over newline-framed stdin/stdout. Clients that cannot
  negotiate `2025-11-25` keep using stdio.
- **Boundary and admission** — browser origins are rejected; Caddy preserves
  Origin and the backend rejects it. HTTP requires bearer auth, limits each
  client to a burst of 10 then 1 request/second, and emits redacted audit
  events to stderr. These measures do not provide volumetric DDoS protection.
- **Serialized execution** — tool calls run one at a time on the main
  thread; a long compile/run delays all HTTP servicing until it finishes.
  Network receive/send bounds are 10 seconds, not an execution deadline.
- **Bounded framing** — 16 connections, 16 KiB headers, 1 MiB body,
  keepalive/chunked/HTTP/2 unsupported (rejected without dispatch).
- **Docs-index preload** — thread-safe builds (`--thread`, Linux) load the
  docs index in a background thread at startup. The Windows non-thread-safe
  build has a known preload race; deployment guidance sets `PBMCP_PRELOAD=0`.

## Distribution

    make-dist.cmd    (Windows)  /  make-dist.sh    (Linux)

Builds the binary straight into `dist/` (via the `PBMCP_OUT` override, so a
running server cannot lock the target), smoke-tests that the artifact
launches, and assembles the self-contained bundle:

    dist/pbmcp[.exe]                  native server binary
    dist/index-*.json                 newest repo-root docs index (working drop-in;
                                      embedded placeholder covers when absent)
    dist/README.md
    dist/INSTALL.md                   quickstart for binary consumers
    dist/skills/purebasic/            companion agent skill (SKILL.md + references/)

`dist/` is gitignored; regenerate after every release-worthy change.

## Companion skill

The repo ships the agent skill this server was built with: the complete
`skills/purebasic/` folder — `SKILL.md` plus its `references/` (tooling,
verification, best-practices). The tools do the work; the skill teaches the
agent PureBasic itself — no VB/FreeBASIC syntax, event-loop rules,
resource-cleanup pairs, and correct tool use (`pb_check` after each coherent
edit batch, console-only `pb_run`, portable relative includes — see the
skill's tooling reference). Not required to run the server, but strongly
recommended — copy the whole folder into the client's skills directory
(see `INSTALL.md`, step 4).

## Client configuration

Stdio **command** server — point the client straight at the binary
(`pbmcp.exe` on Windows, `pbmcp` on Linux; no `.exe` suffix there).

pi — `~/.pi/agent/mcp.json` (Windows paths use `\\` escapes, POSIX paths as-is):

```json
{
  "mcpServers": {
    "purebasic-pb": {
      "command": "C:\\path\\to\\purebasic-mcp-pb\\pbmcp.exe",
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
      "command": "C:\\path\\to\\purebasic-mcp-pb\\pbmcp.exe"
    }
  }
}
```

Cursor — `~/.cursor/mcp.json` uses the same `{"command": ..., "args": []}`
shape under `"mcpServers"`. On Linux the command is e.g.
`/home/you/dist/pbmcp`. Restart the client after editing.

## Other CLI modes

(`pbmcp.exe` below; on Linux the binary is `pbmcp`)

    pbmcp.exe                                      serve MCP over stdio (default)
    pbmcp.exe version                              server/protocol/PureBasic/docs-index versions (also `--version`, `-v`)
    pbmcp.exe scan <html> [<library> <relfile>]    parse one command page as JSON (test utility)
    pbmcp.exe test <file>                          replay a golden .jsonl session (test runner)
    pbmcp.exe http --port 6817 --auth-file <path>  authenticated loopback HTTP (see [HTTP transport](#http-transport))

Protocol: MCP over stdio — JSON-RPC 2.0, newline-framed UTF-8,
`2025-03-26`; the optional HTTP mode speaks stateless Streamable HTTP with
`2025-11-25`.

## Environment variables

| Variable                     | Purpose                                                                                                   |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `PUREBASIC_HOME`             | Compiler install dir; discovery takes the newest install it finds otherwise                                |
| `PUREBASIC_MCP_INDEX`        | Pin an explicit docs index file (overrides exe-dir/embedded discovery)                                     |
| `PUREBASIC_MCP_METRICS`      | Redirect the JSONL metrics file                                                                            |
| `PUREBASIC_MCP_NO_METRICS=1` | Disable metrics writes entirely                                                                            |
| `PBMCP_PRELOAD`              | Serve-mode background docs-index preload. Default: on in thread-safe builds (`--thread` Linux), **off** on the non-thread-safe Windows build (lazy first-docs-call load; the overlap corrupts the heap). `0` forces it off everywhere; `1` force-enables it (known hazard on the Windows non-TS build) |

The metrics file defaults to `<cache>/purebasic-mcp/metrics.jsonl`, where
`<cache>` is `%LOCALAPPDATA%` on Windows and `${XDG_CACHE_HOME:-~/.cache}`
on Linux.

## PureBasic version support

Built and gated on **6.40 x64** on Windows and **6.41 x64** on Linux
(the full acceptance suite passes on both). The 6.50 beta is
compile-checked tool-compatible but not part of the test matrix.

- **Compiler tools**: version detection parses the compiler's version output
  (`/VERSION` on Windows, `--version` on Linux) with a regex and never trusts
  the exit code; capability flags (`bannerFilter`, `versionExitCode`) are
  keyed on major version with conservative defaults for unknown versions.
  `pb_version` (tool) and `pbmcp[.exe] version` (CLI) surface the detected
  version.
- **Docs index**: one index per help version; the newest `index*.json` next to
  the exe wins, so switching help versions is a file copy — no config change,
  no restart beyond the client reconnect.

## Docs index

The index source is the official rendered documentation at
`https://www.purebasic.com/documentation/`.

- Command entries are parsed by the shipped binary itself (`pbmcp[.exe] scan`,
  one process per page).
- Reference pages are found by a fixpoint crawl (the root index links further
  pages); the user-guide and migration pages are recovered this way.
- `purebasicVersion` is `"online"` when built with `--pb-version online` —
  the site carries no version marker; `source` records the URL and crawl
  timestamp for auditability.
- The GitHub repo (fantaisie-software/purebasic) holds DocMaker _sources_,
  not rendered pages — keep it as offline fallback, not as parse target.

Without any index the server starts and `pb_check` / `pb_run` work
untouched — only the docs tools report the missing-index hint.

## Tests

    node test/run_tests.mjs       # full acceptance suite: framing + multibyte,
                                  # protocol, docs tools, pb_check, pb_run,
                                  # metrics, wiring, missing-index UX, scanner
    node --test test/project.test.mjs   # project staging/safety/runtime (focused)
    node --test test/http.test.mjs      # HTTP protocol/security/integration (focused)

Set `PBMCP_EXE` to test a build elsewhere (e.g. `test/out_version/`) — the
repo-root exe is locked while a live server runs on it.

Highlights: 7-byte dribble stress cutting UTF-8 chars across stdin chunk
boundaries, byte-exact error paths, pb_run timeout/orphan/cleanup gates,
and missing-index UX paths. Set `PUREBASIC_HOME` to the 6.40 install to
exercise the primary branch.

## Layout

    src/main.pb        entry, arg parse (serve | http | version | scan | test)
    src/console.pb     WriteLine (UTF-8, LF-framed), RunFile, byte-level RunStdin
    src/jsonrpc.pb     request parse, response/error builders, transport sink, id copy
    src/config.pb      PB home discovery, /VERSION detect, capability flags, cache dir
    src/metrics.pb     JSONL metrics (frozen record shape), error-bucket classifier
    src/docs_index.pb  docs index cache + search + lookup + did-you-mean
    src/html_scan.pb   native HTML scanner + `scan` mode
    src/pbdocs-index.json   embedded docs index (DataSection; placeholder = empty valid index)
    src/tool_check.pb  shared compiler pipeline (staging, spawn/capture, diagnostics) + pb_check
    src/tool_run.pb    pb_run (staged compile/run, timeout, tree-kill)
    src/tools.pb       tool registry, tools/list schemas, docs tool handlers
    src/http.pb        bounded authenticated loopback Streamable HTTP adapter
    tools/lint_encoding.ps1   build-time encoding gate (Windows)
    tools/lint_encoding.sh    build-time encoding gate (Linux; same BOM rule)
    build.sh / make-dist.sh   Linux build + packaging (build.cmd / make-dist.cmd ports)
    tools/fetch-online-docs.mjs   mirror the official online docs
    tools/build-online-index.mjs  frozen-schema docs index from a docs tree
    test/sessions/     golden sessions replayed by `pbmcp.exe test`

## Source-encoding rule

All `src/*.pb` are **UTF-8 with BOM**. BOM-less UTF-8 is silently misread as
CP-1252 by the PB compilers; the lint in `build.cmd` enforces the BOM, and
stub outputs carry a deliberate em-dash canary so an encoding regression is
visible in tool output.

## Status

Production-ready and deployed as the active PureBasic MCP in daily agent use
(verified through a 9-session dogfood week: 71.4 % first-try success on the
frozen task set, zero doc-hallucination classes).

## Author & license

Written by **Tureluut** — [www.tureluut.be](https://www.tureluut.be).

Licensed under the **MIT License** — see [LICENSE](LICENSE). Use it,
modify it, ship it; provided "as is", without warranty of any kind.
