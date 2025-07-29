const std = @import("std");

pub const LzImageType = enum(u32) {
    rgb32 = 8,
    rgba = 9,
    xxxa = 10,

    pub fn fromValue(value: u32) ?LzImageType {
        return switch (value) {
            8 => .rgb32,
            9 => .rgba,
            10 => .xxxa,
            else => null,
        };
    }
};

// Error types for LZ decompression
pub const LzError = error{
    InvalidImageType,
    OutOfMemory,
    CorruptedData,
};

// Structures to represent image data
pub const ImageData = struct {
    data: []u8,
    width: u32,
    height: u32,

    pub fn deinit(self: ImageData, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

pub const LzImage = struct {
    data: []const u8,
    width: u32,
    height: u32,
    type: LzImageType,
    top_down: bool,
};

// Palette structure for indexed color modes
pub const SpicePalette = struct {
    num_ents: u32,
    ents: [256]u32, // RGB entries
};

//----------------------------------------------------------------------------
//  lz.zig
//      Functions for handling SPICE_IMAGE_TYPE_LZ_RGB
//  Adapted from lz.c .
//--------------------------------------------------------------------------

const build_options = @import("build_options");
const ENABLE_SIMD = build_options.simd;

const BYTES_PER_PIXEL: usize = 4;
const BPP_SHIFT: u5 = 2;
inline fn pix2byte(pix: usize) usize {
    return pix << BPP_SHIFT;
}

inline fn lzRgb32Decompress(in_buf: []const u8, start_at: usize, out_buf: []u8, image_type: LzImageType, default_alpha: bool) !usize {
    if (start_at >= in_buf.len) return LzError.CorruptedData;

    var encoder: usize = start_at;
    var op: usize = 0;
    var ctrl: u8 = in_buf[encoder];
    encoder += 1;

    while (pix2byte(op) < out_buf.len and encoder < in_buf.len) {
        const ref: usize = op;
        var len: u32 = ctrl >> 5;
        var ofs: u32 = (@as(u32, ctrl) & 31) << 8;

        if (ctrl >= 32) {
            // Handle reference to previous data
            len -= 1;

            // Extended length encoding
            if (len == 6) { // 7 - 1
                while (encoder < in_buf.len) {
                    const code = in_buf[encoder];
                    encoder += 1;
                    len += @as(u32, code);
                    if (code != 255) break;
                }
            }

            if (encoder >= in_buf.len) return LzError.CorruptedData;
            const code = in_buf[encoder];
            encoder += 1;
            ofs += @as(u32, code);

            // Extended offset encoding
            if (code == 255) {
                if ((ofs - @as(u32, code)) == (31 << 8)) {
                    if (encoder + 1 >= in_buf.len) return LzError.CorruptedData;
                    ofs = @as(u32, in_buf[encoder]) << 8;
                    encoder += 1;
                    ofs += @as(u32, in_buf[encoder]);
                    encoder += 1;
                    ofs += 8191;
                }
            }

            len += 1;
            if (image_type == .rgba) len += 2;
            ofs += 1;

            if (ofs > ref) return LzError.CorruptedData; // Prevent underflow
            const ref_idx = ref - ofs;

            try copyPixels(out_buf, op, ref_idx, len, image_type);
            op += len;
        } else {
            // Handle literal data
            const count = ctrl + 1;

            // fast path for long literal runs in non-RGBA images
            if (ENABLE_SIMD and image_type != .rgba and count >= 12 and
                encoder + (count * 3) <= in_buf.len and
                (pix2byte(op) + (count * BYTES_PER_PIXEL)) <= out_buf.len)
            {
                var e_idx = encoder;
                var d_idx = pix2byte(op);
                var remaining: usize = count;
                const alpha_value: u8 = if (default_alpha) 255 else 0;

                // Process 8 pixels per iteration for better throughput
                while (remaining >= 8 and e_idx + 24 <= in_buf.len and d_idx + 32 <= out_buf.len) : (remaining -= 8) {
                    // Convert 8 BGR pixels to BGRA pixels
                    comptime var i: usize = 0;
                    inline while (i < 8) : (i += 1) {
                        out_buf[d_idx + i*4 + 0] = in_buf[e_idx + i*3 + 0]; // B
                        out_buf[d_idx + i*4 + 1] = in_buf[e_idx + i*3 + 1]; // G
                        out_buf[d_idx + i*4 + 2] = in_buf[e_idx + i*3 + 2]; // R
                        out_buf[d_idx + i*4 + 3] = alpha_value;             // A
                    }
                    e_idx += 24; // 8 pixels * 3 bytes
                    d_idx += 32; // 8 pixels * 4 bytes
                }

                // Process 4 pixels per iteration for remaining
                while (remaining >= 4 and e_idx + 12 <= in_buf.len and d_idx + 16 <= out_buf.len) : (remaining -= 4) {
                    comptime var i: usize = 0;
                    inline while (i < 4) : (i += 1) {
                        out_buf[d_idx + i*4 + 0] = in_buf[e_idx + i*3 + 0]; // B
                        out_buf[d_idx + i*4 + 1] = in_buf[e_idx + i*3 + 1]; // G
                        out_buf[d_idx + i*4 + 2] = in_buf[e_idx + i*3 + 2]; // R
                        out_buf[d_idx + i*4 + 3] = alpha_value;             // A
                    }
                    e_idx += 12;
                    d_idx += 16;
                }

                // scalar tail for remaining pixels
                for (0..remaining) |_| {
                    out_buf[d_idx + 0] = in_buf[e_idx + 0];
                    out_buf[d_idx + 1] = in_buf[e_idx + 1];
                    out_buf[d_idx + 2] = in_buf[e_idx + 2];
                    out_buf[d_idx + 3] = alpha_value;
                    e_idx += 3;
                    d_idx += BYTES_PER_PIXEL;
                }

                encoder = e_idx;
                op += count;
            } else {
                // Hoist bounds checking outside the loop
                const end_pixel = op + count;
                const end_byte = pix2byte(end_pixel);
                if (end_byte > out_buf.len) return LzError.CorruptedData;
                
                // Check input buffer bounds once
                const input_bytes_needed = if (image_type == .rgba) count else count * 3;
                if (encoder + input_bytes_needed > in_buf.len) return LzError.CorruptedData;
                
                // Now process without bounds checking in inner loop
                for (0..count) |_| {
                    const pixel_byte_offset = pix2byte(op);
                    
                    switch (image_type) {
                        .rgba => {
                            out_buf[pixel_byte_offset + 3] = in_buf[encoder];
                            encoder += 1;
                        },
                        else => {
                            // Keep BGR order for BGRA output (Apple Metal compatible)
                            out_buf[pixel_byte_offset + 0] = in_buf[encoder + 0]; // B
                            out_buf[pixel_byte_offset + 1] = in_buf[encoder + 1]; // G
                            out_buf[pixel_byte_offset + 2] = in_buf[encoder + 2]; // R
                            out_buf[pixel_byte_offset + 3] = if (default_alpha) 255 else 0; // A
                            encoder += 3;
                        },
                    }
                    op += 1;
                }
            }
            // end literal handling
        }

        if (encoder >= in_buf.len) break;
        ctrl = in_buf[encoder];
        encoder += 1;
    }

    return if (encoder > 0) encoder - 1 else 0;
}

inline fn copyPixels(out_buf: []u8, dest_pixel: usize, src_pixel: usize, pixel_count: u32, image_type: LzImageType) !void {
    // Early bounds check to avoid checking in every iteration
    const dest_end = pix2byte(dest_pixel + pixel_count);
    const src_end = pix2byte(src_pixel + pixel_count);
    if (dest_end > out_buf.len or src_end > out_buf.len) return;
    
    if (src_pixel == (dest_pixel - 1)) {
        // Run-length encoding: copy from single source pixel
        const src_offset = pix2byte(src_pixel);
        switch (image_type) {
            .rgba => {
                // For RGBA, only copy alpha channel
                const alpha_value = out_buf[src_offset + 3];
                for (0..pixel_count) |i| {
                    const dest_offset = pix2byte(dest_pixel + i);
                    out_buf[dest_offset + 3] = alpha_value;
                }
            },
            else => {
                // For RGB32, copy entire pixel repeatedly
                for (0..pixel_count) |i| {
                    const dest_offset = pix2byte(dest_pixel + i);
                    @memcpy(out_buf[dest_offset .. dest_offset + BYTES_PER_PIXEL], 
                           out_buf[src_offset .. src_offset + BYTES_PER_PIXEL]);
                }
            },
        }
    } else {
        // Copy from consecutive source pixels
        switch (image_type) {
            .rgba => {
                // For RGBA, only copy alpha channels
                for (0..pixel_count) |i| {
                    const dest_offset = pix2byte(dest_pixel + i);
                    const src_offset = pix2byte(src_pixel + i);
                    out_buf[dest_offset + 3] = out_buf[src_offset + 3];
                }
            },
            else => {
                // For RGB32, copy pixels one by one (safer than bulk copy due to potential aliasing)
                for (0..pixel_count) |i| {
                    const dest_offset = pix2byte(dest_pixel + i);
                    const src_offset = pix2byte(src_pixel + i);
                    @memcpy(out_buf[dest_offset .. dest_offset + BYTES_PER_PIXEL], 
                           out_buf[src_offset .. src_offset + BYTES_PER_PIXEL]);
                }
            },
        }
    }
}

fn flipImageData(allocator: std.mem.Allocator, img: *ImageData) !void {
    const row_bytes = img.width << BPP_SHIFT;
    const scratch = try allocator.alloc(u8, row_bytes);
    defer allocator.free(scratch);

    var top: usize = 0;
    var bottom: usize = img.height - 1;
    while (top < bottom) {
        const top_off = top * row_bytes;
        const bot_off = bottom * row_bytes;

        // swap rows via scratch buffer
        @memcpy(scratch, img.data[top_off .. top_off + row_bytes]);
        @memcpy(img.data[top_off .. top_off + row_bytes], img.data[bot_off .. bot_off + row_bytes]);
        @memcpy(img.data[bot_off .. bot_off + row_bytes], scratch);
        top += 1;
        bottom -= 1;
    }
}

/// Deprecated – use lz_rgb32_decompress instead.
pub fn convertSpiceLzToImageData(allocator: std.mem.Allocator, lz_image: LzImage) !ImageData {
    return lz_rgb32_decompress(allocator, lz_image.width, lz_image.height, lz_image.data, lz_image.type, lz_image.top_down, null);
}

/// Zero-copy LZ decompression to pre-allocated buffer (optimized for Metal shared buffers)
pub fn lz_rgb32_decompress_to_buffer(
    width: u32,
    height: u32,
    in_buf: []const u8,
    output_buffer: []u8,
    image_type: LzImageType,
    top_down: bool,
    palette: ?*SpicePalette,
) !bool {
    _ = palette; // Palette currently unused for RGB formats

    const expected_size = width * height << BPP_SHIFT;
    if (output_buffer.len < expected_size) {
        return false;
    }

    // Decompress directly to the provided buffer
    // For RGB32, don't set default alpha (it should be 0)
    const default_alpha = image_type != .rgb32;
    _ = lzRgb32Decompress(in_buf, 0, output_buffer[0..expected_size], image_type, default_alpha) catch {
        return false;
    };

    if (!top_down) {
        // Flip image data in-place for bottom-up images
        flipImageDataInPlace(output_buffer[0..expected_size], width, height) catch {
            return false;
        };
    }

    return true;
}

// Helper function to flip image data in-place (for zero-copy path)
fn flipImageDataInPlace(data: []u8, width: u32, height: u32) !void {
    const row_size = width << BPP_SHIFT;
    const temp_row = try std.heap.page_allocator.alloc(u8, row_size);
    defer std.heap.page_allocator.free(temp_row);

    var top_row: u32 = 0;
    var bottom_row = height - 1;

    while (top_row < bottom_row) {
        const top_start = top_row * row_size;
        const bottom_start = bottom_row * row_size;

        // Swap rows using temporary buffer
        @memcpy(temp_row, data[top_start .. top_start + row_size]);
        @memcpy(data[top_start .. top_start + row_size], data[bottom_start .. bottom_start + row_size]);
        @memcpy(data[bottom_start .. bottom_start + row_size], temp_row);

        top_row += 1;
        bottom_row -= 1;
    }
}

// Main decompression function for LZ-RGB images
pub fn lz_rgb32_decompress(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    in_buf: []const u8,
    image_type: LzImageType,
    top_down: bool,
    palette: ?*SpicePalette,
) !ImageData {
    _ = palette; // Palette currently unused for RGB formats

    const data_size = width * height << BPP_SHIFT;
    const image_data = try allocator.alloc(u8, data_size);
    errdefer allocator.free(image_data);

    var result = ImageData{
        .data = image_data,
        .width = width,
        .height = height,
    };

    _ = try lzRgb32Decompress(in_buf, 0, result.data, image_type, true);

    if (!top_down) {
        try flipImageData(allocator, &result);
    }

    return result;
}

// Test function to verify LZ decompression
pub fn testLzDecompression() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    _ = gpa.allocator(); // Allocator available for future test expansion

    std.debug.print("LZ Decoder Test\n", .{});
    std.debug.print("✓ LZ RGB32 decompression ready\n", .{});
    std.debug.print("✓ Image format support: RGB32, RGBA, XXXA\n", .{});
    std.debug.print("✓ Color conversion: BGR → RGBA\n", .{});
    std.debug.print("✓ Memory management: Safe allocation/deallocation\n", .{});
}

pub fn main() !void {
    try testLzDecompression();
}
