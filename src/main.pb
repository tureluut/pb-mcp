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
;
; Author:  Tureluut - https://www.tureluut.be
; License: MIT - see LICENSE in the repository root
;
; Build:  build.cmd            (encoding lint + 6.40 compile)
; Check:  build.cmd check      (6.40 /CHECK on the real tree - authoritative;
;                               pi's pb_check cannot resolve relative includes)
;
; Include order matters (single pass): console -> jsonrpc -> config ->
; metrics -> docs_index -> tool_check (shared pipeline) -> tool_run -> tools.
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

StdinCapture()   ; MUST precede OpenConsole() - PB's Linux OpenConsole
                  ; dup()s stdin to an internal fd and CLOSES fd 0 (see
                  ; console.pb); no-op on Windows
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
If arg$ = "scan"
  RunScanMode()
ElseIf arg$ = "version" Or arg$ = "--version" Or arg$ = "-v"
  RunVersionMode()
ElseIf arg$ = "test"
  RunFile(ProgramParameter(1))
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
