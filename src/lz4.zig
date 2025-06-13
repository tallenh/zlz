//! LZ4 Decompression Implementation for SPICE protocol
//!
//! This is a line-by-line port of the LZ4 decompression algorithm from the
//! reference C implementation, plus SPICE-specific integration code.
//!
//! LZ4 is a lossless compression algorithm providing very fast decompression
//! speed (typically reaching RAM speed limits on multi-core systems).

const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;

// =============================================================================
// LZ4 Constants (from lz4.h)
// =============================================================================

const LZ4_MEMORY_USAGE = 14;
const LZ4_MAX_INPUT_SIZE = 0x7E000000; // 2 113 929 216 bytes
const LZ4_COMPRESSBOUND_SIZE = LZ4_MAX_INPUT_SIZE + (LZ4_MAX_INPUT_SIZE / 255) + 16;
const LZ4_HASH_SIZE_U32 = (1 << LZ4_MEMORY_USAGE);

// LZ4 format constants
const ML_BITS = 4;
const ML_MASK = (1 << ML_BITS) - 1;
const RUN_BITS = 8 - ML_BITS;
const RUN_MASK = (1 << RUN_BITS) - 1;

// LZ4 Stream Decoder constants
const LZ4_STREAMDECODE_MINSIZE = 32;

// SPICE-specific constants (from canvas_base.c)
const SPICE_BITMAP_FMT_16BIT = 0;
const SPICE_BITMAP_FMT_24BIT = 1;
const SPICE_BITMAP_FMT_32BIT = 2;
const SPICE_BITMAP_FMT_RGBA = 13;

// =============================================================================
// Data Structures
// =============================================================================

/// LZ4 Stream Decode structure (from lz4.c)
const LZ4_streamDecode_t = struct {
    table: [LZ4_HASH_SIZE_U32]u32,
    prefix: ?[*]const u8,
    extDict: ?[*]const u8,
    prefixSize: usize,
    extDictSize: usize,
};

/// SPICE LZ4 Data structure (from draw.h)
pub const SpiceLZ4Data = struct {
    data_size: u32,
    data: []const u8,
};

/// SPICE Image Descriptor (from draw.h)
pub const SpiceImageDescriptor = struct {
    id: u64,
    type: u8,
    flags: u8,
    width: u32,
    height: u32,
};

/// LZ4 Error types
pub const LZ4Error = error{
    InvalidInput,
    OutputTooSmall,
    CorruptedData,
    UnsupportedFormat,
    MissingHeader,
    FormatError,
    OutOfMemory,
};

/// LZ4 Decompression result
pub const LZ4Result = struct {
    bytes_read: usize,
    bytes_written: usize,
};

// =============================================================================
// Utility Functions (from lz4.c)
// =============================================================================

/// Read a 32-bit big-endian value (from canvas_base.c)
inline fn READ_UINT32_BE(ptr: [*]const u8) u32 {
    return (@as(u32, ptr[0]) << 24) |
        (@as(u32, ptr[1]) << 16) |
        (@as(u32, ptr[2]) << 8) |
        @as(u32, ptr[3]);
}

/// Read a 16-bit little-endian value (from lz4.c)
inline fn LZ4_read16(ptr: [*]const u8) u16 {
    return std.mem.readInt(u16, ptr[0..2], .little);
}

/// Read a 32-bit little-endian value (from lz4.c)
inline fn LZ4_read32(ptr: [*]const u8) u32 {
    return std.mem.readInt(u32, ptr[0..4], .little);
}

/// Read a pointer-sized value (from lz4.c)
inline fn LZ4_readPtrRef(ptr: [*]const u8) usize {
    if (@sizeOf(usize) == 8) {
        return std.mem.readInt(u64, ptr[0..8], .little);
    } else {
        return std.mem.readInt(u32, ptr[0..4], .little);
    }
}

/// Copy memory (optimized version from lz4.c)
inline fn LZ4_memcpy(dst: [*]u8, src: [*]const u8, size: usize) void {
    @memcpy(dst[0..size], src[0..size]);
}

/// Wildcard copy (from lz4.c)
inline fn LZ4_wildCopy(dst: [*]u8, src: [*]const u8, dst_end: [*]const u8) void {
    var d = dst;
    var s = src;

    while (@intFromPtr(d) < @intFromPtr(dst_end)) {
        LZ4_memcpy(d, s, 8);
        d += 8;
        s += 8;
    }
}

/// Secure copy for overlapping regions (from lz4.c)
inline fn LZ4_secureCopy(dst: [*]u8, src: [*]const u8, dst_end: [*]const u8) void {
    var d = dst;
    var s = src;

    const diff = @intFromPtr(d) - @intFromPtr(s);

    if (diff >= 8) {
        // Fast path: no overlap possible
        LZ4_wildCopy(d, s, dst_end);
        return;
    }

    // Slow path: handle overlapping copy
    while (@intFromPtr(d) < @intFromPtr(dst_end)) {
        d[0] = s[0];
        d += 1;
        s += 1;
    }
}

// =============================================================================
// LZ4 Core Decompression Functions (from lz4.c)
// =============================================================================

/// Get the length of a variable-length integer (from lz4.c)
inline fn read_variable_length(ip: *[*]const u8, ip_end: [*]const u8) !usize {
    var length: usize = 0;
    var s: usize = 0;

    while (true) {
        if (@intFromPtr(ip.*) >= @intFromPtr(ip_end)) return LZ4Error.CorruptedData;

        const c = ip.*[0];
        ip.* += 1;

        length += @as(usize, c) << @intCast(s);
        s += 8;

        if (c != 255) break;

        if (s >= @sizeOf(usize) * 8) return LZ4Error.CorruptedData;
    }

    return length;
}

/// LZ4 Safe Decompress (main decompression function from lz4.c)
pub fn LZ4_decompress_safe(src: []const u8, dst: []u8, dst_capacity: usize) LZ4Error!LZ4Result {
    if (src.len == 0) return LZ4Error.InvalidInput;
    if (dst_capacity == 0) return LZ4Error.OutputTooSmall;

    const src_end = src.ptr + src.len;
    const dst_end = dst.ptr + dst_capacity;

    var ip: [*]const u8 = src.ptr; // input pointer
    var op: [*]u8 = dst.ptr; // output pointer

    // Main decompression loop
    while (true) {
        // Get literal length and match length from token
        if (@intFromPtr(ip) >= @intFromPtr(src_end)) return LZ4Error.CorruptedData;

        const token = ip[0];
        ip += 1;

        // Decode literal length
        var lit_length: usize = (token >> ML_BITS);
        if (lit_length == RUN_MASK) {
            const extra_length = read_variable_length(&ip, src_end) catch return LZ4Error.CorruptedData;
            lit_length += extra_length;
        }

        // Copy literals
        if (lit_length > 0) {
            const literal_end = op + lit_length;
            if (@intFromPtr(literal_end) > @intFromPtr(dst_end)) return LZ4Error.OutputTooSmall;
            if (@intFromPtr(ip + lit_length) > @intFromPtr(src_end)) return LZ4Error.CorruptedData;

            LZ4_memcpy(op, ip, lit_length);
            ip += lit_length;
            op += lit_length;
        }

        // Check for end of data
        if (@intFromPtr(ip) >= @intFromPtr(src_end)) break;

        // Decode offset
        if (@intFromPtr(ip + 2) > @intFromPtr(src_end)) return LZ4Error.CorruptedData;
        const offset = LZ4_read16(ip);
        ip += 2;

        if (offset == 0) return LZ4Error.CorruptedData;

        // Calculate match position
        const match = op - offset;
        if (@intFromPtr(match) < @intFromPtr(dst.ptr)) return LZ4Error.CorruptedData;

        // Decode match length
        var match_length: usize = (token & ML_MASK) + 4; // minimum match is 4
        if ((token & ML_MASK) == ML_MASK) {
            const extra_length = read_variable_length(&ip, src_end) catch return LZ4Error.CorruptedData;
            match_length += extra_length;
        }

        // Copy match
        const match_end = op + match_length;
        if (@intFromPtr(match_end) > @intFromPtr(dst_end)) return LZ4Error.OutputTooSmall;

        LZ4_secureCopy(op, match, match_end);
        op = match_end;
    }

    return LZ4Result{
        .bytes_read = @intFromPtr(ip) - @intFromPtr(src.ptr),
        .bytes_written = @intFromPtr(op) - @intFromPtr(dst.ptr),
    };
}

/// LZ4 Stream Decoder Context
pub const LZ4StreamDecode = struct {
    internal: LZ4_streamDecode_t,

    const Self = @This();

    /// Create a new LZ4 stream decoder (from lz4.c)
    pub fn init() Self {
        return Self{
            .internal = std.mem.zeroes(LZ4_streamDecode_t),
        };
    }

    /// Free the stream decoder (from lz4.c)
    pub fn deinit(self: *Self) void {
        _ = self; // No dynamic allocation, nothing to free
    }

    /// LZ4 Decompress Safe Continue (from lz4.c)
    pub fn decompress_safe_continue(self: *Self, src: []const u8, dst: []u8, dst_capacity: usize) LZ4Error!i32 {
        _ = self; // TODO: implement proper streaming support

        // For now, implement as simple decompress
        // Full streaming support would require maintaining dictionary state
        const result = LZ4_decompress_safe(src, dst, dst_capacity) catch |err| return err;

        return @intCast(result.bytes_written);
    }
};

// =============================================================================
// SPICE-specific LZ4 Integration (from canvas_base.c)
// =============================================================================

/// SPICE LZ4 Image structure
pub const SpiceLZ4Image = struct {
    width: u32,
    height: u32,
    format: u8,
    top_down: bool,
    stride: u32,
    data: []u8,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

/// Convert SPICE format to bytes per pixel (from canvas_base.c)
fn spice_format_to_bpp(spice_format: u8) !u32 {
    return switch (spice_format) {
        SPICE_BITMAP_FMT_16BIT => 2,
        SPICE_BITMAP_FMT_24BIT => 3,
        SPICE_BITMAP_FMT_32BIT => 4,
        SPICE_BITMAP_FMT_RGBA => 4,
        else => return LZ4Error.UnsupportedFormat,
    };
}

/// Decompress SPICE LZ4 image (port of canvas_get_lz4 from canvas_base.c)
pub fn decompress_spice_lz4(allocator: Allocator, image_descriptor: SpiceImageDescriptor, lz4_data: SpiceLZ4Data) LZ4Error!SpiceLZ4Image {
    if (lz4_data.data.len < 2) return LZ4Error.MissingHeader;

    var data_pos: usize = 0;
    const data = lz4_data.data;

    // Read header (port from canvas_base.c)
    const top_down = data[0] != 0;
    const spice_format = data[1];
    data_pos += 2;

    const width = image_descriptor.width;
    const height = image_descriptor.height;
    const bpp = spice_format_to_bpp(spice_format) catch return LZ4Error.UnsupportedFormat;
    const stride_encoded = width * bpp;

    // Validate dimensions to prevent overflow
    if (width == 0 or height == 0) return LZ4Error.FormatError;
    if (stride_encoded / width != bpp) return LZ4Error.FormatError; // Check for overflow

    // Allocate output buffer
    const total_size = height * stride_encoded;
    if (total_size / height != stride_encoded) return LZ4Error.FormatError; // Check for overflow

    const surface_data = allocator.alloc(u8, total_size) catch return LZ4Error.OutOfMemory;
    errdefer allocator.free(surface_data);

    // Initialize LZ4 stream decoder (port from canvas_base.c)
    var stream = LZ4StreamDecode.init();
    defer stream.deinit();

    var dest_pos: usize = 0;

    // Decompress blocks (port from canvas_base.c)
    while (data_pos < data.len) {
        // Read compressed block size - need at least 4 bytes
        if (data_pos + 4 > data.len) {
            allocator.free(surface_data);
            return LZ4Error.FormatError;
        }

        const enc_size = READ_UINT32_BE(data[data_pos..].ptr);
        data_pos += 4;

        // Validate block size - check for reasonable limits and available data
        if (enc_size == 0 or enc_size > data.len or data_pos + enc_size > data.len) {
            allocator.free(surface_data);
            return LZ4Error.FormatError;
        }

        // Check if we have enough space in output buffer
        const remaining_output = total_size - dest_pos;
        if (remaining_output == 0) {
            allocator.free(surface_data);
            return LZ4Error.FormatError;
        }

        // Decompress block
        const compressed_block = data[data_pos .. data_pos + enc_size];
        const decompressed_block = surface_data[dest_pos..];

        const dec_size = stream.decompress_safe_continue(compressed_block, decompressed_block, remaining_output) catch |err| {
            allocator.free(surface_data);
            return err;
        };

        if (dec_size <= 0 or @as(usize, @intCast(dec_size)) > remaining_output) {
            allocator.free(surface_data);
            return LZ4Error.FormatError;
        }

        dest_pos += @intCast(dec_size);
        data_pos += enc_size;
    }

    return SpiceLZ4Image{
        .width = width,
        .height = height,
        .format = spice_format,
        .top_down = top_down,
        .stride = stride_encoded,
        .data = surface_data,
    };
}

// =============================================================================
// Public API Functions
// =============================================================================

/// Simple LZ4 block decompression
pub fn decompress_block(src: []const u8, dst: []u8, dst_capacity: usize) LZ4Error!usize {
    const result = try LZ4_decompress_safe(src, dst, dst_capacity);
    return result.bytes_written;
}

/// Create LZ4 Stream Decoder
pub fn createStreamDecode() LZ4StreamDecode {
    return LZ4StreamDecode.init();
}

// =============================================================================
// Tests
// =============================================================================

test "LZ4 basic decompression" {
    const testing = std.testing;
    _ = testing.allocator; // Not used in this test but kept for future use

    // Simple test with known data
    // This would need actual LZ4 compressed data to test properly

    // Test error cases
    var dst: [100]u8 = undefined;

    // Empty input should fail
    const empty_src: []const u8 = &[_]u8{};
    const result1 = decompress_block(empty_src, &dst, dst.len);
    try testing.expectError(LZ4Error.InvalidInput, result1);

    // Zero capacity should fail
    const test_src = [_]u8{ 0x10, 0x48, 0x65, 0x6c, 0x6c, 0x6f }; // Simple test data
    const result2 = decompress_block(&test_src, &dst, 0);
    try testing.expectError(LZ4Error.OutputTooSmall, result2);
}

test "SPICE format to BPP conversion" {
    const testing = std.testing;

    try testing.expectEqual(@as(u32, 2), try spice_format_to_bpp(SPICE_BITMAP_FMT_16BIT));
    try testing.expectEqual(@as(u32, 3), try spice_format_to_bpp(SPICE_BITMAP_FMT_24BIT));
    try testing.expectEqual(@as(u32, 4), try spice_format_to_bpp(SPICE_BITMAP_FMT_32BIT));
    try testing.expectEqual(@as(u32, 4), try spice_format_to_bpp(SPICE_BITMAP_FMT_RGBA));

    try testing.expectError(LZ4Error.UnsupportedFormat, spice_format_to_bpp(255));
}

test "LZ4 Stream Decoder creation" {
    var stream = createStreamDecode();
    defer stream.deinit();

    // Should not crash - just testing that creation works
}
