; hints_const.pb - pb_check hint fixture: typed constant.
; The compiler message "A constant can't have a type." triggers the hints lint
; rule #1b (CONST_TYPE_PATTERN) directly - no source lint needed.
EnableExplicit

#PlayerSpeed.f = 2.5

End
