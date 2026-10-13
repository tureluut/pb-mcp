; ---------------------------------------------------------------------------
; metrics.pb - JSONL metrics logging + error-bucket classification.
;
; The record schema is FROZEN so the analysis tooling keeps
; reading the same file unchanged:
;
;   %LOCALAPPDATA%\purebasic-mcp\metrics.jsonl   (Linux: XDG cache dir -
;     ${XDG_CACHE_HOME:-~/.cache}/purebasic-mcp - see ConfigCacheDir)
;   override:  PUREBASIC_MCP_METRICS=<path>
;   opt-out:   PUREBASIC_MCP_NO_METRICS=1   (no writes, tools unaffected)
;
;   {"ts":"...","source":"mcp","tool":"pb_check","file":"...","ok":true,
;    "errorCount":0,"buckets":[],"durationMs":12}
;
; Timestamp note: records carry local time in ISO form without a zone
; suffix (PB core has no UTC conversion). JavaScript's Date.parse treats
; offset-less ISO as LOCAL time, which resolves to the same absolute
; instant - episode-gap math over the log stays correct.
;
; Scope note (plan wording "every tools/call"): ONLY the compiler tools
; (pb_check, pb_run) are logged - tools/call of the docs tools produce no
; record (plan section 7).
;
; Fire-and-forget rule: a metrics failure must be invisible to the
; agent - every failure path returns silently and stdout is never touched.
; ---------------------------------------------------------------------------
EnableExplicit

#METRICS_SOURCE$ = "mcp"

; --- classifier: 21 frozen error-bucket rules ------------------------------
; Order is priority (first match wins per message). Patterns are PCRE and
; used verbatim; #PB_RegularExpression_NoCase reproduces the JS /i flag.
; PB string literals need no backslash escaping - patterns read as-is.
#N_RULES = 21

#RULE_IDX_DECLARATION_FIRST = 0    ; 0..2   declaration
#RULE_IDX_UNKNOWN_FIRST     = 3    ; 3..4   unknown-command
#RULE_IDX_WRONGSIG_FIRST    = 5    ; 5..8   wrong-signature
#RULE_IDX_TYPEMISMATCH_FIRST = 9   ; 9..12  type-mismatch
#RULE_IDX_SYNTAX_FIRST      = 13   ; 13..20 syntax

Global Dim gRule.i(#N_RULES - 1)
Global gRulesReady.i = #False

Procedure MetricsRulesInit()
  Protected i.i
  For i = 0 To #N_RULES - 1 : gRule(i) = 0 : Next
  ; declaration - EnableExplicit and friends
  gRule(0)  = CreateRegularExpression(#PB_Any, "\b(?:variables?|arrays?|lists?|maps?)\b[^.]*\bto be declared\b", #PB_RegularExpression_NoCase)
  gRule(1)  = CreateRegularExpression(#PB_Any, "\bis not declared\b", #PB_RegularExpression_NoCase)
  gRule(2)  = CreateRegularExpression(#PB_Any, "\bmust be declared\b", #PB_RegularExpression_NoCase)
  ; unknown-command - the called name does not exist (classic VB-ism);
  ; covers every "is not a function, array, list, map or macro" enumeration
  gRule(3)  = CreateRegularExpression(#PB_Any, "\bis not a function\b", #PB_RegularExpression_NoCase)
  gRule(4)  = CreateRegularExpression(#PB_Any, "\bunknown (?:command|function)\b", #PB_RegularExpression_NoCase)
  ; wrong-signature - name exists, arity is off (three 5.73 wordings captured
  ; live in the dogfood logs)
  gRule(5)  = CreateRegularExpression(#PB_Any, "\btoo many parameters?\b", #PB_RegularExpression_NoCase)
  gRule(6)  = CreateRegularExpression(#PB_Any, "\bnot enough parameters?\b", #PB_RegularExpression_NoCase)
  gRule(7)  = CreateRegularExpression(#PB_Any, "\bwrong number of parameters?\b", #PB_RegularExpression_NoCase)
  gRule(8)  = CreateRegularExpression(#PB_Any, "\bincorrect number of parameters\b", #PB_RegularExpression_NoCase)
  ; type-mismatch - real-semantics slips, NOT hallucinated syntax
  gRule(9)  = CreateRegularExpression(#PB_Any, "\bmismatch\b", #PB_RegularExpression_NoCase)
  gRule(10) = CreateRegularExpression(#PB_Any, "\bdoes not match the\b", #PB_RegularExpression_NoCase)
  gRule(11) = CreateRegularExpression(#PB_Any, "\bcannot be used as a\b", #PB_RegularExpression_NoCase)
  gRule(12) = CreateRegularExpression(#PB_Any, "\bbad parameter type\b", #PB_RegularExpression_NoCase)
  ; syntax - structure/keyword errors incl. the compiler's usage-reminder form
  gRule(13) = CreateRegularExpression(#PB_Any, "\bis missing\b", #PB_RegularExpression_NoCase)
  gRule(14) = CreateRegularExpression(#PB_Any, "\bsyntax error\b", #PB_RegularExpression_NoCase)
  gRule(15) = CreateRegularExpression(#PB_Any, "\bsyntax is:", #PB_RegularExpression_NoCase)
  gRule(16) = CreateRegularExpression(#PB_Any, "\bonly supported with keywords\b", #PB_RegularExpression_NoCase)
  gRule(17) = CreateRegularExpression(#PB_Any, "\bcan'?t have a type\b", #PB_RegularExpression_NoCase)
  gRule(18) = CreateRegularExpression(#PB_Any, "\billegal\b", #PB_RegularExpression_NoCase)
  gRule(19) = CreateRegularExpression(#PB_Any, "\bwithout a matching\b", #PB_RegularExpression_NoCase)
  gRule(20) = CreateRegularExpression(#PB_Any, "\bunclosed\b", #PB_RegularExpression_NoCase)
  gRulesReady = #True
EndProcedure

; Bucket name for a rule index (frozen bucket names, fixed rule order).
Procedure.s MetricsRuleBucket(RuleIndex.i)
  If RuleIndex >= #RULE_IDX_DECLARATION_FIRST And RuleIndex < #RULE_IDX_UNKNOWN_FIRST
    ProcedureReturn "declaration"
  ElseIf RuleIndex >= #RULE_IDX_UNKNOWN_FIRST And RuleIndex < #RULE_IDX_WRONGSIG_FIRST
    ProcedureReturn "unknown-command"
  ElseIf RuleIndex >= #RULE_IDX_WRONGSIG_FIRST And RuleIndex < #RULE_IDX_TYPEMISMATCH_FIRST
    ProcedureReturn "wrong-signature"
  ElseIf RuleIndex >= #RULE_IDX_TYPEMISMATCH_FIRST And RuleIndex < #RULE_IDX_SYNTAX_FIRST
    ProcedureReturn "type-mismatch"
  EndIf
  ProcedureReturn "syntax"
EndProcedure

; Classify one compiler error message; "other" when nothing matches.
Procedure.s MetricsClassifyError(Message$)
  If Not gRulesReady : MetricsRulesInit() : EndIf
  Protected i.i
  For i = 0 To #N_RULES - 1
    If gRule(i) And MatchRegularExpression(gRule(i), Message$)
      ProcedureReturn MetricsRuleBucket(i)
    EndIf
  Next
  ProcedureReturn "other"
EndProcedure

; Distinct buckets for one compile event's messages, in the frozen priority
; order (declaration, unknown-command, wrong-signature, type-mismatch,
; syntax, other). Fills buckets$(); the
; caller serializes it into the record (names are safe JSON literals).
Procedure MetricsClassifyBuckets(List messages$(), List buckets$())
  ClearList(buckets$())
  Dim seen.i(5)   ; the 5 fixed buckets; "other" tracked separately
  Protected otherSeen.i = #False, b$ = ""
  NewMap order.i()
  order("declaration") = 0
  order("unknown-command") = 1
  order("wrong-signature") = 2
  order("type-mismatch") = 3
  order("syntax") = 4
  ResetList(messages$())
  While NextElement(messages$())
    b$ = MetricsClassifyError(messages$())
    If FindMapElement(order(), b$)
      seen(order(b$)) = #True
    Else
      otherSeen = #True
    EndIf
  Wend
  If seen(0) : AddElement(buckets$()) : buckets$() = "declaration" : EndIf
  If seen(1) : AddElement(buckets$()) : buckets$() = "unknown-command" : EndIf
  If seen(2) : AddElement(buckets$()) : buckets$() = "wrong-signature" : EndIf
  If seen(3) : AddElement(buckets$()) : buckets$() = "type-mismatch" : EndIf
  If seen(4) : AddElement(buckets$()) : buckets$() = "syntax" : EndIf
  If otherSeen : AddElement(buckets$()) : buckets$() = "other" : EndIf
EndProcedure

; --- logging ---------------------------------------------------------------
; The record line is hand-built (not ComposeJSON) because ComposeJSON does
; not preserve member insertion order; consumers read the frozen field order
; ts,source,tool,file,ok,errorCount,buckets,durationMs exactly.

; Escaping (JsonEscape/JsonQ) lives in jsonrpc.pb - hoisted there
; so the tools/list builders can reuse it too.
Procedure MetricsEnabled()
  ProcedureReturn Bool(GetEnvironmentVariable("PUREBASIC_MCP_NO_METRICS") <> "1")
EndProcedure

Procedure.s MetricsPath()
  Protected p$ = GetEnvironmentVariable("PUREBASIC_MCP_METRICS")
  If p$ = "" : p$ = PathJoin(ConfigCacheDir(), "metrics.jsonl") : EndIf
  ProcedureReturn p$
EndProcedure

; Append one frozen-shape record. ok = compile success (for pb_run:
; compile-scoped per the frozen definition - runtime exit codes are behavior,
; not compile fixes). Buckets$() is serialized as the record's buckets array.
Procedure MetricsAppend(Tool$, File$, Ok.i, ErrorCount.i, List Buckets$(), DurationMs.i)
  If Not MetricsEnabled() : ProcedureReturn : EndIf
  Protected path$ = MetricsPath()
  Protected ok$ = "false"
  If Ok : ok$ = "true" : EndIf
  Protected buckets$ = "[", first.i = #True
  ResetList(Buckets$())
  While NextElement(Buckets$())
    If Not first : buckets$ + "," : EndIf
    buckets$ + JsonQ(Buckets$())
    first = #False
  Wend
  buckets$ + "]"
  Protected line$ = "{" + JsonQ("ts") + ":" + JsonQ(FormatDate("%yyyy-%mm-%ddT%hh:%ii:%ss", Date()))
  line$ + "," + JsonQ("source") + ":" + JsonQ(#METRICS_SOURCE$)
  line$ + "," + JsonQ("tool") + ":" + JsonQ(Tool$)
  line$ + "," + JsonQ("file") + ":" + JsonQ(File$)
  line$ + "," + JsonQ("ok") + ":" + ok$
  line$ + "," + JsonQ("errorCount") + ":" + Str(ErrorCount)
  line$ + "," + JsonQ("buckets") + ":" + buckets$
  line$ + "," + JsonQ("durationMs") + ":" + Str(DurationMs) + "}"

  ; append fire-and-forget: create parent dirs, create-or-append, UTF-8
  Protected f.i = OpenFile(#PB_Any, path$, #PB_File_Append)
  If f = 0
    ConfigEnsureCacheDir()
    f = OpenFile(#PB_Any, path$, #PB_File_Append)
  EndIf
  If f = 0 : ProcedureReturn : EndIf   ; metrics failure stays invisible
  WriteString(f, line$ + Chr(10), #PB_UTF8)
  CloseFile(f)
EndProcedure
