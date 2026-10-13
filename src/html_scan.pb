; ---------------------------------------------------------------------------
; html_scan.pb - targeted tolerant HTML scanner and command-page parser.
; Raw-byte UTF-8 decode, lightweight tree, sections, CommandEntry.
; ---------------------------------------------------------------------------
EnableExplicit

#SCAN_SYNTAX = 1
#SCAN_DESCRIPTION = 2
#SCAN_PARAMETERS = 3
#SCAN_RETURN = 4
#SCAN_REMARKS = 5
#SCAN_EXAMPLE = 6
#SCAN_SEEALSO = 7
#SCAN_OS = 8

Structure HtmlNodeT
  kind.i
  tag.s
  text.s
  href.s
  size.s
  first.i
  last.i
  next.i
EndStructure

Global Dim gHtmlNode.HtmlNodeT(0)
Global gHtmlNodeCount.i
Global gHtmlSource$
Global gHtmlCurrent.i
Global gHtmlFoundCount.i
Global Dim gHtmlFound.i(0)
Global Dim gHtmlTables.i(1024)
Global Dim gHtmlRows.i(4096)
Global Dim gHtmlSection.i(8, 1024)
Global Dim gHtmlSectionCount.i(8)
Global gHtmlName$
Global gHtmlLibrary$
Global gHtmlFile$
Global gHtmlDescription$
Global gHtmlReturn$
Global gHtmlRemarks$
Global gHtmlExample$
Global gHtmlSyntaxCount.i
Global Dim gHtmlSyntax$(0)
Global gHtmlParameterCount.i
Global Dim gHtmlParameterName$(0)
Global Dim gHtmlParameterDescription$(0)
Global gHtmlOsCount.i
Global Dim gHtmlOs$(0)
Global gHtmlSeeCount.i
Global Dim gHtmlSeeAlso$(0)

Declare.i HtmlAddNode(Parent.i, Kind.i, Tag$, Text$, Href$, Size$)
Declare HtmlWalkSections(Node.i)
Declare.s HtmlNodeText(Node.i)
Declare.s HtmlNodeRich(Node.i)
Declare HtmlCollect(Node.i, Tag$)
Declare HtmlParseCommand()

Procedure.s HtmlLower(S$)
  ProcedureReturn LCase(S$)
EndProcedure

; Span append. Plain text between entities is copied with one
; Mid() per run (FindString locates the next "&") instead of one char per
; append - "a$ + b$" copies both operands, so the per-char loop was O(n^2).
; Entity decode logic is untouched, so the emitted bytes are identical.
Procedure.s HtmlDecodeEntities(S$)
  Protected out$ = "", i.i = 1, n.i = Len(S$), amp.i, semi.i, entity$, code.i, hexMode.i
  While i <= n
    amp = FindString(S$, "&", i)
    If amp = 0
      out$ + Mid(S$, i)
      Break
    EndIf
    If amp > i : out$ + Mid(S$, i, amp - i) : EndIf
    semi = FindString(S$, ";", amp + 1)
    If semi > amp And semi - amp <= 12
      entity$ = Mid(S$, amp + 1, semi - amp - 1)
      Select LCase(entity$)
        Case "quot" : out$ + Chr(34)
        Case "gt"   : out$ + ">"
        Case "lt"   : out$ + "<"
        Case "amp"  : out$ + "&"
        Case "nbsp" : out$ + Chr(160)
        Default
          If Left(entity$, 1) = "#"
            hexMode = Bool(LCase(Left(entity$, 2)) = "#x")
            If hexMode
              code = Val("$" + Mid(entity$, 3))
            Else
              code = Val(Mid(entity$, 2))
            EndIf
            If code > 0 And code <= 65535
              out$ + Chr(code)
            ElseIf code > 65535 And code <= 1114111
              code - 65536
              out$ + Chr(55296 + (code >> 10)) + Chr(56320 + (code & 1023))
            Else
              out$ + "&" + entity$ + ";"
            EndIf
          Else
            out$ + "&" + entity$ + ";"
          EndIf
      EndSelect
      i = semi + 1
    Else
      out$ + "&"
      i = amp + 1
    EndIf
  Wend
  ProcedureReturn out$
EndProcedure

Procedure.i HtmlAddNode(Parent.i, Kind.i, Tag$, Text$, Href$, Size$)
  gHtmlNodeCount + 1
  If gHtmlNodeCount >= ArraySize(gHtmlNode())
    ReDim gHtmlNode.HtmlNodeT(gHtmlNodeCount + 1024)
  EndIf
  With gHtmlNode(gHtmlNodeCount)
    \kind = Kind
    \tag = Tag$
    \text = Text$
    \href = Href$
    \size = Size$
    \first = 0
    \last = 0
    \next = 0
  EndWith
  If Parent >= 0
    If gHtmlNode(Parent)\first = 0
      gHtmlNode(Parent)\first = gHtmlNodeCount
    Else
      gHtmlNode(gHtmlNode(Parent)\last)\next = gHtmlNodeCount
    EndIf
    gHtmlNode(Parent)\last = gHtmlNodeCount
  EndIf
  ProcedureReturn gHtmlNodeCount
EndProcedure

Procedure HtmlAppendText(Parent.i, S$)
  If S$ <> ""
    HtmlAddNode(Parent, 0, "", HtmlDecodeEntities(S$), "", "")
  EndIf
EndProcedure

Procedure.i HtmlFindTagEnd(Start.i)
  Protected quote.i = 0, i.i, c$
  For i = Start To Len(gHtmlSource$)
    c$ = Mid(gHtmlSource$, i, 1)
    If quote
      If Asc(c$) = quote : quote = 0 : EndIf
    ElseIf c$ = Chr(34) Or c$ = "'"
      quote = Asc(c$)
    ElseIf c$ = ">"
      ProcedureReturn i
    EndIf
  Next
  ProcedureReturn 0
EndProcedure

Procedure.i HtmlIsVoid(Tag$)
  If Tag$ = "br" Or Tag$ = "img" Or Tag$ = "hr" Or Tag$ = "meta" Or Tag$ = "link" Or Tag$ = "input"
    ProcedureReturn #True
  EndIf
  ProcedureReturn #False
EndProcedure

Procedure HtmlParseAttributes(TagText$, *href.String, *size.String)
  Protected i.i = 1, n.i = Len(TagText$), start.i, name$, value$, q$, c$
  *href\s = "" : *size\s = ""
  ; Skip tag name.
  While i <= n And Mid(TagText$, i, 1) <> " " And Mid(TagText$, i, 1) <> Chr(9) And Mid(TagText$, i, 1) <> Chr(10) And Mid(TagText$, i, 1) <> Chr(13) And Mid(TagText$, i, 1) <> "/"
    i + 1
  Wend
  While i <= n
    While i <= n And (Mid(TagText$, i, 1) = " " Or Asc(Mid(TagText$, i, 1)) = 9 Or Asc(Mid(TagText$, i, 1)) = 10 Or Asc(Mid(TagText$, i, 1)) = 13 Or Mid(TagText$, i, 1) = "/")
      i + 1
    Wend
    If i > n : Break : EndIf
    start = i
    While i <= n And Mid(TagText$, i, 1) <> "=" And Mid(TagText$, i, 1) <> " " And Asc(Mid(TagText$, i, 1)) <> 9 And Asc(Mid(TagText$, i, 1)) <> 10 And Asc(Mid(TagText$, i, 1)) <> 13 And Mid(TagText$, i, 1) <> "/"
      i + 1
    Wend
    If i = start : i + 1 : Continue : EndIf
    name$ = LCase(Mid(TagText$, start, i - start))
    While i <= n And (Mid(TagText$, i, 1) = " " Or Asc(Mid(TagText$, i, 1)) = 9 Or Asc(Mid(TagText$, i, 1)) = 10 Or Asc(Mid(TagText$, i, 1)) = 13)
      i + 1
    Wend
    value$ = ""
    If i <= n And Mid(TagText$, i, 1) = "="
      i + 1
      While i <= n And (Mid(TagText$, i, 1) = " " Or Asc(Mid(TagText$, i, 1)) = 9 Or Asc(Mid(TagText$, i, 1)) = 10 Or Asc(Mid(TagText$, i, 1)) = 13)
        i + 1
      Wend
      If i <= n And (Mid(TagText$, i, 1) = Chr(34) Or Mid(TagText$, i, 1) = "'")
        q$ = Mid(TagText$, i, 1) : i + 1 : start = i
        While i <= n And Mid(TagText$, i, 1) <> q$ : i + 1 : Wend
        value$ = Mid(TagText$, start, i - start)
        If i <= n : i + 1 : EndIf
      Else
        start = i
        While i <= n And Mid(TagText$, i, 1) <> " " And Asc(Mid(TagText$, i, 1)) <> 9 And Asc(Mid(TagText$, i, 1)) <> 10 And Asc(Mid(TagText$, i, 1)) <> 13 And Mid(TagText$, i, 1) <> "/"
          i + 1
        Wend
        value$ = Mid(TagText$, start, i - start)
      EndIf
    EndIf
    value$ = HtmlDecodeEntities(value$)
    If name$ = "href" : *href\s = value$ : EndIf
    If name$ = "size" : *size\s = value$ : EndIf
  Wend
EndProcedure

Procedure HtmlParseTree(Html$)
  gHtmlSource$ = ReplaceString(Html$, Chr(13) + Chr(10), Chr(10))
  gHtmlSource$ = ReplaceString(gHtmlSource$, Chr(13), Chr(10))
  gHtmlNodeCount = 0
  ReDim gHtmlNode.HtmlNodeT(1024)
  HtmlAddNode(-1, 1, "#root", "", "", "")
  Dim stack.i(8192)
  Protected depth.i = 1, pos.i = 1, lt.i, gt.i, close.i, raw$, tag$, attrs$, i.i, j.i, n.i, nameChar$, selfClose.i, node.i
  stack(0) = 1
  While pos <= Len(gHtmlSource$)
    lt = FindString(gHtmlSource$, "<", pos)
    If lt = 0
      HtmlAppendText(stack(depth - 1), Mid(gHtmlSource$, pos))
      Break
    EndIf
    If lt > pos : HtmlAppendText(stack(depth - 1), Mid(gHtmlSource$, pos, lt - pos)) : EndIf
    If Mid(gHtmlSource$, lt, 4) = "<!--"
      close = FindString(gHtmlSource$, "-->", lt + 4)
      If close = 0 : Break : EndIf
      pos = close + 3 : Continue
    EndIf
    If lt < Len(gHtmlSource$) And (Mid(gHtmlSource$, lt + 1, 1) = "!" Or Mid(gHtmlSource$, lt + 1, 1) = "?")
      gt = FindString(gHtmlSource$, ">", lt + 2)
      If gt = 0 : Break : EndIf
      pos = gt + 1 : Continue
    EndIf
    If lt = Len(gHtmlSource$) Or Not ((LCase(Mid(gHtmlSource$, lt + 1, 1)) >= "a" And LCase(Mid(gHtmlSource$, lt + 1, 1)) <= "z") Or Mid(gHtmlSource$, lt + 1, 1) = "/")
      HtmlAppendText(stack(depth - 1), "<")
      pos = lt + 1 : Continue
    EndIf
    gt = HtmlFindTagEnd(lt + 1)
    If gt = 0
      HtmlAppendText(stack(depth - 1), Mid(gHtmlSource$, lt))
      Break
    EndIf
    raw$ = Mid(gHtmlSource$, lt + 1, gt - lt - 1)
    close = Bool(Left(raw$, 1) = "/")
    If close : raw$ = Mid(raw$, 2) : EndIf
    raw$ = Trim(raw$)
    selfClose = Bool(Right(raw$, 1) = "/")
    If selfClose : raw$ = RTrim(Left(raw$, Len(raw$) - 1)) : EndIf
    i = 1
    While i <= Len(raw$) And Mid(raw$, i, 1) <> " " And Asc(Mid(raw$, i, 1)) <> 9 And Asc(Mid(raw$, i, 1)) <> 10 And Asc(Mid(raw$, i, 1)) <> 13
      i + 1
    Wend
    tag$ = LCase(Left(raw$, i - 1))
    attrs$ = raw$
    If close
      For j = depth - 1 To 1 Step -1
        If gHtmlNode(stack(j))\tag = tag$
          depth = j
          Break
        EndIf
      Next
    ElseIf tag$ <> ""
      ; Parse5-lite implicit closes for paragraph, table rows/cells and list items.
      If tag$ = "p" Or tag$ = "address" Or tag$ = "article" Or tag$ = "aside" Or tag$ = "blockquote" Or tag$ = "button" Or tag$ = "center" Or tag$ = "details" Or tag$ = "dir" Or tag$ = "div" Or tag$ = "dl" Or tag$ = "fieldset" Or tag$ = "figcaption" Or tag$ = "figure" Or tag$ = "footer" Or tag$ = "form" Or tag$ = "h1" Or tag$ = "h2" Or tag$ = "h3" Or tag$ = "h4" Or tag$ = "h5" Or tag$ = "h6" Or tag$ = "header" Or tag$ = "hgroup" Or tag$ = "hr" Or tag$ = "listing" Or tag$ = "main" Or tag$ = "menu" Or tag$ = "nav" Or tag$ = "ol" Or tag$ = "pre" Or tag$ = "search" Or tag$ = "section" Or tag$ = "summary" Or tag$ = "table" Or tag$ = "ul"
        For j = depth - 1 To 1 Step -1
          If gHtmlNode(stack(j))\tag = "p" : depth = j : Break : EndIf
        Next
      ElseIf tag$ = "tr"
        Protected cellDepth.i = 0
        For j = depth - 1 To 1 Step -1
          If gHtmlNode(stack(j))\tag = "tr"
            depth = j
            cellDepth = -1
            Break
          ElseIf cellDepth = 0 And (gHtmlNode(stack(j))\tag = "td" Or gHtmlNode(stack(j))\tag = "th")
            cellDepth = j
          EndIf
        Next
        If cellDepth > 0 : depth = cellDepth : EndIf
      ElseIf tag$ = "td" Or tag$ = "th"
        For j = depth - 1 To 1 Step -1
          If gHtmlNode(stack(j))\tag = "td" Or gHtmlNode(stack(j))\tag = "th" : depth = j : Break : EndIf
        Next
      ElseIf tag$ = "li"
        For j = depth - 1 To 1 Step -1
          If gHtmlNode(stack(j))\tag = "li" : depth = j : Break : EndIf
        Next
      EndIf
      Protected href.String, size.String
      HtmlParseAttributes(attrs$, @href, @size)
      If tag$ = "br"
        HtmlAddNode(stack(depth - 1), 0, "", Chr(10), "", "")
      Else
        node = HtmlAddNode(stack(depth - 1), 1, tag$, "", href\s, size\s)
        If Not selfClose And Not HtmlIsVoid(tag$) And depth < 8192
          stack(depth) = node
          depth + 1
        EndIf
      EndIf
    EndIf
    pos = gt + 1
  Wend
EndProcedure

Procedure.s HtmlNodeText(Node.i)
  Protected out$ = "", child.i = gHtmlNode(Node)\first
  While child
    If gHtmlNode(child)\kind = 0
      out$ + gHtmlNode(child)\text
    Else
      out$ + HtmlNodeText(child)
    EndIf
    child = gHtmlNode(child)\next
  Wend
  ProcedureReturn out$
EndProcedure

Procedure.s HtmlNodeRich(Node.i)
  Protected out$ = "", child.i = gHtmlNode(Node)\first, tag$
  While child
    If gHtmlNode(child)\kind = 0
      out$ + gHtmlNode(child)\text
    Else
      tag$ = gHtmlNode(child)\tag
      If tag$ <> "style" And tag$ <> "script"
        If tag$ = "pre"
          out$ + Chr(10) + HtmlNodeText(child) + Chr(10)
        ElseIf tag$ = "br"
          out$ + Chr(10)
        Else
          out$ + HtmlNodeRich(child)
        EndIf
      EndIf
    EndIf
    child = gHtmlNode(child)\next
  Wend
  ProcedureReturn out$
EndProcedure

; Locate the first/last non-whitespace by index and slice once.
; The old loop did S$ = Mid(S$, 2) per leading char - a full string copy per
; step, quadratic on indented HTML. Same whitespace set, same result.
Procedure.s HtmlTrimAll(S$)
  Protected first.i = 1, last.i = Len(S$), c.i
  While first <= last
    c = Asc(Mid(S$, first, 1))
    If c = 9 Or c = 10 Or c = 13 Or c = 32 Or c = 160 Or c = 11 Or c = 12
      first + 1
    Else
      Break
    EndIf
  Wend
  While last >= first
    c = Asc(Mid(S$, last, 1))
    If c = 9 Or c = 10 Or c = 13 Or c = 32 Or c = 160 Or c = 11 Or c = 12
      last - 1
    Else
      Break
    EndIf
  Wend
  If last < first : ProcedureReturn "" : EndIf
  ProcedureReturn Mid(S$, first, last - first + 1)
EndProcedure

; Per-line span processing. Each source line is sliced once, tab/CR
; become spaces, then whitespace runs collapse via ReplaceString - the old
; loop appended one Mid(S$, i, 1) per character (O(n^2) appends). Whitespace
; collapse semantics are unchanged ({32,9,13} runs -> one space: converting
; 9/13 to 32 first then collapsing 32-runs yields the same string), as are
; the per-line trim, the blank-line emit rule, the \n\n\n collapse and the
; final trim. Emitted bytes are identical.
Procedure.s HtmlCleanText(S$)
  Protected out$ = "", line$ = "", start.i, nl.i, n.i
  S$ = ReplaceString(S$, Chr(160), " ")
  n = Len(S$)
  start = 1
  While start <= n + 1
    nl = FindString(S$, Chr(10), start)
    If nl = 0 : nl = n + 1 : EndIf
    line$ = Mid(S$, start, nl - start)
    line$ = ReplaceString(line$, Chr(9), " ")
    line$ = ReplaceString(line$, Chr(13), " ")
    While FindString(line$, "  ")
      line$ = ReplaceString(line$, "  ", " ")
    Wend
    line$ = HtmlTrimAll(line$)
    If out$ <> "" Or line$ <> "" : out$ + Chr(10) + line$ : EndIf
    start = nl + 1
  Wend
  While FindString(out$, Chr(10) + Chr(10) + Chr(10))
    out$ = ReplaceString(out$, Chr(10) + Chr(10) + Chr(10), Chr(10) + Chr(10))
  Wend
  ProcedureReturn HtmlTrimAll(out$)
EndProcedure

Procedure.s HtmlFlat(Node.i)
  Protected s$ = HtmlCleanText(HtmlNodeRich(Node))
  s$ = ReplaceString(s$, Chr(10), " ")
  While FindString(s$, "  ") : s$ = ReplaceString(s$, "  ", " ") : Wend
  ProcedureReturn HtmlTrimAll(s$)
EndProcedure

Procedure HtmlCollect(Node.i, Tag$)
  Protected child.i = gHtmlNode(Node)\first
  While child
    If gHtmlNode(child)\kind = 1
      If Tag$ = "" Or gHtmlNode(child)\tag = Tag$
        gHtmlFoundCount + 1
        If gHtmlFoundCount >= ArraySize(gHtmlFound()) : ReDim gHtmlFound(gHtmlFoundCount + 512) : EndIf
        gHtmlFound(gHtmlFoundCount) = child
      EndIf
      HtmlCollect(child, Tag$)
    EndIf
    child = gHtmlNode(child)\next
  Wend
EndProcedure

Procedure.i HtmlMarker(Node.i)
  If gHtmlNode(Node)\tag <> "b" : ProcedureReturn 0 : EndIf
  Protected s$ = LCase(HtmlTrimAll(HtmlNodeText(Node)))
  If Right(s$, 1) = ":" : s$ = HtmlTrimAll(Left(s$, Len(s$) - 1)) : EndIf
  Select s$
    Case "syntax" : ProcedureReturn #SCAN_SYNTAX
    Case "description" : ProcedureReturn #SCAN_DESCRIPTION
    Case "parameters" : ProcedureReturn #SCAN_PARAMETERS
    Case "return value", "return values" : ProcedureReturn #SCAN_RETURN
    Case "remarks" : ProcedureReturn #SCAN_REMARKS
    Case "example", "examples" : ProcedureReturn #SCAN_EXAMPLE
    Case "see also" : ProcedureReturn #SCAN_SEEALSO
    Case "supported os", "operating systems", "os" : ProcedureReturn #SCAN_OS
  EndSelect
  ProcedureReturn 0
EndProcedure

Procedure HtmlSectionPush(Section.i, Node.i)
  If Section > 0 And Section <= 8 And gHtmlSectionCount(Section) < 1024
    gHtmlSectionCount(Section) + 1
    gHtmlSection(Section, gHtmlSectionCount(Section)) = Node
  EndIf
EndProcedure

Procedure HtmlWalkSections(Node.i)
  Protected child.i = gHtmlNode(Node)\first, marker.i, current.i = gHtmlCurrent, firstElement.i
  While child
    If gHtmlNode(child)\kind = 1
      If gHtmlNode(child)\tag = "center" Or gHtmlNode(child)\tag = "style" Or gHtmlNode(child)\tag = "script" Or gHtmlNode(child)\tag = "form" Or gHtmlNode(child)\tag = "select"
        child = gHtmlNode(child)\next : Continue
      EndIf
      marker = HtmlMarker(child)
      If marker
        gHtmlCurrent = marker
      ElseIf gHtmlNode(child)\tag = "p"
        firstElement = gHtmlNode(child)\first
        While firstElement And (gHtmlNode(firstElement)\kind = 0 Or gHtmlNode(firstElement)\tag = "br")
          firstElement = gHtmlNode(firstElement)\next
        Wend
        marker = 0
        If firstElement And gHtmlNode(firstElement)\kind = 1 : marker = HtmlMarker(firstElement) : EndIf
        If marker
          gHtmlCurrent = marker
          HtmlWalkSections(child)
        ElseIf gHtmlCurrent
          HtmlSectionPush(gHtmlCurrent, child)
        EndIf
      ElseIf gHtmlNode(child)\tag = "blockquote" Or gHtmlNode(child)\tag = "table" Or gHtmlNode(child)\tag = "pre" Or gHtmlNode(child)\tag = "p" Or gHtmlNode(child)\tag = "div" Or gHtmlNode(child)\tag = "ol" Or gHtmlNode(child)\tag = "ul"
        If gHtmlCurrent : HtmlSectionPush(gHtmlCurrent, child) : EndIf
      Else
        HtmlWalkSections(child)
      EndIf
    EndIf
    child = gHtmlNode(child)\next
  Wend
EndProcedure

Procedure HtmlNormalizeOs(Raw$)
  Protected s$ = Raw$, i.i, token$, part$, pos.i, andPos.i, start.i, j.i, depth.i, out$
  s$ = ReplaceString(s$, Chr(10), " ")
  While FindString(s$, "  ") : s$ = ReplaceString(s$, "  ", " ") : Wend
  s$ = HtmlTrimAll(s$)
  gHtmlOsCount = 0
  ReDim gHtmlOs$(1024)
  If s$ = "" : ProcedureReturn : EndIf
  If LCase(Left(s$, 3)) = "all"
    If Len(s$) = 3
      gHtmlOsCount = 1 : gHtmlOs$(1) = "All" : ProcedureReturn
    ElseIf Asc(Mid(s$, 4, 1)) <= 32
      gHtmlOsCount = 1 : gHtmlOs$(1) = "All" : ProcedureReturn
    EndIf
  EndIf
  start = 1
  For i = 1 To Len(s$) + 1
    If i <= Len(s$) And Mid(s$, i, 1) = ","
      part$ = HtmlTrimAll(Mid(s$, start, i - start))
      start = i + 1
    ElseIf i <= Len(s$) And i < Len(s$) And LCase(Mid(s$, i, 3)) = "and" And (i = 1 Or Asc(Mid(s$, i - 1, 1)) <= 32) And (i + 3 > Len(s$) Or Asc(Mid(s$, i + 3, 1)) <= 32)
      part$ = HtmlTrimAll(Mid(s$, start, i - start))
      start = i + 3
      i + 2
    ElseIf i > Len(s$)
      part$ = HtmlTrimAll(Mid(s$, start))
    Else
      Continue
    EndIf
    out$ = "" : depth = 0
    For j = 1 To Len(part$)
      If Mid(part$, j, 1) = "(" : depth + 1 : ElseIf Mid(part$, j, 1) = ")" And depth > 0 : depth - 1 : ElseIf depth = 0 : out$ + Mid(part$, j, 1) : EndIf
    Next
    part$ = HtmlTrimAll(out$)
    If part$ <> ""
      Select LCase(part$)
        Case "windows" : part$ = "Windows"
        Case "linux" : part$ = "Linux"
        Case "macos", "macos x", "mac os", "mac osx", "mac os x", "macosx" : part$ = "MacOS"
      EndSelect
      Protected duplicate.i = #False, osIndex.i
      For osIndex = 1 To gHtmlOsCount
        If LCase(gHtmlOs$(osIndex)) = LCase(part$) : duplicate = #True : Break : EndIf
      Next
      If Not duplicate And gHtmlOsCount < 100
        gHtmlOsCount + 1 : gHtmlOs$(gHtmlOsCount) = part$
      EndIf
    EndIf
  Next
EndProcedure

Procedure.s HtmlJoinSection(Section.i, Delimiter$)
  Protected out$ = "", i.i
  For i = 1 To gHtmlSectionCount(Section)
    If i > 1 : out$ + Delimiter$ : EndIf
    out$ + HtmlNodeRich(gHtmlSection(Section, i))
  Next
  ProcedureReturn HtmlCleanText(out$)
EndProcedure

Procedure HtmlParseCommand()
  Protected body.i = 0, i.i, node.i, title.i, font.i, raw$, line$, prev$, j.i, table.i, tr.i, td.i, row.i, desc$, link.i, name$, href$, hasTitle.i
  For i = 1 To gHtmlNodeCount
    If gHtmlNode(i)\tag = "body" : body = i : Break : EndIf
  Next
  If body = 0 : body = 1 : EndIf
  For i = 1 To 8 : gHtmlSectionCount(i) = 0 : Next
  gHtmlCurrent = 0
  HtmlWalkSections(body)
  gHtmlName$ = ""
  gHtmlFoundCount = 0 : HtmlCollect(1, "title")
  If gHtmlFoundCount > 0 : gHtmlName$ = HtmlTrimAll(HtmlNodeText(gHtmlFound(1))) : EndIf
  If gHtmlName$ = ""
    gHtmlFoundCount = 0 : HtmlCollect(1, "font")
    For i = 1 To gHtmlFoundCount
      If gHtmlNode(gHtmlFound(i))\size = "4"
        gHtmlName$ = HtmlFlat(gHtmlFound(i))
        If Right(gHtmlName$, 2) = "()" : gHtmlName$ = Left(gHtmlName$, Len(gHtmlName$) - 2) : EndIf
        gHtmlName$ = HtmlTrimAll(gHtmlName$) : Break
      EndIf
    Next
  EndIf
  gHtmlSyntaxCount = 0 : ReDim gHtmlSyntax$(1024)
  raw$ = ""
  For i = 1 To gHtmlSectionCount(#SCAN_SYNTAX)
    If i > 1 : raw$ + Chr(10) : EndIf
    raw$ + HtmlNodeRich(gHtmlSection(#SCAN_SYNTAX, i))
  Next
  raw$ = ReplaceString(raw$, Chr(13), "")
  Protected start.i = 1, pos.i
  For pos = 1 To Len(raw$) + 1
    If pos > Len(raw$) Or Mid(raw$, pos, 1) = Chr(10)
      line$ = HtmlTrimAll(Mid(raw$, start, pos - start))
      start = pos + 1
      If line$ <> ""
        If gHtmlSyntaxCount > 0
          prev$ = gHtmlSyntax$(gHtmlSyntaxCount)
          If Right(prev$, 1) = "," Or Right(prev$, 1) = "("
            gHtmlSyntax$(gHtmlSyntaxCount) = prev$ + " " + line$
          Else
            gHtmlSyntaxCount + 1 : gHtmlSyntax$(gHtmlSyntaxCount) = line$
          EndIf
        Else
          gHtmlSyntaxCount = 1 : gHtmlSyntax$(1) = line$
        EndIf
      EndIf
    EndIf
  Next
  gHtmlDescription$ = HtmlJoinSection(#SCAN_DESCRIPTION, Chr(10) + Chr(10))
  gHtmlReturn$ = HtmlJoinSection(#SCAN_RETURN, Chr(10) + Chr(10))
  gHtmlRemarks$ = HtmlJoinSection(#SCAN_REMARKS, Chr(10) + Chr(10))
  gHtmlExample$ = ""
  gHtmlFoundCount = 0
  For i = 1 To gHtmlSectionCount(#SCAN_EXAMPLE)
    node = gHtmlSection(#SCAN_EXAMPLE, i)
    If gHtmlNode(node)\tag = "pre"
      gHtmlFoundCount + 1 : gHtmlFound(gHtmlFoundCount) = node
    EndIf
    HtmlCollect(node, "pre")
  Next
  If gHtmlFoundCount > 0
    For i = 1 To gHtmlFoundCount
      raw$ = HtmlTrimAll(HtmlNodeText(gHtmlFound(i)))
      If i > 1 : gHtmlExample$ + Chr(10) + Chr(10) : EndIf
      gHtmlExample$ + raw$
    Next
  Else
    gHtmlExample$ = HtmlJoinSection(#SCAN_EXAMPLE, Chr(10) + Chr(10))
  EndIf
  gHtmlParameterCount = 0
  ReDim gHtmlParameterName$(4096) : ReDim gHtmlParameterDescription$(4096)
  For i = 1 To gHtmlSectionCount(#SCAN_PARAMETERS)
    node = gHtmlSection(#SCAN_PARAMETERS, i)
    gHtmlFoundCount = 0
    If gHtmlNode(node)\tag = "table"
      gHtmlFoundCount = 1 : gHtmlFound(1) = node
    Else
      HtmlCollect(node, "table")
    EndIf
    Protected k.i, t.i, trCount.i, tdCount.i, tableCount.i
    tableCount = gHtmlFoundCount
    For k = 1 To tableCount : gHtmlTables(k) = gHtmlFound(k) : Next
    For k = 1 To tableCount
      table = gHtmlTables(k)
      gHtmlFoundCount = 0 : HtmlCollect(table, "tr") : trCount = gHtmlFoundCount
      For t = 1 To trCount : gHtmlRows(t) = gHtmlFound(t) : Next
      For t = 1 To trCount
        tr = gHtmlRows(t)
        gHtmlFoundCount = 0 : HtmlCollect(tr, "td") : tdCount = gHtmlFoundCount
        If tdCount >= 2
          raw$ = HtmlFlat(gHtmlFound(1)) : desc$ = ""
          For j = 2 To tdCount
            If j > 2 : desc$ + Chr(10) : EndIf
            desc$ + HtmlNodeRich(gHtmlFound(j))
          Next
          desc$ = HtmlTrimAll(HtmlCleanText(desc$))
          gHtmlParameterCount + 1
          gHtmlParameterName$(gHtmlParameterCount) = raw$
          gHtmlParameterDescription$(gHtmlParameterCount) = desc$
        EndIf
      Next
    Next
  Next
  HtmlNormalizeOs(HtmlJoinSection(#SCAN_OS, " "))
  gHtmlSeeCount = 0 : ReDim gHtmlSeeAlso$(1024)
  For i = 1 To gHtmlSectionCount(#SCAN_SEEALSO)
    gHtmlFoundCount = 0 : HtmlCollect(gHtmlSection(#SCAN_SEEALSO, i), "a")
    For j = 1 To gHtmlFoundCount
      link = gHtmlFound(j) : href$ = gHtmlNode(link)\href
      If Left(href$, 1) <> "#"
        name$ = HtmlTrimAll(HtmlNodeText(link))
        If Right(name$, 2) = "()" : name$ = HtmlTrimAll(Left(name$, Len(name$) - 2)) : EndIf
        If name$ <> ""
          Protected found.i = #False, x.i
          For x = 1 To gHtmlSeeCount : If gHtmlSeeAlso$(x) = name$ : found = #True : Break : EndIf : Next
          If Not found : gHtmlSeeCount + 1 : gHtmlSeeAlso$(gHtmlSeeCount) = name$ : EndIf
        EndIf
      EndIf
    Next
  Next
EndProcedure

Procedure.s HtmlCommandJson(Library$, File$)
  gHtmlLibrary$ = Library$ : gHtmlFile$ = File$
  HtmlParseCommand()
  Protected out$ = "{", i.i
  out$ + Chr(34) + "name" + Chr(34) + ":" + JsonQ(gHtmlName$)
  out$ + "," + Chr(34) + "library" + Chr(34) + ":" + JsonQ(gHtmlLibrary$)
  out$ + "," + Chr(34) + "file" + Chr(34) + ":" + JsonQ(gHtmlFile$)
  out$ + "," + Chr(34) + "syntax" + Chr(34) + ":["
  For i = 1 To gHtmlSyntaxCount : If i > 1 : out$ + "," : EndIf : out$ + JsonQ(gHtmlSyntax$(i)) : Next
  out$ + "]," + Chr(34) + "description" + Chr(34) + ":" + JsonQ(gHtmlDescription$) + "," + Chr(34) + "parameters" + Chr(34) + ":["
  For i = 1 To gHtmlParameterCount
    If i > 1 : out$ + "," : EndIf
    out$ + "{" + Chr(34) + "name" + Chr(34) + ":" + JsonQ(gHtmlParameterName$(i)) + "," + Chr(34) + "description" + Chr(34) + ":" + JsonQ(gHtmlParameterDescription$(i)) + "}"
  Next
  out$ + "]," + Chr(34) + "returnValue" + Chr(34) + ":" + JsonQ(gHtmlReturn$) + "," + Chr(34) + "remarks" + Chr(34) + ":" + JsonQ(gHtmlRemarks$) + "," + Chr(34) + "example" + Chr(34) + ":" + JsonQ(gHtmlExample$) + "," + Chr(34) + "os" + Chr(34) + ":["
  For i = 1 To gHtmlOsCount : If i > 1 : out$ + "," : EndIf : out$ + JsonQ(gHtmlOs$(i)) : Next
  out$ + "]," + Chr(34) + "seeAlso" + Chr(34) + ":["
  For i = 1 To gHtmlSeeCount : If i > 1 : out$ + "," : EndIf : out$ + JsonQ(gHtmlSeeAlso$(i)) : Next
  out$ + "]}"
  ProcedureReturn out$
EndProcedure

Procedure ScanCommandPage(Path$, Library$, RelFile$)
  Protected f.i = ReadFile(#PB_Any, Path$), n.i, *buffer
  If f = 0
    ConsoleError("pbmcp: cannot open HTML file: " + Path$)
    End 1
  EndIf
  n = Lof(f)
  *buffer = AllocateMemory(n + 1)
  If n > 0 : ReadData(f, *buffer, n) : EndIf
  CloseFile(f)
  gHtmlSource$ = PeekS(*buffer, n, #PB_UTF8 | #PB_ByteLength)
  FreeMemory(*buffer)
  HtmlParseTree(gHtmlSource$)
  WriteLine(HtmlCommandJson(Library$, RelFile$))
EndProcedure

Procedure RunScanMode()
  Protected path$ = ProgramParameter(1), library$ = ProgramParameter(2), relfile$ = ProgramParameter(3)
  If path$ = ""
    ConsoleError("Usage: " + #BinName$ + " scan <html> [<library> <relfile>]")
    End 1
  EndIf
  If library$ = "" : library$ = GetFilePart(GetPathPart(path$)) : EndIf
  If relfile$ = "" : relfile$ = library$ + "/" + GetFilePart(path$) : EndIf
  ScanCommandPage(path$, library$, relfile$)
EndProcedure
