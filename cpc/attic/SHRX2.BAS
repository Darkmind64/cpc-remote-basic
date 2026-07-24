5 |TERM
10 a$=SPACE$(40)
20 CALL &BD19:|TERMRX,@a$
30 IF LEN(a$)=0 THEN 10
40 PRINT "len=";LEN(a$);" a1=";ASC(a$);" [";a$;"]"
50 GOTO 10
