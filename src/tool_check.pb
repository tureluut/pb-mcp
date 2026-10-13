; ---------------------------------------------------------------------------
; tool_check.pb - pb_check implementation + the SHARED compiler pipeline.
;
; Compiler-diagnostics parsing, banner filtering, the check/run process
; pipelines, the formatting helpers both compiler tools need (truncation/
; collapse rules) and the pb_check-specific error hints.
;
; File-scope note vs the plan's module table: the docs-side formatting maps
; to tools.pb, but
; its generic string helpers (CapText/OneLine/FirstSentence/CollapseLines) are
; needed by tool_run.pb, which includes this file EARLIER - so they live here,
; at the top of the shared pipeline layer. Same for the process runner and
; temp-copy management: both tools use them, split across tool_check.pb and
; tool_run.pb.
;
; Pipeline semantics (frozen):
;   - the user's source file is NEVER touched: compile a temp-dir copy
;     (5.73 wrote PureBasic.exe next to the source; the temp dir isolates it)
;   - compiler cwd = the temp dir (5.73 drops stray artifacts into cwd)
;   - /CHECK: syntax check only; /CONSOLE /EXE <abs>: build without launching
;     (5.73's plain /CONSOLE auto-launches the program - the orphan that
;     motivated the whole pipeline; verified harmless-but-correct on 6.40)
;   - one retry when the compiler fails WITHOUT a line number (AV file-lock
;     flake: "Error: Assembler / error: write failed.")
;   - timeout kills the whole tree (taskkill /PID x /T /F, no shell)
;   - temp dir always cleaned (retry with backoff; fresh exes are briefly
;     AV-locked); cleanup failure is never surfaced
;
; Source-encoding rule: UTF-8 WITH BOM (see console.pb header).
; ---------------------------------------------------------------------------
EnableExplicit

; ---------------------------------------------------------------------------
; shared formatting helpers
; ---------------------------------------------------------------------------
#SEARCH_CAP        = 8000
#COMMAND_CAP       = 14000
#REMARKS_CAP       = 1200
#EXAMPLE_KEEP_LINES = 20
#CHECK_CAP         = 8000
#RUN_SECTION_CAP   = 10000
#CHECK_TIMEOUT_MS  = 15000
#COMPILE_TIMEOUT_MS = 30000
#DEFAULT_RUN_TIMEOUT_MS = 15000
#MAX_RUN_TIMEOUT_MS = 60000
#MAX_CAPTURE_CHARS = 4194304   ; 4 MB capture guard per stream
#STDERR_SPIN_MS = 5            ; poll flat out this long after a stderr line

; JS String.trim(): PB Trim/LTrim/RTrim accept one character, not a set.
Procedure.s TrimAll(Text$)
  Protected ws$ = " " + Chr(9) + Chr(10) + Chr(13) + Chr(11) + Chr(12)
  ws$ + Chr($A0) + Chr($1680) + Chr($2028) + Chr($2029) + Chr($202F) + Chr($205F) + Chr($3000) + Chr($FEFF)
  Protected i.i
  For i = $2000 To $200A : ws$ + Chr(i) : Next
  Protected first.i = 1, last.i = Len(Text$)
  While first <= last And FindString(ws$, Mid(Text$, first, 1))
    first + 1
  Wend
  While last >= first And FindString(ws$, Mid(Text$, last, 1))
    last - 1
  Wend
  ProcedureReturn Mid(Text$, first, last - first + 1)
EndProcedure

; oneLine whitespace set: space, tab, LF, CR, VT, FF (NOT the JS-trim set of
; TrimAll above). Macro arg is used 6x - only ever pass a plain variable (c$).
Macro IsWsChar(C)
  (C = " " Or C = Chr(9) Or C = Chr(10) Or C = Chr(13) Or C = Chr(11) Or C = Chr(12))
EndMacro

; One-line Text$, stopping once CapLen chars are emitted (0 = uncapped);
; *Capped = #True when the full one-lined text would be longer than CapLen.
; Span appends: one Mid() per non-whitespace run instead of per character.
; Parity-proven against the old per-char version
; (940,783 exhaustive/boundary/random comparisons).
Procedure.s OneLineCap(Text$, CapLen.i, *Capped.Integer)
  Protected out$ = "", i.i = 1, n.i = Len(Text$), j.i, c$, skipped.i
  *Capped\i = #False
  While i <= n
    ; skip one whitespace run
    skipped = #False
    While i <= n
      c$ = Mid(Text$, i, 1)
      If IsWsChar(c$)
        skipped = #True
        i + 1
      Else
        Break
      EndIf
    Wend
    If i > n : Break : EndIf
    If skipped And out$ <> "" : out$ + " " : EndIf
    ; append the non-whitespace run Text$[i .. j-1] in one Mid()
    j = i + 1
    While j <= n
      c$ = Mid(Text$, j, 1)
      If IsWsChar(c$) : Break : EndIf
      j + 1
    Wend
    out$ + Mid(Text$, i, j - i)
    i = j
    If CapLen > 0 And Len(out$) >= CapLen
      *Capped\i = #True
      Break
    EndIf
  Wend
  ProcedureReturn out$
EndProcedure

; Collapse whitespace runs to single spaces, trim.
Procedure.s OneLine(Text$)
  Protected capped.i
  ProcedureReturn OneLineCap(Text$, 0, @capped)
EndProcedure

; First sentence, capped at ~max chars with an ellipsis (= firstSentence).
; Early cap: only the first Max+1 one-lined chars can influence the result,
; so the one-lining stops there instead of processing the whole text.
Procedure.s FirstSentence(Text$, Max.i = 60)
  Protected capped.i
  Protected line$ = OneLineCap(Text$, Max + 1, @capped)
  If line$ = "" : ProcedureReturn "" : EndIf
  Protected endPos.i = FindString(line$, ". ", 1)
  If capped
    ; the full one-lined text is longer than Max: either the sentence ends
    ; within the first Max chars (endPos <= Max, so it is inside the window)
    ; or the Max-1 truncation with ellipsis applies
    If endPos > 0 And endPos <= Max : ProcedureReturn Left(line$, endPos) : EndIf
    ProcedureReturn RTrim(Left(line$, Max - 1)) + "…"
  EndIf
  ; uncapped: |line$| <= Max, so |sentence$| <= Max - never truncated
  Protected sentence$
  If endPos = 0
    sentence$ = line$
  Else
    sentence$ = Left(line$, endPos)
  EndIf
  ProcedureReturn sentence$
EndProcedure

; Hard-cap text, marking how much was dropped (= cap).
Procedure.s CapText(Text$, Max.i)
  If Len(Text$) <= Max : ProcedureReturn Text$ : EndIf
  ProcedureReturn Left(Text$, Max) + Chr(10) + "… [+" + Str(Len(Text$) - Max) + " chars truncated]"
EndProcedure

; Collapse long examples by LINES (= collapseLines, keep default 20).
Procedure.s CollapseLines(Text$, Keep.i = #EXAMPLE_KEEP_LINES)
  Protected nLines.i = CountString(Text$, Chr(10)) + 1
  If nLines <= Keep : ProcedureReturn Text$ : EndIf
  Protected out$ = StringField(Text$, 1, Chr(10))
  Protected i.i
  For i = 2 To Keep
    out$ + Chr(10) + StringField(Text$, i, Chr(10))
  Next
  ProcedureReturn out$ + Chr(10) + "… [+" + Str(nLines - Keep) + " lines collapsed]"
EndProcedure

; ---------------------------------------------------------------------------
; banner boilerplate filter (capability-flagged: 6.40 output is silent,
; so the filter only ever fires on the 5.73 fallback branch)
; ---------------------------------------------------------------------------
Procedure.i IsBannerLine(Line$)
  If Not ConfigCapBannerFilter() : ProcedureReturn #False : EndIf
  Protected t$ = Trim(Line$)
  If t$ = "" : ProcedureReturn #False : EndIf   ; blank lines: collapse logic, not banner
  If Left(t$, 10) = "**********" : ProcedureReturn #True : EndIf
  If Left(t$, 10) = "PureBasic " And Mid(t$, 11, 1) >= "0" And Mid(t$, 11, 1) <= "9" : ProcedureReturn #True : EndIf
  If Left(t$, 10) = "Compiling " : ProcedureReturn #True : EndIf
  If Left(t$, 16) = "Loading external" : ProcedureReturn #True : EndIf
  If Left(t$, 21) = "Starting compilation" : ProcedureReturn #True : EndIf
  If Left(t$, 19) = "Creating executable" : ProcedureReturn #True : EndIf
  If Left(t$, 32) = "Creating and launching executable" : ProcedureReturn #True : EndIf
  If Left(t$, 10) = "- Feel the" : ProcedureReturn #True : EndIf
  ProcedureReturn #False
EndProcedure

; stripCompilerNoise: drop banner lines, collapse blank runs, trim.
Procedure.s StripCompilerNoise(Output$)
  Protected kept$ = "", prevBlank.i = #True, i.i, n.i, line$, t$
  n = CountString(Output$, Chr(10)) + 1
  For i = 1 To n
    line$ = RTrim(Trim(StringField(Output$, i, Chr(10))), Chr(13))
    t$ = Trim(line$)
    If t$ <> "" And IsBannerLine(t$) : Continue : EndIf
    If t$ = "" And prevBlank : Continue : EndIf
    kept$ + line$ + Chr(10)
    prevBlank = Bool(t$ = "")
  Next
  ProcedureReturn TrimAll(kept$)
EndProcedure

; ---------------------------------------------------------------------------
; parse compiler diagnostics
; ---------------------------------------------------------------------------
Structure DiagT
  line.i      ; 1-based source line, 0 when the compiler reported none
  message.s
EndStructure

Global Dim gDiagRe.i(3)
Global gDiagReady.i = #False

; Group captures of the last ReMatch() call. GOTCHA FOUND LIVE ON 6.40:
; RegularExpressionGroup() is only valid after ExamineRegularExpression() +
; NextRegularExpressionMatch() - MatchRegularExpression() matches but leaves
; the group state empty, so every diagnostic parsed as "Line 0:" with an
; EMPTY message (silently, no compile error). All group extraction in this
; file goes through ReMatch(); bare MatchRegularExpression() stays in use
; only where the result is a pure boolean (hint lints, metrics classifier).
Global gReG1.s
Global gReG2.s

; Match Text$ against Re (must be a compiled #PB_Any regex); on a match fill
; gReG1/gReG2 with groups 1/2 ("" when the group does not exist). Returns the
; match result. Only the FIRST match of a single-line pattern is needed here
; (the diagnostic rules are anchored ^...$ over one raw line).
Procedure.i ReMatch(Re.i, Text$)
  gReG1 = "" : gReG2 = ""
  If Re = 0 : ProcedureReturn #False : EndIf
  Protected matched.i = #False
  If ExamineRegularExpression(Re, Text$)
    If NextRegularExpressionMatch(Re)
      matched = #True
      If CountRegularExpressionGroups(Re) >= 1 : gReG1 = RegularExpressionGroup(Re, 1) : EndIf
      If CountRegularExpressionGroups(Re) >= 2 : gReG2 = RegularExpressionGroup(Re, 2) : EndIf
    EndIf
  EndIf
  ProcedureReturn matched
EndProcedure

Procedure DiagRulesInit()
  ; "Error: Line 2 - msg." / "Error: msg." / warning variants - PCRE verbatim
  gDiagRe(0) = CreateRegularExpression(#PB_Any, "^Error: Line (\d+) - (.+?)\.?$")
  gDiagRe(1) = CreateRegularExpression(#PB_Any, "^Error: (.+?)\.?$")
  gDiagRe(2) = CreateRegularExpression(#PB_Any, "^Warning: Line (\d+) - (.+?)\.?$")
  gDiagRe(3) = CreateRegularExpression(#PB_Any, "^Warning: (.+)$")
  gDiagReady = #True
EndProcedure

Procedure ParseDiagnostics(Output$, List Errors.DiagT(), List Warnings.DiagT())
  If Not gDiagReady : DiagRulesInit() : EndIf
  ClearList(Errors())
  ClearList(Warnings())
  Protected n.i = CountString(Output$, Chr(10)) + 1
  Protected i.i, raw$, m.i
  For i = 1 To n
    raw$ = Trim(RTrim(Trim(StringField(Output$, i, Chr(10))), Chr(13)))
    If raw$ = "" : Continue : EndIf
    If ReMatch(gDiagRe(0), raw$)
      AddElement(Errors())
      Errors()\line = Val(gReG1)
      Errors()\message = gReG2
    ElseIf ReMatch(gDiagRe(1), raw$)
      AddElement(Errors())
      Errors()\line = 0
      Errors()\message = gReG1
    ElseIf ReMatch(gDiagRe(2), raw$)
      AddElement(Warnings())
      Warnings()\line = Val(gReG1)
      Warnings()\message = gReG2
    ElseIf ReMatch(gDiagRe(3), raw$)
      AddElement(Warnings())
      Warnings()\line = 0
      Warnings()\message = gReG1
    EndIf
  Next
EndProcedure

; ---------------------------------------------------------------------------
; process runner (no shell, capture, timeout, tree-kill)
; ---------------------------------------------------------------------------
Structure RunResT
  spawnFailed.i       ; RunProgram could not start the exe
  exitCodeUnknown.i   ; killed-then-stuck panic path: no code ever observed
  exitCode.i          ; -1 when unknown
  stdout.s
  stderr.s
  timedOut.i
  durationMs.i
EndStructure

; Quote one arg for a raw command line; space-free, quote-free args pass
; through verbatim (byte-identical spawn line on both OSes). RunProgram
; hands Parameter$ to the child VERBATIM - no re-quoting (probe-sealed
; 2026-10-13, tmp/probe_parent.pb: the child's GetCommandLine_() equals the
; parent's Parameter$) - and DQUOTE grouping is identical on both OSes:
; spike S6 (sealed, live WSL run): from parent Parameter 'a "b c" d' the
; bash ground-truth child reported ARG[1]=<b c> AND the PB
; ProgramParameter() child reported PBARG[1]=<b c>, i.e. one argv element,
; quotes consumed. The older community claim of quotes reaching the child
; verbatim (forum t=61786/t=81520) is disproven for current PB Linux. The
; empty-arg '"·"' form is unmeasured on Linux but unreachable: call sites
; pass only guarded, non-empty paths (see MakeTempCopy's whitespace guard -
; quoting is the second belt, the /tmp fallback the first).
;
; Embedded '"' is NOT supported - probe-sealed 2026-10-13
; (tmp/probe_parent*.pb): a PB child's ProgramParameter() parser treats
; '\' as literal data and '"' as pure grouping - consumed as a delimiter,
; never preserved as data ('\' does not escape it, '""' does not fold to a
; literal). PureBasic children have NO command-line escape mechanism at
; all, and CommandLineToArgvW '\'-escaping (probed, then REJECTED) injects
; phantom backslashes into exactly the child population this pipeline
; spawns: pbcompiler.exe for pb_check, a compiled fixture exe for pb_run -
; both PB programs. Args carrying quotes therefore lose the quotes in the
; child's argv (and may split at the quote); siblings stay intact.
Procedure.s ProcQ(Arg$)
  If Arg$ = "" : ProcedureReturn Chr(34) + Chr(34) : EndIf
  If FindString(Arg$, " ", 1) Or FindString(Arg$, Chr(9), 1) : ProcedureReturn Chr(34) + Arg$ + Chr(34) : EndIf
  ProcedureReturn Arg$
EndProcedure

; Tree-kill, whole child tree.
;   Windows: taskkill /PID <pid> /T /F spawned without shell (plan
;   requirement; /T takes the whole child tree - KillProgram alone only
;   kills the direct child).
;   Linux (S7-sealed): KillProgram on the direct child leaves grandchildren
;   alive (spike survivors: two `sleep 60` processes outlived the killed
;   parent), so the child runs under setsid (see RunProcessCapture), making
;   PGID == the observed PID: TERM the whole group, give well-behaved
;   children a 500 ms grace, then KILL the group unconditionally (against
;   an already-reaped group the signal is a no-op, never a surfaced error).
;   The caller's KillProgram backstop still covers the direct child.
;   "kill" resolves through PATH (util-linux/procps - present on every
;   glibc distro); if it cannot spawn, the backstop alone remains, exactly
;   like the Windows taskkill-unresolvable path.
Procedure KillTree(Pid.i)
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    Protected p.i = RunProgram("taskkill", "/PID " + Str(Pid) + " /T /F", "",
                               #PB_Program_Wait | #PB_Program_Hide)
    If p = 0
      ; taskkill unresolvable - the direct-kill fallback is
      ; handled by the caller's KillProgram backstop
    EndIf
  CompilerElse
    If RunProgram("kill", "-TERM -- -" + Str(Pid), "", #PB_Program_Wait | #PB_Program_Hide)
      Delay(500)
    EndIf
    RunProgram("kill", "-KILL -- -" + Str(Pid), "", #PB_Program_Wait | #PB_Program_Hide)
  CompilerEndIf
EndProcedure

; runProcess port: spawn without shell, capture stdout/stderr, enforce the
; timeout, kill the tree on timeout. Stdout is captured as raw bytes and
; decoded UTF-8 once at the end (a multibyte char can never split across two
; ReadProgramData calls this way). Stderr uses ReadProgramError, which never
; blocks - the polling loop can always reach its timeout check.
Procedure RunProcessCapture(Exe$, Params$, WorkingDir$, TimeoutMs.i, *r.RunResT)
  *r\spawnFailed = #False
  *r\exitCodeUnknown = #False
  *r\exitCode = -1
  *r\stdout = ""
  *r\stderr = ""
  *r\timedOut = #False
  Protected t0.i = ElapsedMilliseconds()
  Protected p.i
  CompilerIf #PB_Compiler_OS = #PB_OS_Linux
    ; setsid makes the child a session+group leader (PGID == PID) so one
    ; group signal reaches the whole tree (see KillTree). util-linux setsid
    ; execs the program directly - no fork - when it is not already a group
    ; leader, which is the case for a freshly spawned child, so ProgramID()
    ; IS the program's PID/PGID. If setsid itself cannot spawn, fall back to
    ; a direct spawn: correct behavior, tree-kill degrades to the
    ; KillProgram backstop.
    p = RunProgram("setsid", Trim(ProcQ(Exe$) + " " + Params$), WorkingDir$, 
                   #PB_Program_Open | #PB_Program_Read | #PB_Program_Error | #PB_Program_Hide)
    If p = 0
      p = RunProgram(Exe$, Params$, WorkingDir$,
                     #PB_Program_Open | #PB_Program_Read | #PB_Program_Error | #PB_Program_Hide)
    EndIf
  CompilerElse
    p = RunProgram(Exe$, Params$, WorkingDir$,
                   #PB_Program_Open | #PB_Program_Read | #PB_Program_Error | #PB_Program_Hide)
  CompilerEndIf
  If p = 0
    *r\spawnFailed = #True
    *r\durationMs = ElapsedMilliseconds() - t0
    ProcedureReturn
  EndIf

  ; stdout accumulator (grows on demand; 4 MB cap with truncation marker)
  Protected cap.i = 65536
  Protected *acc = AllocateMemory(cap)
  Protected accLen.i = 0, outTruncated.i = #False, errTruncated.i = #False
  Protected *scratch = AllocateMemory(65536)
  Protected killIssued.i = #False, n.i, available.i, drains.i, e$, panicAt.i = TimeoutMs + 10000
  Protected gotErr.i, lastErrMs.i = -1000   ; last poll cycle that collected stderr
  Protected newCap.i, newAcc   ; staged grow: only applied to *acc/cap on success
  ; stderr lines: joined ONCE after the final drain (a per-line *r\stderr
  ; append copies the whole accumulator each time - quadratic in bytes);
  ; errChars mirrors what a mid-run Len(*r\stderr) would have been.
  NewList errLines$()
  Protected errChars.i = 0

  While ProgramRunning(p)
    ; 6.40 ReadProgramData waits for the requested SIZE, contrary to the
    ; reference's "up to size" wording. Read only the available snapshot.
    ; Bound work per poll so continuously flooding output cannot starve timeout.
    drains = 0
    While drains < 64
      available = AvailableProgramOutput(p)
      If available <= 0 : Break : EndIf
      If available > 65536 : available = 65536 : EndIf
      n = ReadProgramData(p, *scratch, available)
      drains + 1
      If n <= 0 : Break : EndIf
      If accLen + n > #MAX_CAPTURE_CHARS
        n = #MAX_CAPTURE_CHARS - accLen
        If n > 0
          If accLen + n > cap
            newCap = (accLen + n) * 2
            newAcc = ReAllocateMemory(*acc, newCap)
            If newAcc
              *acc = newAcc
              cap = newCap
            EndIf
          EndIf
          If accLen + n <= cap   ; false after a failed grow - skip the copy
            CopyMemory(*scratch, *acc + accLen, n)
            accLen + n
          EndIf
        EndIf
        outTruncated = #True
        Break
      EndIf
      If accLen + n > cap
        newCap = (accLen + n) * 2
        newAcc = ReAllocateMemory(*acc, newCap)
        If newAcc = 0
          ; Grow failed (OOM): ReAllocateMemory's contract keeps the
          ; ORIGINAL block valid at the old size, and cap (assigned only on
          ; success) still matches it - drop this read (already consumed
          ; from the pipe), mark truncated, stop draining this poll.
          outTruncated = #True
          Break
        EndIf
        *acc = newAcc
        cap = newCap
      EndIf
      CopyMemory(*scratch, *acc + accLen, n)
      accLen + n
    Wend
    ; drain stderr (ReadProgramError never halts)
    gotErr = #False
    While #True
      e$ = ReadProgramError(p)
      If e$ = "" : Break : EndIf
      gotErr = #True
      If errChars < #MAX_CAPTURE_CHARS
        AddElement(errLines$())
        errLines$() = e$
        errChars + Len(e$) + 1   ; a line that pushes past the cap is still
      Else                       ; appended in full, exactly like today
        errTruncated = #True
      EndIf
    Wend

    If killIssued = #False And ElapsedMilliseconds() - t0 >= TimeoutMs
      *r\timedOut = #True
      killIssued = #True
      KillTree(ProgramID(p))
      KillProgram(p)
    EndIf
    If killIssued And ElapsedMilliseconds() - t0 > panicAt
      *r\exitCodeUnknown = #True   ; unkillable past the panic backstop
      Break
    EndIf
    If gotErr : lastErrMs = ElapsedMilliseconds() : EndIf
    ; Sleep between polls ONLY while stderr has been quiet. The child's next
    ; stderr write blocks until we read (PB's stderr pipe does not buffer
    ; ahead), so a fixed sleep locks the drain to one line per sleep (~20 ms
    ; on Windows) - an 80k-line flood needed ~28 min that way. While a line
    ; arrived within #STDERR_SPIN_MS, keep polling flat out; quiet runs keep
    ; the old 15 ms pace. Output-preserving: only drain scheduling changes.
    If killIssued = #False And ElapsedMilliseconds() - lastErrMs >= #STDERR_SPIN_MS
      Delay(15)
    EndIf
  Wend

  ; final drain (buffered output after exit / after kill)
  While AvailableProgramOutput(p)
    available = AvailableProgramOutput(p)
    If available > 65536 : available = 65536 : EndIf
    If available <= 0 : Break : EndIf
    n = ReadProgramData(p, *scratch, available)
    If n <= 0 : Break : EndIf
    If accLen + n > #MAX_CAPTURE_CHARS
      n = #MAX_CAPTURE_CHARS - accLen
      outTruncated = #True
    EndIf
    If n > 0
      If accLen + n > cap
        newCap = (accLen + n) * 2
        newAcc = ReAllocateMemory(*acc, newCap)
        If newAcc
          *acc = newAcc
          cap = newCap
        Else
          ; OOM as in the poll loop: original block stays valid, cap still
          ; matches it - skip the copy (read already consumed), mark truncated.
          outTruncated = #True
        EndIf
      EndIf
      If accLen + n <= cap   ; false after a failed grow - skip the copy
        CopyMemory(*scratch, *acc + accLen, n)
        accLen + n
      EndIf
    EndIf
  Wend
  While #True
    e$ = ReadProgramError(p)
    If e$ = "" : Break : EndIf
    If errChars < #MAX_CAPTURE_CHARS
      AddElement(errLines$())
      errLines$() = e$
      errChars + Len(e$) + 1
    Else
      errTruncated = #True
    EndIf
  Wend

  ; one linear join of the collected lines - same layout as the old
  ; accumulator: every line followed by one LF. PeekS's Length is in
  ; characters for #PB_Unicode (6.40 reference); PokeS returns BYTES
  ; written, so the walk advances by its return value.
  If errChars > 0
    Protected *ebuf = AllocateMemory(errChars * SizeOf(Character) + SizeOf(Character))
    If *ebuf
      Protected eoff.i = 0
      ForEach errLines$()
        eoff + PokeS(*ebuf + eoff, errLines$() + Chr(10), -1, #PB_Unicode | #PB_String_NoZero)
      Next
      *r\stderr = PeekS(*ebuf, errChars, #PB_Unicode)
      FreeMemory(*ebuf)
    Else
      errTruncated = #True     ; OOM: stderr dropped, marker shows why
    EndIf
  EndIf

  If *r\exitCodeUnknown
    *r\exitCode = -1
  Else
    *r\exitCode = ProgramExitCode(p)
  EndIf
  If accLen > 0
    ; UTF-8 decode is deliberate: correct on CP65001 consoles (and Linux),
    ; may yield U+FFFD elsewhere; #PB_Ascii rejected (breaks CP65001).
    *r\stdout = PeekS(*acc, accLen, #PB_UTF8 | #PB_ByteLength)
  EndIf
  If outTruncated : *r\stdout + Chr(10) + "…[stdout truncated at 4 MB]" : EndIf
  If errTruncated : *r\stderr + Chr(10) + "…[stderr truncated at 4 MB]" : EndIf
  *r\durationMs = ElapsedMilliseconds() - t0
  FreeMemory(*acc)
  FreeMemory(*scratch)
  CloseProgram(p)
EndProcedure

; ---------------------------------------------------------------------------
; temp-dir copy with guaranteed cleanup
; ---------------------------------------------------------------------------
Structure TempCopyT
  dir.s
  file.s
  ok.i
EndStructure

; makeTempCopy: fresh temp-dir/pbmcp-<uniq> holding a copy under the same
; basename. The caller MUST call CleanupTempDir even on error paths.
Procedure MakeTempCopy(SourceFile$, *t.TempCopyT)
  *t\ok = #False
  *t\dir = "" : *t\file = ""
  Protected base$ = GetTemporaryDirectory()
  CompilerIf #PB_Compiler_OS = #PB_OS_Linux
    ; Defense in depth: ProcQ now DQUOTE-wraps whitespace args (S6-sealed
    ; grouping semantics), but keeping the spawn arguments whitespace-free
    ; entirely avoids the splitter altogether. /tmp is the portable
    ; fallback when TMPDIR is exotic. (Linux branch only; the Windows
    ; pipeline relies on quoting alone.)
    If (FindString(base$, " ", 1) Or FindString(base$, Chr(9), 1)) And FileSize("/tmp") = -2
      base$ = "/tmp"
    EndIf
  CompilerEndIf
  If Right(base$, 1) <> #PathSep$ : base$ + #PathSep$ : EndIf
  Protected tries.i
  For tries = 1 To 20
    Protected dir$ = base$ + "pbmcp-" + Str(ElapsedMilliseconds()) + "-" + Str(Random(999999))
    If CreateDirectory(dir$)
      Protected file$ = dir$ + #PathSep$ + GetFilePart(SourceFile$)
      If CopyFile(SourceFile$, file$)
        *t\dir = dir$
        *t\file = file$
        *t\ok = #True
        ProcedureReturn
      EndIf
      DeleteDirectory(dir$, "")
    EndIf
    Delay(2)
  Next
EndProcedure

; cleanupTemp: best-effort recursive delete; AV scanners hold fresh exes for
; a few hundred ms, hence the backoff. Failures stay silent.
Procedure CleanupTempDir(Dir$)
  Protected delays.i = 0
  Protected attempt.i, delay.i
  For attempt = 0 To 3   ; [0, 100, 250, 500] like cleanupTemp
    If attempt = 0
      delay = 0
    ElseIf attempt = 1
      delay = 100
    ElseIf attempt = 2
      delay = 250
    Else
      delay = 500
    EndIf
    If delay > 0 : Delay(delay) : EndIf
    If DeleteDirectory(Dir$, "", #PB_FileSystem_Recursive | #PB_FileSystem_Force)
      ProcedureReturn
    EndIf
  Next
EndProcedure

; ---------------------------------------------------------------------------
; source reading (line count + hint lint)
; ---------------------------------------------------------------------------

; Whole-file decode. Returns "" for missing/unreadable. The BOM character
; (if any) is KEPT - the hint lints run against the same text as the line
; count.
Procedure.s ReadSourceWhole(File$)
  Protected size.i = FileSize(File$)
  If size < 0 : ProcedureReturn "" : EndIf
  Protected f.i = ReadFile(#PB_Any, File$)
  If f = 0 : ProcedureReturn "" : EndIf
  Protected *buf = AllocateMemory(size + 1)
  ReadData(f, *buf, size)
  CloseFile(f)
  Protected s$ = PeekS(*buf, size, #PB_UTF8 | #PB_ByteLength)
  FreeMemory(*buf)
  ProcedureReturn s$
EndProcedure

; sourceLines: \n, \r\n, \r aware; a single trailing terminator is not an
; extra line; empty file = 0.
Procedure.i SourceLines(Text$)
  If Text$ = "" : ProcedureReturn 0 : EndIf
  Protected norm$ = ReplaceString(Text$, Chr(13) + Chr(10), Chr(10))
  norm$ = ReplaceString(norm$, Chr(13), Chr(10))
  Protected n.i = CountString(norm$, Chr(10)) + 1
  If Right(norm$, 1) = Chr(10) : n - 1 : EndIf
  ProcedureReturn n
EndProcedure

; sourceLineAtNorm: 1-based line over an ALREADY CRLF-normalized text (lone
; \r stays in-line, as before) - StringField only. The caller normalizes
; once; the old SourceLineAt re-normalized the whole file per call.
Procedure.s SourceLineAtNorm(Text$, Line.i)
  If Line < 1 : ProcedureReturn "" : EndIf
  ProcedureReturn StringField(Text$, Line, Chr(10))
EndProcedure

; ---------------------------------------------------------------------------
; compile step with transient-failure retry
; ---------------------------------------------------------------------------

; isTransientCompileFailure: every error is line-less (infra flake).
Procedure.i IsTransientCompileFailure(Output$)
  NewList errs.DiagT()
  NewList warns.DiagT()
  ParseDiagnostics(Output$, errs(), warns())
  If ListSize(errs()) = 0 : ProcedureReturn #False : EndIf
  ForEach errs()
    If errs()\line <> 0 : ProcedureReturn #False : EndIf
  Next
  ProcedureReturn #True
EndProcedure

; CompilerStepWithRetry: cwd pinned to the temp dir; the output switch gets
; the absolute output path (suppresses 5.73 auto-launch; correct on 6.40).
; One retry when the failure is line-less. Switch spellings are per-OS
; constants (#SW_* in config.pb): Windows "/CHECK" "/CONSOLE" "/EXE",
; Linux "--check" "--console" "--output" - "/"-switches do not exist there.
Procedure CompilerStepWithRetry(CompilerExe$, Flag$, SrcFile$, ExeOut$, *r.RunResT)
  Protected timeoutMs.i = #CHECK_TIMEOUT_MS
  If Flag$ = #SW_CONSOLE$ : timeoutMs = #COMPILE_TIMEOUT_MS : EndIf
  Protected params$ = Flag$
  If ExeOut$ <> "" : params$ + " " + #SW_EXE$ + " " + ProcQ(ExeOut$) : EndIf
  params$ + " " + ProcQ(SrcFile$)
  Protected cwd$ = GetPathPart(SrcFile$)

  RunProcessCapture(CompilerExe$, params$, cwd$, timeoutMs, *r)
  If *r\exitCode <> 0 And *r\exitCode <> -1 And *r\timedOut = #False And IsTransientCompileFailure(*r\stdout)
    Delay(250)
    RunProcessCapture(CompilerExe$, params$, cwd$, timeoutMs, *r)
  EndIf
EndProcedure

; ---------------------------------------------------------------------------
; high-confidence error hints (pb_check only)
; ---------------------------------------------------------------------------
Global gHintUndeclared.i = 0
Global gHintConstType.i = 0
Global gHintProcScope.i = 0
Global gHintDimAs.i = 0
Global gHintBadComment.i = 0
Global gHintVbSub.i = 0
Global gLintProcDollar.i = 0
Global gHintsReady.i = #False

Procedure HintsInit()
  gHintUndeclared = CreateRegularExpression(#PB_Any, "\bvariables? have to be declared:\s*(.+)$", #PB_RegularExpression_NoCase)
  gHintConstType  = CreateRegularExpression(#PB_Any, "\bcan'?t have a type\b", #PB_RegularExpression_NoCase)
  ; probe-sealed 2026-10-13 on 5.73 x86 AND 6.40 x64 (tmp/bp-probe/): identical
  ; message text on both, so the message regex is version-safe
  gHintProcScope  = CreateRegularExpression(#PB_Any, "'(?:protected|static)' can only be used inside a procedure", #PB_RegularExpression_NoCase)
  gHintDimAs      = CreateRegularExpression(#PB_Any, "\bDim\s+\w+\s+As\s+", #PB_RegularExpression_NoCase)
  gHintBadComment = CreateRegularExpression(#PB_Any, "^\s*(?:'|//)", #PB_RegularExpression_NoCase)
  gHintVbSub      = CreateRegularExpression(#PB_Any, "\bSub\s+\w|\bEnd\s+Sub\b", #PB_RegularExpression_NoCase)
  ; '$' in a procedure NAME compiles to a bare "Syntax error." (probe-sealed
  ; 5.73 + 6.40) - the hint therefore pairs this source-line lint (matches the
  ; Procedure line's name position, never parameter names like Foo(a$)) with
  ; the generic message at the reported position
  gLintProcDollar = CreateRegularExpression(#PB_Any, "^\s*Procedure\$|^\s*Procedure(\.[A-Za-z*]+)?\s+\w+\$", #PB_RegularExpression_NoCase)
  gHintsReady = #True
EndProcedure

; buildHints: priority order undeclared -> const-type -> source lints (dim-as,
; bad-comment, vb-sub) -> unknown-command bucket; deduplicated by pattern,
; capped at 2.
Procedure BuildHints(List Errors.DiagT(), List Buckets$(), SourceText$, List Hints$())
  ClearList(Hints$())
  If ListSize(Errors()) = 0 : ProcedureReturn : EndIf
  If Not gHintsReady : HintsInit() : EndIf

  ; 1. EnableExplicit wording -> inline fix with the actual missing name
  ForEach Errors()
    If ReMatch(gHintUndeclared, Errors()\message)
      Protected cap$ = gReG1
      Protected name$ = StringField(Trim(ReplaceString(cap$, ",", " ")), 1, " ")
      If name$ <> ""
        AddElement(Hints$())
        Hints$() = "Hint: EnableExplicit is on — declare it first, e.g. `Define " + name$ + ".i` (or `.s` for a string)."
        Break
      EndIf
    EndIf
  Next

  ; 1b. typed-constant wording: "#PlayerSpeed.f = 2.5" is illegal
  ForEach Errors()
    If MatchRegularExpression(gHintConstType, Errors()\message)
      AddElement(Hints$())
      Hints$() = "Hint: constants take no type suffix (`#Name.f` fails) — use `#Name = 1.5` or a variable `Define speed.f`."
      Break
    EndIf
  Next

  ; 1c. Protected/Static at file scope (message-based, probe-sealed 5.73 + 6.40)
  ForEach Errors()
    If MatchRegularExpression(gHintProcScope, Errors()\message)
      AddElement(Hints$())
      Hints$() = "Hint: `Protected`/`Static` can only be used inside a procedure — use `Define` at file scope, `Global` for shared state."
      Break
    EndIf
  Next

  ; 2-4. source-line lint at the reported error positions
  If SourceText$ <> ""
    ; normalize CRLF once for the whole loop (lone CR stays in-line, as before)
    Protected normText$ = ReplaceString(SourceText$, Chr(13) + Chr(10), Chr(10))
    Protected dimAs.i = #False, badComment.i = #False, vbSub.i = #False, procDollar.i = #False
    ForEach Errors()
      Protected src$ = SourceLineAtNorm(normText$, Errors()\line)
      If src$ = "" : Continue : EndIf
      If Not dimAs And MatchRegularExpression(gHintDimAs, src$) : dimAs = #True : EndIf
      If Not badComment And MatchRegularExpression(gHintBadComment, src$) : badComment = #True : EndIf
      If Not vbSub And MatchRegularExpression(gHintVbSub, src$) : vbSub = #True : EndIf
      If Not procDollar And MatchRegularExpression(gLintProcDollar, src$) : procDollar = #True : EndIf
      If dimAs And badComment And vbSub And procDollar : Break : EndIf
    Next
    If procDollar
      AddElement(Hints$())
      Hints$() = "Hint: a procedure name can't end in `$` — that's the string-variable marker; declare the return type instead: `Procedure.s Name()`."
    EndIf
    If dimAs
      AddElement(Hints$())
      Hints$() = "Hint: PureBasic has no `Dim x As Integer` — use `Define x.i` for variables and `Dim a(n)` for arrays."
    EndIf
    If badComment
      AddElement(Hints$())
      Hints$() = "Hint: comments start with `;` — `'` and `//` are syntax errors in PureBasic."
    EndIf
    If vbSub
      AddElement(Hints$())
      Hints$() = "Hint: use `Procedure Name(...)` … `EndProcedure` (no Sub/End Sub); return values via `ProcedureReturn`."
    EndIf
  EndIf

  ; 5. bucket-level advice for invented command names
  ForEach Buckets$()
    If Buckets$() = "unknown-command"
      AddElement(Hints$())
      Hints$() = "Hint: that command does not exist in PureBasic — run pb_docs_search for the real name (PB names differ from VB/FreeBASIC)."
      Break
    EndIf
  Next

  ; cap 2
  While ListSize(Hints$()) > 2
    LastElement(Hints$())
    DeleteElement(Hints$())
  Wend
EndProcedure

; ---------------------------------------------------------------------------
; best-practice scan (always-on lint; fires on OK and error results alike)
; ---------------------------------------------------------------------------
; Rules (sealed 2026-10-13, tmp/bp-probe/): only things the compiler silently
; ACCEPTS - Global inside a procedure, Goto/Gosub, a file without
; EnableExplicit. Rules the compiler already rejects (Protected/Static at
; file scope, '$' procedure names) are HINTS in BuildHints above, not here.

; Strip string literals ("...", "" escape) then cut at the ; comment start.
; Per-line by design: PB has no multiline strings, so a stray quote can only
; degrade that one line, never leak across lines.
Procedure.s BpStripLine(Line$)
  Protected out$ = "", i.i = 1, n.i = Len(Line$), c$
  While i <= n
    c$ = Mid(Line$, i, 1)
    If c$ = Chr(34)
      i + 1
      While i <= n
        c$ = Mid(Line$, i, 1)
        If c$ = Chr(34)
          If Mid(Line$, i + 1, 1) = Chr(34)   ; "" = escaped quote, stays inside
            i + 2
          Else
            i + 1
            Break
          EndIf
        Else
          i + 1
        EndIf
      Wend
      out$ + " "                              ; keep token separation
    ElseIf c$ = ";"
      Break
    Else
      out$ + c$
      i + 1
    EndIf
  Wend
  ProcedureReturn out$
EndProcedure

; First keyword of a stripped line, lowercased (keywords are case-insensitive;
; first-word matching keeps ProcedureReturn from entering procedure depth).
Procedure.s BpFirstWord(Strip$)
  Protected t$ = LCase(Trim(Strip$))
  Protected out$ = "", i.i, n.i = Len(t$), c$
  For i = 1 To n
    c$ = Mid(t$, i, 1)
    If (c$ >= "a" And c$ <= "z") Or (c$ >= "0" And c$ <= "9") Or c$ = "_"
      out$ + c$
    Else
      Break
    EndIf
  Next
  ProcedureReturn out$
EndProcedure

; BpScan: collect the notes. Line-anchored notes first (source order), the
; file-level EnableExplicit note last. Max 3 by rule count - no extra cap.
Procedure BpScan(SourceText$, List Notes$())
  ClearList(Notes$())
  If SourceText$ = "" : ProcedureReturn : EndIf
  Protected norm$ = ReplaceString(SourceText$, Chr(13) + Chr(10), Chr(10))
  Protected nLines.i = CountString(norm$, Chr(10)) + 1
  Protected explicitSeen.i = #False, inProc.i = #False
  Protected globalLine.i = 0, gotoLine.i = 0
  Protected i.i, s$, w$
  For i = 1 To nLines
    s$ = BpStripLine(StringField(norm$, i, Chr(10)))
    w$ = BpFirstWord(s$)
    If w$ = "global" And inProc And globalLine = 0 : globalLine = i : EndIf
    If (w$ = "goto" Or w$ = "gosub") And gotoLine = 0 : gotoLine = i : EndIf
    If w$ = "enableexplicit" : explicitSeen = #True : EndIf
    ; depth: any stripped line containing endprocedure exits (nets zero for
    ; one-line `Procedure X() : EndProcedure`); first word "procedure" enters.
    ; Mid-line `: EndProcedure` and a macro-local `Procedure` without an
    ; EndProcedure in the same macro are the known tradeoffs - best-effort lint.
    If FindString(LCase(s$), "endprocedure", 1) > 0
      inProc = #False
    ElseIf w$ = "procedure"
      inProc = #True
    EndIf
  Next
  If globalLine > 0
    AddElement(Notes$())
    Notes$() = "Line " + Str(globalLine) + ": `Global` inside a procedure creates hidden shared state — declare globals at file scope."
  EndIf
  If gotoLine > 0
    AddElement(Notes$())
    Notes$() = "Line " + Str(gotoLine) + ": avoid `Goto`/`Gosub` — use procedures and structured control flow."
  EndIf
  If explicitSeen = #False
    AddElement(Notes$())
    Notes$() = "Add `EnableExplicit` at the top — without it every typo compiles as an undeclared integer."
  EndIf
EndProcedure

; ---------------------------------------------------------------------------
; pb_check result
; ---------------------------------------------------------------------------

; Line-less errors (POLINK etc.) print as "Line 0: msg" verbatim - the
; golden sessions pin those bytes, so no beautification here.
Procedure.s FormatCheckResult(DurationMs.i, LineCount.i, Ok.i, TimedOut.i, List Errors.DiagT(), RawTail$, File$, SourceText$, List Buckets$())
  Protected out$ = ""
  If Ok
    out$ = "OK — " + Str(LineCount) + " lines, " + Str(DurationMs) + " ms (" + File$ + ")"
  Else
    If TimedOut
      out$ = "COMPILER TIMEOUT after " + Str(#CHECK_TIMEOUT_MS) + " ms (" + File$ + ")"
    Else
      out$ = "ERRORS (" + Str(ListSize(Errors())) + "):"
    EndIf
    If TimedOut = #False
      If ListSize(Errors()) > 0
        ; hints between the header and the error lines (fixed order);
        ; Buckets$() comes pre-classified from the caller - one
        ; MetricsClassifyBuckets run per pb_check, output unchanged
        NewList hints$()
        BuildHints(Errors(), Buckets$(), SourceText$, hints$())
        ForEach hints$()
          out$ + Chr(10) + hints$()
        Next
      EndIf
      Protected shown.i = 0
      ForEach Errors()
        If shown >= 40 : Break : EndIf
        out$ + Chr(10) + "Line " + Str(Errors()\line) + ": " + Errors()\message
        shown + 1
      Next
      If ListSize(Errors()) > shown
        out$ + Chr(10) + "… +" + Str(ListSize(Errors()) - shown) + " more errors"
      EndIf
      If ListSize(Errors()) = 0 And RawTail$ <> ""
        out$ + Chr(10) + "Raw compiler output (last lines):"
        out$ + Chr(10) + RawTail$
      EndIf
    EndIf
  EndIf

  ; best-practice notes: last section (least severe); silence on clean files
  ; keeps every pinned OK/ERROR shape byte-identical
  If SourceText$ <> "" And LineCount > 0
    NewList bp$()
    BpScan(SourceText$, bp$())
    If ListSize(bp$()) > 0
      out$ + Chr(10) + "Best practices (" + Str(ListSize(bp$())) + "):"
      ForEach bp$()
        out$ + Chr(10) + bp$()
      Next
    EndIf
  EndIf
  ProcedureReturn CapText(out$, #CHECK_CAP)
EndProcedure

; ---------------------------------------------------------------------------
; pb_check handler
; ---------------------------------------------------------------------------
Structure CheckResT
  ok.i
  lineCount.i
  durationMs.i
  timedOut.i
  rawTail.s
  sourceText.s
  List errors.DiagT()
EndStructure

; runCheck: temp-copy + /CHECK + parse + rawTail extraction.
Procedure RunCheck(CompilerExe$, AbsFile$, *c.CheckResT)
  ClearList(*c\errors())
  *c\ok = #False
  *c\lineCount = 0
  *c\durationMs = 0
  *c\timedOut = #False
  *c\rawTail = ""
  *c\sourceText = ""

  Protected src$ = ReadSourceWhole(AbsFile$)
  *c\sourceText = src$   ; single read: ToolCheck reuses this for hints/BpScan
  *c\lineCount = SourceLines(src$)

  Protected copy.TempCopyT
  MakeTempCopy(AbsFile$, @copy)
  If copy\ok = #False
    *c\rawTail = "cannot create temp copy of " + AbsFile$
    ProcedureReturn
  EndIf

  Protected proc.RunResT
  CompilerStepWithRetry(CompilerExe$, #SW_CHECK$, copy\file, "", @proc)
  CleanupTempDir(copy\dir)

  NewList warningsLocal.DiagT()
  ParseDiagnostics(proc\stdout, *c\errors(), warningsLocal())
  *c\durationMs = proc\durationMs
  *c\timedOut = proc\timedOut
  *c\ok = Bool(proc\spawnFailed = #False And proc\exitCode = 0 And proc\timedOut = #False And ListSize(*c\errors()) = 0)

  If *c\ok = #False And ListSize(*c\errors()) = 0 And proc\spawnFailed = #False
    Protected combined$ = proc\stdout
    If TrimAll(proc\stderr) <> "" : combined$ + Chr(10) + proc\stderr : EndIf
    Protected stripped$ = StripCompilerNoise(combined$)
    If stripped$ = "" : stripped$ = TrimAll(proc\stderr) : EndIf
    If stripped$ = "" : stripped$ = "compiler produced no output" : EndIf
    ; last 10 lines
    Protected nLines.i = CountString(stripped$, Chr(10)) + 1
    Protected startLine.i = nLines - 9
    If startLine < 1 : startLine = 1 : EndIf
    Protected tail$ = ""
    Protected i.i
    For i = startLine To nLines
      If tail$ <> "" : tail$ + Chr(10) : EndIf
      tail$ + StringField(stripped$, i, Chr(10))
    Next
    *c\rawTail = tail$
  EndIf
EndProcedure

Procedure ToolCheck(IdValue.i, Args.i)
  Protected compiler$ = ConfigCompiler()
  If compiler$ = ""
    SendTextResult(IdValue, "PureBasic compiler not found. Install PureBasic (or set PUREBASIC_HOME to its install dir) and restart the server.", #True)
    ProcedureReturn
  EndIf

  ; validate 'file' (string, min length 1, required) - shared validator
  Protected sOut.String   ; an *out.String must
  Protected issue$ = ValidateStrArg(Args, "file", 0, #True, @sOut)
  If issue$ <> ""
    SendInvalidParams(IdValue, "pb_check", issue$)
    ProcedureReturn
  EndIf
  Protected fileArg$ = sOut\s

  Protected abs$ = ResolvePath(fileArg$)
  If FileSize(abs$) = -1
    SendTextResult(IdValue, "File not found: " + abs$, #True)
    ProcedureReturn
  EndIf

  Protected res.CheckResT
  RunCheck(compiler$, abs$, @res)

  ; metrics: one compile event, resolved path, real error parsing -
  ; ONLY on the success path
  Protected okBuckets.i = res\ok
  NewList msgs$()
  NewList buckets$()
  ForEach res\errors() : AddElement(msgs$()) : msgs$() = res\errors()\message : Next
  MetricsClassifyBuckets(msgs$(), buckets$())
  MetricsAppend("pb_check", abs$, okBuckets, ListSize(msgs$()), buckets$(), res\durationMs)

  ; source text feeds the hints + best-practice scan: RunCheck already read
  ; and decoded it - reuse it under the same sane-size guard instead of a
  ; second full read+UTF-8-decode of the file
  Protected sourceText$ = ""
  If FileSize(abs$) <= 512 * 1024
    sourceText$ = res\sourceText
  EndIf

  SendTextResult(IdValue, FormatCheckResult(res\durationMs, res\lineCount, res\ok, res\timedOut, res\errors(), res\rawTail, fileArg$, sourceText$, buckets$()), Bool(Not res\ok))
EndProcedure
