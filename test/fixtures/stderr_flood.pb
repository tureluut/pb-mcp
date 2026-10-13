; stderr_flood - regression fixture for the stderr pipeline in
; RunProcessCapture (perf pass 2): spin-window drain + linear join. Prints
; 50k stderr lines (~35 chars each, deterministic content, ~1.75 MB total -
; under the 4 MB capture cap), exits 0. With the hot poll loop the whole
; pb_run call stays well under 10 s; against the old always-sleep poll the
; PB stderr pipe locksteps at ~20 ms/line and this needs ~15+ minutes.
EnableExplicit

OpenConsole()

Define i.i
For i = 1 To 50000
  ConsoleError("stderr flood line " + RSet(Str(i), 5, "0") + " 0123456789")
Next

CloseConsole()
End 0
