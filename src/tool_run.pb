; ---------------------------------------------------------------------------
; tool_run.pb - pb_run implementation: compile inside the staged project
; workspace as a console app, then run the exe ourselves under full
; timeout/tree-kill control.
;
; The shared pieces (process
; runner, project staging, diagnostics parsing, retry) live in tool_check.pb.
;
; Invariants (verified live during the spikes):
;   - the exe is built with an explicit absolute output-switch path: without
;     it 5.73 plain /CONSOLE LAUNCHES the compiled program itself - an orphan
;     that keeps running after pbcompiler exits and can lock later compiles
;     (POLINK access denied). 6.40 has no auto-launch but the same path is
;     safe and keeps one code path for both capability branches. Linux uses
;     the --output spelling (no "/"-switches there).
;   - the program runs exactly ONCE, cwd = the staged entry directory
;     (relative data files resolve inside the copied project)
;   - timeout: poll ProgramRunning() at ~15 ms; kill via taskkill /PID /T /F
;     (whole tree) + KillProgram backstop; panic deadline +10 s
;   - the temp tree is always cleaned up, also on the error path
;
; Source-encoding rule: UTF-8 WITH BOM (see console.pb header).
; ---------------------------------------------------------------------------
EnableExplicit

Structure RunResultT
  ok.i                  ; ran AND exit 0 AND not timed out
  stagingError.s
  compileDurationMs.i
  noExecutable.i        ; compiler reported success but produced no exe
  timedOut.i            ; program timeout
  durationMs.i          ; TOTAL wall time (compile + run) - this is what
                        ; the metrics record logs
  hasRun.i
  compileRes.RunResT    ; compiler spawn result (stdout holds diagnostics)
  runRes.RunResT        ; program spawn result (valid when hasRun)
  List compileErrors.DiagT()
EndStructure

; FormatRunResult: exit X · N s / TIMEOUT / COMPILE FAILED.
Procedure.s FormatRunResult(*res.RunResultT, File$)
  Protected out$ = ""
  If *res\stagingError <> "" : ProcedureReturn CapText(*res\stagingError, #RUN_SECTION_CAP) : EndIf
  If *res\hasRun = #False
    out$ = "COMPILE FAILED (" + File$ + ") — " + Str(ListSize(*res\compileErrors())) + " error(s), compile took " + Str(*res\compileDurationMs) + " ms"
    Protected shown.i = 0
    ForEach *res\compileErrors()
      If shown >= 40 : Break : EndIf
      out$ + Chr(10) + "Line " + Str(*res\compileErrors()\line) + ": " + *res\compileErrors()\message
      shown + 1
    Next
    If *res\noExecutable
      out$ + Chr(10) + "(compiler reported success but produced no executable)"
    EndIf
    ProcedureReturn CapText(out$, #RUN_SECTION_CAP)
  EndIf

  If *res\timedOut
    out$ = "TIMEOUT after " + Str(*res\runRes\durationMs) + " ms — process killed (" + File$ + ")"
  Else
    Protected code$ = Str(*res\runRes\exitCode)
    If *res\runRes\exitCodeUnknown : code$ = "null" : EndIf
    ; (durationMs/1000).toFixed(1)
    Protected secs.d = *res\runRes\durationMs / 1000.0
    out$ = "exit " + code$ + " · " + StrD(secs, 1) + " s (" + File$ + ")"
  EndIf
  out$ + Chr(10) + "--- stdout ---"
  If TrimAll(*res\runRes\stdout) = ""
    out$ + Chr(10) + "(empty)"
  Else
    out$ + Chr(10) + CapText(TrimAll(*res\runRes\stdout), #RUN_SECTION_CAP)
  EndIf
  If TrimAll(*res\runRes\stderr) <> ""
    out$ + Chr(10) + "--- stderr ---"
    out$ + Chr(10) + CapText(TrimAll(*res\runRes\stderr), 4000)  ; min(RUN_SECTION_CAP, 4000)
  EndIf
  ProcedureReturn CapText(out$, 18000)
EndProcedure

; Join program args on spaces with per-arg quoting (only whitespace args
; get quotes - same resulting argv).
Procedure.s JoinArgs(List Args$())
  Protected out$ = "", first.i = #True
  ForEach Args$()
    If Not first : out$ + " " : EndIf
    out$ + ProcQ(Args$())
    first = #False
  Next
  ProcedureReturn out$
EndProcedure

; runConsoleProgram port.
Procedure RunConsoleProgram(CompilerExe$, AbsFile$, ProjectRoot$, List ProgArgs$(), TimeoutMs.i, *res.RunResultT)
  ClearList(*res\compileErrors())
  *res\ok = #False
  *res\compileDurationMs = 0
  *res\noExecutable = #False
  *res\timedOut = #False
  *res\durationMs = 0
  *res\hasRun = #False

  Protected t0.i = ElapsedMilliseconds()

  Protected copy.TempCopyT
  MakeTempCopy(AbsFile$, ProjectRoot$, @copy)
  If copy\ok = #False
    *res\stagingError = copy\error
    *res\durationMs = ElapsedMilliseconds() - t0
    ProcedureReturn
  EndIf

  ; exe named after the source (hello.pb -> hello + #ExeSuffix$):
  ; friendlier than PureBasic<suffix>, and ProgramFilename() reports
  ; something meaningful. Windows keeps ".exe"; Linux output is extension-less.
  Protected base$ = GetFilePart(copy\file)
  Protected dot.i = Len(base$)
  If dot > 3 And LCase(Right(base$, 3)) = ".pb" : dot - 3 : EndIf
  Protected runCwd$ = GetPathPart(copy\file)
  Protected exe$ = PathJoin(runCwd$, Left(base$, dot) + #ExeSuffix$)
  Protected fallback$ = PathJoin(runCwd$, "PureBasic" + #ExeSuffix$)

  ; A copied executable must never be mistaken for this compile's output.
  If FileSize(exe$) >= 0 And DeleteFile(exe$, #PB_FileSystem_Force) = 0
    *res\stagingError = "project staging failed: cannot remove stale staged executable " + exe$
  EndIf
  If *res\stagingError = "" And fallback$ <> exe$ And FileSize(fallback$) >= 0 And DeleteFile(fallback$, #PB_FileSystem_Force) = 0
    *res\stagingError = "project staging failed: cannot remove stale fallback executable " + fallback$
  EndIf

  If *res\stagingError = ""
    CompilerStepWithRetry(CompilerExe$, #SW_CONSOLE$, copy\file, exe$, @*res\compileRes)
  EndIf
  *res\compileDurationMs = *res\compileRes\durationMs
  NewList ignoredWarnings.DiagT()
  ParseDiagnostics(*res\compileRes\stdout, *res\compileErrors(), ignoredWarnings())

  Protected compileFailed.i = Bool(*res\compileRes\spawnFailed Or *res\compileRes\exitCode <> 0 Or ListSize(*res\compileErrors()) > 0)

  If compileFailed = #False
    ; defense in depth: if the output switch was ignored but the compiler
    ; fell back to its default name in its cwd (the temp dir), use that.
    ; The fallback name follows the per-OS output naming (Windows: the 5.73
    ; default PureBasic.exe; Linux: extension-less).
    Protected actual$ = ""
    If FileSize(exe$) >= 0
      actual$ = exe$
    ElseIf FileSize(fallback$) >= 0
      actual$ = fallback$
    EndIf
    If actual$ = ""
      *res\noExecutable = #True
    Else
      RunProcessCapture(actual$, JoinArgs(ProgArgs$()), runCwd$, TimeoutMs, @*res\runRes)
      *res\hasRun = #True
      *res\timedOut = *res\runRes\timedOut
    EndIf
  EndIf

  CleanupTempDir(copy\dir)

  *res\durationMs = ElapsedMilliseconds() - t0
  *res\ok = Bool(*res\hasRun And *res\runRes\exitCode = 0 And *res\runRes\timedOut = #False)
EndProcedure

; ---------------------------------------------------------------------------
; pb_run handler
; ---------------------------------------------------------------------------

Procedure ToolRun(IdValue.i, Args.i)
  Protected compiler$ = ConfigCompiler()
  If compiler$ = ""
    SendTextResult(IdValue, "PureBasic compiler not found. Install PureBasic (or set PUREBASIC_HOME to its install dir) and restart the server.", #True)
    ProcedureReturn
  EndIf

  ; validate 'file' (string, min length 1, required) - shared validator
  Protected sOut.String   ; an *out.String must
  Protected issue$ = ValidateStrArg(Args, "file", 0, #True, @sOut)
  If issue$ <> ""
    SendInvalidParams(IdValue, "pb_run", issue$)
    ProcedureReturn
  EndIf
  Protected fileArg$ = sOut\s

  ; validate 'args' (array of strings, optional)
  NewList progArgs$()
  If Args
    Protected argsM.i = GetJSONMember(Args, "args")
    If argsM
      If JSONType(argsM) <> #PB_JSON_Array
        SendInvalidParams(IdValue, "pb_run", "Expected array, received " + JsonTypeName(argsM) + " at args")
        ProcedureReturn
      EndIf
      Protected k.i, e.i
      For k = 1 To JSONArraySize(argsM)
        e = GetJSONElement(argsM, k - 1)
        If JSONType(e) <> #PB_JSON_String
          SendInvalidParams(IdValue, "pb_run", "Expected string, received " + JsonTypeName(e) + " at args." + Str(k - 1))
          ProcedureReturn
        EndIf
        AddElement(progArgs$())
        progArgs$() = GetJSONString(e)
      Next
    EndIf
  EndIf

  ; validate optional projectRoot (same resolution/selection contract as pb_check)
  Protected rootOut.String
  issue$ = ValidateStrArg(Args, "projectRoot", 0, #False, @rootOut)
  If issue$ <> ""
    SendInvalidParams(IdValue, "pb_run", issue$)
    ProcedureReturn
  EndIf

  ; validate 'timeoutMs' (optional; absent = default) - shared validator
  Protected timeout.i = #DEFAULT_RUN_TIMEOUT_MS
  issue$ = ValidateIntArg(Args, "timeoutMs", 1000, #MAX_RUN_TIMEOUT_MS, @timeout)
  If issue$ <> ""
    SendInvalidParams(IdValue, "pb_run", issue$)
    ProcedureReturn
  EndIf

  Protected abs$ = ResolvePath(fileArg$)
  If FileSize(abs$) = -1
    SendTextResult(IdValue, "File not found: " + abs$, #True)
    ProcedureReturn
  EndIf

  Protected res.RunResultT
  RunConsoleProgram(compiler$, abs$, rootOut\s, progArgs$(), timeout, @res)
  If res\stagingError <> ""
    SendTextResult(IdValue, res\stagingError, #True)
    ProcedureReturn
  EndIf

  ; metrics: compile-scoped - runtime exit codes are
  ; behavior, not compile fixes; duration is the TOTAL wall time
  Protected compiled.i = Bool(ListSize(res\compileErrors()) = 0 And res\noExecutable = #False)
  NewList msgs$()
  NewList buckets$()
  ForEach res\compileErrors() : AddElement(msgs$()) : msgs$() = res\compileErrors()\message : Next
  MetricsClassifyBuckets(msgs$(), buckets$())
  MetricsAppend("pb_run", abs$, compiled, ListSize(msgs$()), buckets$(), res\durationMs)

  SendTextResult(IdValue, FormatRunResult(@res, fileArg$), Bool(Not res\ok))
EndProcedure
