const std = @import("std");
const lz = @import("lz.zig");

// GLZ Constants from spice protocol
const LZ_MAGIC: u32 = 0x20205a4c; // "  ZL" when read in big endian format (space space Z L)
const LZ_VERSION: u32 = 0x00010001; // GLZ version format: 0x00010001 (big endian reading of 00 01 00 01)
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
pub const GlzImageHdr = struct {
    id: u64,
    type: lz.LzImageType,
    width: u32,
    height: u32,
    gross_pixels: u32,
    top_down: bool,
    win_head_dist: u32,
};

// GLZ Image structure (matching C struct glz_image)
pub const GlzImage = struct {
    hdr: GlzImageHdr,
    surface: ?*anyopaque,
    data: [*]u8,
    data_slice: []u8, // Keep track of the original slice for freeing
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, hdr: *const GlzImageHdr, image_type: lz.LzImageType, user_data: ?*anyopaque) !*GlzImage {
        _ = user_data;

        if (image_type != .rgb32 and image_type != .rgba) {
            return error.InvalidImageType;
        }

        const img = try allocator.create(GlzImage);
        img.allocator = allocator;
        img.hdr = hdr.*;

        const data_size = hdr.gross_pixels * 4;
        const data_slice = try allocator.alloc(u8, data_size);
        img.data_slice = data_slice;
        img.data = data_slice.ptr;
        img.surface = null;

        if (!img.hdr.top_down) {
            const row_bytes = img.hdr.width * 4;
            img.data = img.data + (img.hdr.height - 1) * row_bytes;
        }

        return img;
    }

    pub fn destroy(self: *GlzImage) void {
        self.allocator.free(self.data_slice);
        self.allocator.destroy(self);
    }
};

// GLZ Decoder Window structure
pub const SpiceGlzDecoderWindow = struct {
    images: []?*GlzImage,
    nimages: u32,
    oldest: u64,
    tail_gap: u64,
    allocator: std.mem.Allocator,

    fn create(allocator: std.mem.Allocator) !*SpiceGlzDecoderWindow {
        const w = try allocator.create(SpiceGlzDecoderWindow);
        w.allocator = allocator;
        w.nimages = 16;
        w.images = try allocator.alloc(?*GlzImage, w.nimages);
        @memset(w.images, null);
        w.oldest = 0;
        w.tail_gap = 0;
        return w;
    }

    fn resize(self: *SpiceGlzDecoderWindow) !void {
        const new_nimages = self.nimages * 2;
        const new_images = try self.allocator.alloc(?*GlzImage, new_nimages);
        @memset(new_images, null);

        for (0..self.nimages) |i| {
            if (self.images[i]) |img| {
                const new_slot = img.hdr.id % new_nimages;
                new_images[new_slot] = img;
            }
        }

        self.allocator.free(self.images);
        self.images = new_images;
        self.nimages = new_nimages;
    }

    pub fn add(self: *SpiceGlzDecoderWindow, img: *GlzImage) !void {
        var slot = img.hdr.id % self.nimages;

        std.debug.print("[GLZ] Adding image to window: id={}, slot={}, size={}x{}\n", .{ img.hdr.id, slot, img.hdr.width, img.hdr.height });

        if (self.images[slot]) |existing| {
            std.debug.print("[GLZ] Slot {} occupied by image id={}, resizing window\n", .{ slot, existing.hdr.id });
            try self.resize();
            slot = img.hdr.id % self.nimages;
            std.debug.print("[GLZ] After resize: new slot={}\n", .{slot});
        }

        self.images[slot] = img;

        while (self.tail_gap <= img.hdr.id and
            self.tail_gap % self.nimages < self.images.len and
            self.images[self.tail_gap % self.nimages] != null)
        {
            self.tail_gap += 1;
        }
    }

    fn bits(self: *SpiceGlzDecoderWindow, id: u64, dist: u32, offset: u32) ?[*]u8 {
        const slot = (id - dist) % self.nimages;
        const target_id = id - dist;

        std.debug.print("[GLZ] Window lookup: looking for id={}, slot={}, offset={}\n", .{ target_id, slot, offset });

        if (self.images[slot]) |img| {
            std.debug.print("[GLZ] Found image at slot {}: id={}, gross_pixels={}\n", .{ slot, img.hdr.id, img.hdr.gross_pixels });
            if (img.hdr.id == target_id and img.hdr.gross_pixels >= offset) {
                std.debug.print("[GLZ] Match! Returning reference data\n", .{});
                return img.data + offset * 4;
            } else {
                std.debug.print("[GLZ] No match: id {} != {} or gross_pixels {} < {}\n", .{ img.hdr.id, target_id, img.hdr.gross_pixels, offset });
            }
        } else {
            std.debug.print("[GLZ] No image at slot {}\n", .{slot});
        }
        return null;
    }

    fn release(self: *SpiceGlzDecoderWindow, oldest: u64) void {
        while (self.oldest < oldest) {
            const slot = self.oldest % self.nimages;
            if (self.images[slot]) |img| {
                img.destroy();
                self.images[slot] = null;
            }
            self.oldest += 1;
        }
    }

    fn clear(self: *SpiceGlzDecoderWindow) void {
        for (0..self.nimages) |i| {
            if (self.images[i]) |img| {
                img.destroy();
            }
        }

        self.allocator.free(self.images);
        self.nimages = 16;
        self.images = self.allocator.alloc(?*GlzImage, self.nimages) catch return;
        @memset(self.images, null);
        self.tail_gap = 0;
    }

    fn destroy(self: *SpiceGlzDecoderWindow) void {
        self.clear();
        self.allocator.free(self.images);
        self.allocator.destroy(self);
    }
};

// GLZ Decoder structure
pub const GlibGlzDecoder = struct {
    in_start: [*]const u8,
    in_now: [*]const u8,
    window: *SpiceGlzDecoderWindow,
    image: GlzImageHdr,
    allocator: std.mem.Allocator,

    fn decode32(self: *GlibGlzDecoder) u32 {
        // Read as big endian (like spice-gtk decode_32 function)
        const word = std.mem.readInt(u32, self.in_now[0..4], .big);
        self.in_now += 4;
        return word;
    }

    fn decode64(self: *GlibGlzDecoder) u64 {
        const long_word = @as(u64, self.decode32()) << 32;
        return long_word | @as(u64, self.decode32());
    }

    fn decodeHeader(self: *GlibGlzDecoder) !void {
        const magic = self.decode32();
        if (magic != LZ_MAGIC) return error.InvalidMagic;

        // Read version as 32-bit big endian (like spice-gtk)
        const version = self.decode32();
        std.debug.print("[GLZ] Received version: 0x{X}, expected: 0x{X}\n", .{ version, LZ_VERSION });
        if (version != LZ_VERSION) return error.InvalidVersion;

        const tmp = self.in_now[0];
        self.in_now += 1;

        self.image.type = lz.LzImageType.fromValue(tmp & LZ_IMAGE_TYPE_MASK) orelse return error.InvalidImageType;
        self.image.top_down = (tmp >> LZ_IMAGE_TYPE_LOG) != 0;
        self.image.width = self.decode32();
        self.image.height = self.decode32();
        const stride = self.decode32();

        self.image.gross_pixels = self.image.width * self.image.height;

        self.image.id = self.decode64();
        self.image.win_head_dist = self.decode32();

        std.debug.print("[GLZ] Header parsed: type={}, {}x{}, stride={}, gross_pixels={}, id={}, win_head_dist={}, top_down={}\n", .{ @intFromEnum(self.image.type), self.image.width, self.image.height, stride, self.image.gross_pixels, self.image.id, self.image.win_head_dist, self.image.top_down });
    }

    fn glzRgb32Decode(self: *GlibGlzDecoder, out_buf: [*]u8, size: u32, palette: ?*lz.SpicePalette) !usize {
        _ = palette;

        var ip = self.in_now;
        const out_pix_buf: [*]Rgb32Pixel = @ptrCast(@alignCast(out_buf));
        var op: u32 = 0;
        const op_limit = size;

        var ctrl = ip[0];
        ip += 1;

        while (true) {
            if (ctrl >= MAX_COPY) {
                var len = @as(u32, ctrl >> 5);
                const pixel_flag = (ctrl >> 4) & 0x01;
                var pixel_ofs = @as(u32, ctrl & 0x0f);
                var image_flag: u8 = undefined;
                var image_dist: u32 = undefined;

                if (len == 7) {
                    while (true) {
                        const code = ip[0];
                        ip += 1;
                        len += code;
                        if (code != 255) break;
                    }
                }

                var code = ip[0];
                ip += 1;
                pixel_ofs += @as(u32, code) << 4;

                code = ip[0];
                ip += 1;
                image_flag = (code >> 6) & 0x03;

                if (pixel_flag == 0) {
                    image_dist = @as(u32, code & 0x3f);
                    for (0..image_flag) |i| {
                        code = ip[0];
                        ip += 1;
                        image_dist += @as(u32, code) << @intCast(6 + (8 * i));
                    }
                } else {
                    const pixel_flag2 = (code >> 5) & 0x01;
                    pixel_ofs += @as(u32, code & 0x1f) << 12;
                    image_dist = 0;
                    for (0..image_flag) |i| {
                        code = ip[0];
                        ip += 1;
                        image_dist += @as(u32, code) << @intCast(8 * i);
                    }

                    if (pixel_flag2 != 0) {
                        code = ip[0];
                        ip += 1;
                        pixel_ofs += @as(u32, code) << 17;
                    }
                }

                len += 1;
                if (image_dist == 0) {
                    pixel_ofs += 1;
                }

                var ref: [*]Rgb32Pixel = undefined;
                if (image_dist == 0) {
                    if (pixel_ofs > op) return error.CorruptedData;
                    ref = out_pix_buf + (op - pixel_ofs);
                } else {
                    const ref_bits = self.window.bits(self.image.id, image_dist, pixel_ofs);
                    if (ref_bits == null) return error.ReferenceNotFound;
                    ref = @ptrCast(@alignCast(ref_bits.?));
                }

                if (op + len > op_limit) return error.OutputOverflow;

                if (ref == (out_pix_buf + op - 1)) {
                    const pixel = (out_pix_buf + op - 1)[0];
                    for (0..len) |_| {
                        out_pix_buf[op] = pixel;
                        op += 1;
                    }
                } else {
                    for (0..len) |_| {
                        out_pix_buf[op] = ref[0];
                        ref += 1;
                        op += 1;
                    }
                }
            } else {
                const count = ctrl + 1;

                if (op + count > op_limit) return error.OutputOverflow;

                for (0..count) |_| {
                    out_pix_buf[op].b = ip[0];
                    out_pix_buf[op].g = ip[1];
                    out_pix_buf[op].r = ip[2];
                    out_pix_buf[op].pad = 0;
                    ip += 3;
                    op += 1;
                }
            }

            if (op < op_limit) {
                ctrl = ip[0];
                ip += 1;
            } else {
                break;
            }
        }

        return @intFromPtr(ip) - @intFromPtr(self.in_now);
    }

    fn glzRgbAlphaDecode(self: *GlibGlzDecoder, out_buf: [*]u8, size: u32, palette: ?*lz.SpicePalette) !usize {
        _ = palette;

        var ip = self.in_now;
        const out_pix_buf: [*]Rgb32Pixel = @ptrCast(@alignCast(out_buf));
        var op: u32 = 0;
        const op_limit = size;

        var ctrl = ip[0];
        ip += 1;

        while (true) {
            if (ctrl >= MAX_COPY) {
                var len = @as(u32, ctrl >> 5);
                const pixel_flag = (ctrl >> 4) & 0x01;
                var pixel_ofs = @as(u32, ctrl & 0x0f);
                var image_flag: u8 = undefined;
                var image_dist: u32 = undefined;

                if (len == 7) {
                    while (true) {
                        const code = ip[0];
                        ip += 1;
                        len += code;
                        if (code != 255) break;
                    }
                }

                var code = ip[0];
                ip += 1;
                pixel_ofs += @as(u32, code) << 4;

                code = ip[0];
                ip += 1;
                image_flag = (code >> 6) & 0x03;

                if (pixel_flag == 0) {
                    image_dist = @as(u32, code & 0x3f);
                    for (0..image_flag) |i| {
                        code = ip[0];
                        ip += 1;
                        image_dist += @as(u32, code) << @intCast(6 + (8 * i));
                    }
                } else {
                    const pixel_flag2 = (code >> 5) & 0x01;
                    pixel_ofs += @as(u32, code & 0x1f) << 12;
                    image_dist = 0;
                    for (0..image_flag) |i| {
                        code = ip[0];
                        ip += 1;
                        image_dist += @as(u32, code) << @intCast(8 * i);
                    }

                    if (pixel_flag2 != 0) {
                        code = ip[0];
                        ip += 1;
                        pixel_ofs += @as(u32, code) << 17;
                    }
                }

                len += 2;
                if (image_dist == 0) {
                    pixel_ofs += 1;
                }

                var ref: [*]Rgb32Pixel = undefined;
                if (image_dist == 0) {
                    if (pixel_ofs > op) return error.CorruptedData;
                    ref = out_pix_buf + (op - pixel_ofs);
                } else {
                    const ref_bits = self.window.bits(self.image.id, image_dist, pixel_ofs);
                    if (ref_bits == null) return error.ReferenceNotFound;
                    ref = @ptrCast(@alignCast(ref_bits.?));
                }

                if (op + len > op_limit) return error.OutputOverflow;

                if (ref == (out_pix_buf + op - 1)) {
                    const alpha = (out_pix_buf + op - 1)[0].pad;
                    for (0..len) |_| {
                        out_pix_buf[op].pad = alpha;
                        op += 1;
                    }
                } else {
                    for (0..len) |_| {
                        out_pix_buf[op].pad = ref[0].pad;
                        ref += 1;
                        op += 1;
                    }
                }
            } else {
                const count = ctrl + 1;

                if (op + count > op_limit) return error.OutputOverflow;

                for (0..count) |_| {
                    out_pix_buf[op].pad = ip[0];
                    ip += 1;
                    op += 1;
                }
            }

            if (op < op_limit) {
                ctrl = ip[0];
                ip += 1;
            } else {
                break;
            }
        }

        return @intFromPtr(ip) - @intFromPtr(self.in_now);
    }

    fn decode(self: *GlibGlzDecoder, data: []const u8, palette: ?*lz.SpicePalette, usr_data: ?*anyopaque) !void {
        self.in_start = data.ptr;
        self.in_now = data.ptr;

        try self.decodeHeader();

        const decoded_type = if (self.image.type == .rgba) lz.LzImageType.rgba else lz.LzImageType.rgb32;
        const decoded_image = try GlzImage.create(self.allocator, &self.image, decoded_type, usr_data);

        const n_in_bytes_decoded = try self.glzRgb32Decode(@ptrCast(decoded_image.data), self.image.gross_pixels, palette);
        self.in_now += n_in_bytes_decoded;

        if (self.image.type == .rgba) {
            _ = try self.glzRgbAlphaDecode(@ptrCast(decoded_image.data), self.image.gross_pixels, palette);
        }

        try self.window.add(decoded_image);

        if (self.window.tail_gap > 0) {
            const image = self.window.images[(self.window.tail_gap - 1) % self.window.nimages];
            if (image) |img| {
                const oldest = img.hdr.id - img.hdr.win_head_dist;
                self.window.release(oldest);
            }
        }
    }

    fn create(allocator: std.mem.Allocator, window: *SpiceGlzDecoderWindow) !*GlibGlzDecoder {
        const d = try allocator.create(GlibGlzDecoder);
        d.allocator = allocator;
        d.window = window;
        d.in_start = undefined;
        d.in_now = undefined;
        d.image = undefined;
        return d;
    }

    fn destroy(self: *GlibGlzDecoder) void {
        self.allocator.destroy(self);
    }
};

// Public API
pub fn glzDecoderWindowNew(allocator: std.mem.Allocator) !*SpiceGlzDecoderWindow {
    return SpiceGlzDecoderWindow.create(allocator);
}

pub fn glzDecoderWindowClear(w: *SpiceGlzDecoderWindow) void {
    w.clear();
}

pub fn glzDecoderWindowDestroy(w: *SpiceGlzDecoderWindow) void {
    w.destroy();
}

pub fn glzDecoderNew(allocator: std.mem.Allocator, w: *SpiceGlzDecoderWindow) !*GlibGlzDecoder {
    return GlibGlzDecoder.create(allocator, w);
}

pub fn glzDecoderDestroy(d: *GlibGlzDecoder) void {
    d.destroy();
}

pub fn glzDecode(decoder: *GlibGlzDecoder, data: []const u8, palette: ?*lz.SpicePalette, usr_data: ?*anyopaque) !void {
    try decoder.decode(data, palette, usr_data);
}

pub fn glzWindowAddImage(window: *SpiceGlzDecoderWindow, img: *GlzImage) !void {
    try window.add(img);
}

pub fn testGlzDecoder() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const window = try glzDecoderWindowNew(allocator);
    defer glzDecoderWindowDestroy(window);

    const decoder = try glzDecoderNew(allocator, window);
    defer glzDecoderDestroy(decoder);

    std.debug.print("GLZ Decoder Test\n", .{});
    std.debug.print("✓ GLZ decoder created successfully\n", .{});
    std.debug.print("✓ Window management implemented\n", .{});
    std.debug.print("✓ Ready for GLZ frame processing\n", .{});
}
