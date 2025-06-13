//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;

pub export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
}

// ZLZ - Zig LZ/GLZ Decoder Library
// A Zig implementation of the LZ and GLZ decoders used in SPICE remote desktop protocol

pub const lz = @import("lz.zig");
pub const glz = @import("glz.zig");

// Re-export commonly used types and functions
pub const LzImageType = lz.LzImageType;
pub const LzError = lz.LzError;
pub const ImageData = lz.ImageData;
pub const LzImage = lz.LzImage;
pub const SpicePalette = lz.SpicePalette;

// GLZ types
pub const SpiceGlzDecoderWindow = glz.SpiceGlzDecoderWindow;
pub const GlibGlzDecoder = glz.GlibGlzDecoder;
pub const GlzImage = glz.GlzImage;
pub const GlzImageHdr = glz.GlzImageHdr;

// Main decompression functions
pub const lz_rgb32_decompress = lz.lz_rgb32_decompress;
pub const convertSpiceLzToImageData = lz.convertSpiceLzToImageData;

// GLZ decoder functions and types
pub const glzDecoderWindowNew = glz.glzDecoderWindowNew;
pub const glzDecoderWindowClear = glz.glzDecoderWindowClear;
pub const glzDecoderWindowDestroy = glz.glzDecoderWindowDestroy;
pub const glzDecoderNew = glz.glzDecoderNew;
pub const glzDecoderDestroy = glz.glzDecoderDestroy;
pub const glzDecode = glz.glzDecode;
pub const glzWindowAddImage = glz.glzWindowAddImage;

// Test functions
pub const testLzDecompression = lz.testLzDecompression;
pub const testGlzDecoder = glz.testGlzDecoder;
