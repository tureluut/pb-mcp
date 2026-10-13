; hello.pb - pb_run fixture: prints a greeting, echoes every argument
; (args pass-through folds in here). Console subsystem, exit 0.
EnableExplicit

If OpenConsole()
  PrintN("hello from pb_run")
  Define i.i
  For i = 1 To CountProgramParameters()
    PrintN("arg" + Str(i) + "=" + ProgramParameter(i - 1))
  Next i
  CloseConsole()
EndIf
End
