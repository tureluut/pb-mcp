; runaway_silent.pb - pb_run timeout fixture: never ends, never prints.
; Compiled exe name (runaway_silent.exe) is unique so the harness can prove
; the taskkill /T /F tree-kill left no orphan behind.
EnableExplicit

Repeat
  Delay(100)
ForEver
