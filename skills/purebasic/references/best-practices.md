# PureBasic best practices (6.40 baseline)

Thirty reviewed practices grouped by topic. Official documentation defines the
behavior; forum threads corroborate pitfalls but are not independently executed
proof. Read only the section your task needs. This file is documentation-reviewed
guidance, not blanket compiler- or runtime-tested coverage — executed checks are
recorded in [verification.md](verification.md). On later PureBasic versions,
confirm the actual compiler and docs with `pb_version` before applying guidance.

## General

### BP01 — Declare explicitly in main and applicable module scopes

Put `EnableExplicit` at the top of each main source file **and** inside every
`Module`/`DeclareModule` where you want it: a file-level setting is not
inherited by module scopes. Declare each name (`Define`, `Global`,
`Protected`, procedure parameters) with minimal visibility. Reason: without
it, any misspelled name silently compiles as a new integer variable.

### BP02 — Pick types by requirement; parsing is not validation

Use `.i` for pointer-sized integers, `.q` when 64-bit range is required (even
on x86), fixed-width types (`.b`/`.w`/`.l`) for external binary layouts or
APIs, `.f`/`.d` per the required precision and output format, `.s` for
strings. Convert deliberately between integer and decimal (`Val()` vs
`ValD()`/`ValF()`). `Val()`/`ValD()` convert whatever they can and yield 0 on
failure — they are not input validators; check the surrounding format.

### BP03 — Check resource creation; store identifiers; use documented flags

Check the return of every open/create/load/allocate call. With `#PB_Any`,
store the returned identifier and treat `#Null` as failure; with fixed
numbers, keep them as named constants so reuse is visible. Built-in flags
live in the `#PB_…` namespace; application-defined constants are legitimate,
but verify a flag's exact name in the command docs instead of inventing one.

### BP04 — Build each supported target; do not trust inactive branches

Guard OS/architecture/backend differences with `CompilerIf`/`CompilerSelect`
and compile every configuration you claim to support (debugger and release,
each OS, each backend). Inactive branches are removed and not validated by
the current build — one successful compile proves only the branches it
selected. Make no cross-version/OS/backend verification claims you have not
run.

Sources (official behavior):

- [Compiler directives](https://www.purebasic.com/documentation/reference/compilerdirectives.html) — `EnableExplicit`, `CompilerIf`/`CompilerSelect`, `#PB_Compiler_Debugger`
- [Compiler functions](https://www.purebasic.com/documentation/reference/compilerfunctions.html) — `ClearStructure`, `#PB_Compiler_*` constants
- [CLI compiler](https://www.purebasic.com/documentation/reference/cli_compiler.html) — thread-safe and other switches

## Modules

### BP05 — Modules for cohesive components, not for everything

Use `DeclareModule`/`Module` for cohesive, reusable components: expose a
small public API as `ModuleName::Procedure` and keep the implementation
private. Modules are a recommendation, not a requirement — a tiny script can
stay flat.

### BP06 — Prefer qualified access at API boundaries

Call across boundaries as `ModuleName::Item`. Use `UseModule` deliberately to
open a module's namespace, and `UnuseModule` to close it again; unqualified
names increase ambiguity when several modules define similar items.

### BP07 — Declare dependency interfaces before use

Declare the `DeclareModule` interface before the `Module` implementation (or
other code) that references it, and keep dependencies simple and preferably
acyclic. Module references resolve at compile time in declaration order — do
not use runtime lookup to bypass ordering problems.

### BP08 — Explicit init/shutdown; module scope is not ownership or thread safety

Module-level statements execute at startup, in program order. For fallible
setup (opening files or databases, allocating resources), prefer explicit
`Module::Init()` / `Module::Shutdown()` procedures with checked returns.
Give every shared module state and resource one owner. Module scope isolates
*names* — not threads and not ownership: a module-level list or map is still
shared mutable state.

Sources (official behavior):

- [Module](https://www.purebasic.com/documentation/reference/module.html) — scope, `::`, imports, execution order, `EnableExplicit` scope

Sources (forum corroboration, not independently executed proof):

- [EnableExplicit and module scope](https://www.purebasic.fr/english/viewtopic.php?t=88017)
- [Module declaration order](https://www.purebasic.fr/english/viewtopic.php?t=87786)

## Strings and files

### BP09 — UTF-8 BOM for non-ASCII source; explicit runtime encoding policy

Save PureBasic source containing non-ASCII text as UTF-8 with BOM (ASCII-only
source is fine as-is). At runtime, define an explicit encoding/BOM policy per
boundary: `ReadFile()` supports per-call encoding flags and `#PB_File_BOM`,
so per-call overrides exist where needed — but do not put BOMs into
JSON/SQL/protocol files just because the source has one. Respect
memory-buffer byte lengths and terminators: byte length is not character
count.

### BP10 — Check file operations; validity predicates are not success checks

Check the return value of every `OpenFile()`/`ReadFile()`/`CreateFile()` and
of the read/write calls themselves, and close files on every path you
control. `IsFile(n)` only tests that the file number is valid and initialized
— not that the last I/O succeeded or that a path exists.

### BP11 — Measure before tuning buffers; flush for a stated boundary only

Change file-buffer sizes only after measuring a real problem. Call
`FlushFileBuffers()` when an explicit visibility/durability boundary calls
for it (checked nonzero result). Flushing is not file locking, not atomic
replacement, and not a per-write requirement.

Sources (official behavior):

- [ReadFile](https://www.purebasic.com/documentation/file/readfile.html) — encoding flags, `#PB_File_BOM`
- [Unicode](https://www.purebasic.com/documentation/reference/unicode.html) — source/runtime encoding model
- [File library](https://www.purebasic.com/documentation/file/index.html)

## Console

### BP12 — Check OpenConsole; pick the executable format per OS

Check `OpenConsole()`'s return before printing — console allocation can fail.
On Windows, the executable format is a deliberate choice: a Console
subsystem build is the natural CLI form, and a GUI-subsystem build can still
open a console. Linux/macOS have no equivalent format restriction.

### BP13 — stdout for results, stderr for diagnostics, intentional exit status

Write results and protocol output to stdout and diagnostics to stderr so
automation can separate them. End with a deliberate status: plain `End` for
success, `End <code>` for failure — console programs commonly return an exit
code.

### BP14 — Match input mode to the use case; never busy-poll

`Input()` is valid for interactive tools and stdin pipelines; nonblocking
`Inkey()`/`RawKey()` polling suits event-style reading, with `RawKey()`
following `Inkey()`. If you poll, add a `Delay()` — do not spin. Provide
bounded noninteractive paths (arguments, files) for automation, and do not
send interactive programs to `pb_run`.

Sources (official behavior):

- [OpenConsole](https://www.purebasic.com/documentation/console/openconsole.html)
- [Inkey](https://www.purebasic.com/documentation/console/inkey.html) — `RawKey()` follows `Inkey()`
- [Console library](https://www.purebasic.com/documentation/console/index.html)

## Memory

### BP15 — Check allocations; keep the old block until realloc succeeds

Validate allocation size and result, and respect byte bounds. A successful
`ReAllocateMemory()` returns a *new* address and the old block must no longer
be used or freed; a failed call returns 0 and leaves the old allocation
valid. Assign the result to a temporary and keep the original pointer until
success. Free each currently owned allocation exactly once — ownership
follows the pointer, not the number of calls.

### BP16 — CopyMemory for disjoint ranges, MoveMemory for overlap

`CopyMemory()` requires nonoverlapping source/destination; use
`MoveMemory()` when ranges overlap. Do not raw-byte-copy structures
containing PB-managed members (strings, lists, maps) — copy field-by-field
or reinitialize the target properly instead.

### BP17 — Pair AllocateStructure/FreeStructure; separate managed from owned

Free structured memory with `FreeStructure()`; it clears PB-managed members
(strings, arrays, lists, maps) automatically. It does not release pointers,
handles, or connections you allocated separately — free those explicitly,
and initialize/clear raw structured memory (`AllocateMemory`) yourself.

Sources (official behavior):

- [ReAllocateMemory](https://www.purebasic.com/documentation/memory/reallocatememory.html)
- [FreeStructure](https://www.purebasic.com/documentation/memory/freestructure.html)
- [Memory library](https://www.purebasic.com/documentation/memory/index.html) — `CopyMemory()`/`MoveMemory()` overlap rules

## Threads

### BP18 — Enable the thread-safe runtime; it does not synchronize your state

Build code that uses threads with the thread-safe runtime (`/THREAD` on
Windows, `--thread` on Linux) and verify the flags of the build you actually
run. Runtime thread safety protects PureBasic internals — your shared
application state still needs your own synchronization.

### BP19 — Synchronize shared data, including collection traversal

Protect shared mutable state with locks, and protect *complete* `ForEach`
traversals of shared lists/maps: a read-only-looking traversal mutates the
shared current-element cursor, so concurrent traversals corrupt each other
even without writes. Do not hold a lock across a blocking call longer than
necessary.

### BP20 — Threaded is per-thread state, not communication

`Threaded` declares thread-local objects in global scope (outside
procedures): each thread gets its own instance. It is not a procedure-local
`Static` replacement, not a shared container, and not a way to inherit
main-thread list/map contents — initialize each thread's containers
deliberately.

### BP21 — Cancel cooperatively; join before freeing

Stop workers through a synchronized flag (protected like any shared state)
and wake blocked workers. Join workers with `WaitThread()` before freeing
their parameters and resources. Do not use `KillThread` or forced suspension
as routine termination.

Sources (official behavior):

- [Thread library](https://www.purebasic.com/documentation/thread/index.html)
- [Threaded](https://www.purebasic.com/documentation/reference/threaded.html)
- [List](https://www.purebasic.com/documentation/list/index.html) / [Map](https://www.purebasic.com/documentation/map/index.html) — current-element cursors

Sources (forum corroboration, not independently executed proof):

- [Concurrent traversal of a shared module-level list](https://www.purebasic.fr/english/viewtopic.php?t=89371)

## Database

### BP22 — Initialize the backend; own the connection

Call the backend initializer (`UseSQLiteDatabase()`, `UsePostgreSQLDatabase()`,
…) before any database use, check `OpenDatabase()`'s result, and close what
you open. Define which thread owns each connection — do not assume a
connection is safe to share.

### BP23 — Bind values; rebind each execution; allowlist identifiers

Bind user data with `SetDatabaseString()`/`SetDatabaseLong()`/… at the
correct zero-based statement index instead of string-building values into the
statement. Placeholder syntax is driver-dependent — check the
`DatabaseQuery()` documentation for your backend's form. Bindings are cleared
after each execution, so rebind before every run. Table/column identifiers
cannot be bound as values — validate or allowlist them.

### BP24 — Check the query, iterate, and always finish it

Check `DatabaseQuery()`'s return before iterating with `NextDatabaseRow()`
(0 means no more rows). Call `FinishDatabaseQuery()` on every exit path after
a successful query — including early exits and aborts.

### BP25 — DatabaseUpdate's return is the success signal

The `DatabaseUpdate()` return value establishes success; zero affected rows
can be a legitimate outcome (nothing matched), so use affected-row counts
only for the operation's intended semantics. Inspect `DatabaseError()`
immediately after a failed `OpenDatabase()`, `DatabaseQuery()`, or
`DatabaseUpdate()`.

### BP26 — Explicit transactions with checked commit and rollback

Use explicit transactions when atomicity or batch writes require them; check
that the transaction start and the commit both succeeded, and roll back on
failure. Transaction SQL is backend-specific — SQLite's `BEGIN`/`COMMIT`
syntax is not a universal API across drivers.

Sources (official behavior):

- [DatabaseQuery](https://www.purebasic.com/documentation/database/databasequery.html) — placeholders and bindings
- [DatabaseUpdate](https://www.purebasic.com/documentation/database/databaseupdate.html) — return value
- [FinishDatabaseQuery](https://www.purebasic.com/documentation/database/finishdatabasequery.html)
- [SQLite: transactions](https://www.sqlite.org/lang_transaction.html) — backend-specific SQL

## GUI

### BP27 — One main dispatcher; no event pumping in callbacks

The normal design is one main `WaitWindowEvent()` loop that routes by
`EventWindow()`/`EventGadget()`. Bound handlers (`BindEvent()`/
`BindGadgetEvent()`) coexist with loop dispatch — but a bound callback must
never pump events: do not call `WindowEvent()`/`WaitWindowEvent()` inside it.

### BP28 — GUI work stays on the main thread; post events with owned payloads

Keep GUI updates on the main thread; keep bound handlers and timers bounded.
Workers report through `PostEvent()` using custom IDs from
`#PB_Event_FirstCustomValue` upward (custom event types from
`#PB_EventType_FirstCustomValue`). Define the payload's lifetime and owner:
`EventData()` carries an integer only — document who frees what and when.

### BP29 — Release at ownership boundaries, not indiscriminately

Release each resource where its ownership ends. Closing a secondary window is
not application shutdown, and scattering `End` calls is not a cleanup
strategy: PureBasic frees many resources automatically at process exit, so
concentrate explicit cleanup on lifetimes you manage (files, threads,
database connections, worker resources).

Sources (official behavior):

- [BindEvent](https://www.purebasic.com/documentation/window/bindevent.html)
- [PostEvent](https://www.purebasic.com/documentation/window/postevent.html) — `#PB_Event_FirstCustomValue`, `EventData()`

## Verification

### BP30 — Debugger during development; runtime checks in release too

Develop and test with the debugger enabled — it reports invalid memory
access, array overruns, and string misuse. Debugger diagnostics do not
replace release-mode behavior: keep input validation, checked error returns,
and runtime tests in release builds. Compilation proves neither execution nor
live GUI behavior; record what was actually verified.

Sources:

- Project: [verification.md](verification.md) — executed 6.40 checks and their exact scope
- Official: [Compiler directives](https://www.purebasic.com/documentation/reference/compilerdirectives.html) — `#PB_Compiler_Debugger`
