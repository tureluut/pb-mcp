; ---------------------------------------------------------------------------
; jsonrpc.pb - JSON-RPC 2.0 request parse + response/error builders.
;
; Provenance: adapted from mcp-pb-spike-640/mcp_server.pb (protocol core
; verified 8/8 on PB 6.40). The tool hooks (ToolList / ToolDispatch) are
; declared here and implemented in tools.pb to break the include cycle.
; ---------------------------------------------------------------------------
EnableExplicit

Declare ToolList(IdValue.i)
Declare ToolDispatch(IdValue.i, Params.i)

#PROTOCOL_VERSION$ = "2025-03-26"
#SERVER_NAME$      = "purebasic-mcp-pb"
#SERVER_VERSION$   = "0.3.3"   ; 0.3.3: pb_check best-practices support (proc-scope hints, always-on lint)

; serverInfo.version and the version CLI line share ServerVersionFull().
; The build stamp is the COMPILE date (#PB_Compiler_Date): a PB constant
; cannot call functions (probe-verified), so a procedure derives it per
; call - every rebuild stamps itself, no hand-maintained date constant.
Procedure.s ServerVersionFull()
  ProcedureReturn #SERVER_VERSION$ + " (build " + FormatDate("%yyyy-%mm-%dd", #PB_Compiler_Date) + ")"
EndProcedure
; NO global output cap: truncation happens inside the formatters (docs
; search 8000 / command 14000 / check 8000 / run caps) - a global cap here
; would clip long pb_run results that fit under their per-tool caps.

; ---------------------------------------------------------------------------
; JSON string escaping (shared with metrics.pb; metrics.pb used to carry a
; private copy, hoisted here).
; ---------------------------------------------------------------------------
Procedure.s JsonEscape(s$)
  Protected out$ = ReplaceString(s$, "\", "\\")
  out$ = ReplaceString(out$, Chr(34), "\" + Chr(34))
  out$ = ReplaceString(out$, Chr(8), "\b")
  out$ = ReplaceString(out$, Chr(12), "\f")
  out$ = ReplaceString(out$, Chr(10), "\n")
  out$ = ReplaceString(out$, Chr(13), "\r")
  out$ = ReplaceString(out$, Chr(9), "\t")
  ; The replaces above already turned \b \f \n \r \t into plain
  ; two-char text, so the only chars < 32 still present are 0-7, 11 and
  ; 14-31 - rare in practice. Scan for them on the raw buffer (PeekU reads
  ; the same code units the old per-char Asc(Mid()) loop compared;
  ; SizeOf(Character) keeps the stride correct; Unicode build assumed by
  ; PeekU). Strings without a control char - the normal case - return in
  ; one piece; otherwise whole spans between controls are appended with
  ; one Mid() each, followed by the identical "\u00xx" escape. Byte-for-
  ; byte output equivalence with the old per-char loop is verified
  ; exhaustively (140/140 identical incl. all controls 0-31,
  ; surrogate pair, U+FFFD, multibyte).
  Protected i.i, n.i = Len(out$), start.i, c.i, res$ = "", *p
  If n = 0 : ProcedureReturn "" : EndIf
  *p = @out$
  For i = 0 To n - 1
    If PeekU(*p + i * SizeOf(Character)) < 32 : Break : EndIf
  Next
  If i >= n : ProcedureReturn out$ : EndIf
  start = 1
  While start <= n
    *p = @out$ + (start - 1) * SizeOf(Character)
    i = 0
    While start + i <= n And PeekU(*p + i * SizeOf(Character)) >= 32 : i + 1 : Wend
    If i > 0 : res$ + Mid(out$, start, i) : EndIf
    If start + i <= n
      c = PeekU(*p + i * SizeOf(Character))
      res$ + "\u00" + RSet(Hex(c), 2, "0")
      start = start + i + 1
    Else
      Break
    EndIf
  Wend
  ProcedureReturn res$
EndProcedure

Procedure.s JsonQ(s$)
  ProcedureReturn Chr(34) + JsonEscape(s$) + Chr(34)
EndProcedure

; ---------------------------------------------------------------------------
; response builders
; ---------------------------------------------------------------------------
Procedure CopyId(IdValue.i, Root.i)
  Protected m.i = AddJSONMember(Root, "id")
  Select JSONType(IdValue)
    Case #PB_JSON_Number
      SetJSONInteger(m, GetJSONInteger(IdValue))
    Case #PB_JSON_String
      SetJSONString(m, GetJSONString(IdValue))
    Default
      SetJSONNull(m)
  EndSelect
EndProcedure

; Response doc with jsonrpc + id (if any) + empty "result" object.
; Reach the result via GetJSONMember(JSONValue(json), "result").
Procedure.i BeginResponse(IdValue.i)
  Protected json.i = CreateJSON(#PB_Any)
  Protected root.i = JSONValue(json)
  SetJSONObject(root)
  SetJSONString(AddJSONMember(root, "jsonrpc"), "2.0")
  If IdValue
    CopyId(IdValue, root)
  EndIf
  Protected res.i = AddJSONMember(root, "result")
  SetJSONObject(res)
  ProcedureReturn json
EndProcedure

Procedure FinishResponse(json.i)
  WriteLine(ComposeJSON(json))
  FreeJSON(json)
EndProcedure

Procedure SendError(IdValue.i, Code.i, Message$)
  Protected json.i = CreateJSON(#PB_Any)
  Protected root.i = JSONValue(json)
  SetJSONObject(root)
  SetJSONString(AddJSONMember(root, "jsonrpc"), "2.0")
  If IdValue
    CopyId(IdValue, root)
  Else
    SetJSONNull(AddJSONMember(root, "id"))
  EndIf
  Protected err.i = AddJSONMember(root, "error")
  SetJSONObject(err)
  SetJSONInteger(AddJSONMember(err, "code"), Code)
  SetJSONString(AddJSONMember(err, "message"), Message$)
  FinishResponse(json)
EndProcedure

; tools/call result with a single text content item
Procedure SendTextResult(IdValue.i, Text$, IsError.i)
  Protected json.i = BeginResponse(IdValue)
  Protected result.i = GetJSONMember(JSONValue(json), "result")
  Protected content.i = AddJSONMember(result, "content")
  SetJSONArray(content)
  Protected item.i = AddJSONElement(content)
  SetJSONObject(item)
  SetJSONString(AddJSONMember(item, "type"), "text")
  SetJSONString(AddJSONMember(item, "text"), Text$)
  SetJSONBoolean(AddJSONMember(result, "isError"), IsError)
  FinishResponse(json)
EndProcedure

Procedure.s MemberStr(Obj.i, Key$, Default$)
  If Obj = 0 : ProcedureReturn Default$ : EndIf
  Protected m.i = GetJSONMember(Obj, Key$)
  If m And JSONType(m) = #PB_JSON_String
    ProcedureReturn GetJSONString(m)
  EndIf
  ProcedureReturn Default$
EndProcedure

; invalid_type wording for "Expected X, received Y": JSON type -> name
Procedure.s JsonTypeName(Value.i)
  Select JSONType(Value)
    Case #PB_JSON_String  : ProcedureReturn "string"
    Case #PB_JSON_Number  : ProcedureReturn "number"
    Case #PB_JSON_Boolean : ProcedureReturn "boolean"
    Case #PB_JSON_Null    : ProcedureReturn "null"
    Case #PB_JSON_Array   : ProcedureReturn "array"
  EndSelect
  ProcedureReturn "object"
EndProcedure

; ---------------------------------------------------------------------------
; argument validators (single-sourced here: jsonrpc.pb is included before
; every user — tools.pb, tool_check.pb, tool_run.pb)
; ---------------------------------------------------------------------------

; Required/optional string prop.
; Returns "" when valid and fills *out\s; else the issue text. Optional
; (= Required #False): absent is VALID and yields "" - a bare "Required at
; <key>" for the optional 'library' was wrong (found while
; writing the harness; only truly required props report Required).
Procedure.s ValidateStrArg(Args.i, Key$, MaxLen.i, Required.i, *out.String)
  Protected m.i = 0
  If Args : m = GetJSONMember(Args, Key$) : EndIf
  If m = 0
    If Required : ProcedureReturn "Required at " + Key$ : EndIf
    *out\s = ""
    ProcedureReturn ""
  ElseIf JSONType(m) <> #PB_JSON_String
    ProcedureReturn "Expected string, received " + JsonTypeName(m) + " at " + Key$
  ElseIf GetJSONString(m) = ""
    ProcedureReturn "String must contain at least 1 character(s) at " + Key$
  ElseIf MaxLen > 0 And Len(GetJSONString(m)) > MaxLen
    ProcedureReturn "String must contain at most " + Str(MaxLen) + " character(s) at " + Key$
  EndIf
  *out\s = GetJSONString(m)
  ProcedureReturn ""
EndProcedure

; Optional integer prop in [MinV, MaxV] (absent = default). "" = valid.
; The caller presets *outVal\i with the default - absent leaves it untouched.
Procedure.s ValidateIntArg(Args.i, Key$, MinV.i, MaxV.i, *outVal.Integer)
  If Args = 0 : ProcedureReturn "" : EndIf
  Protected m.i = GetJSONMember(Args, Key$)
  If m = 0 : ProcedureReturn "" : EndIf
  If JSONType(m) <> #PB_JSON_Number
    ProcedureReturn "Expected number, received " + JsonTypeName(m) + " at " + Key$
  EndIf
  Protected d.d = GetJSONDouble(m)
  If d <> Int(d)
    ProcedureReturn "Expected integer, received " + StrD(d) + " at " + Key$
  EndIf
  Protected v.i = Int(d)
  If v < MinV
    ProcedureReturn "Number must be greater than or equal to " + Str(MinV) + " at " + Key$
  EndIf
  If v > MaxV
    ProcedureReturn "Number must be less than or equal to " + Str(MaxV) + " at " + Key$
  EndIf
  *outVal\i = v
  ProcedureReturn ""
EndProcedure

; invalid-args reply shape: NOT a JSON-RPC error - an isError text result:
;   MCP error -32602: Input validation error: Invalid arguments for tool
;   <name>: <issues joined "; ">
Procedure SendInvalidParams(IdValue.i, Tool$, Issues$)
  SendTextResult(IdValue, "MCP error -32602: Input validation error: Invalid arguments for tool " + Tool$ + ": " + Issues$, #True)
EndProcedure

; ---------------------------------------------------------------------------
; request dispatch
; ---------------------------------------------------------------------------
Procedure HandleLine(Raw$)
  Protected line$ = RTrim(Trim(Raw$), Chr(13))
  If line$ = "" : ProcedureReturn : EndIf
  Protected json.i = ParseJSON(#PB_Any, line$)
  If json = 0
    SendError(0, -32700, "Parse error")
    ProcedureReturn
  EndIf
  Protected root.i = JSONValue(json)
  Protected idM.i = GetJSONMember(root, "id")   ; extracted before the method check: -32600 must echo the request id
  Protected methodM.i = GetJSONMember(root, "method")
  If methodM = 0 Or JSONType(methodM) <> #PB_JSON_String
    ; JSON-RPC 2.0: missing/non-string method is an Invalid Request ->
    ; -32600 with the id echoed (null when absent). Non-object roots
    ; (arrays/numbers - e.g. unsupported batches) land here too: they have
    ; no method member. Valid notifications with a method stay silently
    ; ignored (handled below).
    SendError(idM, -32600, "Invalid Request")
    FreeJSON(json)
    ProcedureReturn
  EndIf
  Protected method$ = GetJSONString(methodM)
  Protected isNotify.i = #False
  If idM = 0 Or JSONType(idM) = #PB_JSON_Null
    isNotify = #True
    idM = 0
  EndIf
  Protected params.i = GetJSONMember(root, "params")
  Select method$
    Case "initialize"
      If Not isNotify
        ; Version negotiation (MCP spec MUST): answer with a version the
        ; server supports - echo the client's offer only when it matches the
        ; supported version, otherwise reply with #PROTOCOL_VERSION$.
        Protected pv$ = #PROTOCOL_VERSION$
        If params
          Protected pvm.i = GetJSONMember(params, "protocolVersion")
          If pvm And JSONType(pvm) = #PB_JSON_String And GetJSONString(pvm) = #PROTOCOL_VERSION$
            pv$ = GetJSONString(pvm)
          EndIf
        EndIf
        Protected resp.i = BeginResponse(idM)
        Protected result.i = GetJSONMember(JSONValue(resp), "result")
        SetJSONString(AddJSONMember(result, "protocolVersion"), pv$)
        Protected caps.i = AddJSONMember(result, "capabilities")
        SetJSONObject(caps)
        Protected capsTools.i = AddJSONMember(caps, "tools")
        SetJSONObject(capsTools)
        SetJSONBoolean(AddJSONMember(capsTools, "listChanged"), #False)   ; static tool list - tools/list_changed can never fire
        ; (AddJSONMember with an existing name returns the SAME member - a
        ; second SetJSONObject on it would RESET tools to {} and drop
        ; listChanged; found live in the smoke test.)
        Protected info.i = AddJSONMember(result, "serverInfo")
        SetJSONObject(info)
        SetJSONString(AddJSONMember(info, "name"), #SERVER_NAME$)
        SetJSONString(AddJSONMember(info, "version"), ServerVersionFull())
        SetJSONString(AddJSONMember(result, "instructions"), "Search before writing PureBasic (pb_docs_search, pb_command), verify every edit with pb_check, and use pb_run only for bounded console tests.")
        FinishResponse(resp)
      EndIf
    Case "tools/list"
      If Not isNotify : ToolList(idM) : EndIf
    Case "tools/call"
      If Not isNotify : ToolDispatch(idM, params) : EndIf
    Case "ping"
      If Not isNotify
        Protected pong.i = BeginResponse(idM)
        FinishResponse(pong)
      EndIf
    Default
      ; notifications (initialized etc.) are silently ignored; unknown
      ; requests get JSON-RPC -32601
      If Not isNotify
        SendError(idM, -32601, "Method not found: " + method$)
      EndIf
  EndSelect
  FreeJSON(json)
EndProcedure
