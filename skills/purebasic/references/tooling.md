# PureBasic MCP workflow and limitations

## Confirm the toolchain

- PureBasic 6.40 is this skill's baseline. Use `pb_version` when compiler or documentation-version compatibility matters, and confirm both against the project's actual target before applying guidance on later versions.
- Use `pb_docs_search` to find command names. Use `pb_command` to check exact syntax, parameters, return values, flags, and supported OS. Do not infer names or flags from another language or an older PB version.
- For reference pages, `pb_command` may return the full-text URL rather than the page contents. Fetch that official URL when details are needed; do not inspect MCP server internals.

## Compile and run

- `pb_check` compiles a temporary copy of the main source file and does not modify the project. Use it after each coherent edit batch; isolate a change sooner when needed to diagnose a failure.
- `pb_run` compiles and executes a console program. Use it only for bounded, noninteractive tests. Do not run a GUI, screen/keyboard loop, or a program waiting for user input; it may block until timeout. Record observed output and exit status.
- The MCP temporary-copy workflow may not resolve a relative `XIncludeFile` next to the original source. This is a tool limitation, not a reason to replace portable project includes with machine-specific absolute paths. If an include check fails, report the limitation; verify through the project-native compiler/build workflow when available, or ask the user if that is required and unavailable.
- Prefer MCP over invoking `pbcompiler` through shells where argument translation may alter compiler switches. Use another compiler route only when MCP cannot verify the project and the alternative is safe and available.
- The MCP `pb_check`/`pb_run` interface exposes no thread-safe compiler option. Code that uses threads must be verified with the project's native thread-safe build (`/THREAD` on Windows, `--thread` on Linux); a plain MCP execution does not verify thread-safe behavior. MCP checks remain useful for syntax and non-threaded logic.

## Failures and unavailable tools

- Distinguish source errors from tool/environment failures. Use the compiler's reported location and message, inspect the relevant source, and consult the 6.40 docs before changing code.
- Do not claim verification when a tool failed, timed out, or checked only a different file than the changed project. State precisely what was and was not verified.
- If MCP is unavailable in another session, use the official documentation and project's own compiler/test workflow if accessible. Do not invent command syntax or claim a compile check.
