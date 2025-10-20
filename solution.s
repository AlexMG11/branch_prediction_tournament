.data
	# === Constants ===
	.equ TABLE_SIZE, 2048                  # Number of entries in each prediction table
	.equ TABLE_MASK, 2047                  # Bitmask (0x7FF) to index into tables
	.equ COUNTER_THRESHOLD, 2              # Prediction threshold (predict taken if counter >= 2)
	.equ COUNTER_MAX, 3                    # Maximum value for saturating counters (2-bit counters: 0-3)
	.equ GHR_MASK, 0xFFF                   # 12-bit mask for Global History Register
	.equ LOCAL_HIST_MASK, 0x3FF            # 10-bit mask for per-branch local history

	.bss
	.align 64
	# === Predictor tables and state ===
gshare_table:     .skip TABLE_SIZE        # Gshare predictor: 2048 2-bit counters (1 byte each)
local_table:      .skip TABLE_SIZE        # Local predictor: 2048 2-bit counters (1 byte each)
selector_table:   .skip TABLE_SIZE        # Meta-predictor: 2048 2-bit counters to choose between predictors
local_history:    .skip TABLE_SIZE * 2    # Per-branch local history: 2048 entries × 2 bytes (10-bit histories)
ghr:              .skip 4                 # Global History Register: 32-bit storage (12 bits used)

	.text
	# ============================================================
	# init - Initialize predictor tables
	# 
	# Sets all counters to weakly-taken state (COUNTER_THRESHOLD=2)
	# and clears all history registers
	# ============================================================
	.global init
init:
	pushq %rbp
	movq %rsp, %rbp

	# Initialize gshare_table to COUNTER_THRESHOLD (weakly taken)
	movq $TABLE_SIZE, %rcx             # rcx = loop counter (2048)
	movb $COUNTER_THRESHOLD, %al       # al = initial value (2)
	lea gshare_table(%rip), %rdi       # rdi = base address of gshare table
.Linit_gshare:
	movb %al, -1(%rdi,%rcx)            # Store counter value at index rcx-1
	loop .Linit_gshare                 # Decrement rcx and loop if not zero

	# Initialize local_table to COUNTER_THRESHOLD (weakly taken)
	movq $TABLE_SIZE, %rcx             # Reset counter to 2048
	lea local_table(%rip), %rdi        # rdi = base address of local table
.Linit_local:
	movb %al, -1(%rdi,%rcx)            # Store counter value at index rcx-1
	loop .Linit_local

	# Initialize selector_table to COUNTER_THRESHOLD (neutral state)
	movq $TABLE_SIZE, %rcx             # Reset counter to 2048
	lea selector_table(%rip), %rdi     # rdi = base address of selector table
.Linit_selector:
	movb %al, -1(%rdi,%rcx)            # Store counter value at index rcx-1
	loop .Linit_selector

	# Zero local_history (clear all per-branch histories)
	movq $TABLE_SIZE, %rcx             # Reset counter to 2048
	lea local_history(%rip), %rdi      # rdi = base address of local history array
.Linit_hist:
	movw $0, -2(%rdi,%rcx,2)           # Clear 16-bit entry at index rcx-1
	loop .Linit_hist

	# Zero global history register
	movl $0, ghr(%rip)                 # Clear the global history register

	popq %rbp
	ret

	# ============================================================
	# predict_branch - Make branch prediction
	# 
	# Uses tournament predictor: selector chooses between gshare
	# (global history) and local (per-branch history) predictors
	# 
	# Input: %rdi = PC (branch address)
	# Output: %rax = prediction (0 = not taken, 1 = taken)
	# ============================================================
	.global predict_branch
predict_branch:
	pushq %rbp
	movq %rsp, %rbp
	pushq %rbx                         # Save callee-saved registers
	pushq %r12
	pushq %r13

	# Calculate per-branch index from PC
	movq %rdi, %r8                     # r8 = PC
	andq $TABLE_MASK, %r8              # r8 = PC & 0x7FF (lower 11 bits)

	# Load selector counter to decide which predictor to use
	lea selector_table(%rip), %rax     # rax = address of selector table
	movzbl (%rax,%r8), %ecx            # ecx = selector[PC_index] (zero-extend byte)

	# Decide which predictor to use based on selector
	# If selector < threshold: use local predictor
	# If selector >= threshold: use gshare predictor
	cmp $COUNTER_THRESHOLD, %ecx
	jl .Luse_local_pred                # Jump if selector < 2

	# === Use gshare predictor ===
.Luse_gshare_pred:
	movl ghr(%rip), %edx               # edx = Global History Register
	movq %rdi, %rax                    # rax = PC
	xorq %rdx, %rax                    # rax = PC ^ GHR (gshare hash function)
	andq $TABLE_MASK, %rax             # rax = (PC ^ GHR) & 0x7FF = gshare index

	lea gshare_table(%rip), %rbx       # rbx = address of gshare table
	movzbl (%rbx,%rax), %ecx           # ecx = gshare_table[index] (counter value)

	# Branchless prediction: predict taken if counter >= threshold
	xorl %eax, %eax                    # eax = 0
	cmp $COUNTER_THRESHOLD, %ecx       # Compare counter with threshold
	setge %al                          # al = 1 if counter >= 2, else 0
	jmp .Lpredict_done

	# === Use local predictor ===
.Luse_local_pred:
	lea local_history(%rip), %rax      # rax = address of local history array
	movzwl (%rax,%r8,2), %edx          # edx = local_history[PC_index] (10-bit history)

	andl $TABLE_MASK, %edx             # edx = history & 0x7FF = local table index
	lea local_table(%rip), %rbx        # rbx = address of local table
	movzbl (%rbx,%rdx), %ecx           # ecx = local_table[history_index] (counter value)

	# Branchless prediction: predict taken if counter >= threshold
	xorl %eax, %eax                    # eax = 0
	cmp $COUNTER_THRESHOLD, %ecx       # Compare counter with threshold
	setge %al                          # al = 1 if counter >= 2, else 0

.Lpredict_done:
	popq %r13                          # Restore callee-saved registers
	popq %r12
	popq %rbx
	popq %rbp
	ret

	# ============================================================
	# actual_branch - Update predictor with actual outcome
	# 
	# Updates all three components:
	# 1. Gshare counter (based on actual outcome)
	# 2. Local counter (based on actual outcome)
	# 3. Selector counter (based on which predictor was correct)
	# Also updates both history registers
	# 
	# Input: %rdi = PC, %rsi = actual outcome (0/1)
	# Output: none
	# ============================================================
	.global actual_branch
actual_branch:
	pushq %rbp
	movq %rsp, %rbp
	pushq %rbx                         # Save callee-saved registers
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15

	# Save inputs for later use
	movq %rdi, %r15                    # r15 = PC (saved)
	movl %esi, %r14d                   # r14d = actual outcome (0 or 1)

	# Calculate per-branch index from PC
	movq %r15, %r8                     # r8 = PC
	andq $TABLE_MASK, %r8              # r8 = PC & 0x7FF = per-branch index

	# === Calculate gshare index and prediction ===
	movl ghr(%rip), %edx               # edx = Global History Register
	movq %r15, %r9                     # r9 = PC
	xorq %rdx, %r9                     # r9 = PC ^ GHR
	andq $TABLE_MASK, %r9              # r9 = (PC ^ GHR) & 0x7FF = gshare index

	lea gshare_table(%rip), %r10       # r10 = address of gshare table
	movzbl (%r10,%r9), %ecx            # ecx = gshare counter value
	xorl %eax, %eax                    # eax = 0
	cmp $COUNTER_THRESHOLD, %ecx       # Compare with threshold
	setge %al                          # al = gshare prediction (0 or 1)

	# === Calculate local index and prediction ===
	lea local_history(%rip), %r11      # r11 = address of local history array
	movzwl (%r11,%r8,2), %edx          # edx = local_history[PC_index]
	andl $TABLE_MASK, %edx             # edx = history & 0x7FF = local table index

	lea local_table(%rip), %r12        # r12 = address of local table
	movzbl (%r12,%rdx), %esi           # esi = local counter value
	xorl %ebx, %ebx                    # ebx = 0
	cmp $COUNTER_THRESHOLD, %esi       # Compare with threshold
	setge %bl                          # bl = local prediction (0 or 1)

	# === Update selector (only if predictors disagree) ===
	# Selector learns which predictor is more accurate
	cmpb %al, %bl                      # Compare gshare and local predictions
	je .Lskip_selector_update          # Skip if both predictors agree

	lea selector_table(%rip), %r13     # r13 = address of selector table
	movzbl (%r13,%r8), %edi            # edi = current selector counter

	# Check if gshare was correct
	cmpb %al, %r14b                    # Compare gshare prediction with actual
	je .Linc_selector_update           # Jump if gshare was correct

	# Check if local was correct
	cmpb %bl, %r14b                    # Compare local prediction with actual
	jne .Lskip_selector_update         # Skip if neither was correct (shouldn't happen)

	# Decrement selector (local was correct, gshare was wrong)
	testl %edi, %edi                   # Check if counter is at minimum (0)
	jle .Lskip_selector_update         # Skip if already at 0
	decb (%r13,%r8)                    # Decrease selector (favor local)
	jmp .Lskip_selector_update

.Linc_selector_update:
	# Increment selector (gshare was correct, local was wrong)
	cmp $COUNTER_MAX, %edi             # Check if counter is at maximum (3)
	jge .Lskip_selector_update         # Skip if already at 3
	incb (%r13,%r8)                    # Increase selector (favor gshare)

.Lskip_selector_update:
	# === Update gshare counter (saturating 2-bit counter) ===
	testl %r14d, %r14d                 # Check actual outcome
	je .Ldec_gshare_counter            # Jump if not taken (0)

	# Increment gshare counter if branch was taken
	cmp $COUNTER_MAX, %ecx             # Check if at maximum (3)
	jge .Lskip_gshare_update           # Skip if already saturated
	incb (%r10,%r9)                    # Increment counter (strengthen taken prediction)
	jmp .Lskip_gshare_update

.Ldec_gshare_counter:
	# Decrement gshare counter if branch was not taken
	testl %ecx, %ecx                   # Check if at minimum (0)
	jle .Lskip_gshare_update           # Skip if already saturated
	decb (%r10,%r9)                    # Decrement counter (strengthen not-taken prediction)

.Lskip_gshare_update:
	# === Update local counter (saturating 2-bit counter) ===
	testl %r14d, %r14d                 # Check actual outcome
	je .Ldec_local_counter             # Jump if not taken (0)

	# Increment local counter if branch was taken
	cmp $COUNTER_MAX, %esi             # Check if at maximum (3)
	jge .Lskip_local_update            # Skip if already saturated
	incb (%r12,%rdx)                   # Increment counter (strengthen taken prediction)
	jmp .Lskip_local_update

.Ldec_local_counter:
	# Decrement local counter if branch was not taken
	testl %esi, %esi                   # Check if at minimum (0)
	jle .Lskip_local_update            # Skip if already saturated
	decb (%r12,%rdx)                   # Decrement counter (strengthen not-taken prediction)

.Lskip_local_update:
	# === Update global history register (12-bit shift register) ===
	movl ghr(%rip), %eax               # eax = current GHR
	shll $1, %eax                      # Shift left by 1 (make room for new bit)
	orl %r14d, %eax                    # Insert actual outcome in LSB
	andl $GHR_MASK, %eax               # Mask to 12 bits (0xFFF)
	movl %eax, ghr(%rip)               # Store updated GHR

	# === Update per-branch local history (10-bit shift register) ===
	movzwl (%r11,%r8,2), %eax          # eax = current local history for this branch
	shll $1, %eax                      # Shift left by 1 (make room for new bit)
	orl %r14d, %eax                    # Insert actual outcome in LSB
	andl $LOCAL_HIST_MASK, %eax        # Mask to 10 bits (0x3FF)
	movw %ax, (%r11,%r8,2)             # Store updated local history

	# Restore callee-saved registers
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	popq %rbp
	ret