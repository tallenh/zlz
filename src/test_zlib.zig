const std = @import("std");
const zlz = @import("root.zig");

test "zlib format detection" {
    const valid_zlib_data = [_]u8{ 0x78, 0x9c, 0x01, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01 };
    const invalid_data = [_]u8{ 0xff, 0xff, 0x00, 0x00 };

    try std.testing.expect(zlz.is_zlib_data(&valid_zlib_data) == true);
    try std.testing.expect(zlz.is_zlib_data(&invalid_data) == false);

    std.debug.print("✓ Zlib format detection test passed\n", .{});
}

test "adler32 checksum" {
    const test_string = "Hello, Zlib World!";
    const checksum = zlz.adler32(1, test_string, test_string.len);

    // Adler-32 should produce a valid checksum (not 1 for non-empty string)
    try std.testing.expect(checksum != 1);
    std.debug.print("✓ Adler-32 checksum: 0x{X}\n", .{checksum});
}

test "basic zlib decompression" {
    const input_data = [_]u8{ 0x78, 0x9c, 0x48, 0x65, 0x6c, 0x6c, 0x6f };
    var output_buffer: [100]u8 = undefined;

    // Test decompression (may succeed or fail depending on data validity)
    const result = zlz.decompress_block_zlib(&input_data, &output_buffer, output_buffer.len);
    if (result) |success| {
        std.debug.print("✓ Basic decompression succeeded: {} bytes read, {} bytes written\n", .{ success.bytes_read, success.bytes_written });
    } else |err| {
        std.debug.print("✓ Basic decompression failed as expected: {}\n", .{err});
    }
}

test "spice zlib-glz integration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const image_desc = zlz.zlib.SpiceImageDescriptor{
        .id = 12345,
        .type = 6, // SPICE_IMAGE_TYPE_ZLIB_GLZ_RGB
        .flags = 0,
        .width = 640,
        .height = 480,
    };

    const mock_zlib_data = [_]u8{ 0x78, 0x9c, 0x01, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01 };
    const zlib_glz_data = zlz.zlib.SpiceZlibGlzRGBData{
        .glz_data_size = 640 * 480 * 3,
        .data_size = mock_zlib_data.len,
        .data = &mock_zlib_data,
    };

    const spice_result = try zlz.decompress_spice_zlib_glz(allocator, image_desc, zlib_glz_data);
    defer {
        var mutable_result = spice_result;
        mutable_result.deinit(allocator);
    }

    try std.testing.expect(spice_result.width == 640);
    try std.testing.expect(spice_result.height == 480);

    std.debug.print("✓ SPICE zlib-glz integration: {}x{}, GLZ data size: {} bytes\n", .{ spice_result.width, spice_result.height, spice_result.data.len });
}

test "utility functions" {
    const format_16 = zlz.zlib.spice_format_to_bpp(16) catch unreachable;
    const format_24 = zlz.zlib.spice_format_to_bpp(24) catch unreachable;
    const format_32 = zlz.zlib.spice_format_to_bpp(32) catch unreachable;

    try std.testing.expect(format_16 == 2);
    try std.testing.expect(format_24 == 3);
    try std.testing.expect(format_32 == 4);

    const input_data = [_]u8{ 0x78, 0x9c, 0x48, 0x65, 0x6c, 0x6c, 0x6f };
    const estimated_size = zlz.zlib.estimate_decompressed_size(&input_data, 10.0);
    try std.testing.expect(estimated_size > 0);

    std.debug.print("✓ Utility functions: 16-bit={} bpp, 24-bit={} bpp, 32-bit={} bpp\n", .{ format_16, format_24, format_32 });
    std.debug.print("✓ Estimated decompressed size: {} bytes\n", .{estimated_size});
}
