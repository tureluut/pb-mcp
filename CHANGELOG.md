# Changelog

Notable changes to pbmcp. The server version lives in `src/jsonrpc.pb`
(`#SERVER_VERSION$`); every rebuild stamps its compile date automatically
(`pbmcp version` / the `pb_version` tool report both).

## 0.4.0

### Added

- **Streamable HTTP transport** — `pbmcp http [--port N]` serves stateless
  Streamable HTTP on the IPv4 loopback only (default port 6817). HTTP mode
  negotiates MCP protocol `2025-11-25`; stdio keeps `2025-03-26`. New
  `src/http.pb`; unknown HTTP options are rejected with an actionable error.
- **Project staging for `pb_check` and `pb_run`** — both tools accept an
  optional `projectRoot` (absolute, or relative to the server's startup
  directory). The complete tree (default: the entry file's parent) is copied
  to a bounded temporary workspace, so parent-relative `XIncludeFile`s
  resolve like a native build and originals are never modified.
  - Limits: 10,000 entries, 256 MiB of regular-file bytes, nesting depth 64,
    15 s staging time; exceeding one returns an actionable error.
  - VCS metadata (`.git`, `.hg`, `.svn`) is excluded; symlinks (Linux) and
    junctions/reparse points (Windows), including dangling ones, are
    rejected instead of followed.
- **`pb_run` executes inside the staged copy** — compiles beside the staged
  entry file and runs with that directory as cwd, so relative resources and
  executable-relative DLL placement (`GetPathPart(ProgramFilename())`)
  work as in a native build. Stale staged executables are removed before
  compiling; files the program writes are ephemeral and deleted with the
  workspace (nothing is copied back).

### Changed

- **Docs-index preload default follows the runtime**: builds without a
  thread-safe runtime (the Windows non-`/THREAD` build) now default the
  serve-mode preload **off** and load the index lazily on the first docs
  call; `PBMCP_PRELOAD=1` force-enables it. Overlapping the preload
  worker's runtime calls with the request loop corrupted the heap on the
  non-TS build (0xC0000005/0xC0000354 in ~8-15% of docs-call sessions);
  thread-safe builds (`--thread`, required on Linux) keep the warm preload.
- Linux build (`build.sh`) passes `--thread` — required; the non-TS runtime
  heap-corrupts when the preload thread runs concurrently.
- `pb_check` best-practice notes stay always-on; the tool description now
  documents the project-staging behavior and `projectRoot` parameter.

### Fixed

- Allocation failures no longer corrupt the protocol: OOM when building a
  JSON-RPC response or growing a stdout buffer exits (1) instead of
  dereferencing null; HTML reads detect short reads and abort cleanly.

## 0.3.3

- `version` / `--version` / `-v` CLI mode; version stays consistent between
  the CLI line and `serverInfo.version`.
- `pb_check` best-practices support (procedure-scope hints, always-on lint).
- Earlier releases predate this changelog.
