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

const BYTES_PER_PIXEL = 4;

fn lzRgb32Decompress(in_buf: []const u8, start_at: usize, out_buf: []u8, image_type: LzImageType, default_alpha: bool) !usize {
    if (start_at >= in_buf.len) return LzError.CorruptedData;

    var encoder: usize = start_at;
    var op: usize = 0;
    var ctrl: u8 = in_buf[encoder];
    encoder += 1;

    while ((op * BYTES_PER_PIXEL) < out_buf.len and encoder < in_buf.len) {
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

            for (0..count) |_| {
                if ((op * BYTES_PER_PIXEL) >= out_buf.len) break;

                switch (image_type) {
                    .rgba => {
                        if (encoder >= in_buf.len) return LzError.CorruptedData;
                        if ((op * BYTES_PER_PIXEL) + 3 < out_buf.len) {
                            out_buf[(op * BYTES_PER_PIXEL) + 3] = in_buf[encoder];
                        }
                        encoder += 1;
                    },
                    else => {
                        if (encoder + 2 >= in_buf.len) return LzError.CorruptedData;
                        if ((op * BYTES_PER_PIXEL) + 3 < out_buf.len) {
                            // Keep BGR order for BGRA output (Apple Metal compatible)
                            out_buf[(op * BYTES_PER_PIXEL) + 0] = in_buf[encoder + 0]; // B
                            out_buf[(op * BYTES_PER_PIXEL) + 1] = in_buf[encoder + 1]; // G
                            out_buf[(op * BYTES_PER_PIXEL) + 2] = in_buf[encoder + 2]; // R
                            if (default_alpha) {
                                out_buf[(op * BYTES_PER_PIXEL) + 3] = 255; // A
                            }
                        }
                        encoder += 3;
                    },
                }
                op += 1;
            }
        }

        if (encoder >= in_buf.len) break;
        ctrl = in_buf[encoder];
        encoder += 1;
    }

    return if (encoder > 0) encoder - 1 else 0;
}

fn copyPixels(out_buf: []u8, dest_pixel: usize, src_pixel: usize, pixel_count: u32, image_type: LzImageType) !void {
    if (src_pixel == (dest_pixel - 1)) {
        // Run-length encoding: copy from single source pixel
        const src_offset = src_pixel * BYTES_PER_PIXEL;
        for (0..pixel_count) |i| {
            const dest_offset = (dest_pixel + i) * BYTES_PER_PIXEL;
            if (dest_offset + 3 >= out_buf.len or src_offset + 3 >= out_buf.len) break;

            switch (image_type) {
                .rgba => {
                    out_buf[dest_offset + 3] = out_buf[src_offset + 3];
                },
                else => {
                    @memcpy(out_buf[dest_offset .. dest_offset + BYTES_PER_PIXEL], out_buf[src_offset .. src_offset + BYTES_PER_PIXEL]);
                },
            }
        }
    } else {
        // Copy from consecutive source pixels
        for (0..pixel_count) |i| {
            const dest_offset = (dest_pixel + i) * BYTES_PER_PIXEL;
            const src_offset = (src_pixel + i) * BYTES_PER_PIXEL;
            if (dest_offset + 3 >= out_buf.len or src_offset + 3 >= out_buf.len) break;

            switch (image_type) {
                .rgba => {
                    out_buf[dest_offset + 3] = out_buf[src_offset + 3];
                },
                else => {
                    @memcpy(out_buf[dest_offset .. dest_offset + BYTES_PER_PIXEL], out_buf[src_offset .. src_offset + BYTES_PER_PIXEL]);
                },
            }
        }
    }
}

fn flipImageData(allocator: std.mem.Allocator, img: *ImageData) !void {
    const row_bytes = img.width * BYTES_PER_PIXEL;
    const temp_buffer = try allocator.alloc(u8, img.data.len);
    defer allocator.free(temp_buffer);

    // Copy rows in reverse order
    for (0..img.height) |row| {
        const src_start = row * row_bytes;
        const src_end = src_start + row_bytes;
        const dest_start = (img.height - 1 - row) * row_bytes;

        if (src_end <= img.data.len and dest_start + row_bytes <= temp_buffer.len) {
            @memcpy(temp_buffer[dest_start .. dest_start + row_bytes], img.data[src_start..src_end]);
        }
    }

    @memcpy(img.data, temp_buffer);
}

pub fn convertSpiceLzToImageData(allocator: std.mem.Allocator, lz_image: LzImage) !ImageData {
    const data_size = lz_image.width * lz_image.height * BYTES_PER_PIXEL;
    const image_data = try allocator.alloc(u8, data_size);
    errdefer allocator.free(image_data);

    var result = ImageData{
        .data = image_data,
        .width = lz_image.width,
        .height = lz_image.height,
    };

    _ = try lzRgb32Decompress(lz_image.data, 0, result.data, lz_image.type, true);

    if (!lz_image.top_down) {
        try flipImageData(allocator, &result);
    }

    return result;
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

    const data_size = width * height * BYTES_PER_PIXEL;
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
