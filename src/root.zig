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

// ZLZ - Zig LZ/GLZ/LZ4 Decoder Library
// A Zig implementation of the LZ, GLZ, and LZ4 decoders used in SPICE remote desktop protocol
//
// LZ4 Support:
// - Basic LZ4 block decompression
// - SPICE-specific LZ4 image decompression
// - Stream-based decompression with dictionary support
// - All pixel formats: 16-bit, 24-bit, 32-bit, RGBA

pub const lz = @import("lz.zig");
pub const glz = @import("glz.zig");
pub const lz4 = @import("lz4.zig");
pub const zlib = @import("zlib.zig");

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
pub const lz_rgb32_decompress_to_buffer = lz.lz_rgb32_decompress_to_buffer; // Zero-copy version
pub const convertSpiceLzToImageData = lz.convertSpiceLzToImageData;

// GLZ decoder functions and types
pub const glzDecoderWindowNew = glz.glzDecoderWindowNew;
pub const glzDecoderWindowClear = glz.glzDecoderWindowClear;
pub const glzDecoderWindowDestroy = glz.glzDecoderWindowDestroy;
pub const glzDecoderNew = glz.glzDecoderNew;
pub const glzDecoderDestroy = glz.glzDecoderDestroy;
pub const glzDecode = glz.glzDecode;
pub const glzDecodeToBuffer = glz.glzDecodeToBuffer; // Zero-copy version
pub const glzWindowAddImage = glz.glzWindowAddImage;

// LZ4 types and functions
pub const LZ4Error = lz4.LZ4Error;
pub const LZ4Result = lz4.LZ4Result;
pub const SpiceLZ4Data = lz4.SpiceLZ4Data;
pub const SpiceLZ4Image = lz4.SpiceLZ4Image;
pub const SpiceImageDescriptor = lz4.SpiceImageDescriptor;
pub const LZ4StreamDecode = lz4.LZ4StreamDecode;

// LZ4 decompression functions
pub const decompress_spice_lz4 = lz4.decompress_spice_lz4;
pub const decompress_block_lz4 = lz4.decompress_block;
pub const LZ4_decompress_safe = lz4.LZ4_decompress_safe;
pub const createStreamDecode = lz4.createStreamDecode;

// Zlib types and functions
pub const ZlibError = zlib.ZlibError;
pub const ZlibResult = zlib.ZlibResult;
pub const SpiceZlibGlzRGBData = zlib.SpiceZlibGlzRGBData;
pub const SpiceZlibGlzImage = zlib.SpiceZlibGlzImage;
pub const z_stream = zlib.z_stream;

// Zlib decompression functions
pub const decompress_spice_zlib_glz = zlib.decompress_spice_zlib_glz;
pub const decompress_block_zlib = zlib.decompress_block;
pub const is_zlib_data = zlib.is_zlib_data;
pub const adler32 = zlib.adler32;

// Test functions
pub const testLzDecompression = lz.testLzDecompression;
pub const testGlzDecoder = glz.testGlzDecoder;
