const std = @import("std");
const lz = @import("lz.zig");
const log = @import("logger").new(.{ .tag = "glz_img" });

const build_options = @import("build_options");
const ENABLE_SIMD = build_options.simd;

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
    owns_buffer: bool, // Whether this image owns its data buffer

    pub fn create(allocator: std.mem.Allocator, hdr: *const GlzImageHdr, image_type: lz.LzImageType, user_data: ?*anyopaque) !*GlzImage {
        _ = user_data;

        if (image_type != .rgb32 and image_type != .rgba) {
            return error.InvalidImageType;
        }

        const img = try allocator.create(GlzImage);
        log.dbg("++ create GlzImage id={} addr=0x{x}", .{ hdr.id, @intFromPtr(img) });
        img.allocator = allocator;
        img.hdr = hdr.*;
        img.owns_buffer = true; // We allocated the buffer

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

    /// Create GlzImage that references existing buffer (for zero-copy operations)
    pub fn createFromExistingBuffer(allocator: std.mem.Allocator, hdr: *const GlzImageHdr, image_type: lz.LzImageType, existing_buffer: []u8, user_data: ?*anyopaque) !*GlzImage {
        _ = user_data;

        if (image_type != .rgb32 and image_type != .rgba) {
            return error.InvalidImageType;
        }

        const expected_size = hdr.gross_pixels * 4;
        if (existing_buffer.len < expected_size) {
            return error.BufferTooSmall;
        }

        const img = try allocator.create(GlzImage);
        log.dbg("++ create GlzImage (zero-copy) id={} addr=0x{x}", .{ hdr.id, @intFromPtr(img) });
        img.allocator = allocator;
        img.hdr = hdr.*;
        img.owns_buffer = false; // We don't own the buffer (zero-copy)

        // Reference the existing buffer instead of allocating new one
        img.data_slice = existing_buffer[0..expected_size];
        img.data = img.data_slice.ptr;
        img.surface = null;

        if (!img.hdr.top_down) {
            const row_bytes = img.hdr.width * 4;
            img.data = img.data + (img.hdr.height - 1) * row_bytes;
        }

        return img;
    }

    pub fn destroy(self: *GlzImage) void {
        log.dbg("-- destroy GlzImage id={} addr=0x{x} owns_buffer={}", .{ self.hdr.id, @intFromPtr(self), self.owns_buffer });
        // Only free data_slice if we own it (not for zero-copy buffers)
        if (self.owns_buffer) {
            self.allocator.free(self.data_slice);
        }
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

        // If the slot is already occupied, first try to grow the window so that
        // both images can coexist.  After a resize the slot might still be
        // occupied (same hash / same id).  In that case we explicitly destroy
        // the old image before overwriting to avoid leaking it.
        if (self.images[slot]) |_| {
            try self.resize();
            slot = img.hdr.id % self.nimages;

            if (self.images[slot]) |existing_after_resize| {
                // Same image-id (or hash collision) still occupies the final
                // slot – we drop the previous entry to prevent a memory leak.
                existing_after_resize.destroy();
                self.images[slot] = null;
            }
        }

        self.images[slot] = img;

        while (self.tail_gap <= img.hdr.id and
            self.tail_gap % self.nimages < self.images.len and
            self.images[self.tail_gap % self.nimages] != null)
        {
            self.tail_gap += 1;
        }
    }

    inline fn bits(self: *SpiceGlzDecoderWindow, id: u64, dist: u32, offset: u32) ?[*]u8 {
        const slot = (id - dist) % self.nimages;
        const target_id = id - dist;

        if (self.images[slot]) |img| {
            if (img.hdr.id == target_id and img.hdr.gross_pixels >= offset) {
                return img.data + offset * 4;
            }
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

    inline fn decode32(self: *GlibGlzDecoder) u32 {
        // Read as big endian (like spice-gtk decode_32 function)
        const word = std.mem.readInt(u32, self.in_now[0..4], .big);
        self.in_now += 4;
        return word;
    }

    inline fn decode64(self: *GlibGlzDecoder) u64 {
        const long_word = @as(u64, self.decode32()) << 32;
        return long_word | @as(u64, self.decode32());
    }

    inline fn decodeHeader(self: *GlibGlzDecoder) !void {
        const magic = self.decode32();
        if (magic != LZ_MAGIC) return error.InvalidMagic;

        // Read version as 32-bit big endian (like spice-gtk)
        const version = self.decode32();
        if (version != LZ_VERSION) return error.InvalidVersion;

        const tmp = self.in_now[0];
        self.in_now += 1;

        self.image.type = lz.LzImageType.fromValue(tmp & LZ_IMAGE_TYPE_MASK) orelse return error.InvalidImageType;
        self.image.top_down = (tmp >> LZ_IMAGE_TYPE_LOG) != 0;
        self.image.width = self.decode32();
        self.image.height = self.decode32();
        _ = self.decode32(); // stride (unused)

        self.image.gross_pixels = self.image.width * self.image.height;

        self.image.id = self.decode64();
        self.image.win_head_dist = self.decode32();
    }

    inline fn glzRgb32Decode(self: *GlibGlzDecoder, out_buf: [*]u8, size: u32, palette: ?*lz.SpicePalette) !usize {
        _ = palette;

        var ip = self.in_now;
        const out_pix_buf: [*]Rgb32Pixel = @ptrCast(@alignCast(out_buf));
        var op: u32 = 0;
        const op_limit = size;

        // Cache for dictionary lookups - reduces redundant window.bits() calls
        var cached_image_dist: u32 = 0xFFFFFFFF; // Invalid value to force initial lookup
        var cached_ref_bits: ?[*]u8 = null;

        var ctrl = ip[0];
        ip += 1;

        while (true) {
            // Optimized control flow: literals first (more common case, better branch prediction)
            if (ctrl < MAX_COPY) {
                // Handle literal data (hot path)
                const count = ctrl + 1;

                // Hoist bounds checking outside loop
                if (op + count > op_limit) {
                    return error.OutputOverflow;
                }

                // Enhanced batch processing for better throughput
                if (ENABLE_SIMD and count >= 16) {
                    const out_bytes: [*]u8 = @ptrCast(out_pix_buf);
                    const out_start_byte = op * 4;
                    var remaining: u32 = count;
                    var ip_offset: usize = 0;
                    var out_offset: usize = out_start_byte;

                    // Process 16 pixels per iteration for maximum throughput
                    while (remaining >= 16) : (remaining -= 16) {
                        comptime var i: usize = 0;
                        inline while (i < 16) : (i += 1) {
                            out_bytes[out_offset + i * 4 + 0] = ip[ip_offset + i * 3 + 0]; // B
                            out_bytes[out_offset + i * 4 + 1] = ip[ip_offset + i * 3 + 1]; // G
                            out_bytes[out_offset + i * 4 + 2] = ip[ip_offset + i * 3 + 2]; // R
                            out_bytes[out_offset + i * 4 + 3] = 0; // A (always 0 for RGB32)
                        }
                        ip_offset += 48; // 16 pixels * 3 bytes
                        out_offset += 64; // 16 pixels * 4 bytes
                    }

                    // Process 8 pixels per iteration for medium batches
                    while (remaining >= 8) : (remaining -= 8) {
                        comptime var i: usize = 0;
                        inline while (i < 8) : (i += 1) {
                            out_bytes[out_offset + i * 4 + 0] = ip[ip_offset + i * 3 + 0]; // B
                            out_bytes[out_offset + i * 4 + 1] = ip[ip_offset + i * 3 + 1]; // G
                            out_bytes[out_offset + i * 4 + 2] = ip[ip_offset + i * 3 + 2]; // R
                            out_bytes[out_offset + i * 4 + 3] = 0; // A (always 0 for RGB32)
                        }
                        ip_offset += 24; // 8 pixels * 3 bytes
                        out_offset += 32; // 8 pixels * 4 bytes
                    }

                    // Process 4 pixels per iteration for remaining
                    while (remaining >= 4) : (remaining -= 4) {
                        comptime var i: usize = 0;
                        inline while (i < 4) : (i += 1) {
                            out_bytes[out_offset + i * 4 + 0] = ip[ip_offset + i * 3 + 0]; // B
                            out_bytes[out_offset + i * 4 + 1] = ip[ip_offset + i * 3 + 1]; // G
                            out_bytes[out_offset + i * 4 + 2] = ip[ip_offset + i * 3 + 2]; // R
                            out_bytes[out_offset + i * 4 + 3] = 0; // A
                        }
                        ip_offset += 12; // 4 pixels * 3 bytes
                        out_offset += 16; // 4 pixels * 4 bytes
                    }

                    // Process remaining pixels
                    for (0..remaining) |_| {
                        out_bytes[out_offset + 0] = ip[ip_offset + 0]; // B
                        out_bytes[out_offset + 1] = ip[ip_offset + 1]; // G
                        out_bytes[out_offset + 2] = ip[ip_offset + 2]; // R
                        out_bytes[out_offset + 3] = 0; // A
                        ip_offset += 3;
                        out_offset += 4;
                    }

                    ip += count * 3;
                    op += count;
                } else {
                    // Fallback scalar path
                    for (0..count) |_| {
                        out_pix_buf[op].b = ip[0];
                        out_pix_buf[op].g = ip[1];
                        out_pix_buf[op].r = ip[2];
                        out_pix_buf[op].pad = 0;
                        ip += 3;
                        op += 1;
                    }
                }
            } else {
                // Handle references (cold path)
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

                // For RGB32, no length bias (unlike PLT/RGB_ALPHA which have +2, RGB16 which has +1)
                // len += 0; // No bias for RGB32
                if (image_dist == 0) {
                    pixel_ofs += 1;
                }

                var ref: [*]Rgb32Pixel = undefined;
                if (image_dist == 0) {
                    if (pixel_ofs > op) return error.CorruptedData;
                    ref = out_pix_buf + (op - pixel_ofs);
                } else {
                    // Cache dictionary lookups to reduce window.bits() calls
                    var ref_bits: ?[*]u8 = null;
                    if (image_dist == cached_image_dist) {
                        ref_bits = cached_ref_bits;
                    } else {
                        ref_bits = self.window.bits(self.image.id, image_dist, 0); // Base reference
                        cached_image_dist = image_dist;
                        cached_ref_bits = ref_bits;

                        // Prefetch window data for better cache locality
                        if (ref_bits) |bits| {
                            @prefetch(bits, .{});
                        }
                    }

                    if (ref_bits == null) return error.ReferenceNotFound;
                    ref = @ptrCast(@alignCast(ref_bits.? + pixel_ofs * 4));
                }

                // Hoist bounds checking outside loops
                if (op + len > op_limit) {
                    return error.OutputOverflow;
                }

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

    inline fn glzRgbAlphaDecode(self: *GlibGlzDecoder, out_buf: [*]u8, size: u32, palette: ?*lz.SpicePalette) !usize {
        _ = palette;

        var ip = self.in_now;
        const out_pix_buf: [*]Rgb32Pixel = @ptrCast(@alignCast(out_buf));
        var op: u32 = 0;
        const op_limit = size;

        // Cache for dictionary lookups - reduces redundant window.bits() calls
        var cached_image_dist: u32 = 0xFFFFFFFF; // Invalid value to force initial lookup
        var cached_ref_bits: ?[*]u8 = null;

        var ctrl = ip[0];
        ip += 1;

        while (true) {
            // Optimized control flow: literals first (more common case, better branch prediction)
            if (ctrl < MAX_COPY) {
                // Handle literal data (hot path for alpha channel)
                const count = ctrl + 1;

                // Hoist bounds checking outside loop
                if (op + count > op_limit) return error.OutputOverflow;

                for (0..count) |_| {
                    out_pix_buf[op].pad = ip[0];
                    ip += 1;
                    op += 1;
                }
            } else {
                // Handle references (cold path)
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
                    // Cache dictionary lookups to reduce window.bits() calls
                    var ref_bits: ?[*]u8 = null;
                    if (image_dist == cached_image_dist) {
                        ref_bits = cached_ref_bits;
                    } else {
                        ref_bits = self.window.bits(self.image.id, image_dist, 0); // Base reference
                        cached_image_dist = image_dist;
                        cached_ref_bits = ref_bits;

                        // Prefetch window data for better cache locality
                        if (ref_bits) |bits| {
                            @prefetch(bits, .{});
                        }
                    }

                    if (ref_bits == null) return error.ReferenceNotFound;
                    ref = @ptrCast(@alignCast(ref_bits.? + pixel_ofs * 4));
                }

                // Hoist bounds checking outside loops
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

/// Zero-copy GLZ decode to pre-allocated buffer (optimized for Metal shared buffers)
pub fn glzDecodeToBuffer(decoder: *GlibGlzDecoder, data: []const u8, output_buffer: []u8, palette: ?*lz.SpicePalette, usr_data: ?*anyopaque) !bool {
    decoder.in_start = data.ptr;
    decoder.in_now = data.ptr;

    decoder.decodeHeader() catch {
        std.debug.print("glzDecodeToBuffer: header decode failed\n", .{});
        return false;
    };

    const expected_size = decoder.image.gross_pixels * 4; // Assuming RGBA/RGB32 format
    if (output_buffer.len < expected_size) {
        std.debug.print("glzDecodeToBuffer: buffer too small: {} < {}\n", .{ output_buffer.len, expected_size });
        return false;
    }

    // Decode directly to the provided buffer instead of creating GlzImage
    const n_in_bytes_decoded = decoder.glzRgb32Decode(@ptrCast(output_buffer.ptr), decoder.image.gross_pixels, palette) catch {
        std.debug.print("glzDecodeToBuffer: RGB decode failed\n", .{});
        return false;
    };
    decoder.in_now += n_in_bytes_decoded;

    if (decoder.image.type == .rgba) {
        _ = decoder.glzRgbAlphaDecode(@ptrCast(output_buffer.ptr), decoder.image.gross_pixels, palette) catch {
            std.debug.print("glzDecodeToBuffer: alpha decode failed\n", .{});
            return false;
        };
    }

    // Smart copy-on-reference strategy:
    // - If this frame might be referenced by future frames (win_head_dist > 0), create a copy for the window
    // - Otherwise, use zero-copy reference to shared buffer
    const decoded_type = if (decoder.image.type == .rgba) lz.LzImageType.rgba else lz.LzImageType.rgb32;

    const window_image = window_image_blk: {
        if (decoder.image.win_head_dist > 0) {
            // This frame will be referenced - create a copy for stable window storage
            const copied_image = GlzImage.create(decoder.allocator, &decoder.image, decoded_type, usr_data) catch {
                std.debug.print("glzDecodeToBuffer: failed to create copied window entry\n", .{});
                return false;
            };
            // Copy the decoded data to the window's stable storage
            @memcpy(copied_image.data_slice, output_buffer[0..expected_size]);
            // std.debug.print("GLZ: Created copy for window (will be referenced, win_head_dist={})\n", .{decoder.image.win_head_dist});
            break :window_image_blk copied_image;
        } else {
            // This frame won't be referenced - use zero-copy reference to shared buffer
            const zero_copy_image = GlzImage.createFromExistingBuffer(decoder.allocator, &decoder.image, decoded_type, output_buffer[0..expected_size], usr_data) catch {
                std.debug.print("glzDecodeToBuffer: failed to create zero-copy window entry\n", .{});
                return false;
            };
            // std.debug.print("GLZ: Using zero-copy reference (not referenced, win_head_dist={})\n", .{decoder.image.win_head_dist});
            break :window_image_blk zero_copy_image;
        }
    };

    decoder.window.add(window_image) catch {
        window_image.destroy();
        std.debug.print("glzDecodeToBuffer: failed to add to window\n", .{});
        return false;
    };

    if (decoder.window.tail_gap > 0) {
        const image = decoder.window.images[(decoder.window.tail_gap - 1) % decoder.window.nimages];
        if (image) |img| {
            const oldest = img.hdr.id - img.hdr.win_head_dist;
            decoder.window.release(oldest);
        }
    }

    return true;
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

    // GLZ decoder test completed successfully
}
