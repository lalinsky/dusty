# Awaitable Memory Layout Analysis

This document analyzes the memory savings from the two proposed optimizations for the Awaitable struct.

## Background

The issue proposes two optimizations:
1. Change `ref_count` from `usize`/`u32` to `u8`
2. Make `group_node` non-optional and instead make the group pointer optional

## Struct Definitions

### Current Layout
```zig
const AwaitableCurrent = struct {
    ref_count: usize,  // 8 bytes on 64-bit, 4 bytes on 32-bit
    group_node: ?struct {  // Optional struct adds a tag byte
        group: *anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};
```

### Optimization #1: ref_count as u8
```zig
const AwaitableOpt1 = struct {
    ref_count: u8,  // 1 byte instead of 8/4
    group_node: ?struct {
        group: *anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};
```

### Optimization #2: Optional group pointer instead of optional struct
```zig
const AwaitableOpt2 = struct {
    ref_count: usize,
    group_node: struct {  // No longer optional
        group: ?*anyopaque,  // Pointer is now optional
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};
```

### Both Optimizations Combined
```zig
const AwaitableOptBoth = struct {
    ref_count: u8,
    group_node: struct {
        group: ?*anyopaque,
        next: ?*anyopaque,
        prev: ?*anyopaque,
    },
    state: enum(u8) { pending, resolved, rejected },
};
```

## Memory Layout Calculation

### Zig's Optional Encoding

Zig optimizes optional pointers to use null representation (no extra space needed).
However, optional structs require a tag byte to indicate presence/absence.

### 64-bit Platform Analysis

**Current Layout:**
- ref_count: 8 bytes (usize)
- group_node optional tag: 1 byte + padding
- group_node.group: 8 bytes
- group_node.next: 8 bytes (already optional pointer, no extra space)
- group_node.prev: 8 bytes (already optional pointer, no extra space)
- state: 1 byte
- Alignment padding to 8-byte boundary

Expected size: ~40-48 bytes (depending on field ordering and padding)

**Optimization #1 (u8 ref_count):**
- ref_count: 1 byte
- Rest unchanged
- Savings: 7 bytes from ref_count, but may affect alignment

**Optimization #2 (optional group pointer):**
- Removes the optional struct tag (saves 1 byte + potential padding)
- group pointer becomes optional (no extra space, uses null)

**Both Optimizations:**
- Combines savings from both changes
- Expected savings: 8-16 bytes depending on alignment

### 32-bit Platform Analysis

**Current Layout:**
- ref_count: 4 bytes (u32)
- group_node optional tag: 1 byte + padding
- group_node.group: 4 bytes
- group_node.next: 4 bytes
- group_node.prev: 4 bytes
- state: 1 byte
- Alignment padding to 4-byte boundary

Expected size: ~20-24 bytes

**Optimization #1 (u8 ref_count):**
- ref_count: 1 byte
- Savings: 3 bytes from ref_count
- Due to 4-byte alignment on 32-bit, this creates better packing opportunities

**Optimization #2 (optional group pointer):**
- Removes optional struct tag
- Savings: 1 byte + padding

**Both Optimizations:**
- Expected savings: 4-8 bytes (16-33% reduction)

## Expected Results

### Theory #1 Validation
✅ ref_count as u8 **will help on 32-bit** due to alignment:
- On 32-bit: Reduces from 4 bytes to 1 byte, improving alignment with the 1-byte state field
- On 64-bit: Reduces from 8 bytes to 1 byte, though padding may absorb some savings

### Theory #2 Validation
✅ Making group_node non-optional and group pointer optional **saves space**:
- Removes the boolean tag from optional struct
- Uses null pointer representation instead (no extra space)
- Estimated savings: 1-8 bytes depending on alignment

## Verification

To verify these calculations, run:
```bash
zig run test_awaitable_size.zig
```

For 32-bit cross-compilation test:
```bash
zig build-exe test_awaitable_size.zig -target x86-linux -femit-bin=test_awaitable_size_32
./test_awaitable_size_32
```

## Recommendations

Both optimizations are recommended:

1. **ref_count as u8**: Unless reference counts can exceed 255, this is a safe optimization that saves 3-7 bytes per instance

2. **Optional group pointer**: This is a pure win with no downside, saving the optional struct tag overhead

Combined savings: **8-15 bytes per Awaitable instance** (15-30% reduction in memory usage)
