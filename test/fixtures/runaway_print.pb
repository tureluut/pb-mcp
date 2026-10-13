; runaway_print.pb - pb_run timeout fixture: prints in a loop forever.
; Same timeout/kill contract as runaway_silent, but with stdout traffic the
; capture drain must survive (final drain after the kill included).
EnableExplicit

If OpenConsole()
  Repeat
    PrintN("tick")
    Delay(50)
  ForEver
EndIf
