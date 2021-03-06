; This Forth implementation is based on jonesforth - https://github.com/nornagon/jonesforth
; Any similarities are probably not accidental.

; The first bootstrap stage of 2K Linux is implemented as a bootloader. This bootsector implements
; FAT32, with the assumption that the sector and cluster sizes are both 512 bytes. Long file names
; are not supported, but their presence for files we don't care about is not harmful. All disk I/O
; is done using EDD, which means won't work on very old PCs (like pre-Pentium old) or when booting
; from booting from a floppy. Both of these problems don't concern me a lot, primarily because CHS
; addressing isn't the most pleasant to work with. Patches welcome. The FAT partition contains all
; of the necessary source code, and should be the first physical partition of the drive.

; EBP is always set to the value 0x7C00 to generate shorter instructions for accessing some memory
; memory locations. Constants that start with `d` represent an offset from EBP. Almost all of them
; are also defined in image-files/stage1.frt. It is imperative that these values match between the
; two files.

; We use a part of the code section as variables after executing it:
;  7C00 -  7C0F -> The EDD disk packet
%define dDiskPacket            0
%define dDiskPacketDestOffset  4
%define dDiskPacketDestSegment 6
%define dDiskPacketLBA         8
;  7C10 -  7C23 -> Forth variables, all are 4 bytes long. More detail can be found in stage1.frt.
%define dBLK    16 ; The currently loaded cluster
%define dTOIN   20 ; The address of the next byte KEY will read, relative to FileBuffer
%define dLATEST 24 ; The LFA of the last Forth word defined.
%define dHERE   28 ; The address of the first free byte of Forth memory.
%define dSTATE  32 ; 1 if compiling words, 0 if interpreting.
%define dLENGTH 36 ; The number of characters left in the file currently being read

; The last two partition entries are reused as a buffer for WORD.

; The general memory map looks like this:
;  0000 -  03FF -> Real mode interrupt vector table
;  0400 -  04FF -> The BIOS data area
;  0500 -  ???? -> Forth return stack
%define ForthR0 0x0500

;  ???? -  7BFF -> the stack, used as the Forth parameter stack
;  7C00 -  7DFF -> The MBR - the first part of this file
;  7E00 -  83FF -> 3 sectors loaded from the FAT filesystem - the second part of this file
ORG 0x7C00

;  8400 -  85FF -> A buffer for one sector of a file or directory
%define FileBuffer 0x8400

;  8600 -  87FF -> A buffer for one sector of FAT
%define FATBuffer  0x8600

;  8800 -  89FF -> A buffer for the sector with BPB
%define BPBBuffer  0x8800

;  8A00 - 7FFFF -> The Forth memory. This is where the definitions of all words are stored, except
;                  the ones defined in this file. HERE is initialized to point to the beginning of
;                  this memory region.
%define ForthMemoryStart 0x8A00

; 80000 - 9FFFF -> Mostly unassigned, but the end is used by the Extended BIOS Data Area. Its size
;                  varies, and this 128 KiB is the maximum
; A0000 - BFFFF -> Video RAM
; C0000 - FFFFF -> ROMs and memory mapped hardware

%define SectorLength   512

; Addresses of the values in the BPB we need to correctly parse the FAT filesystem.
%define BPBReservedSectors BPBBuffer+14
%define BPBFATCount        BPBBuffer+16
%define BPBSectorsPerFAT   BPBBuffer+36
%define BPBRootCluster     BPBBuffer+44

%macro NEXT 0
	lodsd
	jmp eax
%endmacro

%define F_IMMED   0x80
%define F_HIDDEN  0x20
%define F_LENMASK 0x1f

; BIOS loads the first sector of the hard drive at 7C00 and, if the boot signature at offset 0x1FE
; matches, jumps here, in 16-bit Real Mode.
BITS 16

MBR:
; While all BIOSes agree about the destination of the jump, this cannot be said about the value of
; IP - the memory segmentation of x86 present in Real Mode makes it possible to encode the address
; in two different ways, i. e. 0000:7C00 (the sane way) and 07C0:0000 (the I am a snowflake way).

; Because jumps and calls are relative on x86, the difference is not immediately problematic,
; which is probably why the bug went unnoticed until it was too late. However, trying to write
; code that could be loaded at more than one address without the help of relocation table is
; tricky. Hence, let's correct the faulty BIOSes with a long jump.
	jmp 0:start
start:
; Since an interrupt can happen at any time, and interrupts use the stack, one has to disable them
; before moving the stack, since doing so is not an atomic operation.
	cli
	mov bp, MBR
	mov sp, bp

; Here, we set up the segment registers. All real mode code operates in the 00000-0FFFF range, and
; therefore no values other than zero are necessary...
	xor cx, cx
	mov ss, cx
	mov ds, cx
	mov es, cx

; ... except for probing the A20 gate, for which access to the segment FFFF is required.
	dec cx
	mov fs, cx

; When BIOS jumps to 0000:7C00, a few valuable values are left in the registers. One of them is of
; particular interest to any developer of a bootloader or any code that works on a similar level -
; the DL register contains the BIOS number of the disk the MBR was loaded from, which is primarily
; used as a parameter to the BIOS disk calls.

; You will see self modifying code in a few places. Every label used to mark these situations uses
; a suffix `Patch` and, perhaps more importantly, the prefix `..@`, which decouples the label from
; the system of global and local labels. Please refer to yasm's documentation for more details.
	mov byte[..@DiskNumberPatch], dl
	sti

; Setting the video mode makes screen output work even if the BIOS leaves the VGA card in graphics
; mode, like some new BIOSes like to do. This also clears the screen from any BIOS messages.
	mov ax, 0x0003
	int 0x10

; Interpreting a FAT filesystem starts with the BIOS Parameter Block, which is stored in the first
; sector of the partition.
	mov eax, dword[P1LBA]
; What follows is the first instruction that isn't overlapping with the variable area at all.
	mov di, BPBBuffer
	call near DiskRead

; First FAT sector = Partition Start LBA + Reserved Sector Count
	movzx ebx, word[BPBReservedSectors]
	add ebx, dword[P1LBA]
	mov dword[..@FirstFATSectorPatch], ebx

; Cluster Zero LBA = First FAT sector + FAT count * Sectors Per FAT - 2
	mov eax, dword[BPBSectorsPerFAT]
	movzx ecx, byte[BPBFATCount]
	mul ecx
	add eax, ebx
	sub eax, 2
	mov dword[..@ClusterZeroLBAPatch], eax

	mov di, StageZeroFilename
	push word LoadPartTwo
	; fallthrough
; push X / jmp Y is equivalent to call near Y / jmp X, but here jmp Y is a noop, so it was omitted
; TL;DR: call near FindFileRoot / jmp LoadPartTwo

; ---------- PARSING FAT DIRECTORIES -------------------------------------------------------------

; In a FAT filesystem, a directory is just a file that stores constant-size directory entries. One
; directory entry contains:
;  - a filename
;  - an attribute byte
;  - the number of the first cluster of the file the entry describes
;  - the size of the file
;  - a lot of information we don't care about like the creation and modification date.

%define FATNameLength  11
%define DirAttributes  11
%define DirHighCluster 20
%define DirLowCluster  26
%define DirFileSize    28
%define DirEntrySize   32

; The attribute byte is a bit field:
;  - bit 0 (value 1): if set, the file is read only
;  - bit 1 (value 2): if set, the file is hidden
;  - bit 2 (value 4): if set, the file is marked as a system file
;  - bit 3 (value 8): if set, this is not a file but a volume ID
;  - bit 4 (value 16): if set, the file is a directory
;  - bit 5 (value 32): if set, the file has been changed since this bit has last been cleared - it
;                      is commonly used by archiving/backup software.
; If the entry is not a file but a long file name entry, it is marked as read only, hidden, system
; and volume ID, which is unambiguous because volume ID excludes all other three.

%define AttrReadOnly  1
%define AttrHidden    2
%define AttrSystem    4
%define AttrVolumeID  8
%define AttrDirectory 16
%define AttrArchive   32

; If the entry has either of the following bits set, ignore it
%define AttrMaskIgnore AttrVolumeID | AttrSystem | AttrHidden

; FindFileRoot: like FindFile, but looks in the root directory of the partition, as opposed to the
; one currently loaded.
FindFileRoot:
	push di
	mov eax, dword[BPBRootCluster]
	call near ReadCluster
	pop di
	; fallthrough

; FindFile: read the currently loaded file as a directory, find the file with a specified name and
; load its first cluster. Also sets >IN and LENGTH appropriately.
; Input:
;  DI = pointer to filename
FindFile:
; Set >IN to 0
	xor ecx, ecx
	mov dword[byte bp+dTOIN], ecx

; Initialize the loop counter for this cluster
	mov cl, SectorLength / DirEntrySize
; SI holds a pointer to the entry currently being processed
	mov si, FileBuffer
.loop:
; If the filename starts with a zero, the directory ended, which means we couldn't find the file.
	mov al, byte[si]
	or al, al
	jz short .notfound
; Usually, one should check whether the first byte is 0xE5 (if so, you should skip the entry), but
; it won't won't match the filename anyway.

; Check the attribute byte for any flags that indicate we should skip it.
	test byte[byte si+DirAttributes], AttrMaskIgnore
	jnz short .next

; Before comparing the filename, CL, SI and DI need to be pushed on the stack, but remembering all
; registers is shorter and doesn't hurt.
	pusha
	mov cl, FATNameLength
.cmploop:
	lodsb
; Convert the bytes coming from disk to uppercase.
	cmp al, 'a'
	jb .noconvert
	cmp al, 'z'
	ja .noconvert
	sub al, 'a' - 'A'
.noconvert:
	cmp al, byte[di]
	jne short .nomatch
	inc di
	loop .cmploop
	popa

; We have a match! Set LENGTH and load the first cluster.
	mov eax, dword[byte si+DirFileSize]
	mov dword[byte bp+dLENGTH], eax
; Load the doubleword two bytes earlier to make the desired part land in the more significant word
	mov eax, dword[byte si+DirHighCluster-2]
	mov ax, word[byte si+DirLowCluster]
	jmp short ReadCluster
.nomatch:
	popa
.next:
	add si, DirEntrySize
	loop .loop
; Load next cluster of the directory and start from the beginning
	push di
	call near ReadNextCluster
	pop di
	jnc short FindFile
.notfound:
	mov cx, 13
NotFoundError:
	mov si, di
	call near PrintTextLength
	jmp short PrintGenericErrorMsg

ReadNextCluster:
; one FAT entry is 4 bytes, a sector is 512 bytes, 512 / 4 = 128, log_2 128 = 7
	mov eax, dword[byte bp+dBLK]
	shr eax, 7
	db 0x66, 0x05 ; add eax, imm32
..@FirstFATSectorPatch:
	dd 0          ; modified during initialisation

	mov di, FATBuffer
	call near DiskRead

	movzx bx, byte[byte bp+dBLK]
	shl bl, 1 ; discard the top bit
	shl bx, 1
	mov eax, dword[di+bx] ; DI is preserved during DiskRead
	and eax, 0x0fffffff ; fun fact: FAT32 uses only the bottom 28 bits, the top 4 are reserved
	cmp eax, 0x0ffffff8 ; if the carry is set, it means "below", i. e. go to ReadCluster
	cmc                 ; cmc flips the carry to make "set carry" mean "EOF"
	jc short ..@Return

ReadCluster:
	mov dword[bp+dBLK], eax
	db 0x66, 0x05 ; add eax, imm32
..@ClusterZeroLBAPatch:
	dd 0          ; modified during initialisation

	db 0xBF, 0x00 ; mov di, imm16
..@ReadClusterDestinationPatch:
	db FileBuffer>>8 ; modified when loading the remaining 1.5K of this file
	; fallthrough

; DiskRead: read a sector
; Input:
;   EAX = LBA
;   DI  = output buffer
DiskRead:
	mov dword[byte bp+dDiskPacketLBA], eax
	xor eax, eax
	mov dword[byte bp+dDiskPacketLBA+4], eax
	mov dword[byte bp+dDiskPacket], 0x10010
	mov word[byte bp+dDiskPacketDestOffset], di
	mov word[byte bp+dDiskPacketDestSegment], ax
	db 0xB2 ; mov dl, imm8
..@DiskNumberPatch:
	db 0xFF ; modified during initialisation
	mov ah, 0x42
	mov si, bp
	int 0x13
	jnc short ..@Return

	; disk error handling
	mov al, ah
	shr al, 4
	call near PrintHexDigit

	mov al, ah
	and al, 0x0f
	call near PrintHexDigit

	mov si, DiskErrorMsg
	; fallthrough
Error:
	call near PrintText
PrintGenericErrorMsg:
	mov si, GenericErrorMsg
	call near PrintText
	cli
	hlt

PrintHexDigit:
	add al, '0'
	cmp al, '9'
	jbe short PrintChar
	add al, 'A' - '0' - 0x0A
	; fallthrough
PrintChar:
	pusha
	xor bx, bx
	mov ah, 0x0e
	int 0x10
	popa
..@Return:
	ret

; Print a Pascal-style string.
; Input:
;  DS:SI -> the string
PrintText:
	lodsb
	movzx cx, al
; Print a string with the length passed in explicitly.
; Input:
;  DS:SI -> the string
;  CX = length
PrintTextLength:
	lodsb
	call near PrintChar
	loop PrintTextLength
	ret

StageZeroFilename:
	db 'STAGE0  BIN'

A20ErrorMsg:
	db 3, 'A20'

DiskErrorMsg:
	db 3, 'DSK'

GenericErrorMsg:
	db 4, ' ERR'

EOFMessage:
	db 3, 'EOF'

GDT:
	dw GDT_End-GDT-1
	dd GDT
	dw 0

%define Selector_Code16 0x08
	dw 0xffff
	dw 0
	db 0
	db 0x9a
	db 0x8f
	db 0

%define Selector_Code32 0x10
	dw 0xffff
	dw 0
	db 0
	db 0x9a
	db 0xcf
	db 0

%define Selector_Data   0x18
	dw 0xffff
	dw 0
	db 0
	db 0x92
	db 0xcf
	db 0
GDT_End:

LoadPartTwo:
	mov byte[..@ReadClusterDestinationPatch], 0x7E
.loop:
	call near ReadNextCluster
	jc short A20
	add byte[..@ReadClusterDestinationPatch], 2
	jmp short .loop

KBC_SendCommand:
	in al, 0x64
	test al, 2
	jnz KBC_SendCommand
	pop si
	lodsb
	out 0x64, al
	jmp si

MBR_FREESPACE EQU 446 - ($ - $$)
	times MBR_FREESPACE db 0

PartitionTable:
; The following 64 bytes will be overwritten by the partition table. In the first four of them are
; stored the amounts of free space in each of the two code regions, which are calculated easily by
; the assembler.
	dw MBR_FREESPACE ; could be replaced with 0 with no consequencess
	dw REST_FREESPACE ; same
	times 4 db 0

P1LBA:      dd 0
P1Length:   dd 0

	times 16 db 0

WORDBuffer:

	times 32 db 0

	dw 0xaa55

A20:
	call near Check_A20
	mov ax, 0x2401
	int 0x15
	call near Check_A20

	call near KBC_SendCommand
	db 0xAD

	call near KBC_SendCommand
	db 0xD0

.readwait:
	in al, 0x64
	test al, 1
	jz .readwait

	in al, 0x60
	push ax

	call near KBC_SendCommand
	db 0xD1

	pop ax
	or al, 2
	out 0x60, al

	call near KBC_SendCommand
	db 0xAE

	call near Check_A20
	in al, 0x92
	or al, 2
	and al, 0xfe
	out 0x92, al
	call near Check_A20
	mov si, A20ErrorMsg
	jmp Error

Check_A20:
	; we have set DS to 0 and FS to 0xFFFF and the very beginning
	cli
	mov si, 0x7dfe
.loop:
	mov al, byte[si]
	inc byte[fs:si+0x10]
	wbinvd
	cmp al, byte[si]
	jz .ok
	loop .loop
	ret
.ok:
	pop ax ; discard the return address
	push dword PM_Entry-2
	jmp short GoPM

BITS 32
CallRM:
	xchg ebp, eax
	mov eax, dword[esp]
	mov eax, dword[eax]
	jmp Selector_Code16:.code16
BITS 16
.code16:
	push word GoPM
	push ax
	mov eax, cr0
	dec ax
	mov cr0, eax
	jmp 0:.rmode
.rmode:
	xor ax, ax
	mov ds, ax
	mov es, ax
	mov ss, ax
	xchg eax, ebp
	mov bp, MBR
	sti
	ret
GoPM:
	cli
	lgdt [GDT]
	mov ebp, eax
	mov eax, cr0
	inc ax
	mov cr0, eax
	jmp Selector_Code32:.code32
BITS 32
.code32:
	mov ax, Selector_Data
	mov ds, ax
	mov es, ax
	mov ss, ax
	movzx esp, sp
	add dword[esp], 2
	mov eax, ebp
	mov ebp, MBR
	ret

; Here is where the actual Forth implementation starts. In contrast to jonesforth, we are using
; direct threaded code. Also, the link fields in the dictionary are relative.

StageOneFilename:
	db 'STAGE1  FRT'

PM_Entry:
	mov di, StageOneFilename
	call near CallRM
	dw FindFileRoot

	mov dword[ebp+dLATEST], LATESTInitialValue

	xor eax, eax
	mov dword[ebp+dSTATE], eax

	mov ah, ForthMemoryStart >> 8
	mov dword[ebp+dHERE], eax

	; fallthrough

INTERPRET:
	call near doWORD
	mov ebx, eax

	mov edx, [ebp+dLATEST]
.find:
	lea esi, [edx+2]
	lodsb
	and al, F_HIDDEN|F_LENMASK
	cmp al, cl
	jnz .next

	mov edi, ebx
	push ecx
	repe cmpsb
	pop ecx
	je short .found
.next:
	movzx eax, word[edx]
	or eax, eax
	jz short .handle_number
	sub edx, eax
	jmp short .find
.found:
	xchg eax, esi
	mov ebx, [ebp+dSTATE]
	or ebx, ebx
	jz short .interpret ; if we're in interpreting mode, execute the word

	test byte[edx+2], F_IMMED
	jz short .comma_next ; not immediate, compile it

.interpret:
	mov esi, INTERPRET_LOOP
	mov edi, ForthR0
	jmp eax

.interpret_number:
	push eax
.go_again:
	jmp short INTERPRET

.handle_number:
	push ecx
	push esi
	mov esi, WORDBuffer
	mov word[.negate_patch], 0x9066 ; two byte nop - assume we don't need to negate
	xor ebx, ebx
	mul ebx      ; zeroes EAX, EBX and EDX
	mov dl, 10
	mov bl, [esi]
	cmp bl, '$'
	jne .nothex
	mov dl, 16
	inc esi
	dec ecx
.nothex:
	cmp bl, '-'
	jne .loop
	mov word[.negate_patch], 0xd8f7
	inc esi
	dec ecx
.loop:
	mov bl, [esi]
	sub bl, '0'
	jb .end
	cmp bl, 9
	jbe .gotdigit
	sub bl, 'A' - '0'
	jb .end
	add bl, 10
.gotdigit:
	cmp bl, dl
	jae .end
	push edx
	mul edx
	add eax, ebx
	pop edx
	inc esi
	loop .loop
.end:
.negate_patch:
	dw 0xd8f7 ; either `neg eax' or `nop'
	pop esi

	or ecx, ecx
	pop ecx
	jnz short .error

	mov ebx, [ebp+dSTATE]
	or ebx, ebx
	jz short .interpret_number

	push eax
	mov eax, LIT
	call near doCOMMA
	pop eax

.comma_next:
	call near doCOMMA
	jmp short .go_again

.error:
	mov di, WORDBuffer
	call near CallRM
	dw NotFoundError

doCOMMA:
	lea edx, [ebp+dHERE]
	mov ebx, [edx]
	mov [ebx], eax
	add dword[edx], 4
	ret

INTERPRET_LOOP:
	dd INTERPRET

; ( -- )
; Return to executing its callee. Appended automatically by `;` at the end of all definitions, but
; may be used explicitly, usually conditionally
EXIT:
	sub edi, 4
	mov esi, [edi]
	jmp short doNEXT

LIT:
	lodsd
	push eax
	jmp short doNEXT

link_SUB:
	dw 0
	db 1, '-'
	pop eax
	sub dword[esp], eax
	jmp short doNEXT

link_ZEQ:
	dw $-link_SUB
	db 2, '0='
	pop ecx
	xor eax, eax
	or ecx, ecx
	setnz al
	dec eax
	push eax
	jmp short doNEXT

link_ULT:
	dw $-link_ZEQ
	db 2, 'U<'
	pop ecx
	pop ebx
	xor eax, eax
	cmp ebx, ecx
	setnb al
	dec eax
	push eax
	jmp short doNEXT

link_AND:
	dw $-link_ULT
	db 3, 'AND'
	pop eax
	and dword[esp], eax
	jmp short doNEXT

link_RSHIFT:
	dw $-link_AND
	db 6, 'RSHIFT'
	pop ecx
	shr dword[esp], cl
	jmp short doNEXT

link_STORE:
	dw $-link_RSHIFT
	db 1, '!'
	pop ebx
	pop eax
	mov [ebx], eax
	jmp short doNEXT

link_FETCH:
	dw $-link_STORE
	db 1, '@'
	pop eax
	mov eax, [eax]
	push eax
	jmp short doNEXT

link_RPSTORE:
	dw $-link_FETCH
	db 3, 'RP!'
	pop edi
	jmp short doNEXT

link_RPFETCH:
	dw $-link_RPSTORE
	db 3, 'RP@'
	push edi
	jmp short doNEXT

DOCOL:
	mov [edi], esi
	add edi, 4
	pop esi
doNEXT:
	NEXT

link_SPSTORE:
	dw $-link_RPFETCH
	db 3, 'SP!'
	pop esp
	jmp short doNEXT

link_SPFETCH:
	dw $-link_SPSTORE
	db 3, 'SP@'
	mov eax, esp
	push eax
	jmp short doNEXT

link_KEY:
	dw $-link_SPFETCH
	db 3, 'KEY'
	call near doKEY
	push eax
	jmp short doNEXT

link_EMIT:
	dw $-link_KEY
	db 4, 'EMIT'
	pop eax
	call near CallRM
	dw PrintChar
	jmp short doNEXT

; ( cluster -- )
; A thin wrapper around ReadCluster
link_LOAD:
	dw $-link_EMIT
	db 4, 'LOAD'
	pop eax
	pushad
	call near CallRM
	dw ReadCluster
	popad
	jmp short doNEXT

; ( name-pointer -- )
; A thin wrapper around FindFile
link_FILE:
	dw $-link_LOAD
	db 4, 'FILE'
	pop eax
	xchg edi, eax
	pushad
	call near CallRM
	dw FindFile
	popad
	xchg edi, eax
	jmp short doNEXT

link_COLON:
	dw $-link_FILE
	db 1, ':'
COLON:
	call near doWORD
	or cl, F_HIDDEN

	push edi
	push esi
	xchg esi, eax
	mov edi, [ebp+dHERE]
	mov eax, edi
	sub eax, [ebp+dLATEST]
	mov [ebp+dLATEST], edi
	stosw
	mov al, cl
	stosb
	and cl, F_LENMASK
	rep movsb
	mov [ebp+dHERE], edi
	pop esi

	mov edi, [ebp+dHERE]
	mov al, 0xE8
	stosb
	mov eax, DOCOL-4 ; eax = DOCOL - (edi + 4)
	sub eax, edi
	stosd
	mov [ebp+dHERE], edi
	pop edi

	xor eax, eax
	dec eax
ChangeState:
	mov [ebp+dSTATE], eax
	NEXT

link_SEMICOLON:
	dw $-link_COLON
	db F_IMMED|1, ';'
SEMICOLON:
	mov eax, EXIT
	call near doCOMMA

	mov eax, [ebp+dLATEST]
	and byte[eax+2], ~F_HIDDEN

	xor eax, eax
	jmp short ChangeState

doKEY:
	mov eax, [ebp+dLENGTH]
	or eax, eax
	jz .end
	dec dword[ebp+dLENGTH]

	mov ebx, dword[ebp+dTOIN]
	cmp bx, 0x200
	jb .nonextcluster

	pushad
	call near CallRM
	dw ReadNextCluster
	popad

	xor ebx, ebx
.nonextcluster:
	xor eax, eax
	mov al, byte[FileBuffer+ebx]
	inc ebx
	mov dword[ebp+dTOIN], ebx
.end:
	ret

doWORD:
	call near doKEY
	or al, al
	jz .eof
	cmp al, ' '
	jbe doWORD
	xor ecx, ecx
	mov edx, WORDBuffer
.loop:
	mov [edx+ecx], al
	inc ecx
	call near doKEY
	cmp al, ' '
	ja .loop

	xchg edx, eax
	ret
.eof:
	mov si, EOFMessage
	call near CallRM
	dw Error

LATESTInitialValue EQU link_SEMICOLON

REST_FREESPACE EQU 2048 - ($ - $$)
	times REST_FREESPACE db 0x00
