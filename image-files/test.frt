\ a portion of the Forth core test suite
\ (C) 1995 JOHNS HOPKINS UNIVERSITY / APPLIED PHYSICS LABORATORY
\ MAY BE DISTRIBUTED FREELY AS LONG AS THIS COPYRIGHT NOTICE REMAINS.
CREATE ACTUAL-RESULTS $20 CELLS ALLOT
VARIABLE ACTUAL-DEPTH
VARIABLE START-DEPTH
VARIABLE ERROR-XT

: EMPTY-STACK S0 SP! ;
: ERROR ERROR-XT @ EXECUTE ;
: ERROR1 TYPE CR EMPTY-STACK HALT ;
' ERROR1 ERROR-XT !

: T{ DEPTH START-DEPTH ! ;
: ->
  DEPTH DUP ACTUAL-DEPTH !
  START-DEPTH @ - 0 ?DO
    ACTUAL-RESULTS I CELLS + !
  LOOP ;

: }T
  DEPTH ACTUAL-DEPTH @ = IF
    DEPTH START-DEPTH @ - 0 ?DO
      ACTUAL-RESULTS I CELLS + @
      <> IF
        S" INCORRECT RESULT" ERROR LEAVE
      THEN
    LOOP
  ELSE
    S" WRONG NUMBER OF RESULTS" ERROR
  THEN ;

0 CONSTANT 0S
0 INVERT CONSTANT 1S

0 INVERT                   CONSTANT MAX-UINT
0 INVERT 1 RSHIFT          CONSTANT MAX-INT
0 INVERT 1 RSHIFT INVERT   CONSTANT MIN-INT
0 INVERT 1 RSHIFT          CONSTANT MID-UINT
0 INVERT 1 RSHIFT INVERT   CONSTANT MID-UINT+1

." Part 1" CR

T{ : GD1 DO I LOOP ; -> }T
T{ 4 1 GD1 -> 1 2 3 }T
T{ 2 -1 GD1 -> -1 0 1 }T
T{ MID-UINT+1 MID-UINT GD1 -> MID-UINT }T

." Part 2" CR

T{ : GD2 DO I -1 +LOOP ; -> }T
T{ 1 4 GD2 -> 4 3 2 1 }T
T{ -1 2 GD2 -> 2 1 0 -1 }T
T{ MID-UINT MID-UINT+1 GD2 -> MID-UINT+1 MID-UINT }T

." Part 3" CR

T{ : GD3 DO 1 0 DO J LOOP LOOP ; -> }T
T{ 4 1 GD3 -> 1 2 3 }T
T{ 2 -1 GD3 -> -1 0 1 }T
T{ MID-UINT+1 MID-UINT GD3 -> MID-UINT }T

." Part 4" CR

T{ : GD4 DO 1 0 DO J LOOP -1 +LOOP ; -> }T
T{ 1 4 GD4 -> 4 3 2 1 }T
T{ -1 2 GD4 -> 2 1 0 -1 }T
T{ MID-UINT MID-UINT+1 GD4 -> MID-UINT+1 MID-UINT }T

." Part 5" CR

T{ : GD5 123 SWAP 0 DO I 4 > IF DROP 234 LEAVE THEN LOOP ; -> }T
T{ 1 GD5 -> 123 }T
T{ 5 GD5 -> 123 }T
T{ 6 GD5 -> 234 }T

." Part 6" CR

T{ : GD6  ( PAT: T{0 0},{0 0}{1 0}{1 1},{0 0}{1 0}{1 1}{2 0}{2 1}{2 2} )
   0 SWAP 0 DO
      I 1+ 0 DO I J + 3 = IF I UNLOOP I UNLOOP EXIT THEN 1+ LOOP
    LOOP ; -> }T
T{ 1 GD6 -> 1 }T
T{ 2 GD6 -> 3 }T
T{ 3 GD6 -> 4 1 2 }T

HALT