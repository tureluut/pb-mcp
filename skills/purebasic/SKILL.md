---
name: purebasic
description: PureBasic 6.40 coding conventions with MCP documentation, compilation, and console testing. Use when writing, editing, or debugging .pb or .pbi source — prevents VB/FreeBASIC syntax hallucinations and guides declarations, events, flags, resource cleanup, and verification.
---

# PureBasic conventions (6.40)

Write PureBasic, not Visual Basic, not FreeBASIC. Target PureBasic 6.40.
When version compatibility matters, confirm the compiler and documentation
index with `pb_version`; do not assume they match the target.
Before writing PureBasic, use `pb_docs_search` to locate real commands.
Before any unfamiliar call, confirm exact syntax and flags with `pb_command`.
Run `pb_check` after each coherent edit batch, before execution or delivery;
check earlier when a risky change needs isolation. Tool instructions take
precedence over batching shortcuts. Compilation does not prove runtime behavior.

## MCP documentation and verification

When this server is used over HTTP, remember that the default profile is
docs-only; compiler tools require explicit opt-in on a trusted isolated host.
The HTTP endpoint requires bearer credentials and remains loopback-only behind
an HTTPS gateway. See the repository's `INSTALL.md` for deployment details.

MCP is the primary workflow: command search → exact documentation → compilation
→ noninteractive console tests where applicable. For reference-page lookup,
relative-include staging, safe execution, and unavailable-tool handling,
read [`references/tooling.md`](references/tooling.md) when relevant.
The tested scope, array-read, and parsing cases are recorded in
[`references/verification.md`](references/verification.md); other guidance is
not a blanket claim of compiler-tested coverage.
For module organization, console I/O, files and encoding, memory management,
threads, databases, GUI lifetimes, and release verification, read the matching
section of [`references/best-practices.md`](references/best-practices.md)
before writing code — load only the sections the task needs.

## PureBasic is not Visual Basic

- Comments start with `;` — never `'` or `//`. A `'` line is a syntax error.
- Strings use double quotes only: `"text"`. Single quotes are not string
  delimiters. Escaped strings: `~"line\n"` (not `"..."` with backslash escapes).
- No `Sub`/`End Sub`, no `Function`/`End Function`, no `Dim x As Integer`,
  no `#Const`, no `Set x = y`. Read the sections below for the real forms.
- Statements end at end-of-line. `:` joins several statements on one line:
  `If ok : Debug "yes" : EndIf`.
- Keywords (`If`, `For`, `Define`, …) take no `()`; functions always require
  `()` even with zero arguments: `EventWindow()` is a call, `EventWindow` is a
  variable.

## Minimal single-window GUI skeleton

```purebasic
EnableExplicit

Procedure OnClick()
  Debug "clicked"
EndProcedure

Define Event.i

If OpenWindow(0, 0, 0, 320, 200, "Demo", #PB_Window_SystemMenu | #PB_Window_ScreenCentered)
  ButtonGadget(0, 10, 10, 300, 30, "Click me")
  BindGadgetEvent(0, @OnClick())
  Repeat
    Event = WaitWindowEvent()
    Select Event
      Case #PB_Event_Timer ; periodic work via AddWindowTimer(#Window, 1, 500)
        Debug "timer tick"
    EndSelect
  Until Event = #PB_Event_CloseWindow
EndIf
End
```

## Declarations and types

- Put `EnableExplicit` at the top of every file; then declare before use:
  `Define count.i = 0`, `Define path.s`, `Define scale.f = 1.5`. A file-level
  `EnableExplicit` does **not** extend into `Module` scopes — enable it in
  each module too when wanted.
- Without `EnableExplicit`, any name compiles as an undeclared integer — bugs
  hide. Keep it on.
- Default type is `.i` (integer, pointer-sized: 8 bytes on 64-bit). Use `.i`
  by default; `.l`/`.q`/`.w`/`.b` only when a fixed width or an API demands it;
  `.f` (float) / `.d` (double) for reals; `.s` for strings.
- `$` at the end of a name makes it a string: `name$` ≡ a string variable. The
  `$` is part of the name and always attached.
- Arrays: `Dim values.f(10)` — parentheses with a size, no `As` clause.
  `Dim Count As Integer` is a syntax error. Indexing is 0-based and `Dim n(10)`
  allocates 11 elements.
- Dynamic collections: `NewList items.s()` / `NewMap ages.i()`, iterated with
  `ForEach items() … Next`. There are no list/dict literals.
- Scope: main-level `Define` scalars and ordinary arrays, lists, and maps are
  not automatically accessible inside procedures. Declare shared state with
  `Global count.i`, `Global Dim grid.i(9)`, or `Global NewList queue.i()`
  before the procedure, or use `Shared count, grid()` inside it. Modules
  isolate names, not threads or ownership, and do not inherit a file-level
  `EnableExplicit` — see the Modules section of the best-practices reference
  for API boundaries, declaration order, and init/shutdown.
- `Read` can fill a visible scalar or array element. In a procedure,
  `Read.i grid(x)` works when `grid()` is global or shared. Match the read
  type to the stored data and ensure the data position is valid.
- Constants: `#MAX_RETRIES = 3`. A constant can never have a type suffix —
  `#PlayerSpeed.f = 2.5` fails with "A constant can't have a type".

## Procedures

- `Procedure[.<type>] Name(param.i, text.s) … EndProcedure`. The type after
  `Procedure` is the return type: `Procedure.s Join(a.s, b.s)`.
- Return with `ProcedureReturn value` — never by assigning to the procedure
  name. `ProcedureReturn` exits immediately.
- Trailing parameters may have constant default values: `Procedure
  Draw(x.i, y.i, mode.i = 0)`.
- Declare callbacks before use when needed: `Declare OnClick()` ahead of code
  that references it; define later.

## Event loop rules

- For a simple single-window GUI, use one main event loop around
  `WaitWindowEvent()` and dispatch its returned event. Do not fetch an extra
  event accidentally: each call removes another event from the queue.
  Multi-window applications must check `EventWindow()` before deciding to quit.
  Give the wait a timeout only when needed; prefer window timers for periodic work.
- Gadget events: handle `#PB_Event_Gadget` + `EventGadget()` in the loop,
  bind `BindGadgetEvent(#Gadget, @Callback())`, or both — bound handlers and
  loop dispatch coexist. Never pump events from inside a bound callback: do
  not call `WindowEvent()`/`WaitWindowEvent()` there.
- Timers: `AddWindowTimer(#Window, Timer, TimeoutMs)` fires `#PB_Event_Timer`;
  identify via `EventTimer()`.
- Prefer `#PB_Any` for auto-numbered windows/gadgets only when you store the
  returned handle; numbered constants (`0`, `1`) are simpler for small tools.

## Constants and flags

- Built-in flags live in the `#PB_…` namespace (`#PB_Window_SystemMenu`,
  `#PB_Button_Toggle`, `#PB_String_Numeric`, `#PB_Event_CloseWindow`,
  `#PB_EventType_Change`). Combine with `|`.
- **Never invent a constant.** If unsure of a name or a gadget's flags, check
  `pb_command` for the creating command — its Parameters section lists the
  valid flags. `#True`/`#False`/`#Null` exist; `#Empty$`/`#Null$` are the
  special string constants.
- Some plausible names are already taken: `#HIDDEN` is a built-in constant (use
  `#HIDDEN_ROWS` for a playfield's hidden-row count), and the 2DDrawing outline
  mode is `#PB_2DDrawing_Outlined` — `#PB_2DDrawing_Outline` does not exist.
  When `pb_check` reports a constant error, fix from the error or the docs
  rather than guessing a variant.

## OS and debugger branches

- `CompilerSelect #PB_Compiler_OS … CompilerCase #PB_OS_Windows …
  CompilerEndSelect`; guards via `CompilerIf #PB_Compiler_Debugger …
  CompilerEndIf`. Inactive branches are removed and not validated by the
  current build — one successful compile proves only its selected branches,
  so build each supported OS/architecture/backend target. Note:
  `CompilerEndSelect`, not `EndCompilerSelect`.

## Resource cleanup pairs (open ↔ free)

| Acquire | Release |
|---|---|
| `OpenFile()` / `ReadFile()` / `CreateFile()` | `CloseFile()` |
| `OpenConsole()` | `CloseConsole()` |
| `LoadImage()` / `CatchImage()` / `CreateImage()` | `FreeImage()` |
| `LoadFont()` | `FreeFont()` |
| `LoadSprite()` / `CatchSprite()` | `FreeSprite()` |
| `LoadSound()` / `CatchSound()` | `FreeSound()` |
| `AllocateMemory()` | `FreeMemory()` |
| `OpenWindow()` | `CloseWindow()` |
| `OpenScreen()` | `CloseScreen()` |
| `RunProgram()` with `#PB_Program_Open` | `CloseProgram()` |

Guard reuse with `IsFile()` / `IsImage()` / `IsSound()` / `IsWindow()`.
Draw with `StartDrawing(...Output())` ↔ `StopDrawing()`.

Release a resource when its ownership ends — closing a secondary window is
not application shutdown, and scattering `End` calls is not a cleanup
strategy. PureBasic frees many resources automatically at process exit;
explicit cleanup matters for lifetimes you manage (files, threads,
connections).

## Naming

- Recommended defaults: procedures `PascalCase`, variables `camelCase`,
  constants `#ALL_CAPS` — follow the target project's existing style when it
  differs.
- Path/file splitting is `…Part()`-suffixed: `GetExtensionPart("a.pb")` →
  `"pb"` (no dot), plus `GetFilePart()`, `GetPathPart()`. `GetExtension()`
  does not exist — search instead of guessing names.
- Integer conversion: `Str(42)` and `Val("42")`. Decimal parsing:
  `ValD("3.5")` for doubles or `ValF("3.5")` for floats. `Val()` returns an
  integer; do not use it to preserve fractional values. Concatenation is `+`.

## Console programs vs GUI

- Console: check `OpenConsole()`'s result before printing, then
  `PrintN(text)`, `line.s = Input()`, `CloseConsole()`. `Input()` is
  legitimate for interactive tools and stdin pipelines; a Windows GUI-format
  executable can still open a console.
- **Do not run GUI, screen/keyboard, or interactive console programs via
  `pb_run`** — they can wait for input until the timeout kills them. Compile
  with `pb_check`; use safe automated noninteractive tests for logic and
  report manual/live checks separately. Compilation alone does not verify UI behavior.
- Game loop shape: `InitSprite()` (+ `InitKeyboard()`), `OpenScreen()`,
  `Repeat … FlipBuffers() … Until quit`, then `CloseScreen()` and free
  sprites. `ElapsedMilliseconds()` for timing, `Delay(ms)` to sleep.

## Verification discipline

- Check each coherent edit batch with `pb_check`; fix compilation errors
  before running. If a check fails because the project reaches outside the
  staged root, widen `projectRoot` (see the tooling reference) rather than
  changing production includes to machine-specific absolute paths.
- Use `pb_run` only for bounded, noninteractive console tests. Record the
  actual output and exit status, not just the intended result.
- Run development and test builds under the debugger: it reports invalid
  memory access and array/string misuse that release builds may silently
  corrupt. Debugger diagnostics do not replace release-mode input validation
  and error returns.
- Never label an unavailable or failed check as verified.
