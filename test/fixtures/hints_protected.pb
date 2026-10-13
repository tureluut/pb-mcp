; hints_protected.pb - pb_check hint fixture: Protected at file scope.
; The compiler error "'Protected' can only be used inside a procedure."
; triggers the message-based hint (probe-sealed on 5.73 and 6.40).
; Deliberately NO EnableExplicit: also pins the error-path Best practices note.
Protected w.i = 3

End
