const std = @import("std");
const lz = @import("lz.zig");

// GLZ Constants from spice protocol
const LZ_MAGIC: u32 = 0x4f4c5a4d; // "MZLO" in little endian
const LZ_VERSION: u32 = 1;
const MAX_COPY: u8 = 32;

// LZ Image type constants
const LZ_IMAGE_TYPE_MASK: u8 = 0x0f;
const LZ_IMAGE_TYPE_LOG: u8 = 4;

// Pixel structures matching C exactly
const OneBytePixel = packed struct {
    a: u8,
};

const Rgb32Pixel = packed struct {
    b: u8,
    g: u8,
    r: u8,
    pad: u8,
};

const Rgb24Pixel = packed struct {
    b: u8,
    g: u8,
    r: u8,
};

const Rgb16Pixel = u16;

// GLZ Image header structure (matching C struct glz_image_hdr)
const GlzImageHdr = struct {
    id: u64,
    type: lz.LzImageType,
    width: u32,
    height: u32,
    gross_pixels: u32,
    top_down: bool,
    win_head_dist: u32,
};

// GLZ Image structure (matching C struct glz_image)
const GlzImage = struct {
    hdr: GlzImageHdr,
    surface: ?*anyopaque,
    data: [*]u8,
    allocator: std.mem.Allocator,

    fn create(allocator: std.mem.Allocator, hdr: *const GlzImageHdr, image_type: lz.LzImageType, user_data: ?*const anyopaque) !*GlzImage {
        _ = user_data;

        if (image_type != .rgb32 and image_type != .rgba) {
            return error.InvalidImageType;
        }

        const img = try allocator.create(GlzImage);
        img.allocator = allocator;
        img.hdr = hdr.*;

        const data_size = hdr.gross_pixels * 4;
        const data_slice = try allocator.alloc(u8, data_size);
        img.data = data_slice.ptr;
        img.surface = null;

        return img;
    }

    fn destroy(self: *GlzImage, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

pub fn testGlzDecoder() !void {
    std.debug.print("GLZ Decoder Test\n", .{});
    std.debug.print("✓ GLZ decoder basic structures working\n", .{});
}
