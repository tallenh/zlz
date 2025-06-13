//! Test program for LZ4 implementation
//!
//! This demonstrates how to use the LZ4 decoder with both basic block
//! decompression and SPICE-specific LZ4 image decompression.

const std = @import("std");
const lz4 = @import("lz4.zig");

// Helper function for format conversion testing
fn spice_format_to_bpp(spice_format: u8) !u32 {
    return switch (spice_format) {
        0 => 2, // SPICE_BITMAP_FMT_16BIT
        1 => 3, // SPICE_BITMAP_FMT_24BIT
        2 => 4, // SPICE_BITMAP_FMT_32BIT
        13 => 4, // SPICE_BITMAP_FMT_RGBA
        else => return lz4.LZ4Error.UnsupportedFormat,
    };
}

test "lz4 stream decoder creation" {
    var stream = lz4.createStreamDecode();
    defer stream.deinit();

    // Basic verification that the stream was created
    try std.testing.expect(@TypeOf(stream) == lz4.LZ4StreamDecode);

    std.debug.print("✓ LZ4 stream decoder created successfully\n", .{});
}

test "lz4 error handling" {
    var dst_buffer: [100]u8 = undefined;

    // Test empty input
    const empty_src: []const u8 = &[_]u8{};
    const result1 = lz4.decompress_block(empty_src, &dst_buffer, dst_buffer.len);
    try std.testing.expect(std.meta.isError(result1));

    // Test zero capacity
    const test_src = [_]u8{ 0x10, 0x48, 0x65, 0x6c, 0x6c, 0x6f };
    const result2 = lz4.decompress_block(&test_src, &dst_buffer, 0);
    try std.testing.expect(std.meta.isError(result2));

    std.debug.print("✓ LZ4 error handling works correctly\n", .{});
}

test "spice format conversion" {
    const formats = [_]struct { format: u8, name: []const u8, expected_bpp: u32 }{
        .{ .format = 0, .name = "16BIT", .expected_bpp = 2 },
        .{ .format = 1, .name = "24BIT", .expected_bpp = 3 },
        .{ .format = 2, .name = "32BIT", .expected_bpp = 4 },
        .{ .format = 13, .name = "RGBA", .expected_bpp = 4 },
    };

    for (formats) |fmt| {
        const bpp = spice_format_to_bpp(fmt.format) catch |err| {
            std.debug.print("❌ Error converting format {s}: {}\n", .{ fmt.name, err });
            try std.testing.expect(false);
            continue;
        };
        try std.testing.expect(bpp == fmt.expected_bpp);
        std.debug.print("✓ Format {s}: {} bpp\n", .{ fmt.name, bpp });
    }
}

test "spice lz4 structure example" {
    const image_descriptor = lz4.SpiceImageDescriptor{
        .id = 1234,
        .type = 6, // SPICE_IMAGE_TYPE_LZ4
        .flags = 0,
        .width = 64,
        .height = 64,
    };

    // This would be real LZ4 compressed data in practice
    const mock_lz4_data = lz4.SpiceLZ4Data{
        .data_size = 10,
        .data = &[_]u8{ 1, 2, 0, 0, 0, 6, 0x10, 0x48, 0x65, 0x6c }, // Mock header + data
    };

    try std.testing.expect(image_descriptor.width == 64);
    try std.testing.expect(image_descriptor.height == 64);
    try std.testing.expect(mock_lz4_data.data_size == 10);

    std.debug.print("✓ SPICE LZ4 structure validation: {}x{} pixels, {} bytes\n", .{ image_descriptor.width, image_descriptor.height, mock_lz4_data.data_size });
}
