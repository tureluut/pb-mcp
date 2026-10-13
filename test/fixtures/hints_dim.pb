; hints_dim.pb - pb_check hint fixture: VB-style array declaration.
; The compiler error lands on line 4; hints lint #2 (DIM_AS_PATTERN)
; fires on the source line at the reported position.
EnableExplicit

Dim x As Integer

End
