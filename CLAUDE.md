# ZLZ - Zig LZ Decoder Optimization Notes

## Completed Optimizations (Priority 1)

### ✅ Implemented and Verified
- **Optimized copyPixels function**: Hoisted bounds checking, improved RLE handling
- **Hoisted bounds checking**: Single validation per literal run instead of per pixel  
- **Enhanced SIMD processing**: 8-pixel batching, better thresholds, cached alpha values

## Future Optimization Opportunities

### Priority 2: Medium Risk, Good Impact

#### D) Optimize control flow structure
**Current Issue**: Main loop branches frequently on `ctrl >= 32`
```zig
// Current structure
if (ctrl >= 32) {
    // Handle references (less common)
} else {
    // Handle literals (more common)
}
```

**Optimization**: Restructure to optimize for literal case (more common):
```zig
// Optimized structure - literals as fall-through
if (ctrl < 32) {
    // Handle literals (hot path - no branch prediction penalty)
} else {
    // Handle references (cold path)
}
```

**Expected Benefit**: 2-5% improvement due to better branch prediction

#### E) Reduce function call overhead
**Current Issue**: `pix2byte()` called frequently, even though inlined
```zig
inline fn pix2byte(pix: usize) usize {
    return pix << BPP_SHIFT;
}
```

**Optimization**: More aggressive inlining and direct bit shifts:
```zig
// Consider @call(.always_inline, ...) for critical paths
// Or direct bit shifts: `op << BPP_SHIFT` instead of `pix2byte(op)`
```

**Expected Benefit**: 1-3% improvement in tight loops

### Priority 3: Higher Risk, Requires Careful Testing

#### F) True SIMD with vector intrinsics
**Current Implementation**: Scalar loop unrolling pretending to be SIMD
```zig
// Current "SIMD" - actually scalar
inline while (i < 8) : (i += 1) {
    out_buf[d_idx + i*4 + 0] = in_buf[e_idx + i*3 + 0]; // B
    out_buf[d_idx + i*4 + 1] = in_buf[e_idx + i*3 + 1]; // G
    out_buf[d_idx + i*4 + 2] = in_buf[e_idx + i*3 + 2]; // R
    out_buf[d_idx + i*4 + 3] = alpha_value;             // A
}
```

**True SIMD Optimization**:
```zig
if (comptime std.simd.suggestVectorLength(u8)) |vec_len| {
    // Use actual SIMD vectors for BGR→BGRA conversion
    // Leverage shuffle instructions
    // Platform-specific: SSE4.1, AVX2, NEON
    const Vec = @Vector(vec_len, u8);
    // Load 3-byte BGR triplets into vectors
    // Shuffle/expand to 4-byte BGRA quads
    // Set alpha channel with vector broadcast
}
```

**Challenges**:
- Platform-specific optimization required
- Complex shuffle patterns for 3→4 byte expansion
- Need fallback for platforms without SIMD

**Expected Benefit**: 15-40% improvement on modern CPUs

#### G) Memory layout optimizations
**Current Issue**: `flipImageDataInPlace` allocates temporary row buffer
```zig
const temp_row = try std.heap.page_allocator.alloc(u8, row_size);
defer std.heap.page_allocator.free(temp_row);
```

**Optimizations**:
```zig
// 1. SIMD row swapping for large images
if (row_size >= 64) {
    // Use SIMD to swap 16/32 bytes at a time
    // Vectorized memory operations
}

// 2. Cache-friendly tiling for very large images
if (width * height > LARGE_IMAGE_THRESHOLD) {
    // Process in tiles to improve cache locality
    // Reduce memory pressure
}

// 3. Stack allocation for small rows
if (row_size <= 1024) {
    var temp_row: [1024]u8 = undefined;
    // Avoid heap allocation overhead
}
```

**Expected Benefit**: 10-25% improvement for image flipping operations

#### H) Batch control byte processing
**Current Issue**: Reading control bytes one at a time in main loop
```zig
ctrl = in_buf[encoder];
encoder += 1;
```

**Optimization**: Prefetch and batch process control information
```zig
// Read multiple control bytes ahead
// Predict upcoming operations
// Reduce memory access overhead
// Better instruction pipeline utilization
```

**Challenges**:
- Complex state management
- Variable-length encoding makes batching difficult
- Risk of over-engineering

**Expected Benefit**: 5-10% improvement in decode loops

## Testing Strategy for Future Optimizations

### Regression Testing
- Always run `zig build test-lz` before and after changes
- Verify byte-perfect match with C reference implementation
- Test with multiple image sizes and formats

### Performance Testing
```bash
# Benchmark current vs optimized implementation
zig build -Doptimize=ReleaseFast
# Profile with perf/Instruments on large datasets
```

### Safety Validation
- Test with AddressSanitizer/Valgrind equivalent
- Verify bounds checking still prevents overruns
- Test edge cases: small images, malformed data, boundary conditions

## Implementation Priority Order

1. **Priority 2D** (Control flow optimization) - Safest, good impact
2. **Priority 2E** (Function call overhead) - Low risk, measurable benefit  
3. **Priority 3G** (Memory layout) - Medium risk, good for large images
4. **Priority 3F** (True SIMD) - Highest risk, highest reward
5. **Priority 3H** (Batch processing) - Complex, uncertain benefit

## Notes
- Always measure performance before/after optimizations
- Maintain compatibility with all target platforms
- Document any platform-specific code paths
- Consider compile-time feature flags for advanced optimizations