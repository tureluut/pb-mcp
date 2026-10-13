; ---------------------------------------------------------------------------
; console.pb - UTF-8 console output + input loops (stdio transport).
;
; BOM-less UTF-8 is silently misread as CP-1252 by the PB compilers;
; build.cmd enforces the BOM via tools/lint_encoding.ps1.
; ---------------------------------------------------------------------------
EnableExplicit

Declare HandleLine(Raw$)

CompilerIf #PB_Compiler_OS = #PB_OS_Linux
; Raw read(2) for the stdin loop (see RunStdin) + dup/close for the capture
; below. Measured live on WSL/6.41 (port Phase 2): ReadConsoleData on a piped
; stdin waits for the FULL requested count before returning (same "waits for
; requested size" semantics the test suite already documents for
; ReadProgramData) and blocks at EOF instead of returning 0 - interactive
; sessions never saw a response until stdin closed, and a closed stdin never
; terminated the loop (file mode and one-big-write pipe mode were unaffected).
; read(2) has exactly the semantics the loop needs: returns what is available
; (short reads), 0 = EOF, -1 = error (EINTR -> retry).
;
; AND, the second live finding (strace, WSL/6.41): PB's Linux OpenConsole()
; does dup(0) -> internal console fd, then CLOSES fd 0 outright. Every read
; on fd 0 after that is EBADF (or worse - fd 0 gets recycled by unrelated
; opens from other threads; the trace showed a directory landing on 0 and
; read(0) failing EISDIR). So the loop must NOT read fd 0 at all: main.pb
; calls StdinCapture() BEFORE OpenConsole(), we dup our own handle while fd 0
; is still the client's pipe, and RunStdin reads that saved fd. dup returns
; the lowest free fd; we store the actual number, no fixed-fd assumptions.
; Imported under aliases because 'Read' is a PB keyword; ImportC "" adds no
; link flags - the symbols resolve from the libc every PB Linux binary links.
; fasm (the PB Linux assembler backend) treats 'dup' as a reserved word -
; ImportC As "dup" emits 'extrn dup' and the assembly step fails. fcntl
; F_DUPFD does the same job (duplicate fd to the LOWEST free fd >= arg,
; exactly dup's contract) and is a plain libc symbol. F_DUPFD = 0 on Linux.
#F_DUPFD = 0
ImportC ""
  StdinRead(fd.i, *buf, count.i) As "read"
  StdinDupFd(fd.i, cmd.i, arg.i) As "fcntl"
  StdinClose(fd.i) As "close"
EndImport

Global gStdinFd.i = -1
CompilerEndIf

; MUST run before OpenConsole() (see the block above for why). Windows: a
; no-op - the Windows build keeps reading fd 0 via ReadConsoleData, exactly
; as before the Linux port. -1 = capture failed (fd 0 already closed at
; startup); RunStdin then degenerates to a quick clean EOF exit.
Procedure StdinCapture()
  CompilerIf #PB_Compiler_OS = #PB_OS_Linux
    gStdinFd = StdinDupFd(0, #F_DUPFD, 0)
  CompilerEndIf
EndProcedure

; One UTF-8, LF-framed line to stdout (the MCP protocol channel).
Procedure WriteLine(Text$)
  Protected s$ = Text$ + Chr(10)
  Protected len.i = StringByteLength(s$, #PB_UTF8)
  Protected *buf = AllocateMemory(len + 1)
  PokeS(*buf, s$, -1, #PB_UTF8)
  WriteConsoleData(*buf, len)
  FreeMemory(*buf)
EndProcedure

; Golden-session mode: one client message per line, responses to stdout.
; Missing file -> stderr note + exit code 1 (this is a test runner).
Procedure RunFile(Path$)
  Protected f.i = ReadFile(#PB_Any, Path$)
  If f = 0
    ConsoleError("pbmcp: cannot open session file: " + Path$)
    End 1
  EndIf
  While Not Eof(f)
    HandleLine(ReadString(f, #PB_UTF8))
  Wend
  CloseFile(f)
EndProcedure

; Decode one complete raw line (bytes, no trailing LF) and hand it to the
; protocol layer. CRLF tolerated: trailing CR bytes are stripped BEFORE the
; UTF-8 decode, so a 0x0D can never end up inside a multibyte sequence.
; Empty lines (numBytes = 0) are dropped - HandleLine ignores them anyway,
; this just avoids a wasted PeekS.
Procedure HandleRawLine(*bytes, numBytes.i)
  While numBytes > 0 And PeekA(*bytes + numBytes - 1) = 13
    numBytes - 1
  Wend
  If numBytes = 0 : ProcedureReturn : EndIf
  ; #PB_ByteLength is REQUIRED: PeekS' Length counts characters for #PB_UTF8
  ; unless this flag is set - without it, a byte-count silently truncates the
  ; line mid-character and every multibyte line turns into a parse error.
  HandleLine(PeekS(*bytes, numBytes, #PB_UTF8 | #PB_ByteLength))
EndProcedure

; Live serve mode - The buffer now holds RAW bytes;
; UTF-8 decoding happens only on complete LF-framed lines, so a chunk can end
; mid-character without harm. Buffer doubles on demand for long lines.
;
; Scan discipline: pending bytes (indices < len-n) are guaranteed LF-free
; (they were scanned after the previous read), so only the new region needs
; scanning - but a line may START in the old region, hence the absolute
; `start` cursor and the one MoveMemory compaction per chunk.
#STDIN_CHUNK = 65536

Procedure RunStdin()
  Protected cap.i = #STDIN_CHUNK
  Protected *buf = AllocateMemory(cap)
  Protected len.i = 0, n.i, start.i, i.i, errStreak.i
  CompilerIf #PB_Compiler_OS = #PB_OS_Linux
    Protected fd.i = gStdinFd      ; the captured stdin (see StdinCapture);
    If fd < 0 : fd = 0 : EndIf     ; uncaptured degenerate case: try fd 0
  CompilerEndIf
  Repeat
    If len >= cap
      cap * 2
      *buf = ReAllocateMemory(*buf, cap)
      If *buf = 0 : End 1 : EndIf
    EndIf
    CompilerIf #PB_Compiler_OS = #PB_OS_Windows
      n = ReadConsoleData(*buf + len, cap - len)
    CompilerElse
      n = StdinRead(fd, *buf + len, cap - len)
      If n < 0
        ; Transient errors (EINTR - a signal arriving mid-read) retry; a
        ; persistent error gives up after 64 consecutive failures instead of
        ; spinning forever. The streak resets on any successful read.
        errStreak + 1
        If errStreak > 64 : n = 0 : EndIf
      Else
        errStreak = 0
      EndIf
    CompilerEndIf
    If n > 0
      len + n
      start = 0
      For i = len - n To len - 1       ; scan new bytes only
        If PeekA(*buf + i) = 10        ; LF: complete line [start .. i)
          HandleRawLine(*buf + start, i - start)
          start = i + 1
        EndIf
      Next
      If start > 0                     ; compact the partial-line remainder
        MoveMemory(*buf + start, *buf, len - start)
        len - start
      EndIf
    EndIf
  Until n = 0
  If len > 0 : HandleRawLine(*buf, len) : EndIf  ; last line without LF
  CompilerIf #PB_Compiler_OS = #PB_OS_Linux
    If gStdinFd >= 0                         ; release the captured stdin
      StdinClose(gStdinFd)
      gStdinFd = -1
    EndIf
  CompilerEndIf
  FreeMemory(*buf)
EndProcedure

; IDE Options = PureBasic 6.40 (Windows - x64)
; CursorPosition = 89
; FirstLine = 50
; Folding = -
; EnableXP
; DPIAware