; ---------------------------------------------------------------------------
; config.pb - PureBasic installation discovery + capability flags.
;
; Everything is resolved
; lazily and idempotently by ConfigInit(); tool bodies call the accessors,
; never the globals, so first use costs one ~60 ms /VERSION spawn and later
; uses are free (process-lifetime cache, same pattern as the docs index).
;
; Capability flags (evidence: mcp-pb-spike-640 probe + RESULTS-6.40.md):
;   capBannerFilter      5.73 prints a "PureBasic x.y ..." banner line on
;                        every compiler run and must filter it; 6.40 success
;                        output is totally silent, so the filter is a no-op.
;                        Kept as a no-op shim so 5.73 fallback still works.
;   capVersionExitCode   6.40 `/VERSION` prints the banner but EXITS 1. The
;                        exit code of /VERSION must therefore never be
;                        interpreted - we parse stdout only.
;
; Source-encoding rule: UTF-8 WITH BOM (see console.pb header).
; ---------------------------------------------------------------------------
EnableExplicit

; --- OS layer (Linux port Phase 1) ------------------------------------------
; One source tree, thin per-OS branches (CompilerIf / CompilerSelect). The
; Windows values are the reference; every Linux value traces to the Phase 0
; spike notes in PORTING-LINUX.md. Windows behavior is byte-identical.
CompilerSelect #PB_Compiler_OS
  CompilerCase #PB_OS_Windows
    #PathSep$    = "\"
    #BinName$    = "pbmcp.exe"
    #ExeSuffix$  = ".exe"          ; executed output keeps the extension
    #ProgReadFmt = #PB_Ascii       ; compiler output follows the console code page
    #SW_VERSION$ = "/VERSION"      ; "/"-switches are the documented Windows form
    #SW_CHECK$   = "/CHECK"
    #SW_CONSOLE$ = "/CONSOLE"
    #SW_EXE$     = "/EXE"
  CompilerCase #PB_OS_Linux
    #PathSep$    = "/"
    #BinName$    = "pbmcp"
    #ExeSuffix$  = ""              ; executed output carries no extension
    #ProgReadFmt = #PB_UTF8        ; Linux compiler output is UTF-8 (spike 0.8)
    #SW_VERSION$ = "--version"     ; "/"-switches do not exist on Linux (spike 0.1)
    #SW_CHECK$   = "--check"
    #SW_CONSOLE$ = "--console"
    #SW_EXE$     = "--output"      ; /EXE has no Linux equivalent
CompilerEndSelect

; Separator-aware path join for every *path join* outside this file's own
; OS branches (port rule: no hardcoded "\" outside the Windows branches).
Procedure.s PathJoin(A$, B$)
  If A$ = "" : ProcedureReturn B$ : EndIf
  If Right(A$, 1) = #PathSep$ : ProcedureReturn A$ + B$ : EndIf
  ProcedureReturn A$ + #PathSep$ + B$
EndProcedure

#VERSION_TIMEOUT_MS = 15000   ; /VERSION spawn budget

Global gConfigReady.i = #False
Global gPbHome$       = ""
Global gCompilerPath$ = ""
Global gPbVersion$    = ""
Global gCapBannerFilter.i    = #True   ; conservative defaults until init:
Global gCapVersionExitCode.i = #True   ; filter on, never trust exit codes

; --- version detect (shared: config discovery + index builder) -------------
; Spawns <compilerPath> with the version switch, drains stdout with a timeout
; poll, and regexes "PureBasic\s+(\d+\.\d+)" over the output. Exit code ignored
; on purpose (6.40 /VERSION exits 1). Returns "" when detection fails.
Procedure.s ConfigDetectVersion(compilerPath$)
  Protected p.i = RunProgram(compilerPath$, #SW_VERSION$, "",
                             #PB_Program_Open | #PB_Program_Read | #PB_Program_Hide)
  If p = 0 : ProcedureReturn "" : EndIf
  Protected out$ = "", t0.i = ElapsedMilliseconds()
  While ProgramRunning(p) And ElapsedMilliseconds() - t0 < #VERSION_TIMEOUT_MS
    If AvailableProgramOutput(p)
      out$ + ReadProgramString(p, #ProgReadFmt) + Chr(10)
    Else
      Delay(5)
    EndIf
  Wend
  If ProgramRunning(p) : KillProgram(p) : EndIf
  While AvailableProgramOutput(p)   ; drain what is left after exit
    out$ + ReadProgramString(p, #ProgReadFmt) + Chr(10)
  Wend
  CloseProgram(p)

  Protected version$ = ""
  Protected re.i = CreateRegularExpression(#PB_Any, "PureBasic\s+(\d+\.\d+)")
  If re
    If ExamineRegularExpression(re, out$)
      If NextRegularExpressionMatch(re)
        version$ = RegularExpressionGroup(re, 1)
      EndIf
    EndIf
    FreeRegularExpression(re)
  EndIf
  ProcedureReturn version$
EndProcedure

; --- accessors (each implies ConfigInit) -----------------------------------
Procedure ConfigInit()
  If gConfigReady : ProcedureReturn : EndIf
  gConfigReady = #True   ; set first: no re-entrancy on failure paths

  CompilerSelect #PB_Compiler_OS
    CompilerCase #PB_OS_Windows
      ; candidate list, plan order: PUREBASIC_HOME > Program Files (x86) >
      ; Program Files > C:\PureBasic > per-user install. The last entry is
      ; PB 6.40's default per-user install location (and where build.cmd looks
      ; on this machine).
      Protected NewList candidates$()
      Protected env$ = GetEnvironmentVariable("PUREBASIC_HOME")
      Protected lad$ = GetEnvironmentVariable("LOCALAPPDATA")
      If env$ <> "" : AddElement(candidates$()) : candidates$() = env$ : EndIf
      AddElement(candidates$()) : candidates$() = "C:\Program Files (x86)\PureBasic"
      AddElement(candidates$()) : candidates$() = "C:\Program Files\PureBasic"
      AddElement(candidates$()) : candidates$() = "C:\PureBasic"
      If lad$ <> ""
        AddElement(candidates$())
        candidates$() = lad$ + "\Programs\PureBasic"
      EndIf

      ; isPbHome: directory exists AND carries the compiler.
      ForEach candidates$()
        Protected home$ = candidates$()
        If Right(home$, 1) = "\" : home$ = Left(home$, Len(home$) - 1) : EndIf
        ; FileSize: -1 = missing, -2 = directory (a valid home), >= 0 = file size
        If FileSize(home$) = -1 : Continue : EndIf
        If FileSize(home$ + "\Compilers\pbcompiler.exe") >= 0
          gPbHome$ = home$
          Break
        EndIf
      Next

      If gPbHome$ = "" : ProcedureReturn : EndIf   ; no install: tools report the error
      gCompilerPath$ = gPbHome$ + "\Compilers\pbcompiler.exe"

    CompilerCase #PB_OS_Linux
      ; Spike 0.4: no fixed install dir (users unpack anywhere, register.sh
      ; uses cwd or PUREBASIC_HOME). Candidate list per the plan:
      ; PUREBASIC_HOME > ~/purebasic > /opt/purebasic > /usr/local/purebasic,
      ; binary <home>/compilers/pbcompiler (LOWERCASE "compilers" - Linux is
      ; case-sensitive). gcc must be on PATH for linking (compiler's problem,
      ; surfaced through its own diagnostics).
      Protected NewList candidates$()
      Protected lenv$ = GetEnvironmentVariable("PUREBASIC_HOME")
      If lenv$ <> "" : AddElement(candidates$()) : candidates$() = lenv$ : EndIf
      AddElement(candidates$()) : candidates$() = GetHomeDirectory() + "purebasic"
      AddElement(candidates$()) : candidates$() = "/opt/purebasic"
      AddElement(candidates$()) : candidates$() = "/usr/local/purebasic"
      ForEach candidates$()
        Protected lhome$ = candidates$()
        If Right(lhome$, 1) = "/" : lhome$ = Left(lhome$, Len(lhome$) - 1) : EndIf
        If FileSize(lhome$) = -1 : Continue : EndIf
        If FileSize(lhome$ + "/compilers/pbcompiler") >= 0
          gPbHome$ = lhome$
          Break
        EndIf
      Next
      If gPbHome$ <> ""
        gCompilerPath$ = gPbHome$ + "/compilers/pbcompiler"
      Else
        ; last resort: bare name, resolved through PATH by RunProgram
        ; (gPbHome$ stays "" - only the compiler path is known)
        gCompilerPath$ = "pbcompiler"
      EndIf
  CompilerEndSelect

  gPbVersion$ = ConfigDetectVersion(gCompilerPath$)

  ; capability flags from the detected major version (conservative defaults
  ; when the version string is missing: filter on, exit codes never trusted)
  Protected major.i = Val(StringField(gPbVersion$, 1, "."))
  If major >= 6
    gCapBannerFilter    = #False  ; 6.x success output is silent
    gCapVersionExitCode = #True   ; 6.40 /VERSION exits 1
  Else
    gCapBannerFilter    = #True   ; 5.x prints the banner, exits 0
    gCapVersionExitCode = #False
  EndIf
EndProcedure

Procedure.s ConfigPbHome()
  ConfigInit()
  ProcedureReturn gPbHome$
EndProcedure

Procedure.s ConfigCompiler()
  ConfigInit()
  ProcedureReturn gCompilerPath$
EndProcedure

Procedure.s ConfigVersion()
  ConfigInit()
  ProcedureReturn gPbVersion$
EndProcedure

Procedure ConfigCapBannerFilter()
  ConfigInit()
  ProcedureReturn gCapBannerFilter
EndProcedure

Procedure ConfigCapVersionExitCode()
  ConfigInit()
  ProcedureReturn gCapVersionExitCode
EndProcedure

; --- path resolution -------------------------------------------------------
; Tool handlers resolve user-supplied paths against the server cwd.
; Windows: forward slashes become backslashes, '.' and '..' segments
; collapse, relative paths anchor at the current directory. UNC paths pass
; through untouched; drive-relative paths anchor at the cwd's drive.
; Linux (port Phase 1): leading "/" = absolute, "/" kept, '.'/'..' collapse,
; relative paths anchor at the cwd; no drive or UNC logic. Tool-facing
; semantics on both OSes: absolute paths in, absolute paths out.
Procedure.s ResolvePath(P$)
  CompilerIf #PB_Compiler_OS = #PB_OS_Linux
    Protected lroot$ = "", lrest$ = P$
    If Left(lrest$, 1) = "/"
      lroot$ = "/"
      lrest$ = Mid(lrest$, 2)
    Else
      lroot$ = GetCurrentDirectory()
      If Right(lroot$, 1) <> "/" : lroot$ + "/" : EndIf
    EndIf
    ; segment walk: drop empty/".", pop on ".." (same walk as the Windows
    ; branch - golden behavior, separator-swapped only)
    Protected NewList lsegs$()
    Protected ln.i = CountString(lrest$, "/") + 1, li.i, lseg$
    For li = 1 To ln
      lseg$ = StringField(lrest$, li, "/")
      If lseg$ = "" Or lseg$ = "." : Continue : EndIf
      If lseg$ = ".."
        If ListSize(lsegs$()) > 0
          LastElement(lsegs$())
          DeleteElement(lsegs$())
        EndIf
      Else
        AddElement(lsegs$())
        lsegs$() = lseg$
      EndIf
    Next
    If ListSize(lsegs$()) = 0 : ProcedureReturn lroot$ : EndIf
    Protected lout$ = lroot$
    Protected lfirst.i = #True
    ForEach lsegs$()
      If Not lfirst : lout$ + "/" : EndIf
      lout$ + lsegs$()
      lfirst = #False
    Next
    ProcedureReturn lout$
  CompilerEndIf
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
  Protected s$ = ReplaceString(P$, "/", "\")
  Protected root$ = "", rest$ = "", c$
  If Len(s$) >= 2 And Mid(s$, 2, 1) = ":"
    c$ = UCase(Left(s$, 1))
    If c$ >= "A" And c$ <= "Z"
      If Mid(s$, 3, 1) = "\"
        root$ = Left(s$, 3)
        rest$ = Mid(s$, 4)
      Else
        root$ = Left(s$, 2) + "\"   ; "C:file" - drive-relative edge, anchor at drive root
        rest$ = Mid(s$, 3)
      EndIf
    EndIf
  ElseIf Left(s$, 2) = "\\"
    ProcedureReturn s$              ; UNC - pass through
  ElseIf Left(s$, 1) = "\"
    root$ = Left(GetCurrentDirectory(), 3)   ; \foo -> <cwd drive>\foo
    rest$ = Mid(s$, 2)
  Else
    root$ = GetCurrentDirectory()
    If Right(root$, 1) <> "\" : root$ + "\" : EndIf
    rest$ = s$
  EndIf
  ; segment walk: drop empty/".", pop on ".."
  Protected NewList segs$()
  Protected n.i = CountString(rest$, "\") + 1, i.i, seg$
  For i = 1 To n
    seg$ = StringField(rest$, i, "\")
    If seg$ = "" Or seg$ = "." : Continue : EndIf
    If seg$ = ".."
      If ListSize(segs$()) > 0
        LastElement(segs$())
        DeleteElement(segs$())
      EndIf
    Else
      AddElement(segs$())
      segs$() = seg$
    EndIf
  Next
  If ListSize(segs$()) = 0 : ProcedureReturn root$ : EndIf
  Protected out$ = root$
  Protected first.i = #True
  ForEach segs$()
    If Not first : out$ + "\" : EndIf
    out$ + segs$()
    first = #False
  Next
  ProcedureReturn out$
  CompilerEndIf
EndProcedure

; --- cache dir -------------------------------------------------------------
; Windows: %LOCALAPPDATA%\purebasic-mcp holds the docs index + metrics.jsonl.
; Linux (port Phase 1): ${XDG_CACHE_HOME:-~/.cache}/purebasic-mcp.
Procedure.s ConfigCacheDir()
  CompilerIf #PB_Compiler_OS = #PB_OS_Linux
    Protected base$ = GetEnvironmentVariable("XDG_CACHE_HOME")
    If base$ = ""
      base$ = GetHomeDirectory() + ".cache"   ; GetHomeDirectory ends with "/"
    EndIf
    ProcedureReturn base$ + "/purebasic-mcp"
  CompilerEndIf
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
  Protected lad$ = GetEnvironmentVariable("LOCALAPPDATA")
  If lad$ = "" : lad$ = GetEnvironmentVariable("USERPROFILE") + "\AppData\Local" : EndIf
  ProcedureReturn lad$ + "\purebasic-mcp"
  CompilerEndIf
EndProcedure

; mkdir -p equivalent for the cache dir (CreateDirectory is single-level;
; create each missing level, skip existing). Separator-aware: on Windows the
; root prefix "X:\" (3 chars) is skipped, on Linux the leading "/" (1 char).
Procedure ConfigEnsureCacheDir()
  Protected path$ = ConfigCacheDir()
  Protected skip.i = 1
  CompilerIf #PB_Compiler_OS = #PB_OS_Windows
    skip = 3   ; skip "X:\"
  CompilerEndIf
  Protected i.i, part$
  For i = skip + 1 To Len(path$)
    If Mid(path$, i, 1) = #PathSep$
      part$ = Left(path$, i - 1)
      If FileSize(part$) = -1 : CreateDirectory(part$) : EndIf
    EndIf
  Next
  If FileSize(path$) = -1 : CreateDirectory(path$) : EndIf
EndProcedure
