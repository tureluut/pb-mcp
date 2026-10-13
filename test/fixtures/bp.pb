; bp.pb - pb_check best-practices fixture: all three lint rules fire
; (no EnableExplicit, Global inside a procedure, Goto). Compiles clean.
Procedure Bump()
  Global counter.i
  counter = counter + 1
EndProcedure
Goto skip
skip:
End
