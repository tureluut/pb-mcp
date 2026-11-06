# Installing purebasic-mcp-pb (binary distribution)

This bundle is self-contained: one MCP server executable plus the companion
agent skill. No Node, no npx, no installer. The binary is `pbmcp.exe` on
Windows, `pbmcp` on Linux.

    pbmcp[.exe]                    the MCP server (stdio, JSON-RPC 2.0; optional
                                   HTTP serve mode, see step 3)
    index-6.40.json                docs index drop-in (newest index-*.json in
                                   the exe's directory wins)
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

## 3. Optional: authenticated HTTP and HTTPS gateway

HTTP now **requires bearer authentication**, including for localhost and VPN
use. There is no anonymous/insecure mode. Existing HTTP users must create a
verifier file and restart with it; stdio is unchanged. For remote access, use
a private VPN or SSH tunnel where practical. Public deployment is for known
native MCP clients that can attach a bearer `Authorization` header; it is not
full MCP OAuth authorization/discovery, and browser clients/CORS are not
supported.

The backend listens only on IPv4 loopback (default port 6817). Create a 32-byte
random token and its SHA-256 verifier using Node's built-in crypto. Run this
in PowerShell or bash; copy the token once into the client's secret store and
keep it out of command history, logs, tickets and process arguments:

```powershell
$token = node -e "process.stdout.write(require('node:crypto').randomBytes(32).toString('hex'))"
$hash = node -e "process.stdout.write(require('node:crypto').createHash('sha256').update(process.argv[1], 'ascii').digest('hex'))" $token
# Write the verifier JSON with $hash; provision $token only to the client secret store.
```

```bash
token=$(node -e "process.stdout.write(require('node:crypto').randomBytes(32).toString('hex'))")
hash=$(node -e "process.stdout.write(require('node:crypto').createHash('sha256').update(process.argv[1], 'ascii').digest('hex'))" "$token")
# Write the verifier JSON with $hash; provision $token only to the client secret store.
unset token
```

The token is 64 lowercase hex characters. The file contains only its SHA-256
of the token's ASCII representation, never the plaintext:

```json
{"clients":[{"id":"workstation","tokenSha256":"<64 lowercase hex characters>"}]}
```

Use 1–32 clients with unique ASCII IDs (`[A-Za-z0-9_-]{1,64}`) and unique
64-character lowercase SHA-256 hashes. The file is limited to 16 KiB; malformed
JSON, duplicate object members, unknown fields and invalid entries fail startup.
Store it outside source trees and temporary staging. On Linux, restrict it to
the service account (`chmod 600`); on Windows, use a protected NTFS ACL granting
read access only to administrators/SYSTEM and the dedicated service account.
Rotate or revoke by atomically replacing the file and restarting pbmcp; there
is no hot reload or token expiry. Treat shells, environment capture and
command-line history as sensitive while generating/provisioning secrets.

Start a docs-only service (the default; exactly `pb_docs_search` and
`pb_command` are available):

```text
pbmcp.exe http --port 6817 --auth-file C:\ProgramData\pbmcp\auth.json
```

The equivalent Linux invocation is `pbmcp http --port 6817 --auth-file
/etc/pbmcp/auth.json`. Every request, including initialize and notifications,
needs `Authorization: Bearer <token>`. Native client support for a manually
configured authorization header is required. HTTPS termination is supplied by
the gateway below; never expose the loopback backend or send bearer tokens over
cleartext HTTP. The backend rejects browser origins and binds only
`127.0.0.1`.

### Canonical Caddy 2.10.2 gateway

This marked block is the canonical stock Caddyfile configuration exercised by
the gateway tests. Set `PBMCP_SITE_HOSTNAME` to the DNS name, the backend port
to the matching loopback listener, and the log path to a restricted file. Use
stock Caddy 2.10.2 or later and validate the rendered configuration with the
installed release. The tested release here is stock Caddy 2.10.2; see the
implementation handoff for the upstream release-checksum discrepancy and
verified asset digests.

```caddyfile
# BEGIN PBMCP SECURE HTTP GATEWAY
{
    admin off
    servers :443 {
        timeouts {
            read_header 10s
            read_body 10s
            write 200s
            idle 30s
        }
        max_header_size 16KiB
        protocols h1 h2
    }
}

{$PBMCP_SITE_HOSTNAME} {
    request_body {
        max_size 1048576
    }
    tls {
        protocols tls1.2 tls1.3
    }
    log {
        output file {$PBMCP_GATEWAY_LOG} {
            roll_size 10MiB
            roll_keep 5
        }
        format filter {
            request>uri delete
            request>headers delete
            resp_headers delete
        }
    }

    @pbmcp_mcp {
        path /mcp
        method POST
        expression {http.request.uri.query} == ""
    }
    handle @pbmcp_mcp {
        reverse_proxy 127.0.0.1:{$PBMCP_BACKEND_PORT} {
            # Caddy's default load-balancer retry count/duration are zero.
            header_up Host 127.0.0.1:{$PBMCP_BACKEND_PORT}
            header_up -Forwarded
            header_up -X-Forwarded-For
            header_up -X-Forwarded-Proto
            header_up -X-Forwarded-Host
            transport http {
                versions 1.1
                keepalive off
                dial_timeout 5s
                response_header_timeout 180s
                max_conns_per_host 16
            }
        }
    }
    respond 404
}
# END PBMCP SECURE HTTP GATEWAY
```

Caddy terminates HTTPS and preserves each client's `Authorization`; it does
not replace tokens with a shared backend credential. It rewrites upstream
`Host` to loopback, removes forwarding identity headers, preserves `Origin`,
accepts only exact `POST /mcp` without a query, caps request bodies, and does
not retry tool POSTs. Clients start at HTTPS, validate the public certificate,
use TLS 1.2 or newer and must not follow cross-host redirects. DNS and a public
CA certificate are required. Caddy obtains/renews certificates automatically;
optionally expose TCP 80 only for ACME/redirect handling, never proxy the
backend there. Expose only TCP 443 (and optionally 80), disable public admin,
metrics and debug endpoints, and keep Caddy's admin API disabled/local. This
configuration is not a general-purpose volumetric rate limiter; use upstream
firewall/IP allowlisting or edge protection on hostile public networks.

The backend keeps its bounded 16-connection/16-KiB-header/1-MiB-body limits,
10-second network bounds, per-client burst-10/refill-1-per-second admission,
and serialized tool execution. Caddy allows at most 16 backend connections;
queued requests may still time out behind a long-running compile/run (head of
line blocking), despite the 180-second upstream-header and 200-second gateway
write limits. These limits do not promise parallel jobs or a strict execution
wall-clock bound. Backend audit events go to stderr; restrict and rotate them.
Gateway access logs are restricted rolling files (10 MiB, five retained) and
exclude request headers, URI/query and response headers. Do not enable
`log_credentials` or body logging. Caddy does not need access to the auth file.

#### Linux service and firewall

Run pbmcp as a dedicated non-admin `pbmcp` user, with the executable/docs
read-only, only its required temporary/log paths writable, and the verifier
file readable only by that account. Example `/etc/systemd/system/pbmcp-http.service`:

```ini
[Unit]
Description=pbmcp authenticated HTTP backend
After=network.target

[Service]
User=pbmcp
Group=pbmcp
WorkingDirectory=/opt/pbmcp
Environment=PBMCP_PRELOAD=0
ExecStart=/opt/pbmcp/pbmcp http --port 6817 --auth-file /etc/pbmcp/auth.json
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/opt/pbmcp
ReadWritePaths=/var/lib/pbmcp /var/log/pbmcp

[Install]
WantedBy=multi-user.target
```

Keep the credential file separately protected (`root:pbmcp`, mode `0640`),
restrict and rotate captured stderr/journal and Caddy logs, and configure the
host firewall to expose only 443 and optional 80. The reverse proxy and backend
should run under separate restricted accounts. Verify actual service-account
read/write access before enabling the service.

#### Windows service supervision and firewall

Use a dedicated non-administrator account for pbmcp, protected NTFS ACLs on the
auth file and logs, and an explicit working directory. pbmcp is a console
program, **not** a Windows SCM service; do not register it directly with
`sc.exe`. Use Task Scheduler (At startup, run whether user is logged on or
not, restart on failure) to supervise it. Example action/arguments:

```text
Program:   C:\Program Files\pbmcp\pbmcp.exe
Arguments: http --port 6817 --auth-file C:\ProgramData\pbmcp\auth.json
Start in:  C:\Program Files\pbmcp
Environment: PBMCP_PRELOAD=0
```

Configure Task Scheduler's failure restart policy and capture stderr to a
restricted, rotated log using the site's approved wrapper/supervision method.
Run Caddy as a separate restricted account using its documented native
service mechanism; grant it no access to `auth.json`. Allow inbound TCP 443
and optionally 80 only; block public access to 6817. Verify effective ACLs and
service-account file access. Set `PBMCP_PRELOAD=0` in both platform recipes
because of the separate known Windows preload race. Compiler tools are not
available by default; use `--allow-compiler-tools` only on an isolated host
for trusted clients. Compilation can read host files and execute with the
service account's filesystem/network rights. Authentication and TLS do not
sandbox malicious code or protect credentials readable by that account. Never
run this opt-in service with personal/cloud credentials; use a disposable VM or
container, restricted filesystem and outbound network, or a safer VPN/SSH
alternative.

## 4. Docs index (optional)

The bundle ships a ready `index-6.40.json`; the docs tools
(`pb_docs_search` / `pb_command`) answer from it out of the box.

To switch to a different PureBasic help version, get the matching
`index-<version>.json` (built once with Node from the official online docs —
see the build recipe in `README.md`) and drop it next to the binary. The
newest `index-*.json` in the exe's directory wins; old versions keep working.

Without any index the server still starts and `pb_check` / `pb_run` work —
only the docs tools answer with a build hint.

## 5. Install the companion skill (recommended)

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

## 6. Environment variables (all optional)

| Variable                     | Purpose                                                                |
| ---------------------------- | ---------------------------------------------------------------------- |
| `PUREBASIC_HOME`             | Compiler install dir (overrides discovery)                             |
| `PUREBASIC_MCP_INDEX`        | Pin an explicit docs index file (overrides exe-dir/embedded discovery) |
| `PUREBASIC_MCP_METRICS`      | Redirect the JSONL metrics file                                        |
| `PUREBASIC_MCP_NO_METRICS=1` | Disable metrics writes                                                 |
| `PBMCP_PRELOAD`              | Serve-mode docs-index preload: default on in thread-safe builds (`--thread` Linux), off on the Windows non-TS build; `0` forces off, `1` forces on (heap-corruption hazard on Windows non-TS) |

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
