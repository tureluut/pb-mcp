; ---------------------------------------------------------------------------
; docs_index.pb - docs index consumption: load + keyword search + command
; lookup + did-you-mean.
;
; The
; index schema is FROZEN; the JSON is produced by
; tools/build-online-index.mjs and reaches the server one of two ways:
; dropped as index*.json next to the executable (keeps the exe small, makes
; switching PureBasic help versions a file copy) or baked into the binary
; via the DataSection below (self-contained build). The algorithms are
; frozen - scoring values, tie-breaking and thresholds are ranking-
; critical (agent-visible), so no "improvements" here (plan section 7).
;
;   load       resolution order: PUREBASIC_MCP_INDEX env -> newest
;              index*.json next to the executable by mtime -> the
;              DataSection-embedded index (src/pbdocs-index.json) ->
;              newest index-*.json in the cache dir; never
;              throws. An index with zero commands (the committed
;              placeholder) is reported as "no index" with an actionable
;              hint instead of a working-but-empty docs tool.
;   search     tokenize (lowercase, split on non [a-z0-9_$#]); name-first
;              scoring 100/80/60/40/30/20 for commands, 90/70/50/30 for
;              reference pages; library filter excludes reference; sort
;              score desc, then name (localeCompare approximated by
;              case-insensitive compare), then original order (stable).
;   lookup     byName map is lowercase -> command index; levenshtein DP;
;              similarity = 1 - dist/maxLen (+0.2 containment bonus, cap 1);
;              suggestions: score > 0.3, top 5. Reference pages resolve by
;              exact lowercase title/id (0.3.1) - the index carries their
;              file path, so the answer is the full-text URL locator.
;
;   #DOCS_URL_BASE$ + index reference "file" = online full-text URL
;              (file values are repo-relative like "reference/foo.html").
;
; Index parse cost is the measured 214.8 ms one-time LoadJSON on the 1.9 MB
; file (RESULTS-6.40.md) - lazy on first docs tool use, process-lifetime
; cache.
;
; Normalized search records (lowercased fields, flattened
; parameters) are built once per process after index validation; DocsSearch
; scores them with no JSON traversal and no per-request LCase. Scoring
; values, tie-breaking and every emitted string are unchanged - golden
; sessions are the regression gate.
;
; Source-encoding rule: UTF-8 WITH BOM (see console.pb header).
; ---------------------------------------------------------------------------
EnableExplicit

; --- embedded index (DataSection) ------------------------------------------
; tools/build-online-index.mjs writes the JSON; copying its output over
; src/pbdocs-index.json and rebuilding bakes it into the binary. The
; committed placeholder is an empty-but-valid index so the build never
; depends on a generated artifact. CatchJSON() reads the raw UTF-8 bytes.
DataSection
EmbedIndexStart:
  IncludeBinary "pbdocs-index.json"
EmbedIndexEnd:
EndDataSection

Global gIndexReady.i  = #False   ; load attempted (idempotent init)
Global gIndexJson.i   = 0        ; parsed index doc (never freed - cache)
Global gIndexOk.i     = #False
Global gIndexDetail$  = ""
Global gIndexPath$    = ""
Global gCmdCount.i    = 0
Global gRefCount.i    = 0
; pb_version surface (0.3.0): the index root's purebasicVersion/generatedAt
; members, captured at load - the "which help version am I answering from"
; answer. Empty on any failed/absent index.
Global gIndexPbVersion$  = ""
Global gIndexGeneratedAt$ = ""
Global gIndexBytes.i   = 0        ; index size in bytes (embedded: data-section span)
Global NewMap gByName.i()        ; lowercase command name -> commands[] index
; Base URL for reference-page full text (0.3.1): #DOCS_URL_BASE$ + file.
#DOCS_URL_BASE$ = "https://www.purebasic.com/documentation/"

; --- S1 diagnostics: stderr-only timing, inert unless PBMCP_DOCS_TIMING=1 ---
; ConsoleError() writes verbatim (message + newline) to stderr; the JSON-RPC
; layer only ever writes stdout, so these lines cannot corrupt MCP traffic.
; Flag off the only cost is one cached integer compare per docs operation.
Global gDocsTiming.i = -1        ; -1 = unprobed, else 0/1
Global gIndexLoadMs.i = 0        ; LoadJSON wall time (DocsIndexInit)
Global gIndexRecsMs.i = 0        ; record-build wall time (DocsIndexInit)

Procedure.i DocsTimingOn()
  If gDocsTiming = -1            ; probe the env exactly once
    gDocsTiming = Bool(GetEnvironmentVariable("PBMCP_DOCS_TIMING") = "1")
  EndIf
  ProcedureReturn gDocsTiming
EndProcedure

; --- accessors --------------------------------------------------------------
Procedure.i DocsIndexOk()
  ProcedureReturn gIndexOk
EndProcedure

Procedure.s DocsIndexDetail()
  ProcedureReturn gIndexDetail$
EndProcedure

; pb_version accessors (raw reads - callers run DocsIndexEnsure first).
Procedure.s DocsIndexPath()
  ProcedureReturn gIndexPath$
EndProcedure

Procedure.s DocsIndexPbVersion()
  ProcedureReturn gIndexPbVersion$
EndProcedure

Procedure.s DocsIndexGeneratedAt()
  ProcedureReturn gIndexGeneratedAt$
EndProcedure

Procedure.i DocsCommandCount()
  ProcedureReturn gCmdCount
EndProcedure

Procedure.i DocsReferenceCount()
  ProcedureReturn gRefCount
EndProcedure

; JSON array of commands (or 0 when the index is missing/invalid)
Procedure.i DocsIndexCommands()
  If gIndexJson = 0 : ProcedureReturn 0 : EndIf
  ProcedureReturn GetJSONMember(JSONValue(gIndexJson), "commands")
EndProcedure

Procedure.i DocsIndexReference()
  If gIndexJson = 0 : ProcedureReturn 0 : EndIf
  ProcedureReturn GetJSONMember(JSONValue(gIndexJson), "reference")
EndProcedure

; --- process-lifetime normalized search records -----------------------------
; Built once at the end of a successful DocsIndexInit: lowercased fields the
; warm search path scores with no JSON traversal and no per-request LCase.
; The JSON document stays in memory (pb_command needs the full entries);
; DocsSearch fetches original-case display fields from it for the winners
; only. Plain struct members + one flat parameter pair: parameters vary per
; command (embedding arrays/lists would mean ~1774 per-element ReDims at
; build), and the paramOfs/paramCnt split keeps name/description as separate
; fields - required by the golden sessions (no substring matches across field
; boundaries).
; A Map would not do here: the scan must visit entries in original index
; order (stable ord tie-break) and substring matching cannot use keys.
Structure DocsCmdRecT
  nameLc.s
  libLc.s
  descLc.s
  paramOfs.i                 ; first slot in gParamNameLc$()/gParamDescLc$()
  paramCnt.i                 ; 0 = command without parameters
EndStructure

Structure DocsRefRecT
  titleLc.s
  idLc.s
  summaryLc.s
EndStructure

Global Dim gCmdRecs.DocsCmdRecT(0)
Global Dim gRefRecs.DocsRefRecT(0)
Global Dim gParamNameLc$(0)
Global Dim gParamDescLc$(0)
Global gRecsReady.i = #False

; Fill the records from the validated index (called from DocsIndexInit only).
Procedure DocsRecsBuild()
  If gRecsReady : ProcedureReturn : EndIf
  gRecsReady = #True
  Protected cmds.i = DocsIndexCommands()
  Protected refs.i = DocsIndexReference()
  Protected i.i, e.i, k.i, params.i, p.i, nParams.i, n.i
  n = gCmdCount : If n < 1 : n = 1 : EndIf
  ReDim gCmdRecs.DocsCmdRecT(n - 1)
  Protected capParams.i = 1024
  ReDim gParamNameLc$(capParams - 1)
  ReDim gParamDescLc$(capParams - 1)
  Protected paramTotal.i = 0
  For i = 0 To gCmdCount - 1
    e = GetJSONElement(cmds, i)
    gCmdRecs(i)\nameLc = LCase(MemberStr(e, "name", ""))
    gCmdRecs(i)\libLc = LCase(MemberStr(e, "library", ""))
    gCmdRecs(i)\descLc = LCase(MemberStr(e, "description", ""))
    gCmdRecs(i)\paramOfs = paramTotal
    gCmdRecs(i)\paramCnt = 0
    params = GetJSONMember(e, "parameters")
    If params And JSONType(params) = #PB_JSON_Array
      nParams = JSONArraySize(params)
      If nParams > 0
        If paramTotal + nParams > capParams
          capParams = paramTotal + nParams + 512
          ReDim gParamNameLc$(capParams - 1)
          ReDim gParamDescLc$(capParams - 1)
        EndIf
        For k = 0 To nParams - 1
          p = GetJSONElement(params, k)
          gParamNameLc$(paramTotal) = LCase(MemberStr(p, "name", ""))
          gParamDescLc$(paramTotal) = LCase(MemberStr(p, "description", ""))
          paramTotal + 1
        Next
        gCmdRecs(i)\paramCnt = nParams
      EndIf
    EndIf
  Next
  n = gRefCount : If n < 1 : n = 1 : EndIf
  ReDim gRefRecs.DocsRefRecT(n - 1)
  If refs
    For i = 0 To gRefCount - 1
      e = GetJSONElement(refs, i)
      gRefRecs(i)\titleLc = LCase(MemberStr(e, "title", ""))
      gRefRecs(i)\idLc = LCase(MemberStr(e, "id", ""))
      gRefRecs(i)\summaryLc = LCase(MemberStr(e, "summary", ""))
    Next
  EndIf
EndProcedure

; Exe directory - the drop-in slot for index*.json next to the binary.
Procedure.s DocsExeDir()
  ProcedureReturn GetPathPart(ProgramFilename())
EndProcedure

; Newest index-*.json in a dir by mtime, or ""
Procedure.s DocsFindNewestIndex(Dir$)
  Protected best$ = "", bestDate.i = 0
  Protected h.i = ExamineDirectory(#PB_Any, Dir$, "index-*.json")
  If h = 0 : ProcedureReturn "" : EndIf
  While NextDirectoryEntry(h)
    If DirectoryEntryType(h) = #PB_DirectoryEntry_File
      Protected d.i = DirectoryEntryDate(h, #PB_Date_Modified)
      If best$ = "" Or d > bestDate
        bestDate = d
        best$ = PathJoin(Dir$, DirectoryEntryName(h))
      EndIf
    EndIf
  Wend
  FinishDirectory(h)
  ProcedureReturn best$
EndProcedure

; Load the index: env pin first, then a drop-in file next to the executable,
; then the DataSection-embedded copy, then the cache dir. Never
; throws - gIndexDetail$ always carries an actionable message.
Procedure DocsIndexInit()
  If gIndexReady : ProcedureReturn : EndIf
  gIndexReady = #True

  Protected path$ = ""
  Protected embedded.i = #False
  Protected env$ = GetEnvironmentVariable("PUREBASIC_MCP_INDEX")
  If env$ <> ""
    If FileSize(env$) = -1
      gIndexDetail$ = "PUREBASIC_MCP_INDEX points at a missing file: " + env$
      ProcedureReturn
    EndIf
    path$ = env$
  Else
    path$ = DocsFindNewestIndex(DocsExeDir())
    If path$ = "" : embedded = #True : EndIf
  EndIf

  Protected tLoad.i
  Protected j.i
  If DocsTimingOn() : tLoad = ElapsedMilliseconds() : EndIf
  If embedded
    j = CatchJSON(#PB_Any, ?EmbedIndexStart, ?EmbedIndexEnd - ?EmbedIndexStart)
    path$ = "the embedded index (src/pbdocs-index.json)"
  Else
    j = LoadJSON(#PB_Any, path$)
  EndIf
  If DocsTimingOn() : gIndexLoadMs = ElapsedMilliseconds() - tLoad : EndIf
  If j = 0
    gIndexDetail$ = "Index " + path$ + " is not valid JSON: " + JSONErrorMessage() + " (line " + Str(JSONErrorLine()) + ")"
    ProcedureReturn
  EndIf

  Protected root.i = JSONValue(j)
  Protected cmds.i = GetJSONMember(root, "commands")
  Protected refs.i = GetJSONMember(root, "reference")
  If cmds = 0 Or JSONType(cmds) <> #PB_JSON_Array Or refs = 0 Or JSONType(refs) <> #PB_JSON_Array
    FreeJSON(j)
    gIndexDetail$ = "Index " + path$ + " failed schema validation: commands/reference arrays missing"
    ProcedureReturn
  EndIf

  ; byName map: lowercase name -> index; duplicates overwrite, so the LAST
  ; entry wins.
  gCmdCount = JSONArraySize(cmds)
  gRefCount = JSONArraySize(refs)
  If gCmdCount = 0
    ; The committed placeholder (or an index built from an empty tree):
    ; report as no-index with the build hint instead of a working-but-empty
    ; docs tool - the tool-level missing-index UX keys off gIndexOk.
    FreeJSON(j)
    gIndexDetail$ = "Docs index has no commands - build one: node tools/build-online-index.mjs <docsRoot> --out pbdocs-index.json (drop index-*.json next to the executable to switch help versions)"
    ProcedureReturn
  EndIf
  ClearMap(gByName())
  Protected i.i, e.i
  For i = 0 To gCmdCount - 1
    e = GetJSONElement(cmds, i)
    gByName(LCase(GetJSONString(GetJSONMember(e, "name")))) = i
  Next

  gIndexJson = j
  gIndexPath$ = path$
  If embedded
    gIndexBytes = ?EmbedIndexEnd - ?EmbedIndexStart
  Else
    gIndexBytes = FileSize(path$)
  EndIf
  gIndexOk = #True
  gIndexPbVersion$ = MemberStr(root, "purebasicVersion", "?")
  gIndexGeneratedAt$ = MemberStr(root, "generatedAt", "")
  gIndexDetail$ = "Loaded " + Str(gCmdCount) + " commands, " + Str(gRefCount) + " reference pages (PB " + MemberStr(root, "purebasicVersion", "?") + ") from " + path$
  ; Build the normalized search records once, inside the measured load.
  Protected tRecs.i
  If DocsTimingOn() : tRecs = ElapsedMilliseconds() : EndIf
  DocsRecsBuild()
  If DocsTimingOn() : gIndexRecsMs = ElapsedMilliseconds() - tRecs : EndIf
  ; S1: one stderr line per process after a successful load (failure paths
  ; carry their own gIndexDetail$ message instead).
  If DocsTimingOn()
    Protected bytes.i = gIndexBytes
    ConsoleError("[timing] index path=" + gIndexPath$ + " bytes=" + Str(bytes) + " cmds=" + Str(gCmdCount) + " refs=" + Str(gRefCount) + " load=" + Str(gIndexLoadMs) + "ms recs=" + Str(gIndexRecsMs) + "ms")
  EndIf
EndProcedure

; ---------------------------------------------------------------------------
; Background-thread index preload.
;
; Goal: the first docs call in a fresh serve process lands warm (~1 ms)
; instead of paying the ~207 ms LoadJSON, by overlapping the load with the
; client's handshake/think time. Synchronization is WaitThread() only: the
; worker writes every index global (gIndex*, gByName(), the records)
; strictly before it ends, and no thread reads them until DocsIndexEnsure()'
; s WaitThread returns - no mutex. PBMCP_PRELOAD=0 restores today's lazy
; path byte for byte (runtime kill-switch).
;
; DEFAULT depends on the runtime, not the OS: overlapping the worker's PB
; runtime calls (LoadJSON's ~215 ms parse, map inserts, DocsRecsBuild()'s
; ReDim + ~5800 LCase allocations) with main-thread runtime use in the
; request loop is only legal under a thread-safe runtime. The Windows build
; (build.cmd) deliberately compiles WITHOUT /THREAD, and there the overlap
; corrupted the heap: the process died mid-session with 0xC0000005 /
; 0xC0000354 in ~8-15% of docs-call sessions - reproduced 2/24 piped
; sessions, PBMCP_PRELOAD=0 24/24 clean (2026-11-06). A non-TS build
; therefore defaults the preload OFF (lazy first-docs-call load, the
; already-tested path - the WaitThread join itself was never the hazard;
; the concurrent parse window starting at CreateThread was, and no race-
; free worker restructure keeps a useful preload). A /THREAD build (Linux
; --thread, REQUIRED there) keeps the warm preload default.
;
; Never-worse rule: a docs call arriving before the load finishes blocks on
; the same worker, then DocsIndexInit() no-ops via gIndexReady - exactly the
; lazy path's latency. DocsPreloadStart() is serve-mode only (main.pb, after
; OpenConsole()); test/index/scan modes keep lazy init. Output-preserving:
; preload changes WHEN DocsIndexInit() runs, not what it emits (under
; PBMCP_DOCS_TIMING=1 the one [timing] index stderr line moves to startup;
; stdout is never touched by the worker).
; ---------------------------------------------------------------------------
Global gPreloadOn.i = -1         ; -1 = unprobed; else 0 (off) / 1 (on)
Global gPreloadThread.i = 0      ; CreateThread handle while running

; Probe PBMCP_PRELOAD exactly once:
;   "0"    -> off on every build (runtime kill-switch, unchanged)
;   "1"    -> on on every build (explicit opt-in; known heap-corruption
;             hazard on a non-TS runtime - see the section comment above)
;   absent -> on only under a thread-safe runtime (#PB_Compiler_Thread);
;             a non-TS build takes the lazy path by default.
Procedure.i DocsPreloadOn()
  If gPreloadOn = -1
    CompilerIf #PB_Compiler_Thread
      gPreloadOn = Bool(GetEnvironmentVariable("PBMCP_PRELOAD") <> "0")
    CompilerElse
      gPreloadOn = Bool(GetEnvironmentVariable("PBMCP_PRELOAD") = "1")
    CompilerEndIf
  EndIf
  ProcedureReturn gPreloadOn
EndProcedure

; Worker body: run the one-shot lazy init in the background; that is all.
; Never writes stdout. Unused parameter is the CreateThread contract
; ("must take one parameter and cannot return anything").
Procedure DocsPreloadThread(P.i)
  DocsIndexInit()
EndProcedure

; Serve entry hook: start the worker once. A failed CreateThread simply
; leaves gPreloadThread at 0 -> DocsIndexEnsure() stays on the lazy path.
Procedure DocsPreloadStart()
  If DocsPreloadOn() = 0 : ProcedureReturn : EndIf
  gPreloadThread = CreateThread(@DocsPreloadThread(), 0)
EndProcedure

; Shutdown hook (0.3.0): wait for the one-shot worker before process
; teardown. Without this, a serve session that ends before ANY docs call
; (the common test-runner shape, and short-lived clients) tears the process
; down mid-DocsIndexInit and dies with 0xC0000005 - reproduced 35/40 quick
; sessions; DocsIndexEnsure() only waits when a docs tool was actually
; called, so the wait must also live on the exit path. Bounded: the worker
; is one LoadJSON (~200 ms) plus the record build. Same idempotent
; wait-and-zero as DocsIndexEnsure().
Procedure DocsPreloadStop()
  If gPreloadThread
    WaitThread(gPreloadThread)
    gPreloadThread = 0
  EndIf
EndProcedure

; Serve-path gate for every docs entry point: block until the preload
; worker is done (immediate once it finished or was never started), then
; run the idempotent init (no-op via gIndexReady when the worker already
; did the work - identical outcome to today's direct DocsIndexInit()).
Procedure DocsIndexEnsure()
  If gPreloadThread
    WaitThread(gPreloadThread)
    gPreloadThread = 0
  EndIf
  DocsIndexInit()
EndProcedure

; ---------------------------------------------------------------------------
; search
; ---------------------------------------------------------------------------
Structure HitT
  name.s
  library.s
  summary.s
  ref.i      ; reference page flag
  score.i
  ord.i      ; original position - the stable-sort tiebreaker
  idx.i      ; entry index, for the deferred display-field fetch
EndStructure

; tokenize(query): lowercase, split on runs of non [a-z0-9_$#], drop empties.
Procedure DocsTokenize(Query$, List tokens$())
  ClearList(tokens$())
  Protected s$ = LCase(Query$)
  Protected cur$ = "", i.i, c$
  For i = 1 To Len(s$)
    c$ = Mid(s$, i, 1)
    If (c$ >= "a" And c$ <= "z") Or (c$ >= "0" And c$ <= "9") Or c$ = "_" Or c$ = "$" Or c$ = "#"
      cur$ + c$
    ElseIf cur$ <> ""
      AddElement(tokens$())
      tokens$() = cur$
      cur$ = ""
    EndIf
  Next
  If cur$ <> ""
    AddElement(tokens$())
    tokens$() = cur$
  EndIf
EndProcedure

; scoreCommandToken verbatim: name 100/80/60, library 40, description 30,
; parameter text 20. The lowercased name/library/description come from
; the normalized command record (identical values to the old per-request
; LCase fetches) and the parameter fallback reads the flat
; per-field arrays in the same JSON order - comparisons, first-match
; precedence and every score value unchanged.
Procedure.i DocsScoreCommandToken(Cmd.i, Token$)
  If gCmdRecs(Cmd)\nameLc = Token$ : ProcedureReturn 100 : EndIf
  If Left(gCmdRecs(Cmd)\nameLc, Len(Token$)) = Token$ : ProcedureReturn 80 : EndIf
  If FindString(gCmdRecs(Cmd)\nameLc, Token$, 1) > 0 : ProcedureReturn 60 : EndIf
  If gCmdRecs(Cmd)\libLc = Token$ : ProcedureReturn 40 : EndIf
  If FindString(gCmdRecs(Cmd)\descLc, Token$, 1) > 0 : ProcedureReturn 30 : EndIf
  Protected k.i, last.i = gCmdRecs(Cmd)\paramOfs + gCmdRecs(Cmd)\paramCnt - 1
  For k = gCmdRecs(Cmd)\paramOfs To last
    If FindString(gParamNameLc$(k), Token$, 1) > 0 : ProcedureReturn 20 : EndIf
    If FindString(gParamDescLc$(k), Token$, 1) > 0 : ProcedureReturn 20 : EndIf
  Next
  ProcedureReturn 0
EndProcedure

; scoreReferenceToken verbatim: title/id 90/70/50, summary 30. Lowercased
; title/id/summary arrive precomputed from DocsSearch - no
; JSON fetch left in here, comparisons unchanged.
Procedure.i DocsScoreReferenceToken(Token$, TitleLc$, IdLc$, SummaryLc$)
  If TitleLc$ = Token$ Or IdLc$ = Token$ : ProcedureReturn 90 : EndIf
  If Left(TitleLc$, Len(Token$)) = Token$ Or Left(IdLc$, Len(Token$)) = Token$ : ProcedureReturn 70 : EndIf
  If FindString(TitleLc$, Token$, 1) > 0 Or FindString(IdLc$, Token$, 1) > 0 : ProcedureReturn 50 : EndIf
  If FindString(SummaryLc$, Token$, 1) > 0 : ProcedureReturn 30 : EndIf
  ProcedureReturn 0
EndProcedure

; Sort comparator: score desc, then name (localeCompare approximated by
; case-insensitive compare, then raw compare), then original order - which
; makes the sort stable like ES2019+ Array.sort.
Procedure.i DocsHitBefore(*a.HitT, *b.HitT)
  If *a\score <> *b\score
    ProcedureReturn Bool(*a\score > *b\score)
  EndIf
  Protected la$ = LCase(*a\name), lb$ = LCase(*b\name)
  If la$ <> lb$ : ProcedureReturn Bool(la$ < lb$) : EndIf
  ProcedureReturn Bool(*a\ord < *b\ord)
EndProcedure

; Stable bottom-up merge sort over the hits array (arrays, not lists, so the
; comparator can run both directions without list cursors).
Procedure DocsMergeSort(Array hits.HitT(1), n.i)
  Protected Dim tmp.HitT(n - 1)
  Protected width.i, lo.i, mid.i, hi.i, a.i, b.i, k.i
  width = 1
  While width < n
    lo = 0
    While lo < n
      mid = lo + width : If mid > n : mid = n : EndIf
      hi = lo + width * 2 : If hi > n : hi = n : EndIf
      a = lo : b = mid
      For k = lo To hi - 1
        If a < mid And (b >= hi Or DocsHitBefore(@hits(a), @hits(b)))
          tmp(k) = hits(a) : a + 1
        Else
          tmp(k) = hits(b) : b + 1
        EndIf
      Next
      lo + width * 2
    Wend
    For k = 0 To n - 1 : hits(k) = tmp(k) : Next
    width * 2
  Wend
EndProcedure

; searchCommands verbatim. LibraryFilter$ "" = off; Limit clamped 1..25 with
; default 10 (0/absent = default). Hits are appended to Hits() in ranked
; order, capped at the limit.
Procedure DocsSearch(Query$, LibraryFilter$, Limit.i, List Hits.HitT())
  ; S1 diagnostics: when PBMCP_DOCS_TIMING=1, bracket tokenize / command scan /
  ; reference scan / sort / materialize and emit one stderr line after the call.
  Protected timing.i = DocsTimingOn()
  Protected tStart.i, tMark.i
  Protected msTok.i, msCmd.i, msRef.i, msSort.i, msMat.i, msTotal.i
  If timing : tStart = ElapsedMilliseconds() : tMark = tStart : EndIf
  ClearList(Hits())
  NewList tokens$()
  DocsTokenize(Query$, tokens$())
  If ListSize(tokens$()) = 0
    If timing
      msTok = ElapsedMilliseconds() - tMark   ; empty scan floor: total = tokenize
      ConsoleError("[timing] q=" + Query$ + " matches=0 shown=0 tokenize=" + Str(msTok) + " scan=0 sort=0 mat=0 total=" + Str(msTok) + "ms")
    EndIf
    ProcedureReturn
  EndIf
  If timing : msTok = ElapsedMilliseconds() - tMark : tMark = ElapsedMilliseconds() : EndIf
  If Limit <= 0 : Limit = 10 : EndIf            ; DEFAULT_SEARCH_LIMIT
  If Limit > 25 : Limit = 25 : EndIf            ; MAX_SEARCH_LIMIT
  Protected lib$ = ""
  If Trim(LibraryFilter$) <> "" : lib$ = LCase(Trim(LibraryFilter$)) : EndIf

  ; Materialization variant: a hit can be appended at most
  ; once per index entry, so size ranked once for commands + reference
  ; instead of ReDim-growing it per hit (a struct ReDim reallocates AND
  ; copies the whole array each time). gRefCount is 0 whenever reference
  ; pages are absent and both counts are 0 without a loaded index - clamp
  ; the dimension at 1 because Dim n(0) is the one-element array.
  Protected maxHits.i = gCmdCount + gRefCount
  If maxHits < 1 : maxHits = 1 : EndIf
  Protected Dim ranked.HitT(maxHits - 1)
  Protected cnt.i = 0
  Protected i.i, k.i, score.i

  ; Score the normalized records - no JSON traversal, no LCase in these
  ; loops (the S1-measured dominant term). ranked\name holds the cached
  ; LOWERCASE name: the comparator's LCase() is idempotent, so the tie order
  ; is unchanged; display fields are fetched for the winners only, below.
  For i = 0 To gCmdCount - 1
    If lib$ <> "" And gCmdRecs(i)\libLc <> lib$ : Continue : EndIf
    score = 0
    ResetList(tokens$())
    While NextElement(tokens$())
      score + DocsScoreCommandToken(i, tokens$())
    Wend
    If score > 0
      ranked(cnt)\name = gCmdRecs(i)\nameLc
      ranked(cnt)\ref = #False
      ranked(cnt)\score = score
      ranked(cnt)\ord = cnt
      ranked(cnt)\idx = i
      cnt + 1
    EndIf
  Next
  If timing : msCmd = ElapsedMilliseconds() - tMark : tMark = ElapsedMilliseconds() : EndIf

  If lib$ = "" And gRefCount > 0
    For i = 0 To gRefCount - 1
      score = 0
      ResetList(tokens$())
      While NextElement(tokens$())
        score + DocsScoreReferenceToken(tokens$(), gRefRecs(i)\titleLc, gRefRecs(i)\idLc, gRefRecs(i)\summaryLc)
      Wend
      If score > 0
        ranked(cnt)\name = gRefRecs(i)\titleLc
        ranked(cnt)\library = "reference"
        ranked(cnt)\ref = #True
        ranked(cnt)\score = score
        ranked(cnt)\ord = cnt
        ranked(cnt)\idx = i
        cnt + 1
      EndIf
    Next
  EndIf
  If timing : msRef = ElapsedMilliseconds() - tMark : tMark = ElapsedMilliseconds() : EndIf

  If cnt > 1 : DocsMergeSort(ranked(), cnt) : EndIf
  If timing : msSort = ElapsedMilliseconds() - tMark : tMark = ElapsedMilliseconds() : EndIf
  Protected shown.i = cnt
  If shown > Limit : shown = Limit : EndIf
  ; Fetch original-case display fields from the retained JSON doc for
  ; the winners only - the same MemberStr expressions the old per-match path
  ; used, so Hits() carries byte-identical strings. cmds/refs are guaranteed
  ; non-zero here: a hit exists only when its section had entries.
  Protected cmds.i = DocsIndexCommands()
  Protected refs.i = DocsIndexReference()
  Protected e.i
  ClearList(Hits())
  For k = 0 To shown - 1
    AddElement(Hits())
    If ranked(k)\ref
      e = GetJSONElement(refs, ranked(k)\idx)
      Hits()\name = MemberStr(e, "title", "")
      Hits()\library = "reference"
      Hits()\summary = MemberStr(e, "summary", "")
      Hits()\ref = #True
    Else
      e = GetJSONElement(cmds, ranked(k)\idx)
      Hits()\name = MemberStr(e, "name", "")
      Hits()\library = MemberStr(e, "library", "")
      Hits()\summary = MemberStr(e, "description", "")
      Hits()\ref = #False
    EndIf
    Hits()\score = ranked(k)\score
    Hits()\ord = ranked(k)\ord
    Hits()\idx = ranked(k)\idx
  Next
  If timing
    msMat = ElapsedMilliseconds() - tMark
    msTotal = ElapsedMilliseconds() - tStart
    ConsoleError("[timing] q=" + Query$ + " matches=" + Str(cnt) + " shown=" + Str(shown) + " tokenize=" + Str(msTok) + " scan=" + Str(msCmd + msRef) + " sort=" + Str(msSort) + " mat=" + Str(msMat) + " total=" + Str(msTotal) + "ms")
  EndIf
EndProcedure

; ---------------------------------------------------------------------------
; lookup
; ---------------------------------------------------------------------------
; Case-insensitive exact command lookup, 0 when unknown (= findCommand).
Procedure.i DocsFindCommand(Name$)
  DocsIndexEnsure()
  If Not gIndexOk : ProcedureReturn 0 : EndIf
  Protected key$ = LCase(Trim(Name$))
  If FindMapElement(gByName(), key$) = 0 : ProcedureReturn 0 : EndIf
  ProcedureReturn GetJSONElement(DocsIndexCommands(), gByName(key$))
EndProcedure

; Reference-page lookup (0.3.1): case-insensitive exact match on title or
; id, 0 when unknown (same contract as DocsFindCommand). A trailing
; " (reference)" on the query is stripped first - pb_docs_search renders
; reference hits as "Title (reference) [reference]" and agents copy that
; display form into pb_command verbatim (found live 2026-10-11). Linear
; scan: 103 titles, cold path, no map warranted.
Procedure.i DocsFindReference(Name$)
  DocsIndexEnsure()
  If Not gIndexOk : ProcedureReturn 0 : EndIf
  Protected key$ = LCase(Trim(Name$))
  Protected suffix$ = " (reference)"
  If Len(key$) > Len(suffix$) And Right(key$, Len(suffix$)) = suffix$
    key$ = Trim(Left(key$, Len(key$) - Len(suffix$)))
  EndIf
  If key$ = "" : ProcedureReturn 0 : EndIf
  Protected i.i
  For i = 0 To gRefCount - 1
    If gRefRecs(i)\titleLc = key$ Or gRefRecs(i)\idLc = key$
      ProcedureReturn GetJSONElement(DocsIndexReference(), i)
    EndIf
  Next
  ProcedureReturn 0
EndProcedure

; DP scratch reused across calls (same single-writer discipline as
; gCmdRecs: the request path runs strictly after DocsIndexEnsure()'s
; WaitThread, so nothing can touch these concurrently). Procedure-local
; Dim would allocate + zero three arrays per candidate - the dominant
; churn left after the Mid$ removal. Grown on demand; never shrinks.
Global Dim gLevPrev.i(0)
Global Dim gLevCurr.i(0)
Global Dim gLevBc.i(0)
Global gLevCap.i = 0             ; current Dim of the three arrays

; Minimal edit distance (iterative DP) - levenshtein verbatim. Code-unit
; compares via PeekU (same idiom as JsonEscape: @string + (n-1)*SizeOf
; (Character) is the char data in this Unicode build) instead of two Mid$
; allocations per DP cell - identical distances, no string churn.
Procedure.i DocsLevenshtein(a$, b$)
  If a$ = b$ : ProcedureReturn 0 : EndIf
  Protected la.i = Len(a$), lb.i = Len(b$)
  If la = 0 : ProcedureReturn lb : EndIf
  If lb = 0 : ProcedureReturn la : EndIf
  If lb > gLevCap                     ; grow once per new max length
    ReDim gLevPrev.i(lb)
    ReDim gLevCurr.i(lb)
    ReDim gLevBc.i(lb)
    gLevCap = lb
  EndIf
  ; prefetch b$'s code units once - the DP body then compares integers only
  Protected j.i, i.i
  For j = 1 To lb
    gLevBc(j) = PeekU(@b$ + (j - 1) * SizeOf(Character))
  Next
  For j = 0 To lb : gLevPrev(j) = j : Next
  For i = 1 To la
    gLevCurr(0) = i
    Protected ac.i = PeekU(@a$ + (i - 1) * SizeOf(Character))  ; a$'s row unit, cached once
    For j = 1 To lb
      Protected cost.i = 1
      If ac = gLevBc(j) : cost = 0 : EndIf
      Protected v1.i = gLevPrev(j) + 1
      Protected v2.i = gLevCurr(j - 1) + 1
      Protected v3.i = gLevPrev(j - 1) + cost
      If v2 < v1 : v1 = v2 : EndIf
      If v3 < v1 : v1 = v3 : EndIf
      gLevCurr(j) = v1
    Next
    CopyArray(gLevCurr(), gLevPrev())
  Next
  ProcedureReturn gLevPrev(lb)
EndProcedure

; Similarity in [0,1]: 1 - dist/maxLen, +0.2 containment bonus, cap 1.
; Doubles (.d) throughout - the 0.3 threshold comparison must match JS.
; Both inputs arrive pre-lowercased (DocsSimilarNames lowercases the query
; once per scan instead of two LCase allocations per candidate).
Procedure.d DocsNameSimilarityLc(qLc$, cLc$)
  If qLc$ = cLc$ : ProcedureReturn 1.0 : EndIf
  Protected dist.i = DocsLevenshtein(qLc$, cLc$)
  Protected maxLen.i = Len(qLc$)
  If Len(cLc$) > maxLen : maxLen = Len(cLc$) : EndIf
  Protected score.d = 1.0 - dist / maxLen
  If FindString(cLc$, qLc$, 1) > 0 Or FindString(qLc$, cLc$, 1) > 0 : score + 0.2 : EndIf
  If score > 1.0 : score = 1.0 : EndIf
  ProcedureReturn score
EndProcedure

; Top `limit` names most similar to Name$, best first - similarNames verbatim
; (score > 0.3, sort score desc then name, stable, slice).
Procedure DocsSimilarNames(Name$, Limit.i, List Names$())
  ClearList(Names$())
  DocsIndexEnsure()
  If Not gIndexOk : ProcedureReturn : EndIf
  Protected cmds.i = DocsIndexCommands()
  If cmds = 0 : ProcedureReturn : EndIf
  ; Materialization variant: candidates come from commands
  ; only - size once instead of ReDim per candidate (see DocsSearch).
  Protected maxCands.i = gCmdCount
  If maxCands < 1 : maxCands = 1 : EndIf
  Protected Dim cands.HitT(maxCands - 1)
  Protected qLc$ = LCase(Name$)                ; lowercase the query once
  Protected cnt.i = 0, i.i, score.d
  ; Score the cached lowercased names - no JSON traversal, no LCase in this
  ; loop (same S1 pattern as DocsSearch). cands\name holds the LOWERCASE
  ; name: the comparator's LCase() is idempotent, so the tie order is
  ; unchanged; \idx keeps the entry for the winners-only fetch below.
  For i = 0 To gCmdCount - 1
    score = DocsNameSimilarityLc(qLc$, gCmdRecs(i)\nameLc)
    If score > 0.3
      cands(cnt)\name = gCmdRecs(i)\nameLc
      cands(cnt)\score = Int(score * 1000)   ; 3 decimals: far below the 0.001
      cands(cnt)\ord = cnt                   ; resolution of real distances
      cands(cnt)\idx = i
      cnt + 1
    EndIf
  Next
  ; reuse the hit sort: score desc, name asc, stable
  If cnt > 1 : DocsMergeSort(cands(), cnt) : EndIf
  Protected shown.i = cnt
  If Limit > 0 And shown > Limit : shown = Limit : EndIf
  ; Fetch original-case names from the retained JSON doc for the winners
  ; only (mirrors DocsSearch) - the same MemberStr expression the old
  ; per-candidate path used, so Names$() carries byte-identical strings.
  For i = 0 To shown - 1
    AddElement(Names$())
    Names$() = MemberStr(GetJSONElement(cmds, cands(i)\idx), "name", "")
  Next
EndProcedure
