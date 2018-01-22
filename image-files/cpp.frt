(
  The entries in the include stack look as follows:

  0 - 12    Saved FILENAME (counted string)
  13 - 16   Saved LINE
  17 - 20   Saved >IN
  21 - 24   Saved BLK
)

16 CONSTANT INCLUDE-STACK-SIZE
25 CONSTANT INCLUDE-STACK-ESIZE
VARIABLE INCLUDE-STACK-DEPTH
CREATE INCLUDE-STACK INCLUDE-STACK-SIZE INCLUDE-STACK-ESIZE * ALLOT

VARIABLE LINE
VARIABLE MAIN-EOF-XT
CREATE FILENAME 13 ALLOT

: PRINT-LOCATION
  FILENAME COUNT TYPE
  ." :"
  LINE @ .X
  ." : "
;

: INCLUDE-STACK-CURR ( -- include-stack-pointer ) INCLUDE-STACK INCLUDE-STACK-ESIZE INCLUDE-STACK-DEPTH @ * + ;

: SAVE-LOC ( -- )
  INCLUDE-STACK-DEPTH @ INCLUDE-STACK-SIZE >= IF
    PRINT-LOCATION ." include stack overflow" ABORT
  THEN

  INCLUDE-STACK-CURR
  FILENAME OVER 13 CMOVE 13 +
  LINE @ OVER ! 4+
  >IN @ OVER ! 4+
  BLK @ OVER ! DROP
  1 INCLUDE-STACK-DEPTH +!
;

: RESTORE-LOC
  INCLUDE-STACK-DEPTH 0= IF
    MAIN-EOF-XT @ EXECUTE
  ELSE
    1 INCLUDE-STACK-DEPTH -!
    INCLUDE-STACK-CURR
    DUP FILENAME 13 CMOVE 13 +
    DUP @ LINE ! 4+
    DUP @ >IN ! 4+
    @ LOAD
  THEN
;

: KEY
  KEY
  DUP NL = IF
    1 LINE +!
  THEN
;

: OPEN-FILE ( filename length -- )
  FILENAME 13 0 FILL
  DUP FILENAME C!
  FILENAME 1+ SWAP CMOVE
  ROOT
  FILENAME COUNT FILE
  1 LINE !
;

: TEST
  S" TEST.C" OPEN-FILE
  3 0 ?DO
    PRINT-LOCATION
    BEGIN
      KEY DUP NL <>
    WHILE
      EMIT
    REPEAT
    CR
  LOOP
  ABORT
;

: MAIN-EOF
  ." TOPMOST EOF NOT IMPLEMENTED" ABORT
;

' MAIN-EOF MAIN-EOF-XT !

TEST
