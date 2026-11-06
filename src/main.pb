; ---------------------------------------------------------------------------
; main.pb - pbmcp entry point (PureBasic 6.40 x64; binary name per OS:
; pbmcp.exe on Windows, pbmcp on Linux).
;
;   pbmcp                serve MCP over stdio
;   pbmcp version        build + environment report (server/protocol/
;   pbmcp --version      PureBasic/docs versions), exit 0 (0.3.3)
;   pbmcp scan <html>    parse one command page as JSON
;   pbmcp test <file>    replay a golden .jsonl session (one msg per line)
;   pbmcp <file>         same as "test <file>" (spike compatibility)
;   pbmcp http [--port N] --auth-file PATH [--allow-compiler-tools]
;                        authenticated localhost Streamable HTTP (MCP 2025-11-25;
;                        binds 127.0.0.1 only; default port 6817)
;
; Author:  Tureluut - https://www.tureluut.be
; License: MIT - see LICENSE in the repository root
;
; Build:  build.cmd            (encoding lint + 6.40 compile)
; Check:  build.cmd check      (6.40 /CHECK on the real tree - authoritative)
;
; Include order matters (single pass): console -> jsonrpc -> config ->
; metrics -> docs_index -> tool_check (shared pipeline) -> tool_run -> tools -> http.
; Each layer only calls procedures defined earlier or forward-declared.
; ---------------------------------------------------------------------------
EnableExplicit

XIncludeFile "console.pb"   ; WriteLine / RunFile / RunStdin (declares HandleLine)
XIncludeFile "jsonrpc.pb"   ; HandleLine + response builders (declares tool hooks)
XIncludeFile "config.pb"    ; PB home discovery, /VERSION detect, capability flags, ResolvePath
XIncludeFile "metrics.pb"   ; JSONL metrics (needs config: ConfigCacheDir$, jsonrpc: JsonQ)
XIncludeFile "docs_index.pb"; index load + search + lookup (needs config, jsonrpc MemberStr)
XIncludeFile "tool_check.pb"; shared pipeline + pb_check (needs jsonrpc, config, metrics)
XIncludeFile "tool_run.pb"  ; pb_run (needs tool_check's runner/temp-copy/parsing)
XIncludeFile "tools.pb"     ; registry + docs handlers (implements the hooks)
XIncludeFile "html_scan.pb" ; HTML scanner + scan CLI mode
XIncludeFile "http.pb"      ; optional localhost Streamable HTTP transport

Procedure.i ParseHttpOptions(*port.Integer, *authPath.String, *allowCompiler.Integer, *error.String)
  *port\i = #HTTP_DEFAULT_PORT
  *allowCompiler\i = #False
  *authPath\s = ""
  Protected i.i, j.i, ch.i, value.i, text$
  Protected portSeen.i = #False, authSeen.i = #False, allowSeen.i = #False
  Protected count.i = CountProgramParameters()
  i = 1
  While i < count
    Select ProgramParameter(i)
      Case "--port"
        If portSeen Or i + 1 >= count
          *error\s = "--port must be supplied once with a value"
          ProcedureReturn #False
        EndIf
        portSeen = #True
        i + 1
        text$ = ProgramParameter(i)
        If text$ = ""
          *error\s = "--port requires an integer from 1 to 65000"
          ProcedureReturn #False
        EndIf
        value = 0
        For j = 1 To Len(text$)
          ch = Asc(Mid(text$, j, 1))
          If ch < 48 Or ch > 57
            *error\s = "--port requires an integer from 1 to 65000"
            ProcedureReturn #False
          EndIf
          value = value * 10 + ch - 48
          If value > #HTTP_MAX_PORT
            *error\s = "--port must be from 1 to 65000"
            ProcedureReturn #False
          EndIf
        Next
        If value < 1
          *error\s = "--port must be from 1 to 65000"
          ProcedureReturn #False
        EndIf
        *port\i = value
      Case "--auth-file"
        If authSeen Or i + 1 >= count
          *error\s = "--auth-file must be supplied once with a nonempty path"
          ProcedureReturn #False
        EndIf
        authSeen = #True
        i + 1
        *authPath\s = ProgramParameter(i)
        If *authPath\s = ""
          *error\s = "--auth-file must be supplied once with a nonempty path"
          ProcedureReturn #False
        EndIf
      Case "--allow-compiler-tools"
        If allowSeen
          *error\s = "--allow-compiler-tools may be supplied only once"
          ProcedureReturn #False
        EndIf
        allowSeen = #True
        *allowCompiler\i = #True
      Default
        *error\s = "unknown HTTP option: " + ProgramParameter(i)
        ProcedureReturn #False
    EndSelect
    i + 1
  Wend
  If Not authSeen
    *error\s = "http requires --auth-file <path>"
    ProcedureReturn #False
  EndIf
  ProcedureReturn #True
EndProcedure

If ProgramParameter(0) <> "http"
  StdinCapture()   ; MUST precede OpenConsole() - PB's Linux OpenConsole
                  ; dup()s stdin to an internal fd and CLOSES fd 0 (see
                  ; console.pb); no-op on Windows. HTTP does not capture stdin.
EndIf
If OpenConsole() = 0 : End 1 : EndIf

; --- version / --version / -v (0.3.3) --------------------------------------
; The same facts the pb_version tool reports to agents, on stdout for humans
; and scripts checking WHICH exe is deployed. ASCII-only: PrintN follows the
; console code page, unlike the UTF-8 WriteLine protocol channel - em-dashes
; here would mojibake in cmd.exe. Docs-index
; info costs the one-shot ~200 ms load; the compiler line costs the usual
; one-shot /VERSION spawn (~60 ms). Exit 0 even when PB/index are missing -
; a version check must not fail just because the environment is broken.
Procedure RunVersionMode()
  PrintN(#BinName$ + " " + #SERVER_NAME$ + " " + ServerVersionFull() + ", MCP protocol " + #PROTOCOL_VERSION$)
  Protected home$ = ConfigPbHome()
  Protected pb$ = ConfigVersion()
  If home$ = ""
    PrintN("PureBasic: not found (set PUREBASIC_HOME or install PureBasic)")
  ElseIf pb$ = ""
    PrintN("PureBasic: version detection failed - " + home$)
  Else
    PrintN("PureBasic " + pb$ + " - " + home$)
  EndIf
  DocsIndexEnsure()
  If DocsIndexOk()
    PrintN("Docs index: PB " + DocsIndexPbVersion() + ", built " + DocsIndexGeneratedAt() + ", " + Str(DocsCommandCount()) + " commands, " + Str(DocsReferenceCount()) + " reference pages")
    PrintN("  " + DocsIndexPath())
  Else
    PrintN("Docs index: none - " + DocsIndexDetail())
  EndIf
EndProcedure

Define arg$ = ProgramParameter(0)
Define httpPort.Integer, httpError.String, httpAuthPath.String, httpAllowCompiler.Integer
If arg$ = "scan"
  RunScanMode()
ElseIf arg$ = "version" Or arg$ = "--version" Or arg$ = "-v"
  RunVersionMode()
ElseIf arg$ = "test"
  RunFile(ProgramParameter(1))
ElseIf arg$ = "http"
  If Not ParseHttpOptions(@httpPort, @httpAuthPath, @httpAllowCompiler, @httpError)
    ConsoleError("pbmcp: " + httpError\s)
    End 2
  EndIf
  If Not HttpLoadCredentials(httpAuthPath\s)
    ConsoleError("pbmcp: invalid or unreadable HTTP credentials file")
    End 2
  EndIf
  gHttpAllowCompilerTools = httpAllowCompiler\i
  DocsPreloadStart()
  If Not HttpServe(httpPort\i)
    DocsPreloadStop()
    End 1
  EndIf
ElseIf arg$ <> ""
  RunFile(arg$)
Else
  DocsPreloadStart()   ; background docs-index preload (serve mode only;
                       ; no-op unless enabled - PBMCP_PRELOAD=0 kills it)
  RunStdin()
  DocsPreloadStop()    ; join the preload worker before teardown (0xC0000005
                       ; exit race - see docs_index.pb)
EndIf
CloseConsole()
