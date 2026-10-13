; hints_procdollar.pb - pb_check hint fixture: '$' in a procedure name.
; The compiler reports a bare "Syntax error." on the Procedure line; the hint
; pairs it with the source-line lint (probe-sealed on 5.73 and 6.40).
EnableExplicit

Procedure Foo$()
  ProcedureReturn "x"
EndProcedure

Debug Foo$()
