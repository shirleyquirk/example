// poison_call(fn, dst, src, n): fill every callee-saved register with a
// known value, call fn, and report the first one fn destroyed. Catches
// AAPCS64 violations deterministically rather than by luck.
    .text
    .global poison_call
    .type poison_call, %function

    .macro CHKX reg, val, code
    cmp     \reg, #\val
    mov     w10, #\code
    b.ne    .Lfail
    .endm

    .macro CHKD reg, val, code
    fmov    x11, \reg
    cmp     x11, #\val
    mov     w10, #\code
    b.ne    .Lfail
    .endm

poison_call:
    stp     x29, x30, [sp, #-112]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]
    stp     x27, x28, [sp, #80]
    str     x18, [sp, #96]
    sub     sp, sp, #64
    stp     d8,  d9,  [sp, #0]
    stp     d10, d11, [sp, #16]
    stp     d12, d13, [sp, #32]
    stp     d14, d15, [sp, #48]

    mov     x9, x0                  // fn
    mov     x0, x1                  // dst
    mov     x1, x2                  // src
    mov     x2, x3                  // n

    mov     x18, #18
    mov     x19, #19
    mov     x20, #20
    mov     x21, #21
    mov     x22, #22
    mov     x23, #23
    mov     x24, #24
    mov     x25, #25
    mov     x26, #26
    mov     x27, #27
    mov     x28, #28
    mov     x11, #8
    fmov    d8, x11
    mov     x11, #9
    fmov    d9, x11
    mov     x11, #10
    fmov    d10, x11
    mov     x11, #11
    fmov    d11, x11
    mov     x11, #12
    fmov    d12, x11
    mov     x11, #13
    fmov    d13, x11
    mov     x11, #14
    fmov    d14, x11
    mov     x11, #15
    fmov    d15, x11

    blr     x9

    CHKX    x18, 18, 18
    CHKX    x19, 19, 19
    CHKX    x20, 20, 20
    CHKX    x21, 21, 21
    CHKX    x22, 22, 22
    CHKX    x23, 23, 23
    CHKX    x24, 24, 24
    CHKX    x25, 25, 25
    CHKX    x26, 26, 26
    CHKX    x27, 27, 27
    CHKX    x28, 28, 28
    CHKD    d8,  8,  108
    CHKD    d9,  9,  109
    CHKD    d10, 10, 110
    CHKD    d11, 11, 111
    CHKD    d12, 12, 112
    CHKD    d13, 13, 113
    CHKD    d14, 14, 114
    CHKD    d15, 15, 115
    mov     w10, #0
.Lfail:
    mov     w0, w10
    ldp     d8,  d9,  [sp, #0]
    ldp     d10, d11, [sp, #16]
    ldp     d12, d13, [sp, #32]
    ldp     d14, d15, [sp, #48]
    add     sp, sp, #64
    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    ldp     x25, x26, [sp, #64]
    ldp     x27, x28, [sp, #80]
    ldr     x18, [sp, #96]
    ldp     x29, x30, [sp], #112
    ret
