# Tournament Branch Predictor

A high-performance tournament branch predictor implementation in x86-64 assembly, combining gshare and local predictors with a meta-predictor selector.

## Overview

This project implements a sophisticated branch prediction algorithm that dynamically chooses between two complementary prediction strategies:

- **Gshare Predictor**: Uses global branch history XORed with the program counter
- **Local Predictor**: Uses per-branch local history patterns
- **Selector (Meta-predictor)**: Learns which predictor performs better for each branch

## Architecture

### Prediction Tables

| Component | Size | Description |
|-----------|------|-------------|
| Gshare Table | 2048 × 2-bit | Saturating counters indexed by (PC ⊕ GHR) |
| Local Table | 2048 × 2-bit | Saturating counters indexed by local history |
| Selector Table | 2048 × 2-bit | Meta-predictor choosing between gshare/local |
| Local History | 2048 × 10-bit | Per-branch history shift registers |
| Global History | 12-bit | Global history shift register |

### Saturating Counters

Each 2-bit counter represents prediction confidence:
- `0`: Strongly not taken
- `1`: Weakly not taken
- `2`: Weakly taken (prediction threshold)
- `3`: Strongly taken

## API

### `void init()`

Initializes all predictor tables and history registers.

- Sets all counters to weakly-taken state (value 2)
- Clears global and local history registers
- Must be called before making predictions

### `int predict_branch(uint64_t pc)`

Makes a prediction for a branch at the given program counter.

**Parameters:**
- `pc`: Program counter (branch address)

**Returns:**
- `1` if branch is predicted taken
- `0` if branch is predicted not taken

**Algorithm:**
1. Index into selector table using PC bits [10:0]
2. If selector ≥ 2, use gshare prediction
3. If selector < 2, use local prediction
4. Return prediction based on chosen counter

### `void actual_branch(uint64_t pc, int outcome)`

Updates the predictor with the actual branch outcome.

**Parameters:**
- `pc`: Program counter (branch address)
- `outcome`: Actual result (1 = taken, 0 = not taken)

**Updates:**
1. **Gshare counter**: Increment/decrement based on outcome (saturating)
2. **Local counter**: Increment/decrement based on outcome (saturating)
3. **Selector counter**: Adjust based on which predictor was correct (only when predictions differ)
4. **Global history**: Shift in new outcome bit (12-bit register)
5. **Local history**: Shift in new outcome bit (10-bit register)

## How It Works

### Prediction Phase

```
1. Calculate index: PC & 0x7FF
2. Read selector[index]
3. If selector favors gshare:
   - Index = (PC ⊕ GHR) & 0x7FF
   - Return gshare_table[index] ≥ 2
4. If selector favors local:
   - Index = local_history[PC] & 0x7FF
   - Return local_table[index] ≥ 2
```

### Update Phase

```
1. Make both gshare and local predictions
2. If predictions differ:
   - Increment selector if gshare correct
   - Decrement selector if local correct
3. Update gshare counter (saturating)
4. Update local counter (saturating)
5. Shift outcome into GHR (12 bits)
6. Shift outcome into local_history[PC] (10 bits)
```

## Usage Example

```c
#include <stdint.h>

// Assembly functions
extern void init();
extern int predict_branch(uint64_t pc);
extern void actual_branch(uint64_t pc, int outcome);

int main() {
    // Initialize predictor
    init();
    
    // Simulate branch execution
    uint64_t branch_pc = 0x1000;
    
    // Make prediction
    int prediction = predict_branch(branch_pc);
    
    // Execute branch and get actual outcome
    int actual = /* ... actual branch result ... */;
    
    // Update predictor
    actual_branch(branch_pc, actual);
    
    return 0;
}
```

## Performance Characteristics

- **Memory footprint**: ~10 KB total
  - 6 KB for prediction tables (3 × 2048 bytes)
  - 4 KB for local history (2048 × 2 bytes)
  - 4 bytes for global history
- **Prediction latency**: Single table lookup after selector decision
- **Update complexity**: Updates 3-5 tables per branch (depending on predictor agreement)

## Design Decisions

### Why Tournament?

Different branches exhibit different patterns:
- **Global patterns**: Correlated with other branches (e.g., loop iterators)
- **Local patterns**: Dependent only on branch's own history (e.g., alternating branches)

The tournament structure allows the predictor to adaptively choose the best strategy per branch.

### Index Sizes

- **11-bit PC indexing** (2048 entries): Balances capacity and aliasing
- **12-bit GHR**: Captures sufficient global context
- **10-bit local history**: Adequate for most local patterns



## Limitations

- **Aliasing**: Multiple branches may map to same predictor entries
- **Cold start**: Requires warm-up period for accurate predictions
- **Indirect branches**: Not specifically optimized for indirect jumps
- **History length**: Fixed history depths may not suit all workloads

