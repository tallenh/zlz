const std = @import("std");
const lz = @import("lz.zig");
const glz = @import("glz.zig");

pub fn main() !void {
    std.debug.print("ZLZ - Zig LZ/GLZ Image Decoder\n", .{});
    std.debug.print("================================\n\n", .{});

    // Test LZ decoder
    std.debug.print("Testing LZ Decoder:\n", .{});
    try lz.testLzDecompression();

    std.debug.print("\n", .{});

    // Test GLZ decoder
    std.debug.print("Testing GLZ Decoder:\n", .{});
    try glz.testGlzDecoder();

    std.debug.print("\n✅ All decoders initialized successfully!\n", .{});
    std.debug.print("Ready to process SPICE image frames.\n", .{});
}
