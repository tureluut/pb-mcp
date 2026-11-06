; ---------------------------------------------------------------------------
; tools.pb - tool registry + tools/list schemas + the two docs tools.
;
; All four tools are live. Compiler handlers live in tool_check.pb
; (pb_check) and tool_run.pb (pb_run); their results are formatted by
; FormatCheckResult / FormatRunResult over there, since the include order
; puts this file last. This file owns:
;   - tools/list schemas (names, titles, descriptions incl. em-dashes,
;     property constraints, required arrays, additionalProperties, $schema,
;     annotations). PB ComposeJSON alphabetizes object
;     members (plan gotcha), so WIRE member order is alphabetical by design -
;     consumers compare parsed structures, the values are exact.
;   - pb_docs_search / pb_command handlers incl. formatSearchResults /
;     formatCommandEntry and the did-you-mean path (per the plan's module
;     table)
;   - dispatch: unknown tool -> "MCP error -32602: Tool <name> not found"
;     as an isError text result; metrics
;     moved into the compiler handlers (dispatch-level stub removed)
;
; Source-encoding rule: UTF-8 WITH BOM (see console.pb header). The em-dashes
; in the descriptions below double as the encoding canary.
; ---------------------------------------------------------------------------
EnableExplicit

; ---------------------------------------------------------------------------
; schema builders
; ---------------------------------------------------------------------------
Procedure AddProp(Props.i, Name$, JsonType$, Desc$)
  Protected p.i = AddJSONMember(Props, Name$)
  SetJSONObject(p)
  SetJSONString(AddJSONMember(p, "type"), JsonType$)
  If Desc$ <> ""
    SetJSONString(AddJSONMember(p, "description"), Desc$)
  EndIf
EndProcedure

; string prop constraints - minLength always present, maxLength only when
; constrained (0 = none).
Procedure AddStrProp(Props.i, Name$, Desc$, MinLen.i, MaxLen.i)
  Protected p.i = AddJSONMember(Props, Name$)
  SetJSONObject(p)
  SetJSONString(AddJSONMember(p, "type"), "string")
  SetJSONInteger(AddJSONMember(p, "minLength"), MinLen)
  If MaxLen > 0 : SetJSONInteger(AddJSONMember(p, "maxLength"), MaxLen) : EndIf
  SetJSONString(AddJSONMember(p, "description"), Desc$)
EndProcedure

; z.number().int().min(m).max(M)
Procedure AddIntProp(Props.i, Name$, Desc$, MinV.i, MaxV.i)
  Protected p.i = AddJSONMember(Props, Name$)
  SetJSONObject(p)
  SetJSONString(AddJSONMember(p, "type"), "integer")
  SetJSONInteger(AddJSONMember(p, "minimum"), MinV)
  SetJSONInteger(AddJSONMember(p, "maximum"), MaxV)
  SetJSONString(AddJSONMember(p, "description"), Desc$)
EndProcedure

; z.array(z.string())
Procedure AddArrayProp(Props.i, Name$, Desc$)
  Protected p.i = AddJSONMember(Props, Name$)
  SetJSONObject(p)
  SetJSONString(AddJSONMember(p, "type"), "array")
  Protected items.i = AddJSONMember(p, "items")
  SetJSONObject(items)
  SetJSONString(AddJSONMember(items, "type"), "string")
  SetJSONString(AddJSONMember(p, "description"), Desc$)
EndProcedure

Procedure AddRequired(Schema.i, Name$)
  Protected req.i = AddJSONMember(Schema, "required")
  SetJSONArray(req)
  SetJSONString(AddJSONElement(req), Name$)
EndProcedure

; inputSchema epilogue: additionalProperties:false + draft-07 $schema,
; present on every tool schema.
Procedure FinishSchema(Schema.i)
  SetJSONBoolean(AddJSONMember(Schema, "additionalProperties"), #False)
  SetJSONString(AddJSONMember(Schema, "$schema"), "http://json-schema.org/draft-07/schema#")
EndProcedure

; Adds one tool object (name, title, description, inputSchema, annotations) to the tools array; returns its inputSchema value. -1 for
; Destructive/OpenWorld = annotation absent (only set where meaningful).
Procedure.i AddTool(Tools.i, Name$, Title$, Desc$, ReadOnlyHint.i, DestructiveHint.i, OpenWorldHint.i)
  Protected e.i = AddJSONElement(Tools)
  SetJSONObject(e)
  SetJSONString(AddJSONMember(e, "name"), Name$)
  SetJSONString(AddJSONMember(e, "title"), Title$)
  SetJSONString(AddJSONMember(e, "description"), Desc$)
  Protected schema.i = AddJSONMember(e, "inputSchema")
  SetJSONObject(schema)
  SetJSONString(AddJSONMember(schema, "type"), "object")
  Protected props.i = AddJSONMember(schema, "properties")
  SetJSONObject(props)
  Protected ann.i = AddJSONMember(e, "annotations")
  SetJSONObject(ann)
  If ReadOnlyHint : SetJSONBoolean(AddJSONMember(ann, "readOnlyHint"), #True) : EndIf
  If DestructiveHint <> -1 : SetJSONBoolean(AddJSONMember(ann, "destructiveHint"), Bool(DestructiveHint = 1)) : EndIf
  If OpenWorldHint <> -1 : SetJSONBoolean(AddJSONMember(ann, "openWorldHint"), Bool(OpenWorldHint = 1)) : EndIf
  ProcedureReturn schema
EndProcedure

; ---------------------------------------------------------------------------
; index-missing error - docs tools only
; ---------------------------------------------------------------------------
Procedure SendIndexMissing(IdValue.i)
  SendTextResult(IdValue, DocsIndexDetail() + Chr(10) + "Build the index (node tools/build-online-index.mjs) or drop index-*.json next to the executable, then restart the server.", #True)
EndProcedure

; ---------------------------------------------------------------------------
; pb_docs_search formatter
; ---------------------------------------------------------------------------
Procedure.s FormatSearchResults(List Hits.HitT(), Query$)
  If ListSize(Hits()) = 0
    ProcedureReturn "No matches for " + Chr(34) + Query$ + Chr(34) + ~". Try shorter keywords (e.g. \"window\", \"string\", \"file\")."
  EndIf
  Protected out$ = "", i.i = 0
  ForEach Hits()
    i + 1
    If i > 1 : out$ + Chr(10) : EndIf
    out$ + Str(i) + ". " + Hits()\name + " (" + Hits()\library + ")"
    If Hits()\ref : out$ + " [reference]" : EndIf
    out$ + " — " + FirstSentence(Hits()\summary)
    ; 0.3.1: reference hits carry their full-text URL (indented so the
    ; "N. " hit-line parsing and the trailer assertion below stay intact).
    ; The index stores no page text - the locator is the answer.
    If Hits()\ref
      Protected refFile.i = GetJSONElement(DocsIndexReference(), Hits()\idx)
      out$ + Chr(10) + "   full text: " + #DOCS_URL_BASE$ + MemberStr(refFile, "file", "")
    EndIf
  Next
  ProcedureReturn CapText(out$, #SEARCH_CAP) + Chr(10) + ~"Use pb_command(\"<name>\") for full syntax."
EndProcedure

; ---------------------------------------------------------------------------
; pb_command formatter
; ---------------------------------------------------------------------------

; One parameter bullet; continuation lines indented 4 spaces.
Procedure.s FormatParameter(Name$, Description$)
  Protected desc$ = ReplaceString(Description$, Chr(13) + Chr(10), Chr(10))
  desc$ = RTrim(desc$)
  Protected nLines.i = CountString(desc$, Chr(10)) + 1
  Protected head$ = "  • " + Name$ + " — " + StringField(desc$, 1, Chr(10))
  If nLines = 1 : ProcedureReturn head$ : EndIf
  Protected out$ = head$, i.i
  For i = 2 To nLines
    out$ + Chr(10) + "    " + StringField(desc$, i, Chr(10))
  Next
  ProcedureReturn out$
EndProcedure

; JoinJSONStrArray: ", "-joined string array member (os, seeAlso, syntax).
Procedure.s JoinJSONStrArray(Arr.i, Sep$)
  Protected out$ = ""
  If Arr And JSONType(Arr) = #PB_JSON_Array
    Protected k.i
    For k = 1 To JSONArraySize(Arr)
      If k > 1 : out$ + Sep$ : EndIf
      out$ + GetJSONString(GetJSONElement(Arr, k - 1))
    Next
  EndIf
  ProcedureReturn out$
EndProcedure

; Syntax and Parameters are never truncated - the final COMMAND_CAP clip can
; only eat Description/Remarks/Example/SeeAlso; the exact call signature
; always survives. Each section appends
; independently, fixed order, "\n\n" between present sections.
Procedure.s FormatCommandEntry(Entry.i)
  Protected parts$ = ""
  Protected retVal$ = Trim(MemberStr(Entry, "returnValue", ""))
  Protected desc$ = Trim(MemberStr(Entry, "description", ""))
  Protected k.i, e.i

  ; header: "name  [library]  OS: a, b" - "All" when os is empty
  Protected osArr.i = GetJSONMember(Entry, "os")
  Protected os$ = "All"
  If osArr And JSONType(osArr) = #PB_JSON_Array And JSONArraySize(osArr) > 0
    os$ = JoinJSONStrArray(osArr, ", ")
  EndIf
  parts$ = MemberStr(Entry, "name", "") + "  [" + MemberStr(Entry, "library", "") + "]  OS: " + os$

  Protected synArr.i = GetJSONMember(Entry, "syntax")
  If synArr And JSONType(synArr) = #PB_JSON_Array And JSONArraySize(synArr) > 0
    parts$ + Chr(10) + Chr(10) + "Syntax: " + JoinJSONStrArray(synArr, Chr(10) + "        ")
  EndIf

  Protected parArr.i = GetJSONMember(Entry, "parameters")
  If parArr And JSONType(parArr) = #PB_JSON_Array And JSONArraySize(parArr) > 0
    Protected par$ = ""
    For k = 1 To JSONArraySize(parArr)
      If k > 1 : par$ + Chr(10) : EndIf
      e = GetJSONElement(parArr, k - 1)
      par$ + FormatParameter(MemberStr(e, "name", ""), MemberStr(e, "description", ""))
    Next
    parts$ + Chr(10) + Chr(10) + "Parameters:" + Chr(10) + par$
  EndIf

  If retVal$ <> ""
    parts$ + Chr(10) + Chr(10) + "Returns: " + retVal$
  EndIf

  If desc$ <> "" And desc$ <> retVal$
    parts$ + Chr(10) + Chr(10) + "Description: " + CapText(OneLine(desc$), 800)
  EndIf

  Protected rem$ = Trim(MemberStr(Entry, "remarks", ""))
  If rem$ <> ""
    parts$ + Chr(10) + Chr(10) + "Remarks: " + CapText(rem$, #REMARKS_CAP)
  EndIf

  Protected ex$ = Trim(MemberStr(Entry, "example", ""))
  If ex$ <> ""
    parts$ + Chr(10) + Chr(10) + "Example:" + Chr(10) + CollapseLines(ex$)
  EndIf

  Protected seeArr.i = GetJSONMember(Entry, "seeAlso")
  If seeArr And JSONType(seeArr) = #PB_JSON_Array And JSONArraySize(seeArr) > 0
    parts$ + Chr(10) + Chr(10) + "See also: " + JoinJSONStrArray(seeArr, ", ")
  EndIf

  ProcedureReturn CapText(parts$, #COMMAND_CAP)
EndProcedure

; ---------------------------------------------------------------------------
; reference-page formatter (0.3.1)
; ---------------------------------------------------------------------------

; The index carries title/id/file/summary only - never the page text - so
; the answer is the full-text locator plus the one-fetch instruction, not
; a paraphrase of the page from its title.
Procedure.s FormatReferenceEntry(Entry.i)
  Protected title$ = MemberStr(Entry, "title", "")
  Protected summary$ = Trim(MemberStr(Entry, "summary", ""))
  Protected out$ = title$ + "  [reference page]"
  out$ + Chr(10) + Chr(10) + "Full text: " + #DOCS_URL_BASE$ + MemberStr(Entry, "file", "")
  out$ + Chr(10) + "Reference pages cover language constructs, not library commands - fetch"
  out$ + Chr(10) + "the URL for the full page (one fetch answers it)."
  If summary$ <> "" And summary$ <> title$
    out$ + Chr(10) + Chr(10) + "Summary: " + summary$
  EndIf
  ProcedureReturn out$
EndProcedure

; ---------------------------------------------------------------------------
; pb_docs_search
; ---------------------------------------------------------------------------
Procedure ToolDocsSearch(IdValue.i, Args.i)
  DocsIndexEnsure()
  If Not DocsIndexOk()
    SendIndexMissing(IdValue)
    ProcedureReturn
  EndIf

  Protected sOut.String   ; an *out.String must
                          ; receive a .String STRUCTURE member address; @ of a
                          ; plain string$ is its CONTENT buffer (writes never
                          ; reach the variable - found live on 6.40)
  Protected query$, library$, limit.i = 0
  Protected issues$ = ""
  Protected issue$ = ValidateStrArg(Args, "query", 80, #True, @sOut)
  query$ = sOut\s
  If issue$ <> "" : issues$ = issue$ : EndIf
  issue$ = ValidateStrArg(Args, "library", 40, #False, @sOut)
  library$ = sOut\s
  If issue$ <> ""
    If issues$ <> "" : issues$ + "; " : EndIf
    issues$ + issue$
  EndIf
  issue$ = ValidateIntArg(Args, "limit", 1, 25, @limit)
  If issue$ <> ""
    If issues$ <> "" : issues$ + "; " : EndIf
    issues$ + issue$
  EndIf
  If issues$ <> ""
    SendInvalidParams(IdValue, "pb_docs_search", issues$)
    ProcedureReturn
  EndIf

  NewList hits.HitT()
  DocsSearch(query$, library$, limit, hits())
  SendTextResult(IdValue, FormatSearchResults(hits(), query$), #False)
EndProcedure

; ---------------------------------------------------------------------------
; pb_command
; ---------------------------------------------------------------------------
Procedure ToolDocsCommand(IdValue.i, Args.i)
  DocsIndexEnsure()
  If Not DocsIndexOk()
    SendIndexMissing(IdValue)
    ProcedureReturn
  EndIf

  Protected sOut.String
  Protected name$
  Protected issue$ = ValidateStrArg(Args, "name", 80, #True, @sOut)
  name$ = sOut\s
  If issue$ <> ""
    SendInvalidParams(IdValue, "pb_command", issue$)
    ProcedureReturn
  EndIf

  Protected entry.i = DocsFindCommand(name$)
  If entry = 0
    ; 0.3.1: reference-page titles resolve too - the index stores their
    ; file path, so the answer is the full-text URL (success result, not
    ; the unknown-command error).
    Protected refEntry.i = DocsFindReference(name$)
    If refEntry <> 0
      SendTextResult(IdValue, FormatReferenceEntry(refEntry), #False)
      ProcedureReturn
    EndIf
    NewList sugg$()
    DocsSimilarNames(name$, 5, sugg$())
    Protected hint$ = ""
    If ListSize(sugg$()) > 0
      Protected first.i = #True
      ForEach sugg$()
        If Not first : hint$ + ", " : EndIf
        hint$ + sugg$()
        first = #False
      Next
      hint$ = "Did you mean: " + hint$ + "?"
    Else
      hint$ = "Use pb_docs_search to find the right name."
    EndIf
    SendTextResult(IdValue, "Unknown command " + Chr(34) + name$ + Chr(34) + ". " + hint$, #True)
    ProcedureReturn
  EndIf
  SendTextResult(IdValue, FormatCommandEntry(entry), #False)
EndProcedure

; ---------------------------------------------------------------------------
; pb_version (0.3.0) - server / protocol / compiler / docs-index versions.
; PB-only tool (added in 0.3.0, on top of the four core tools).
; Arguments are ignored (schema declares no properties); a version report
; must answer even when the compiler or the docs index are missing.
; ---------------------------------------------------------------------------
Procedure ToolVersion(IdValue.i, Args.i)
  DocsIndexEnsure()
  Protected out$ = #SERVER_NAME$ + " " + ServerVersionFull() + ", MCP protocol " + ActiveProtocolVersion()
  Protected home$ = ConfigPbHome()
  Protected pb$ = ConfigVersion()
  If home$ = ""
    out$ + Chr(10) + "PureBasic: not found (set PUREBASIC_HOME or install PureBasic)"
  ElseIf pb$ = ""
    out$ + Chr(10) + "PureBasic: version detection failed — " + home$
  Else
    out$ + Chr(10) + "PureBasic " + pb$ + " — " + home$
  EndIf
  If DocsIndexOk()
    out$ + Chr(10) + "Docs index: PB " + DocsIndexPbVersion() + ", built " + DocsIndexGeneratedAt() + ", " +
      Str(DocsCommandCount()) + " commands, " + Str(DocsReferenceCount()) + " reference pages" + Chr(10) +
      "  " + DocsIndexPath()
  Else
    out$ + Chr(10) + "Docs index: none — " + DocsIndexDetail()
  EndIf
  SendTextResult(IdValue, out$, #False)
EndProcedure

; ---------------------------------------------------------------------------
; tools/list; tool order = registration order below. pb_version (PB-only)
; is appended last, after the four core tools.
; ---------------------------------------------------------------------------
Procedure ToolList(IdValue.i)
  Protected json.i = BeginResponse(IdValue)
  Protected result.i = GetJSONMember(JSONValue(json), "result")
  Protected tools.i = AddJSONMember(result, "tools")
  SetJSONArray(tools)
  Protected schema.i

  ; 1. pb_docs_search
  schema = AddTool(tools, "pb_docs_search", "Search PureBasic docs",
    "Search the PureBasic command reference. Returns command names, library, and one-line summaries. " +
    "Use before writing any PureBasic code to find real function names; follow up with pb_command for full syntax. " +
    "PureBasic is not Visual Basic — command and constant names differ from VB/FreeBASIC; search before writing any unfamiliar call.",
    #True, -1, -1)
  AddStrProp(GetJSONMember(schema, "properties"), "query", ~"Keywords, e.g. \"open window\", \"string\", \"read file\"", 1, 80)
  AddStrProp(GetJSONMember(schema, "properties"), "library", ~"Filter by library name, e.g. \"Window\", \"String\", \"File\"", 1, 40)
  AddIntProp(GetJSONMember(schema, "properties"), "limit", "Max results (default 10)", 1, 25)
  AddRequired(schema, "query")
  FinishSchema(schema)

  ; 2. pb_command
  schema = AddTool(tools, "pb_command", "PureBasic command docs",
    "Full documentation for one PureBasic command: exact syntax, parameters, return value, remarks, example, " +
    "supported OS, related commands. Also resolves reference-page titles (Compiler Directives, Includes, " +
    "migration guides, UserGuide) to their full-text URL. Always check here before using an unfamiliar command.",
    #True, -1, -1)
  AddStrProp(GetJSONMember(schema, "properties"), "name", ~"Exact command name, e.g. \"OpenWindow\" (case-insensitive)", 1, 80)
  AddRequired(schema, "name")
  FinishSchema(schema)

  ; Compiler and version tools are visible in stdio and only in explicitly
  ; opted-in HTTP processes. Keep their schema construction/order unchanged.
  If Not gHttpMode Or gHttpAllowCompilerTools
  ; 3. pb_check
  schema = AddTool(tools, "pb_check", "Syntax-check PureBasic source",
    "Syntax-check a PureBasic source file with the real compiler (~350 ms). Returns structured errors with " +
    "line numbers, high-confidence hints on common beginner errors, and best-practice notes (missing " +
    "EnableExplicit, Global inside procedures, Goto/Gosub). Run after every edit. The selected project " +
    "tree is copied to a bounded temporary workspace and the original files are never modified.",
    #True, #False, -1)
  AddStrProp(GetJSONMember(schema, "properties"), "file", "Path to the .pb source file (absolute, or relative to this server's cwd)", 1, 0)
  AddStrProp(GetJSONMember(schema, "properties"), "projectRoot", "Optional project directory to stage; defaults to the entry file's parent", 1, 0)
  AddRequired(schema, "file")
  FinishSchema(schema)

  ; 4. pb_run
  schema = AddTool(tools, "pb_run", "Compile and run PureBasic console program",
    "Compile and run a PureBasic console program, capturing stdout. The agent can verify behavior end-to-end. " +
    "Console programs only — a GUI program will block until timeout; use pb_check for GUI code instead. " +
    "Console subsystem; 15 s default timeout. The project tree is copied to a bounded temporary workspace; " +
    "the program runs with the staged copy's entry directory as its working directory, so relative resources " +
    "and executable-relative DLLs resolve from the copied project; generated files are ephemeral.",
    #False, #False, #False)
  AddStrProp(GetJSONMember(schema, "properties"), "file", "Path to the .pb source file (absolute, or relative to this server's cwd)", 1, 0)
  AddStrProp(GetJSONMember(schema, "properties"), "projectRoot", "Optional project directory to stage; defaults to the entry file's parent", 1, 0)
  AddArrayProp(GetJSONMember(schema, "properties"), "args", "Arguments passed verbatim to the compiled program")
  AddIntProp(GetJSONMember(schema, "properties"), "timeoutMs", "Run timeout in ms (default 15000, max 60000)", 1000, 60000)
  AddRequired(schema, "file")
  FinishSchema(schema)

  ; 5. pb_version - PB-only (added in 0.3.0, after the four core tools)
  schema = AddTool(tools, "pb_version", "Server and PureBasic versions",
    "Report the server version, MCP protocol version, detected PureBasic compiler version and install path, " +
    "and the docs-index version (which PureBasic help the docs tools answer from). Takes no arguments.",
    #True, -1, -1)
  FinishSchema(schema)
  EndIf

  FinishResponse(json)
EndProcedure

; ---------------------------------------------------------------------------
; dispatch - metrics live in the compiler handlers now; unknown tool answer:
; "MCP error -32602: Tool <name> not found"
; ---------------------------------------------------------------------------
Procedure ToolDispatch(IdValue.i, Params.i)
  Protected name$ = MemberStr(Params, "name", "")
  Protected args.i = GetJSONMember(Params, "arguments")
  If gHttpMode And Not gHttpAllowCompilerTools And (name$ = "pb_check" Or name$ = "pb_run" Or name$ = "pb_version")
    SendTextResult(IdValue, "Tool unavailable in this HTTP profile: " + name$, #True)
    ProcedureReturn
  EndIf
  Select name$
    Case "pb_docs_search"
      ToolDocsSearch(IdValue, args)
    Case "pb_command"
      ToolDocsCommand(IdValue, args)
    Case "pb_check"
      ToolCheck(IdValue, args)
    Case "pb_run"
      ToolRun(IdValue, args)
    Case "pb_version"
      ToolVersion(IdValue, args)
    Default
      SendTextResult(IdValue, "MCP error -32602: Tool " + name$ + " not found", #True)
  EndSelect
EndProcedure
