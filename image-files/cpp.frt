(
  The entries in the include stack look as follows:

  0 - 12    Saved FILENAME (counted string)
  13 - 16   Saved LINE
  17 - 20   Saved >IN
  21 - 24   Saved LENGTH
  25 - 28   Saved BLK
)

64 CONSTANT INCSTK-SIZE
25 CONSTANT INCSTK-ESIZE
VARIABLE INCSTK-DEPTH
CREATE INCSTK INCSTK-SIZE INCSTK-ESIZE * ALLOT
0 INCSTK-DEPTH !
: INCSTK-CURR ( -- include-stack-pointer ) INCSTK INCSTK-ESIZE INCSTK-DEPTH @ * + ;

VARIABLE LINE
DEFER MAIN-EOF
CREATE FILENAME 13 ALLOT

: PRINT-LOC
  FILENAME COUNT TYPE
  ." :"
  LINE @ .X
  ." : "
;

: QUOTE-TILL-EOL CR BEGIN KEY DUP #CR <> WHILE EMIT REPEAT DROP ;

: SAVE-LOC ( -- )
  INCSTK-DEPTH @ INCSTK-SIZE >= IF
    PRINT-LOC ." include stack overflow" ABORT
  THEN

  INCSTK-CURR
  FILENAME OVER 13 CMOVE 13 +
  LINE @ OVER ! CELL+
  >IN @ OVER ! CELL+
  LENGTH @ OVER ! CELL+
  BLK @ SWAP !
  1 INCSTK-DEPTH +!
;

: RESTORE-LOC
  INCSTK-DEPTH @ 0= IF
    MAIN-EOF
  ELSE
    1 INCSTK-DEPTH -!
    INCSTK-CURR
    DUP FILENAME 13 CMOVE 13 +
    DUP @ LINE ! CELL+
    DUP @ >IN ! CELL+
    DUP @ LENGTH ! CELL+
    @ LOAD
  THEN
;

: PEEK KEY UNGETC ;

: UNGETC
  UNGETC
  PEEK #CR = IF
    1 LINE -!
  THEN
;

: KEY
  KEY
  DUP #CR = IF
    1 LINE +!
  THEN

  DUP 0= IF
    DROP #CR RESTORE-LOC
  THEN
;

HIDE KEY-NOEOF

: OPEN-FILE ( filename length -- )
  FILENAME 13 0 FILL
  DUP FILENAME C!
  FILENAME 1+ SWAP CMOVE
  ROOT
  FILENAME COUNT FILE
  1 LINE !
;

: IDENT? DUP [CHAR] _ = SWAP ALNUM? OR ;

: SKIP-LINE           BEGIN KEY #CR =                  UNTIL ;
: SKIP-WHITE          BEGIN KEY BL >                   UNTIL UNGETC ;
: SKIP-WHITE-ONE-LINE BEGIN KEY DUP BL > SWAP #CR = OR UNTIL UNGETC ;

: ASSERT-CR
  SKIP-WHITE-ONE-LINE
  KEY #CR <> IF
    PRINT-LOC ." expected newline, got:" UNGETC QUOTE-TILL-EOL
    ABORT
  THEN
;

: PARSE-IDENT
  HERE
  BEGIN
    KEY DUP IDENT?
  WHILE
    C,
  REPEAT
  DROP UNGETC
  HERE OVER -
  OVER HERE!
;

0 CONSTANT DIR-NONE
1 CONSTANT DIR-IF
2 CONSTANT DIR-IFDEF
3 CONSTANT DIR-IFNDEF
4 CONSTANT DIR-ELSE
5 CONSTANT DIR-ELIF
6 CONSTANT DIR-ENDIF
7 CONSTANT DIR-INCLUDE
8 CONSTANT DIR-DEFINE
9 CONSTANT DIR-UNDEF
10 CONSTANT DIR-LINE
11 CONSTANT DIR-ERROR
12 CONSTANT DIR-PRAGMA

: GET-DIRECTIVE
  SKIP-WHITE-ONE-LINE
  PARSE-IDENT
  SCASE
    S" if"      SOF DIR-IF SENDOF
    S" ifdef"   SOF DIR-IFDEF SENDOF
    S" ifndef"  SOF DIR-IFNDEF SENDOF
    S" else"    SOF DIR-ELSE SENDOF
    S" elif"    SOF DIR-ELIF SENDOF
    S" endif"   SOF DIR-ENDIF SENDOF
    S" include" SOF DIR-INCLUDE SENDOF
    S" define"  SOF DIR-DEFINE SENDOF
    S" undef"   SOF DIR-UNDEF SENDOF
    S" line"    SOF DIR-LINE SENDOF
    S" error"   SOF DIR-ERROR SENDOF
    S" pragma"  SOF DIR-PRAGMA SENDOF
    CR PRINT-LOC ." unknown preprocessor directive: " TYPE ABORT
  SENDCASE
;

: SKIP-TILL-ENDIF
  BEGIN
    KEY [CHAR] # = IF
      GET-DIRECTIVE DIR-ENDIF = IF EXIT THEN
    THEN
    SKIP-LINE
  AGAIN
;

DEFER HANDLE-IFCOND

: FIND-OTHER-IF-BRANCH
  BEGIN
    KEY [CHAR] # = IF
      GET-DIRECTIVE CASE
        DIR-ELSE   OF ASSERT-CR       EXIT ENDOF
        DIR-ELIF   OF HANDLE-IFCOND   EXIT ENDOF
        DIR-IF     OF HANDLE-IFCOND   EXIT ENDOF
        DIR-IFDEF  OF SKIP-TILL-ENDIF EXIT ENDOF
        DIR-IFNDEF OF SKIP-TILL-ENDIF EXIT ENDOF
      ENDCASE
    THEN
  AGAIN
;

:NONAME
  SKIP-WHITE-ONE-LINE PARSE-IDENT S" TRUE" S= SKIP-LINE ( TODO: EVALUATE CONDITION )
  INVERT IF FIND-OTHER-IF-BRANCH THEN
; IS HANDLE-IFCOND

: MAYBE-HANDLE-DIR
  KEY [CHAR] # <> IF UNGETC EXIT THEN
  GET-DIRECTIVE CASE
    DIR-NONE    OF EXIT ENDOF
    DIR-IF      OF HANDLE-IFCOND ENDOF
    DIR-IFDEF   OF SKIP-TILL-ENDIF ENDOF
    DIR-IFNDEF  OF SKIP-TILL-ENDIF ENDOF

( If you encounter else or elif in this state, it means you've just finished the branch you aren't
  supposed to ignore, and therefore, you want to ignore all other branches of the conditional    )
    DIR-ELSE    OF ASSERT-CR SKIP-TILL-ENDIF ENDOF
    DIR-ELIF    OF SKIP-TILL-ENDIF ENDOF
    DIR-ENDIF   OF ASSERT-CR ENDOF
    PRINT-LOC ." unhandled directive #" . ABORT
  ENDCASE
;

: TEST
  S" TEST.C" OPEN-FILE
  BEGIN
    MAYBE-HANDLE-DIR
    PRINT-LOC
    BEGIN
      KEY DUP #CR <>
    WHILE
      EMIT
    REPEAT
    CR
  AGAIN
;

TEST
