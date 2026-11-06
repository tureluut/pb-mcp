; ---------------------------------------------------------------------------
; http.pb - bounded, stateless localhost Streamable HTTP adapter.
; All MCP dispatch stays on the main thread; each connection owns one bounded
; raw request buffer and is closed after one request.
; ---------------------------------------------------------------------------
EnableExplicit

#HTTP_DEFAULT_PORT = 6817
#HTTP_MAX_PORT = 65000
#HTTP_MAX_CONNECTIONS = 16
#HTTP_MAX_HEADERS = 16384
#HTTP_MAX_BODY = 1048576
#HTTP_RECEIVE_TIMEOUT_MS = 10000
#HTTP_SEND_TIMEOUT_MS = 10000
#HTTP_BUFFER_SIZE = #HTTP_MAX_HEADERS + #HTTP_MAX_BODY
#HTTP_READ_CHUNK = 65536
#HTTP_MAX_AUTH_FILE = 16384
#HTTP_MAX_AUTH_CLIENTS = 32

Structure HttpClientT
  id.s
  tokenHash.s
  rateTokens.i
  lastRefill.q
EndStructure

Structure HttpSeenKeyT
  depth.i
  key.s
EndStructure

Global NewList gHttpClients.HttpClientT()
Global gHttpAnonymousAuditCount.i = 0
Global gHttpAnonymousAuditAt.q = 0

Structure HttpConnectionT
  client.i
  *buffer
  used.i
  acceptedAt.i
  headerEnd.i
  bodyOffset.i
  bodyLength.i
  headersReady.i
  method.s
  path.s
  protocol.s
  clientIndex.i
EndStructure

Global NewList gHttpConnections.HttpConnectionT()
Global gHttpPort.i = #HTTP_DEFAULT_PORT

Procedure.s HttpStatusText(Status.i)
  Select Status
    Case 200 : ProcedureReturn "OK"
    Case 202 : ProcedureReturn "Accepted"
    Case 400 : ProcedureReturn "Bad Request"
    Case 403 : ProcedureReturn "Forbidden"
    Case 404 : ProcedureReturn "Not Found"
    Case 405 : ProcedureReturn "Method Not Allowed"
    Case 406 : ProcedureReturn "Not Acceptable"
    Case 408 : ProcedureReturn "Request Timeout"
    Case 411 : ProcedureReturn "Length Required"
    Case 413 : ProcedureReturn "Payload Too Large"
    Case 415 : ProcedureReturn "Unsupported Media Type"
    Case 401 : ProcedureReturn "Unauthorized"
    Case 429 : ProcedureReturn "Too Many Requests"
    Case 431 : ProcedureReturn "Request Header Fields Too Large"
    Case 503 : ProcedureReturn "Service Unavailable"
  EndSelect
  ProcedureReturn "Error"
EndProcedure

Procedure.i HttpSendBytes(Client.i, *data, Length.i)
  Protected sent.i = 0, n.i, started.i = ElapsedMilliseconds()
  While sent < Length
    n = SendNetworkData(Client, *data + sent, Length - sent)
    If n < 0 : ProcedureReturn #False : EndIf
    If n = 0
      If ElapsedMilliseconds() - started >= #HTTP_SEND_TIMEOUT_MS : ProcedureReturn #False : EndIf
      Delay(1)
    Else
      sent + n
    EndIf
  Wend
  ProcedureReturn #True
EndProcedure

Procedure.i HttpSendResponse(Client.i, Status.i, ContentType$, Body$, ExtraHeaders$ = "")
  Protected bodyBytes.i = StringByteLength(Body$, #PB_UTF8)
  Protected response$ = "HTTP/1.1 " + Str(Status) + " " + HttpStatusText(Status) + #CRLF$
  response$ + "Content-Length: " + Str(bodyBytes) + #CRLF$
  If ContentType$ <> "" : response$ + "Content-Type: " + ContentType$ + #CRLF$ : EndIf
  If ExtraHeaders$ <> "" : response$ + ExtraHeaders$ : EndIf
  response$ + "Connection: close" + #CRLF$ + #CRLF$ + Body$
  Protected responseBytes.i = StringByteLength(response$, #PB_UTF8)
  Protected *wire = AllocateMemory(responseBytes + 1)
  If *wire = 0 : ProcedureReturn #False : EndIf
  PokeS(*wire, response$, -1, #PB_UTF8)
  Protected ok.i = HttpSendBytes(Client, *wire, responseBytes)
  FreeMemory(*wire)
  ProcedureReturn ok
EndProcedure

Procedure.s HttpJsonError(Code.i, Message$)
  ProcedureReturn "{" + #DQUOTE$ + "jsonrpc" + #DQUOTE$ + ":" + #DQUOTE$ + "2.0" + #DQUOTE$ + "," + #DQUOTE$ + "id" + #DQUOTE$ + ":null," + #DQUOTE$ + "error" + #DQUOTE$ + ":{" + #DQUOTE$ + "code" + #DQUOTE$ + ":" + Str(Code) + "," + #DQUOTE$ + "message" + #DQUOTE$ + ":" + JsonQ(Message$) + "}}"
EndProcedure

Procedure HttpAuditEvent(ClientIndex.i, Method$, Tool$, Status.i, Category$, Elapsed.i, Count.i = 1)
  Protected clientId$ = "anonymous"
  If ClientIndex > 0 And SelectElement(gHttpClients(), ClientIndex - 1)
    clientId$ = gHttpClients()\id
  EndIf
  Protected event$ = "{" + #DQUOTE$ + "timestamp" + #DQUOTE$ + ":" + JsonQ(FormatDate("%yyyy-%mm-%ddT%hh:%ii:%ssZ", DateUTC()))
  event$ + "," + #DQUOTE$ + "client" + #DQUOTE$ + ":" + JsonQ(Left(clientId$, 80))
  event$ + "," + #DQUOTE$ + "method" + #DQUOTE$ + ":" + JsonQ(Left(Method$, 80))
  event$ + "," + #DQUOTE$ + "tool" + #DQUOTE$ + ":" + JsonQ(Left(Tool$, 80))
  event$ + "," + #DQUOTE$ + "status" + #DQUOTE$ + ":" + Str(Status)
  event$ + "," + #DQUOTE$ + "category" + #DQUOTE$ + ":" + JsonQ(Left(Category$, 80))
  event$ + "," + #DQUOTE$ + "elapsedMs" + #DQUOTE$ + ":" + Str(Elapsed)
  event$ + "," + #DQUOTE$ + "count" + #DQUOTE$ + ":" + Str(Count) + "}"
  ConsoleError(event$)
EndProcedure

Procedure HttpAuditAnonymous(Status.i)
  gHttpAnonymousAuditCount + 1
  Protected now.q = ElapsedMilliseconds()
  If gHttpAnonymousAuditAt = 0 Or now - gHttpAnonymousAuditAt >= 60000
    HttpAuditEvent(0, "POST", "", Status, "rejected", 0, gHttpAnonymousAuditCount)
    gHttpAnonymousAuditAt = now
    gHttpAnonymousAuditCount = 0
  EndIf
EndProcedure

Procedure.i HttpAdmitClient(ClientIndex.i, *retryAfter.Integer)
  If ClientIndex < 1 Or Not SelectElement(gHttpClients(), ClientIndex - 1) : ProcedureReturn #False : EndIf
  Protected now.q = ElapsedMilliseconds(), elapsed.q = now - gHttpClients()\lastRefill, retry.i
  If elapsed > 0
    gHttpClients()\rateTokens + elapsed
    If gHttpClients()\rateTokens > 10000 : gHttpClients()\rateTokens = 10000 : EndIf
    gHttpClients()\lastRefill = now
  EndIf
  If gHttpClients()\rateTokens >= 1000
    gHttpClients()\rateTokens - 1000
    ProcedureReturn #True
  EndIf
  retry = (1000 - gHttpClients()\rateTokens + 999) / 1000
  If retry < 1 : retry = 1 : EndIf
  *retryAfter\i = retry
  ProcedureReturn #False
EndProcedure

Procedure HttpReject(Client.i, Status.i)
  Protected extra$ = ""
  If Status = 405 : extra$ = "Allow: POST" + #CRLF$ : EndIf
  If Status = 401
    extra$ = "WWW-Authenticate: Bearer realm=" + Chr(34) + "pbmcp" + Chr(34) + #CRLF$ + "Cache-Control: no-store" + #CRLF$
    HttpAuditAnonymous(Status)
  EndIf
  HttpSendResponse(Client, Status, "", "", extra$)
EndProcedure

; Reject duplicate JSON object members before ParseJSON can collapse them.
; Escaped member names are rejected (the credentials schema uses ASCII keys).
Procedure.i HttpJsonUniqueMembers(Text$)
  NewList seen.HttpSeenKeyT()
  Dim kind.i(32)
  Dim expectKey.i(32)
  Protected depth.i = 0, i.i = 1, n.i = Len(Text$), j.i, key$, ch$
  While i <= n
    ch$ = Mid(Text$, i, 1)
    If ch$ = Chr(34)
      j = i + 1 : key$ = ""
      While j <= n
        ch$ = Mid(Text$, j, 1)
        If ch$ = Chr(92)
          If depth > 0 And kind(depth) = 1 And expectKey(depth) : ProcedureReturn #False : EndIf
          j + 2 : Continue
        EndIf
        If ch$ = Chr(34) : Break : EndIf
        If depth > 0 And kind(depth) = 1 And expectKey(depth) : key$ + ch$ : EndIf
        j + 1
      Wend
      If j > n : ProcedureReturn #False : EndIf
      If depth > 0 And kind(depth) = 1 And expectKey(depth)
        ForEach seen()
          If seen()\depth = depth And seen()\key = key$ : ProcedureReturn #False : EndIf
        Next
        AddElement(seen()) : seen()\depth = depth : seen()\key = key$
        expectKey(depth) = #False
      EndIf
      i = j + 1 : Continue
    ElseIf ch$ = "{"
      depth + 1
      If depth > 32 : ProcedureReturn #False : EndIf
      kind(depth) = 1 : expectKey(depth) = #True
    ElseIf ch$ = "["
      depth + 1
      If depth > 32 : ProcedureReturn #False : EndIf
      kind(depth) = 2 : expectKey(depth) = #False
    ElseIf ch$ = "}"
      ForEach seen()
        If seen()\depth = depth : DeleteElement(seen()) : EndIf
      Next
      depth - 1
    ElseIf ch$ = "]"
      depth - 1
    ElseIf ch$ = "," And depth > 0 And kind(depth) = 1
      expectKey(depth) = #True
    ElseIf ch$ = ":" And depth > 0 And kind(depth) = 1
      expectKey(depth) = #False
    EndIf
    If depth < 0 : ProcedureReturn #False : EndIf
    i + 1
  Wend
  If depth = 0 : ProcedureReturn #True : EndIf
  ProcedureReturn #False
EndProcedure

Procedure.i HttpValidClientId(Id$)
  If Len(Id$) < 1 Or Len(Id$) > 64 : ProcedureReturn #False : EndIf
  Protected i.i, c.i
  For i = 1 To Len(Id$)
    c = Asc(Mid(Id$, i, 1))
    If Not ((c >= 48 And c <= 57) Or (c >= 65 And c <= 90) Or (c >= 97 And c <= 122) Or c = 45 Or c = 95)
      ProcedureReturn #False
    EndIf
  Next
  ProcedureReturn #True
EndProcedure

Procedure.i HttpValidHash(Hash$)
  If Len(Hash$) <> 64 : ProcedureReturn #False : EndIf
  Protected i.i, c.i
  For i = 1 To 64
    c = Asc(Mid(Hash$, i, 1))
    If Not ((c >= 48 And c <= 57) Or (c >= 97 And c <= 102)) : ProcedureReturn #False : EndIf
  Next
  ProcedureReturn #True
EndProcedure

Procedure.i HttpLoadCredentials(Path$)
  ClearList(gHttpClients())
  Protected file.i = ReadFile(#PB_Any, Path$, #PB_File_SharedRead)
  If file = 0 : ProcedureReturn #False : EndIf
  Protected size.q = Lof(file)
  If size < 1 Or size > #HTTP_MAX_AUTH_FILE : CloseFile(file) : ProcedureReturn #False : EndIf
  Protected *data = AllocateMemory(size + 1)
  If *data = 0 : CloseFile(file) : ProcedureReturn #False : EndIf
  Protected readCount.i = ReadData(file, *data, size)
  CloseFile(file)
  If readCount <> size : FreeMemory(*data) : ProcedureReturn #False : EndIf
  Protected text$ = PeekS(*data, size, #PB_UTF8 | #PB_ByteLength)
  FreeMemory(*data)
  If Not HttpJsonUniqueMembers(text$) : ProcedureReturn #False : EndIf
  Protected json.i = ParseJSON(#PB_Any, text$)
  If json = 0 : ProcedureReturn #False : EndIf
  Protected root.i = JSONValue(json), clients.i = GetJSONMember(JSONValue(json), "clients")
  If JSONType(root) <> #PB_JSON_Object Or JSONObjectSize(root) <> 1 Or Not clients Or JSONType(clients) <> #PB_JSON_Array Or JSONArraySize(clients) < 1 Or JSONArraySize(clients) > #HTTP_MAX_AUTH_CLIENTS
    FreeJSON(json) : ProcedureReturn #False
  EndIf
  Protected item.i, id$, hash$, i.i
  For i = 0 To JSONArraySize(clients) - 1
    item = GetJSONElement(clients, i)
    If JSONType(item) <> #PB_JSON_Object Or JSONObjectSize(item) <> 2
      FreeJSON(json) : ClearList(gHttpClients()) : ProcedureReturn #False
    EndIf
    id$ = MemberStr(item, "id", "")
    hash$ = MemberStr(item, "tokenSha256", "")
    If Not HttpValidClientId(id$) Or Not HttpValidHash(hash$) Or GetJSONMember(item, "id") = 0 Or GetJSONMember(item, "tokenSha256") = 0
      FreeJSON(json) : ClearList(gHttpClients()) : ProcedureReturn #False
    EndIf
    ForEach gHttpClients()
      If gHttpClients()\id = id$ Or gHttpClients()\tokenHash = hash$
        FreeJSON(json) : ClearList(gHttpClients()) : ProcedureReturn #False
      EndIf
    Next
    AddElement(gHttpClients())
    gHttpClients()\id = id$ : gHttpClients()\tokenHash = hash$
    gHttpClients()\rateTokens = 10000 : gHttpClients()\lastRefill = ElapsedMilliseconds()
  Next
  FreeJSON(json)
  UseSHA2Fingerprint()
  ProcedureReturn #True
EndProcedure

; Returns the configured client index (1-based), scanning every verifier and
; all 64 hex characters for each comparison. No bearer value is retained.
Procedure.i HttpAuthenticate(Value$, *clientIndex.Integer)
  Protected space.i = FindString(Value$, " "), scheme$, token$, digest$, i.i, j.i, diff.i, matched.i = 0
  If space < 2 Or CountString(Value$, " ") <> 1 Or FindString(Value$, ",") : ProcedureReturn 0 : EndIf
  scheme$ = LCase(Left(Value$, space - 1))
  token$ = Mid(Value$, space + 1)
  If scheme$ <> "bearer" Or Not HttpValidHash(token$) : ProcedureReturn 0 : EndIf
  digest$ = StringFingerprint(token$, #PB_Cipher_SHA2, 256, #PB_Ascii)
  ForEach gHttpClients()
    diff = 0
    For j = 1 To 64
      diff | (Asc(Mid(digest$, j, 1)) ! Asc(Mid(gHttpClients()\tokenHash, j, 1)))
    Next
    If diff = 0 : matched = ListIndex(gHttpClients()) + 1 : EndIf
  Next
  If matched : *clientIndex\i = matched : EndIf
  ProcedureReturn matched
EndProcedure

Procedure.i HttpFindHeaderEnd(*data, Length.i)
  Protected i.i
  For i = 0 To Length - 4
    If PeekA(*data + i) = 13 And PeekA(*data + i + 1) = 10 And PeekA(*data + i + 2) = 13 And PeekA(*data + i + 3) = 10
      ProcedureReturn i + 4
    EndIf
  Next
  ProcedureReturn 0
EndProcedure

Procedure.i HttpDecimal(Text$, *Value.Integer)
  If Text$ = "" : ProcedureReturn 0 : EndIf
  Protected i.i, c.i, value.q = 0
  For i = 1 To Len(Text$)
    c = Asc(Mid(Text$, i, 1))
    If c < 48 Or c > 57 : ProcedureReturn 0 : EndIf
    value = value * 10 + c - 48
    If value > #HTTP_MAX_BODY : ProcedureReturn -1 : EndIf
  Next
  *Value\i = value
  ProcedureReturn 1
EndProcedure

Procedure.i HttpAcceptHas(Accept$, Media$)
  Protected i.i, item$, semi.i
  For i = 1 To CountString(Accept$, ",") + 1
    item$ = LCase(Trim(StringField(Accept$, i, ",")))
    semi = FindString(item$, ";")
    If semi : item$ = Trim(Left(item$, semi - 1)) : EndIf
    If item$ = Media$ : ProcedureReturn #True : EndIf
  Next
  ProcedureReturn #False
EndProcedure

; Parse once the complete CRLF header block is available. Return 0 for
; incomplete, 1 for parsed, or -1 after sending a framing/policy error.
Procedure.i HttpParseHeaders(*c.HttpConnectionT)
  Protected endAt.i = HttpFindHeaderEnd(*c\buffer, *c\used)
  If endAt = 0
    If *c\used > #HTTP_MAX_HEADERS
      HttpReject(*c\client, 431) : ProcedureReturn -1
    EndIf
    ProcedureReturn 0
  EndIf
  If endAt > #HTTP_MAX_HEADERS
    HttpReject(*c\client, 431) : ProcedureReturn -1
  EndIf
  *c\headerEnd = endAt
  Protected header$ = PeekS(*c\buffer, endAt - 4, #PB_UTF8 | #PB_ByteLength)
  header$ = ReplaceString(header$, #CRLF$, #LF$)
  Protected line$ = StringField(header$, 1, #LF$)
  If CountString(line$, " ") <> 2 Or FindString(line$, #TAB$) Or FindString(line$, Chr(0))
    HttpReject(*c\client, 400) : ProcedureReturn -1
  EndIf
  *c\method = StringField(line$, 1, " ")
  *c\path = StringField(line$, 2, " ")
  *c\protocol = StringField(line$, 3, " ")
  If *c\method = "" Or *c\path = "" Or *c\protocol <> "HTTP/1.1"
    HttpReject(*c\client, 400) : ProcedureReturn -1
  EndIf

  Protected host$, accept$, contentType$, version$, authorization$, contentSeen.i = #False
  Protected authorizationSeen.i = #False, matchedClient.Integer
  Protected hostSeen.i = #False, originSeen.i = #False, typeSeen.i = #False
  Protected versionSeen.i = #False, transferSeen.i = #False, expectSeen.i = #False
  Protected forwardedSeen.i = #False, contentLength.i = 0, parsed.i
  Protected colon.i, i.i, name$, value$
  For i = 2 To CountString(header$, #LF$) + 1
    line$ = StringField(header$, i, #LF$)
    If line$ = "" : Continue : EndIf
    If Left(line$, 1) = " " Or Left(line$, 1) = #TAB$
      HttpReject(*c\client, 400) : ProcedureReturn -1
    EndIf
    colon = FindString(line$, ":")
    If colon < 2 : HttpReject(*c\client, 400) : ProcedureReturn -1 : EndIf
    name$ = LCase(Trim(Left(line$, colon - 1)))
    value$ = Trim(Mid(line$, colon + 1))
    If name$ = "host"
      If hostSeen : HttpReject(*c\client, 400) : ProcedureReturn -1 : EndIf
      hostSeen = #True : host$ = LCase(value$)
    ElseIf name$ = "origin"
      originSeen = #True
    ElseIf name$ = "content-length"
      If contentSeen : HttpReject(*c\client, 400) : ProcedureReturn -1 : EndIf
      contentSeen = #True
      parsed = HttpDecimal(value$, @contentLength)
      If parsed = 0 : HttpReject(*c\client, 400) : ProcedureReturn -1 : EndIf
      If parsed < 0 : HttpReject(*c\client, 413) : ProcedureReturn -1 : EndIf
    ElseIf name$ = "transfer-encoding"
      transferSeen = #True
    ElseIf name$ = "content-type"
      If typeSeen : HttpReject(*c\client, 400) : ProcedureReturn -1 : EndIf
      typeSeen = #True : contentType$ = value$
    ElseIf name$ = "accept"
      If accept$ <> "" : accept$ + "," : EndIf
      accept$ + value$
    ElseIf name$ = "mcp-protocol-version"
      If versionSeen : HttpReject(*c\client, 400) : ProcedureReturn -1 : EndIf
      versionSeen = #True : version$ = value$
    ElseIf name$ = "authorization"
      If authorizationSeen Or FindString(value$, ",") : HttpReject(*c\client, 400) : ProcedureReturn -1 : EndIf
      authorizationSeen = #True : authorization$ = value$
    ElseIf name$ = "expect"
      expectSeen = #True
    ElseIf name$ = "forwarded" Or Left(name$, 12) = "x-forwarded-"
      forwardedSeen = #True
    EndIf
  Next

  If originSeen : HttpReject(*c\client, 403) : ProcedureReturn -1 : EndIf
  If forwardedSeen Or Not hostSeen Or (host$ <> "127.0.0.1:" + Str(gHttpPort) And host$ <> "localhost:" + Str(gHttpPort))
    HttpReject(*c\client, 400) : ProcedureReturn -1
  EndIf
  If transferSeen Or expectSeen : HttpReject(*c\client, 400) : ProcedureReturn -1 : EndIf
  If *c\path <> "/mcp"
    HttpReject(*c\client, 404) : ProcedureReturn -1
  EndIf
  If *c\method <> "POST"
    HttpReject(*c\client, 405) : ProcedureReturn -1
  EndIf
  If Not contentSeen : HttpReject(*c\client, 411) : ProcedureReturn -1 : EndIf
  If contentLength > #HTTP_MAX_BODY : HttpReject(*c\client, 413) : ProcedureReturn -1 : EndIf
  Protected typeValue$ = LCase(Trim(StringField(contentType$, 1, ";")))
  If Not typeSeen Or typeValue$ <> "application/json"
    HttpReject(*c\client, 415) : ProcedureReturn -1
  EndIf
  If Not HttpAcceptHas(accept$, "application/json") Or Not HttpAcceptHas(accept$, "text/event-stream")
    HttpReject(*c\client, 406) : ProcedureReturn -1
  EndIf
  If Not authorizationSeen Or Not HttpAuthenticate(authorization$, @matchedClient)
    HttpReject(*c\client, 401) : ProcedureReturn -1
  EndIf
  Protected retryAfter.Integer
  If Not HttpAdmitClient(matchedClient\i, @retryAfter)
    HttpSendResponse(*c\client, 429, "", "", "Retry-After: " + Str(retryAfter\i) + #CRLF$ + "Cache-Control: no-store" + #CRLF$)
    HttpAuditEvent(matchedClient\i, *c\method, "", 429, "denied", ElapsedMilliseconds() - *c\acceptedAt)
    ProcedureReturn -1
  EndIf
  *c\clientIndex = matchedClient\i

  *c\bodyOffset = endAt
  *c\bodyLength = contentLength
  *c\headersReady = #True
  ProcedureReturn 1
EndProcedure

Procedure.i HttpValidJsonRpc(JSON.i, *isNotification.Integer, *isResponse.Integer, *isInitialize.Integer)
  Protected root.i = JSONValue(JSON)
  If JSONType(root) <> #PB_JSON_Object : ProcedureReturn #False : EndIf
  Protected rpc.i = GetJSONMember(root, "jsonrpc")
  If rpc = 0 Or JSONType(rpc) <> #PB_JSON_String Or GetJSONString(rpc) <> "2.0" : ProcedureReturn #False : EndIf
  Protected method.i = GetJSONMember(root, "method")
  Protected id.i = GetJSONMember(root, "id")
  If method = 0
    ; A client response has exactly one of result/error and a valid response id.
    If id = 0 : ProcedureReturn #False : EndIf
    If JSONType(id) <> #PB_JSON_Null And JSONType(id) <> #PB_JSON_String And JSONType(id) <> #PB_JSON_Number
      ProcedureReturn #False
    EndIf
    Protected result.i = GetJSONMember(root, "result")
    Protected err.i = GetJSONMember(root, "error")
    If (result = 0 And err = 0) Or (result <> 0 And err <> 0) : ProcedureReturn #False : EndIf
    If err And JSONType(err) <> #PB_JSON_Object : ProcedureReturn #False : EndIf
    *isResponse\i = #True
    ProcedureReturn #True
  EndIf
  If JSONType(method) <> #PB_JSON_String Or GetJSONString(method) = "" : ProcedureReturn #False : EndIf
  If id = 0
    *isNotification\i = #True
  ElseIf JSONType(id) <> #PB_JSON_String And JSONType(id) <> #PB_JSON_Number
    ProcedureReturn #False
  EndIf
  Protected params.i = GetJSONMember(root, "params")
  If params And JSONType(params) <> #PB_JSON_Object And JSONType(params) <> #PB_JSON_Array
    ProcedureReturn #False
  EndIf
  If GetJSONString(method) = "initialize" : *isInitialize\i = #True : EndIf
  ProcedureReturn #True
EndProcedure

Procedure HttpProcessBody(Client.i, *body, BodyLength.i, VersionHeader$, VersionSeen.i, ClientIndex.i, StartedAt.q)
  Protected body$ = PeekS(*body, BodyLength, #PB_UTF8 | #PB_ByteLength)
  Protected json.i = ParseJSON(#PB_Any, body$)
  If json = 0
    HttpSendResponse(Client, 400, "application/json", HttpJsonError(-32700, "Parse error"))
    HttpAuditEvent(ClientIndex, "POST", "", 400, "denied", ElapsedMilliseconds() - StartedAt)
    ProcedureReturn
  EndIf
  Protected notify.Integer, response.Integer, initialize.Integer
  If Not HttpValidJsonRpc(json, @notify, @response, @initialize)
    FreeJSON(json)
    HttpSendResponse(Client, 400, "application/json", HttpJsonError(-32600, "Invalid Request"))
    HttpAuditEvent(ClientIndex, "POST", "", 400, "denied", ElapsedMilliseconds() - StartedAt)
    ProcedureReturn
  EndIf
  Protected root.i = JSONValue(json), method$ = MemberStr(JSONValue(json), "method", "response"), tool$ = ""
  If method$ = "tools/call"
    tool$ = MemberStr(GetJSONMember(root, "params"), "name", "")
  EndIf
  If initialize\i = #False And (Not VersionSeen Or VersionHeader$ <> #HTTP_PROTOCOL_VERSION$)
    FreeJSON(json)
    HttpReject(Client, 400)
    HttpAuditEvent(ClientIndex, method$, tool$, 400, "denied", ElapsedMilliseconds() - StartedAt)
    ProcedureReturn
  EndIf
  If response\i Or notify\i
    FreeJSON(json)
    HttpSendResponse(Client, 202, "", "")
    HttpAuditEvent(ClientIndex, method$, tool$, 202, "success", ElapsedMilliseconds() - StartedAt)
    ProcedureReturn
  EndIf

  gHttpCapturedResponse = ""
  gHttpMode = #True
  HandleLine(body$)
  Protected reply$ = gHttpCapturedResponse, status.i = 200, category$ = "success"
  gHttpCapturedResponse = ""
  FreeJSON(json)
  If reply$ = ""
    ; A valid request with no response is not expected; do not leak stdout or
    ; fabricate a JSON-RPC result. Treat it as an accepted no-content message.
    status = 202
    HttpSendResponse(Client, status, "", "")
  Else
    Protected replyJson.i = ParseJSON(#PB_Any, reply$)
    If replyJson
      ; JSON-RPC error replies (-32601 etc.) carry "error" and no "result";
      ; GetJSONMember requires an object value - asking a 0 member crashes.
      Protected replyResult.i = GetJSONMember(JSONValue(replyJson), "result")
      If replyResult
        Protected isError.i = GetJSONMember(replyResult, "isError")
        If isError And JSONType(isError) = #PB_JSON_Boolean And GetJSONBoolean(isError)
          category$ = "tool_error"
          Protected content.i = GetJSONMember(replyResult, "content")
          If content And JSONArraySize(content) > 0
            Protected item.i = GetJSONElement(content, 0), textValue.i = GetJSONMember(item, "text")
            If textValue And JSONType(textValue) = #PB_JSON_String And FindString(LCase(GetJSONString(textValue)), "unavailable")
              category$ = "denied"
            EndIf
          EndIf
        EndIf
      EndIf
      FreeJSON(replyJson)
    EndIf
    HttpSendResponse(Client, status, "application/json", reply$, "MCP-Protocol-Version: " + #HTTP_PROTOCOL_VERSION$ + #CRLF$)
  EndIf
  HttpAuditEvent(ClientIndex, method$, tool$, status, category$, ElapsedMilliseconds() - StartedAt)
EndProcedure

Procedure HttpProcessReady(*c.HttpConnectionT)
  Protected bodyEnd.i = *c\bodyOffset + *c\bodyLength
  If *c\used > bodyEnd
    HttpReject(*c\client, 400) : ProcedureReturn #True
  EndIf
  If *c\used < bodyEnd : ProcedureReturn #False : EndIf
  Protected versionHeader$, versionSeen.i = #False
  ; Header fields are parsed a second time only for the negotiated version.
  Protected header$ = PeekS(*c\buffer, *c\headerEnd - 4, #PB_UTF8 | #PB_ByteLength)
  header$ = ReplaceString(header$, #CRLF$, #LF$)
  Protected i.i, line$, colon.i, name$
  For i = 2 To CountString(header$, #LF$) + 1
    line$ = StringField(header$, i, #LF$)
    colon = FindString(line$, ":")
    If colon > 1
      name$ = LCase(Trim(Left(line$, colon - 1)))
      If name$ = "mcp-protocol-version"
        versionSeen = #True
        versionHeader$ = Trim(Mid(line$, colon + 1))
      EndIf
    EndIf
  Next
  HttpProcessBody(*c\client, *c\buffer + *c\bodyOffset, *c\bodyLength, versionHeader$, versionSeen, *c\clientIndex, *c\acceptedAt)
  ProcedureReturn #True
EndProcedure

Procedure HttpRemoveConnection(Client.i, CloseClient.i)
  ForEach gHttpConnections()
    If gHttpConnections()\client = Client
      If CloseClient : CloseNetworkConnection(Client) : EndIf
      If gHttpConnections()\buffer : FreeMemory(gHttpConnections()\buffer) : EndIf
      DeleteElement(gHttpConnections())
      ProcedureReturn
    EndIf
  Next
EndProcedure

Procedure HttpOnData(Client.i, *scratch)
  ForEach gHttpConnections()
    If gHttpConnections()\client = Client
      Protected n.i = ReceiveNetworkData(Client, *scratch, #HTTP_READ_CHUNK)
      If n < 0
        HttpRemoveConnection(Client, #False)
        ProcedureReturn
      EndIf
      If n = 0 : ProcedureReturn : EndIf
      If gHttpConnections()\used + n > #HTTP_BUFFER_SIZE
        If HttpFindHeaderEnd(gHttpConnections()\buffer, gHttpConnections()\used) = 0
          HttpReject(Client, 431)
        Else
          HttpReject(Client, 413)
        EndIf
        HttpRemoveConnection(Client, #True)
        ProcedureReturn
      EndIf
      CopyMemory(*scratch, gHttpConnections()\buffer + gHttpConnections()\used, n)
      gHttpConnections()\used + n
      If gHttpConnections()\headersReady = #False
        Protected parsed.i = HttpParseHeaders(@gHttpConnections())
        If parsed < 0
          HttpRemoveConnection(Client, #True)
          ProcedureReturn
        EndIf
      EndIf
      If gHttpConnections()\headersReady
        If HttpProcessReady(@gHttpConnections())
          HttpRemoveConnection(Client, #True)
          ProcedureReturn
        EndIf
      EndIf
      ProcedureReturn
    EndIf
  Next
EndProcedure

Procedure HttpAccept(Client.i)
  If ListSize(gHttpConnections()) >= #HTTP_MAX_CONNECTIONS
    HttpReject(Client, 503)
    CloseNetworkConnection(Client)
    ProcedureReturn
  EndIf
  AddElement(gHttpConnections())
  gHttpConnections()\client = Client
  gHttpConnections()\acceptedAt = ElapsedMilliseconds()
  gHttpConnections()\buffer = AllocateMemory(#HTTP_BUFFER_SIZE)
  If gHttpConnections()\buffer = 0
    DeleteElement(gHttpConnections())
    HttpReject(Client, 503)
    CloseNetworkConnection(Client)
  EndIf
EndProcedure

Procedure HttpExpireConnections()
  ForEach gHttpConnections()
    If ElapsedMilliseconds() - gHttpConnections()\acceptedAt >= #HTTP_RECEIVE_TIMEOUT_MS
      Protected client.i = gHttpConnections()\client
      HttpReject(client, 408)
      HttpRemoveConnection(client, #True)
      Break
    EndIf
  Next
EndProcedure

Procedure.i HttpServe(Port.i)
  Protected server.i = CreateNetworkServer(#PB_Any, Port, #PB_Network_TCP | #PB_Network_IPv4, "127.0.0.1")
  If server = 0
    ConsoleError("pbmcp: cannot bind HTTP server to 127.0.0.1:" + Str(Port))
    ProcedureReturn #False
  EndIf
  gHttpPort = Port
  gHttpMode = #True
  ConsoleError("pbmcp: HTTP listening on http://127.0.0.1:" + Str(Port) + "/mcp")
  Protected scratch = AllocateMemory(#HTTP_READ_CHUNK)
  If scratch = 0
    CloseNetworkServer(server)
    ConsoleError("pbmcp: cannot allocate HTTP receive buffer")
    ProcedureReturn #False
  EndIf
  Protected event.i, client.i
  Repeat
    event = NetworkServerEvent(server)
    While event <> #PB_NetworkEvent_None
      client = EventClient()
      Select event
        Case #PB_NetworkEvent_Connect
          HttpAccept(client)
        Case #PB_NetworkEvent_Data
          HttpOnData(client, scratch)
        Case #PB_NetworkEvent_Disconnect
          HttpRemoveConnection(client, #False)
      EndSelect
      event = NetworkServerEvent(server)
    Wend
    HttpExpireConnections()
    Delay(2)
  ForEver
  FreeMemory(scratch)
  CloseNetworkServer(server)
  ProcedureReturn #True
EndProcedure

; IDE Options = PureBasic 6.40 (Windows - x64)
