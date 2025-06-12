# ZLZ - Zig LZ/GLZ Decoder

A Zig implementation of the LZ and GLZ decoders used in SPICE remote desktop protocol for image compression.

## Installation

### As a Dependency

To use ZLZ in your Zig project, add it as a dependency:

```bash
zig fetch --save https://github.com/tallenh/zlz/archive/main.tar.gz
```

Then in your `build.zig`:

```zig
const zlz = b.dependency("zlz", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zlz", zlz.module("zlz"));
```

### Building from Source

```bash
git clone https://github.com/tallenh/zlz.git
cd zlz
zig build
```

## Usage

### Standalone LZ Decoder

The LZ decoder can be used independently to decompress LZ-compressed data:

```zig
const zlz = @import("zlz");

// Decompress LZ data
const decompressed = try zlz.lz_rgb32_decompress(
    allocator,
    width,
    height,
    compressed_data,
    .rgb32,
    true, // top_down
    null, // palette
);
defer decompressed.deinit(allocator);
```

### Processing SPICE Frames

For processing SPICE remote desktop frames, you'll need to handle both LZ and GLZ frames:

```zig
const zlz = @import("zlz");

// Process LZ frame (I-frame)
const lz_image = try zlz.lz_rgb32_decompress(
    allocator,
    width,
    height,
    lz_frame_data,
    .rgb32,
    top_down,
    null,
);
defer lz_image.deinit(allocator);

// GLZ frames (P-frames) - decoder in development
// const glz_image = try zlz.glz.decode(glz_frame_data);
```

### Testing with Real Frames

The project includes a test executable that processes real binary frames:

```bash
zig build test-frames
```

This will:

1. Read LZ frames (I-frames) from `test/lz_frames.bin`
2. Read GLZ frames (P-frames) from `test/glz_frames.bin`
3. Process them sequentially to reconstruct the image

## Frame Types

- **LZ Frames (I-frames)**: Complete frames compressed using LZ compression
- **GLZ Frames (P-frames)**: Partial updates to the previous LZ frame, compressed using GLZ compression

## Dependencies

- Zig 0.14.0 or later
- SDL3 (optional, for visualization in tests)

## License

MIT License - see LICENSE file for details.
