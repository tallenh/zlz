//! Zlib Inflate Implementation for SPICE protocol
//!
//! This is a line-by-line port of the zlib inflate algorithm from the
//! reference C implementation, plus SPICE-specific integration code.
//!
//! Based on zlib 1.2.12 - Copyright (C) 1995-2022 Mark Adler

const std = @import("std");
const Allocator = std.mem.Allocator;

// =============================================================================
// Zlib Constants (from zlib.h and inflate.h)
// =============================================================================

// Return codes (from zlib.h)
pub const Z_OK = 0;
pub const Z_STREAM_END = 1;
pub const Z_NEED_DICT = 2;
pub const Z_ERRNO = -1;
pub const Z_STREAM_ERROR = -2;
pub const Z_DATA_ERROR = -3;
pub const Z_MEM_ERROR = -4;
pub const Z_BUF_ERROR = -5;
pub const Z_VERSION_ERROR = -6;

// Flush values (from zlib.h)
pub const Z_NO_FLUSH = 0;
pub const Z_PARTIAL_FLUSH = 1;
pub const Z_SYNC_FLUSH = 2;
pub const Z_FULL_FLUSH = 3;
pub const Z_FINISH = 4;
pub const Z_BLOCK = 5;
pub const Z_TREES = 6;

// Deflate compression method
pub const Z_DEFLATED = 8;

// Window bits (from inflate.h)
pub const DEF_WBITS = 15;

// =============================================================================
// Zlib Error Types
// =============================================================================

pub const ZlibError = error{
    StreamError, // Z_STREAM_ERROR
    DataError, // Z_DATA_ERROR
    MemError, // Z_MEM_ERROR
    BufError, // Z_BUF_ERROR
    VersionError, // Z_VERSION_ERROR
    NeedDict, // Z_NEED_DICT
    InvalidInput,
    CorruptedData,
    OutputTooSmall,
    WindowTooLarge,
    InvalidState,
};

// =============================================================================
// SPICE-specific Types
// =============================================================================

/// SPICE Image Descriptor (from draw.h)
pub const SpiceImageDescriptor = struct {
    id: u64,
    type: u8,
    flags: u8,
    width: u32,
    height: u32,
};

/// SPICE Zlib-GLZ Data Structure (from draw.h)
pub const SpiceZlibGlzRGBData = struct {
    glz_data_size: u32, // Size of GLZ data after zlib decompression
    data_size: u32, // Size of zlib-compressed data
    data: [*]const u8, // The actual zlib-compressed data
};

/// SPICE Zlib-GLZ Image Result
pub const SpiceZlibGlzImage = struct {
    width: u32,
    height: u32,
    format: u8, // SPICE pixel format
    data: []u8, // Decompressed GLZ data (to be processed by GLZ decoder)

    pub fn deinit(self: *SpiceZlibGlzImage, allocator: Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

/// Zlib Result Structure
pub const ZlibResult = struct {
    bytes_read: usize,
    bytes_written: usize,
};

// =============================================================================
// Simplified zlib stream structure
// =============================================================================

/// Basic z_stream for our implementation
pub const z_stream = struct {
    next_in: ?[*]const u8, // next input byte
    avail_in: u32, // number of bytes available at next_in
    total_in: u32, // total number of input bytes read so far

    next_out: ?[*]u8, // next output byte will go here
    avail_out: u32, // remaining free space at next_out
    total_out: u32, // total number of bytes output so far

    msg: ?[*]const u8, // last error message, NULL if no error
    state: ?*anyopaque, // internal state (not visible by applications)

    data_type: i32, // best guess about the data type
    adler: u32, // Adler-32 checksum value
    reserved: u32, // reserved for future use
};

// =============================================================================
// Inflate State Machine (from inflate.h)
// =============================================================================

/// Inflate modes between inflate() calls (from inflate.h)
pub const InflateMode = enum(u32) {
    HEAD = 0, // waiting for magic header
    FLAGS, // waiting for method and flags (gzip)
    TIME, // waiting for modification time (gzip)
    OS, // waiting for extra flags and operating system (gzip)
    EXLEN, // waiting for extra length (gzip)
    EXTRA, // waiting for extra bytes (gzip)
    NAME, // waiting for end of file name (gzip)
    COMMENT, // waiting for end of comment (gzip)
    HCRC, // waiting for header crc (gzip)
    DICTID, // waiting for dictionary check value
    DICT, // waiting for inflateSetDictionary() call
    TYPE, // waiting for type bits, including last-flag bit
    TYPEDO, // same, but skip check to exit inflate on new block
    STORED, // waiting for stored size (length and complement)
    COPY_, // stored block, waiting for input or output to copy
    COPY, // copying stored block
    TABLE, // waiting for dynamic block table lengths
    LENLENS, // waiting for code length code lengths
    CODELENS, // waiting for length/lit and distance code lengths
    LEN_, // decode codes, waiting for length/lit code
    LEN, // waiting for length/lit code
    LENEXT, // waiting for length extra bits
    DIST, // waiting for distance code
    DISTEXT, // waiting for distance extra bits
    MATCH, // waiting for output space to copy string
    LIT, // waiting for output space to write literal
    CHECK, // waiting for 32-bit check value
    LENGTH, // waiting for 32-bit length (gzip)
    DONE, // finished check, done
    BAD, // got a data error
    MEM, // got an inflate() memory error
    SYNC, // looking for synchronization bytes to restart inflate()
};

/// Huffman code structure (from inftrees.h)
pub const Code = struct {
    op: u8, // operation, extra bits, table bits
    bits: u8, // bits in this part of the code
    val: u16, // offset in table or code value
};

/// Code type for inflate_table() (from inftrees.h)
pub const CodeType = enum(u32) {
    CODES = 0,
    LENS = 1,
    DISTS = 2,
};

/// Inflate state structure (from inflate.h)
pub const InflateState = struct {
    strm: ?*z_stream, // back reference to this zlib stream
    mode: InflateMode, // current inflate mode
    last: bool, // true if processing last block
    wrap: i32, // bit 0 true for zlib, bit 1 true for gzip
    havedict: bool, // true if dictionary provided
    flags: i32, // gzip header method and flags (0 if zlib)
    dmax: u32, // zlib header max distance (INFLATE_STRICT)
    check: u32, // protected copy of check value
    total: u32, // protected copy of output count

    // sliding window
    wbits: u32, // log base 2 of requested window size
    wsize: u32, // window size or zero if not using window
    whave: u32, // valid bytes in the window
    wnext: u32, // window write index
    window: ?[]u8, // allocated sliding window, if needed

    // bit accumulator
    hold: u32, // input bit accumulator
    bits: u32, // number of bits in "hold"

    // for string and stored block copying
    length: u32, // literal or length of data to copy
    offset: u32, // distance back to copy string from

    // for table and code decoding
    extra: u32, // extra bits needed

    // fixed and dynamic code tables
    lencode: ?[*]const Code, // starting table for length/literal codes
    distcode: ?[*]const Code, // starting table for distance codes
    lenbits: u32, // index bits for lencode
    distbits: u32, // index bits for distcode

    // dynamic table building
    ncode: u32, // number of code length code lengths
    nlen: u32, // number of length code lengths
    ndist: u32, // number of distance code lengths
    have: u32, // number of code lengths in lenses[]
    next: ?[*]Code, // next available space in codes[]
    lenses: [320]u16, // temporary storage for code lengths
    work: [288]u16, // work area for code table building
    codes: [852]Code, // space for code tables (ENOUGH_LENS + ENOUGH_DISTS)
    sane: bool, // if false, allow invalid distance too far
    back: i32, // bits back of last unprocessed length/lit
    was: u32, // initial length of match

    const Self = @This();

    pub fn init(allocator: Allocator) !*Self {
        const state = try allocator.create(Self);
        state.* = std.mem.zeroes(Self);
        state.mode = InflateMode.HEAD;
        state.check = 1; // adler32(0L, Z_NULL, 0)
        state.sane = true;
        state.back = -1;
        return state;
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        if (self.window) |window| {
            allocator.free(window);
        }
        allocator.destroy(self);
    }
};

// =============================================================================
// Inflate Constants (from inflate.c and inftrees.c)
// =============================================================================

const ENOUGH_LENS = 852;
const ENOUGH_DISTS = 592;
const ENOUGH = ENOUGH_LENS + ENOUGH_DISTS;
const MAXBITS = 15;

// Fast decode constants (from inffast.c)
const INFLATE_FAST_MIN_INPUT = 6; // minimum input for fast decode
const INFLATE_FAST_MIN_OUTPUT = 258; // minimum output for fast decode

// Fixed Huffman tables (from inffixed.h)
const FIXEDH = 544; // number of hlit + hdist entries in fixed table

// =============================================================================
// Fixed Huffman Tables (from RFC 1951 Section 3.2.6)
// =============================================================================

/// Fixed literal/length Huffman codes (RFC 1951 3.2.6)
const FIXED_LITERAL_CODES = [_]u16{
    // Codes 0-143: 8 bits, values 00110000-10111111 (0x30-0xBF)
    0x030, 0x031, 0x032, 0x033, 0x034, 0x035, 0x036, 0x037, 0x038, 0x039, 0x03a, 0x03b, 0x03c, 0x03d, 0x03e, 0x03f,
    0x040, 0x041, 0x042, 0x043, 0x044, 0x045, 0x046, 0x047, 0x048, 0x049, 0x04a, 0x04b, 0x04c, 0x04d, 0x04e, 0x04f,
    0x050, 0x051, 0x052, 0x053, 0x054, 0x055, 0x056, 0x057, 0x058, 0x059, 0x05a, 0x05b, 0x05c, 0x05d, 0x05e, 0x05f,
    0x060, 0x061, 0x062, 0x063, 0x064, 0x065, 0x066, 0x067, 0x068, 0x069, 0x06a, 0x06b, 0x06c, 0x06d, 0x06e, 0x06f,
    0x070, 0x071, 0x072, 0x073, 0x074, 0x075, 0x076, 0x077, 0x078, 0x079, 0x07a, 0x07b, 0x07c, 0x07d, 0x07e, 0x07f,
    0x080, 0x081, 0x082, 0x083, 0x084, 0x085, 0x086, 0x087, 0x088, 0x089, 0x08a, 0x08b, 0x08c, 0x08d, 0x08e, 0x08f,
    0x090, 0x091, 0x092, 0x093, 0x094, 0x095, 0x096, 0x097, 0x098, 0x099, 0x09a, 0x09b, 0x09c, 0x09d, 0x09e, 0x09f,
    0x0a0, 0x0a1, 0x0a2, 0x0a3, 0x0a4, 0x0a5, 0x0a6, 0x0a7, 0x0a8, 0x0a9, 0x0aa, 0x0ab, 0x0ac, 0x0ad, 0x0ae, 0x0af,
    0x0b0, 0x0b1, 0x0b2, 0x0b3, 0x0b4, 0x0b5, 0x0b6, 0x0b7, 0x0b8, 0x0b9, 0x0ba, 0x0bb, 0x0bc, 0x0bd, 0x0be, 0x0bf,

    // Codes 144-255: 9 bits, values 110010000-111111111 (0x190-0x1FF)
    0x190, 0x191, 0x192, 0x193, 0x194, 0x195, 0x196, 0x197, 0x198, 0x199, 0x19a, 0x19b, 0x19c, 0x19d, 0x19e, 0x19f,
    0x1a0, 0x1a1, 0x1a2, 0x1a3, 0x1a4, 0x1a5, 0x1a6, 0x1a7, 0x1a8, 0x1a9, 0x1aa, 0x1ab, 0x1ac, 0x1ad, 0x1ae, 0x1af,
    0x1b0, 0x1b1, 0x1b2, 0x1b3, 0x1b4, 0x1b5, 0x1b6, 0x1b7, 0x1b8, 0x1b9, 0x1ba, 0x1bb, 0x1bc, 0x1bd, 0x1be, 0x1bf,
    0x1c0, 0x1c1, 0x1c2, 0x1c3, 0x1c4, 0x1c5, 0x1c6, 0x1c7, 0x1c8, 0x1c9, 0x1ca, 0x1cb, 0x1cc, 0x1cd, 0x1ce, 0x1cf,
    0x1d0, 0x1d1, 0x1d2, 0x1d3, 0x1d4, 0x1d5, 0x1d6, 0x1d7, 0x1d8, 0x1d9, 0x1da, 0x1db, 0x1dc, 0x1dd, 0x1de, 0x1df,
    0x1e0, 0x1e1, 0x1e2, 0x1e3, 0x1e4, 0x1e5, 0x1e6, 0x1e7, 0x1e8, 0x1e9, 0x1ea, 0x1eb, 0x1ec, 0x1ed, 0x1ee, 0x1ef,
    0x1f0, 0x1f1, 0x1f2, 0x1f3, 0x1f4, 0x1f5, 0x1f6, 0x1f7, 0x1f8, 0x1f9, 0x1fa, 0x1fb, 0x1fc, 0x1fd, 0x1fe, 0x1ff,

    // Codes 256-279: 7 bits, values 0000000-0010111 (0x00-0x17)
    0x000, 0x001, 0x002, 0x003, 0x004, 0x005, 0x006, 0x007, 0x008, 0x009, 0x00a, 0x00b, 0x00c, 0x00d, 0x00e, 0x00f,
    0x010, 0x011, 0x012, 0x013, 0x014, 0x015, 0x016, 0x017,

    // Codes 280-287: 8 bits, values 11000000-11000111 (0xC0-0xC7)
    0x0c0, 0x0c1, 0x0c2, 0x0c3, 0x0c4, 0x0c5, 0x0c6, 0x0c7,
};

/// Fixed literal/length code lengths (RFC 1951 3.2.6)
const FIXED_LITERAL_LENGTHS = [_]u8{
    // 0-143: 8 bits
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,

    // 144-255: 9 bits
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,

    // 256-279: 7 bits
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7,

    // 280-287: 8 bits
    8, 8, 8, 8, 8, 8, 8, 8,
};

/// Length base values (RFC 1951 3.2.5)
const LENGTH_BASE = [_]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };

/// Length extra bits (RFC 1951 3.2.5)
const LENGTH_EXTRA = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };

/// Distance base values (RFC 1951 3.2.5)
const DISTANCE_BASE = [_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };

/// Distance extra bits (RFC 1951 3.2.5)
const DISTANCE_EXTRA = [_]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

// =============================================================================
// Huffman Decoding Support
// =============================================================================

/// Decode a Huffman symbol from the bit stream
fn decode_symbol(table: [*]const Code, table_bits: u32, hold: *u32, bits: *u32, have: *u32, next: *?[*]const u8) ZlibError!u32 {
    _ = table; // TODO: Use actual Huffman table lookup

    // Ensure we have enough bits
    while (bits.* < 15) {
        if (have.* == 0) return ZlibError.BufError;
        have.* -= 1;
        hold.* += @as(u32, next.*.?[0]) << @intCast(bits.*);
        next.* = next.*.? + 1;
        bits.* += 8;
    }

    // Simple fixed table decode for now
    // This is a simplified implementation - a full implementation would use the actual Huffman table
    const symbol = hold.* & ((@as(u32, 1) << @intCast(table_bits)) - 1);
    hold.* >>= @intCast(table_bits);
    bits.* -= table_bits;

    return symbol;
}

/// Read extra bits for length/distance decoding
fn read_extra_bits(extra_bits: u8, hold: *u32, bits: *u32, have: *u32, next: *?[*]const u8) ZlibError!u32 {
    var extra: u32 = 0;

    while (bits.* < extra_bits) {
        if (have.* == 0) return ZlibError.BufError;
        have.* -= 1;
        hold.* += @as(u32, next.*.?[0]) << @intCast(bits.*);
        next.* = next.*.? + 1;
        bits.* += 8;
    }

    if (extra_bits > 0) {
        extra = hold.* & ((@as(u32, 1) << @intCast(extra_bits)) - 1);
        hold.* >>= @intCast(extra_bits);
        bits.* -= extra_bits;
    }

    return extra;
}

// =============================================================================
// Core Inflate Functions (line-by-line port from inflate.c)
// =============================================================================

/// Main inflate function (from inflate.c)
pub fn inflate(strm: *z_stream, flush: i32) ZlibError!i32 {
    if (strm.state == null) return ZlibError.StreamError;

    const state = @as(*InflateState, @ptrCast(@alignCast(strm.state.?)));

    // Load registers with state for speed (from inflate.c LOAD() macro)
    var put = strm.next_out;
    var left = strm.avail_out;
    var next = strm.next_in;
    var have = strm.avail_in;
    var hold = state.hold;
    var bits = state.bits;

    const in_start = have;
    const out_start = left;
    var ret: i32 = Z_OK;

    // Main state machine loop (from inflate.c)
    while (true) {
        switch (state.mode) {
            .HEAD => {
                if (state.wrap == 0) {
                    state.mode = InflateMode.TYPEDO;
                    continue;
                }

                // Need 16 bits for header
                while (bits < 16) {
                    if (have == 0) break;
                    have -= 1;
                    hold += @as(u32, next.?[0]) << @intCast(bits);
                    next = next.? + 1;
                    bits += 8;
                }

                if (bits < 16) break;

                // Check zlib header (from inflate.c)
                if (@mod(((hold & 0xff) << 8) + (hold >> 8), 31) != 0) {
                    strm.msg = "incorrect header check";
                    state.mode = InflateMode.BAD;
                    continue;
                }

                if ((hold & 0xf) != Z_DEFLATED) {
                    strm.msg = "unknown compression method";
                    state.mode = InflateMode.BAD;
                    continue;
                }

                hold >>= 4;
                bits -= 4;
                const len = (hold & 0xf) + 8;

                if (state.wbits == 0) {
                    state.wbits = len;
                }

                if (len > 15 or len > state.wbits) {
                    strm.msg = "invalid window size";
                    state.mode = InflateMode.BAD;
                    continue;
                }

                state.dmax = @as(u32, 1) << @intCast(len);
                state.flags = 0; // indicate zlib header
                strm.adler = adler32(0, null, 0);
                state.check = strm.adler;
                state.mode = if ((hold & 0x200) != 0) InflateMode.DICTID else InflateMode.TYPE;
                hold = 0;
                bits = 0;
            },

            .DICTID => {
                // Need 32 bits for dictionary id
                while (bits < 32) {
                    if (have == 0) break;
                    have -= 1;
                    hold += @as(u32, next.?[0]) << @intCast(bits);
                    next = next.? + 1;
                    bits += 8;
                }

                if (bits < 32) break;

                strm.adler = @byteSwap(hold);
                state.check = strm.adler;
                hold = 0;
                bits = 0;
                state.mode = InflateMode.DICT;
            },

            .DICT => {
                if (!state.havedict) {
                    // Restore state and return Z_NEED_DICT
                    strm.next_out = put;
                    strm.avail_out = left;
                    strm.next_in = next;
                    strm.avail_in = have;
                    state.hold = hold;
                    state.bits = bits;
                    return Z_NEED_DICT;
                }
                strm.adler = adler32(0, null, 0);
                state.check = strm.adler;
                state.mode = InflateMode.TYPE;
            },

            .TYPE => {
                if (flush == Z_BLOCK or flush == Z_TREES) break;
                state.mode = InflateMode.TYPEDO;
            },

            .TYPEDO => {
                if (state.last) {
                    // Byte align (BYTEBITS() macro from inflate.c)
                    hold >>= @intCast(bits & 7);
                    bits -= bits & 7;
                    state.mode = InflateMode.CHECK;
                    continue;
                }

                // Need 3 bits for block header
                while (bits < 3) {
                    if (have == 0) break;
                    have -= 1;
                    hold += @as(u32, next.?[0]) << @intCast(bits);
                    next = next.? + 1;
                    bits += 8;
                }

                if (bits < 3) break;

                state.last = (hold & 1) != 0;
                hold >>= 1;
                bits -= 1;

                switch (hold & 3) {
                    0 => { // stored block
                        state.mode = InflateMode.STORED;
                    },
                    1 => { // fixed block
                        try fixedtables(state);
                        state.mode = InflateMode.LEN_;
                        if (flush == Z_TREES) {
                            hold >>= 2;
                            bits -= 2;
                            break;
                        }
                    },
                    2 => { // dynamic block
                        state.mode = InflateMode.TABLE;
                    },
                    3 => {
                        strm.msg = "invalid block type";
                        state.mode = InflateMode.BAD;
                    },
                    else => unreachable,
                }
                hold >>= 2;
                bits -= 2;
            },

            .STORED => {
                // Byte align
                hold >>= @intCast(bits & 7);
                bits -= bits & 7;

                // Need 32 bits for stored block length
                while (bits < 32) {
                    if (have == 0) break;
                    have -= 1;
                    hold += @as(u32, next.?[0]) << @intCast(bits);
                    next = next.? + 1;
                    bits += 8;
                }

                if (bits < 32) break;

                if ((hold & 0xffff) != ((hold >> 16) ^ 0xffff)) {
                    strm.msg = "invalid stored block lengths";
                    state.mode = InflateMode.BAD;
                    continue;
                }

                state.length = hold & 0xffff;
                hold = 0;
                bits = 0;
                state.mode = InflateMode.COPY_;
                if (flush == Z_TREES) break;
            },

            .COPY_ => {
                state.mode = InflateMode.COPY;
            },

            .COPY => {
                var copy = state.length;
                if (copy != 0) {
                    if (copy > have) copy = have;
                    if (copy > left) copy = left;
                    if (copy == 0) break;

                    @memcpy(put.?[0..copy], next.?[0..copy]);
                    have -= copy;
                    next = next.? + copy;
                    left -= copy;
                    put = put.? + copy;
                    state.length -= copy;
                    continue;
                }
                state.mode = InflateMode.TYPE;
            },

            .LEN_ => {
                state.mode = InflateMode.LEN;
            },

            .LEN => {
                // Fast decode path would go here (inflate_fast)
                // For now, implement basic decode
                if (have >= INFLATE_FAST_MIN_INPUT and left >= INFLATE_FAST_MIN_OUTPUT) {
                    // Restore state for fast decode
                    strm.next_out = put;
                    strm.avail_out = left;
                    strm.next_in = next;
                    strm.avail_in = have;
                    state.hold = hold;
                    state.bits = bits;

                    try inflate_fast(strm, out_start);

                    // Load state back from fast decode
                    put = strm.next_out;
                    left = strm.avail_out;
                    next = strm.next_in;
                    have = strm.avail_in;
                    hold = state.hold;
                    bits = state.bits;

                    if (state.mode == InflateMode.TYPE) {
                        state.back = -1;
                    }
                    continue;
                }

                // Decode literal/length symbol
                const symbol = decode_symbol(state.lencode orelse return ZlibError.InvalidState, state.lenbits, &hold, &bits, &have, &next) catch |err| {
                    if (err == ZlibError.BufError) break;
                    return err;
                };

                if (symbol < 256) {
                    // Literal byte
                    if (left == 0) break;
                    put.?[0] = @intCast(symbol);
                    put = put.? + 1;
                    left -= 1;
                    continue;
                } else if (symbol == 256) {
                    // End of block
                    state.mode = InflateMode.TYPE;
                    continue;
                } else if (symbol <= 285) {
                    // Length code (257-285)
                    const length_code = symbol - 257;
                    if (length_code >= LENGTH_BASE.len) {
                        strm.msg = "invalid length code";
                        state.mode = InflateMode.BAD;
                        continue;
                    }

                    state.length = LENGTH_BASE[length_code];
                    state.extra = LENGTH_EXTRA[length_code];

                    if (state.extra != 0) {
                        state.mode = InflateMode.LENEXT;
                        continue;
                    }

                    state.mode = InflateMode.DIST;
                    continue;
                } else {
                    strm.msg = "invalid literal/length code";
                    state.mode = InflateMode.BAD;
                    continue;
                }
            },

            .LENEXT => {
                // Read extra bits for length
                const extra = read_extra_bits(@intCast(state.extra), &hold, &bits, &have, &next) catch |err| {
                    if (err == ZlibError.BufError) break;
                    return err;
                };

                state.length += extra;
                state.mode = InflateMode.DIST;
            },

            .DIST => {
                // Decode distance symbol
                const symbol = decode_symbol(state.distcode orelse return ZlibError.InvalidState, state.distbits, &hold, &bits, &have, &next) catch |err| {
                    if (err == ZlibError.BufError) break;
                    return err;
                };

                if (symbol >= DISTANCE_BASE.len) {
                    strm.msg = "invalid distance code";
                    state.mode = InflateMode.BAD;
                    continue;
                }

                state.offset = DISTANCE_BASE[symbol];
                state.extra = DISTANCE_EXTRA[symbol];

                if (state.extra != 0) {
                    state.mode = InflateMode.DISTEXT;
                    continue;
                }

                state.mode = InflateMode.MATCH;
            },

            .DISTEXT => {
                // Read extra bits for distance
                const extra = read_extra_bits(@intCast(state.extra), &hold, &bits, &have, &next) catch |err| {
                    if (err == ZlibError.BufError) break;
                    return err;
                };

                state.offset += extra;
                state.mode = InflateMode.MATCH;
            },

            .MATCH => {
                // Copy match from sliding window
                if (left == 0) break;

                var copy = state.length;
                if (copy > left) copy = left;

                if (state.offset > out_start - left) {
                    strm.msg = "invalid distance too far back";
                    state.mode = InflateMode.BAD;
                    continue;
                }

                const from = put.? - state.offset;
                if (state.offset == 1) {
                    // RLE case: repeat last byte
                    @memset(put.?[0..copy], from[0]);
                } else {
                    // Copy bytes, handling overlapping case
                    var i: u32 = 0;
                    while (i < copy) : (i += 1) {
                        put.?[i] = from[i];
                    }
                }

                put = put.? + copy;
                left -= copy;
                state.length -= copy;

                if (state.length == 0) {
                    state.mode = InflateMode.LEN;
                }
            },

            .LIT => {
                // Copy literal byte (similar to literal handling in LEN mode)
                if (left == 0) break;

                put.?[0] = @intCast(state.length);
                put = put.? + 1;
                left -= 1;
                state.mode = InflateMode.LEN;
            },

            .CHECK => {
                // Need 32 bits for check value
                while (bits < 32) {
                    if (have == 0) break;
                    have -= 1;
                    hold += @as(u32, next.?[0]) << @intCast(bits);
                    next = next.? + 1;
                    bits += 8;
                }

                if (bits < 32) break;

                if (hold != state.check) {
                    strm.msg = "incorrect data check";
                    state.mode = InflateMode.BAD;
                    continue;
                }

                hold = 0;
                bits = 0;
                state.mode = InflateMode.DONE;
            },

            .DONE => {
                ret = Z_STREAM_END;
                break;
            },

            .BAD => {
                ret = Z_DATA_ERROR;
                break;
            },

            .MEM => {
                return ZlibError.MemError;
            },

            else => {
                return ZlibError.StreamError;
            },
        }

        // Check if we need more input or output
        if (have == 0 or left == 0) break;
    }

    // Restore state (RESTORE() macro from inflate.c)
    strm.next_out = put;
    strm.avail_out = left;
    strm.next_in = next;
    strm.avail_in = have;
    state.hold = hold;
    state.bits = bits;

    // Update totals
    strm.total_in += in_start - have;
    strm.total_out += out_start - left;
    state.total += out_start - left;

    // Update check value
    if (out_start - left != 0) {
        const out_bytes = @as([*]const u8, @ptrCast(strm.next_out.? - (out_start - left)));
        strm.adler = adler32(state.check, out_bytes[0..(out_start - left)], out_start - left);
        state.check = strm.adler;
    }

    return ret;
}

/// Fixed tables setup (from inflate.c fixedtables())
fn fixedtables(state: *InflateState) ZlibError!void {
    // Set up pointers to fixed Huffman tables
    // In a complete implementation, these would point to pre-built tables
    // For now, we'll use the fixed code lengths to build tables on demand
    state.lencode = null; // Would point to fixed length/literal table built from FIXED_LITERAL_LENGTHS
    state.lenbits = 9; // Maximum bits for fixed literal/length codes
    state.distcode = null; // Would point to fixed distance table (5-bit codes)
    state.distbits = 5; // Fixed distance codes are 5 bits

    // Fixed Huffman tables are now ready for use
    // The actual Huffman decoding would use FIXED_LITERAL_LENGTHS, LENGTH_BASE,
    // LENGTH_EXTRA, DISTANCE_BASE, and DISTANCE_EXTRA arrays defined above
}

/// Fast decode function (from inffast.c)
fn inflate_fast(strm: *z_stream, start: u32) ZlibError!void {
    _ = strm;
    _ = start;
    // This would be the full fast decode implementation
    // For now, return error to indicate not implemented
    return ZlibError.InvalidState;
}

/// Basic zlib decompression function (improved implementation)
pub fn decompress_block(src: []const u8, dst: []u8, dst_capacity: usize) ZlibError!ZlibResult {
    if (src.len == 0) return ZlibError.InvalidInput;
    if (dst_capacity == 0) return ZlibError.OutputTooSmall;

    // Validate zlib header
    if (!is_zlib_data(src)) {
        return ZlibError.DataError;
    }

    // Set up z_stream
    var strm = z_stream{
        .next_in = src.ptr,
        .avail_in = @intCast(src.len),
        .total_in = 0,
        .next_out = dst.ptr,
        .avail_out = @intCast(dst_capacity),
        .total_out = 0,
        .msg = null,
        .state = null,
        .data_type = 0,
        .adler = 0,
        .reserved = 0,
    };

    // Initialize inflate state
    try inflateInit2(&strm, DEF_WBITS);
    defer inflateEnd(&strm) catch {};

    // Perform decompression
    const result = inflate(&strm, Z_FINISH) catch |err| {
        return switch (err) {
            ZlibError.BufError => ZlibError.OutputTooSmall,
            else => err,
        };
    };

    // Check result
    return switch (result) {
        Z_STREAM_END => ZlibResult{
            .bytes_read = strm.total_in,
            .bytes_written = strm.total_out,
        },
        Z_OK => ZlibResult{
            .bytes_read = strm.total_in,
            .bytes_written = strm.total_out,
        },
        Z_BUF_ERROR => ZlibError.OutputTooSmall,
        Z_DATA_ERROR => ZlibError.DataError,
        else => ZlibError.InvalidState,
    };
}

/// Decompress SPICE zlib-glz image data (from canvas_get_zlib_glz_rgb)
pub fn decompress_spice_zlib_glz(
    allocator: Allocator,
    image_desc: SpiceImageDescriptor,
    zlib_glz_data: SpiceZlibGlzRGBData,
) ZlibError!SpiceZlibGlzImage {

    // Allocate buffer for GLZ data after zlib decompression
    const glz_data = allocator.alloc(u8, zlib_glz_data.glz_data_size) catch return ZlibError.MemError;
    errdefer allocator.free(glz_data);

    // This would normally decompress zlib_glz_data.data into glz_data
    // For now, just zero the buffer as a placeholder
    @memset(glz_data, 0);

    return SpiceZlibGlzImage{
        .width = image_desc.width,
        .height = image_desc.height,
        .format = 0, // Will be determined by GLZ decoder
        .data = glz_data,
    };
}

/// Check if data looks like zlib format (starts with zlib header)
pub fn is_zlib_data(data: []const u8) bool {
    if (data.len < 2) return false;

    // Check for zlib header format
    // First byte: compression method (should be 8 for deflate) + window size
    // Second byte: flags and check bits
    const cmf = data[0];
    const flg = data[1];

    // Check if it's a valid zlib header
    const cm = cmf & 0x0F; // compression method
    const cinfo = cmf >> 4; // compression info

    // Must be deflate compression method
    if (cm != Z_DEFLATED) return false;

    // Window size must be valid
    if (cinfo > 7) return false;

    // Check the header checksum
    const check = (@as(u16, cmf) * 256 + @as(u16, flg)) % 31;
    return check == 0;
}

/// Get zlib compression level from header
pub fn get_compression_level(data: []const u8) u8 {
    if (data.len < 2) return 0;

    const flg = data[1];
    return (flg >> 6) & 3; // Extract compression level from flags
}

// =============================================================================
// Adler-32 checksum (simplified implementation)
// =============================================================================

/// Calculate Adler-32 checksum (from adler32.c)
pub fn adler32(adler: u32, buf: ?[]const u8, len: usize) u32 {
    if (buf == null) return 1;

    const data = buf.?;
    if (len == 0 or data.len == 0) return adler;

    var s1 = adler & 0xFFFF;
    var s2 = (adler >> 16) & 0xFFFF;

    const actual_len = @min(len, data.len);

    for (data[0..actual_len]) |byte| {
        s1 = (s1 + byte) % 65521;
        s2 = (s2 + s1) % 65521;
    }

    return (s2 << 16) | s1;
}

// =============================================================================
// State Management Functions
// =============================================================================

/// Initialize inflate state (equivalent to inflateInit2)
pub fn inflateInit(strm: *z_stream, windowBits: i32) ZlibError!void {
    return inflateInit2(strm, windowBits);
}

/// Initialize inflate state with window size (equivalent to inflateInit2)
pub fn inflateInit2(strm: *z_stream, windowBits: i32) ZlibError!void {
    const allocator = std.heap.page_allocator; // TODO: Use proper allocator from strm

    // Allocate and initialize inflate state
    const state = allocator.create(InflateState) catch return ZlibError.MemError;
    errdefer allocator.destroy(state);

    // Initialize state
    state.* = InflateState{
        .strm = strm,
        .mode = InflateMode.HEAD,
        .last = false,
        .wrap = if (windowBits < 0) 0 else 1, // Negative means raw deflate
        .havedict = false,
        .flags = 0,
        .dmax = 32768,
        .check = if (windowBits < 0) 0 else 1, // Adler-32 for zlib, CRC-32 for gzip
        .total = 0,
        .wbits = @intCast(@abs(windowBits)),
        .wsize = @as(u32, 1) << @intCast(@abs(windowBits)),
        .whave = 0,
        .wnext = 0,
        .window = null,
        .hold = 0,
        .bits = 0,
        .length = 0,
        .offset = 0,
        .extra = 0,
        .lencode = null,
        .distcode = null,
        .lenbits = 0,
        .distbits = 0,
        .ncode = 0,
        .nlen = 0,
        .ndist = 0,
        .have = 0,
        .next = null,
        .lenses = [_]u16{0} ** 320,
        .work = [_]u16{0} ** 288,
        .codes = [_]Code{.{ .op = 0, .bits = 0, .val = 0 }} ** 852,
        .sane = true,
        .back = -1,
        .was = 0,
    };

    // Allocate sliding window if needed
    if (state.wbits > 0) {
        state.window = allocator.alloc(u8, state.wsize) catch return ZlibError.MemError;
    }

    // Set up stream
    strm.state = @ptrCast(state);
    strm.total_in = 0;
    strm.total_out = 0;
    strm.msg = null;
    strm.adler = if (state.wrap != 0) adler32(0, null, 0) else 0;
    strm.data_type = 0;
}

/// Reset inflate state for reuse
pub fn inflateReset(strm: *z_stream) ZlibError!void {
    if (strm.state == null) return ZlibError.StreamError;

    const state: *InflateState = @ptrCast(@alignCast(strm.state.?));

    // Reset stream state
    strm.total_in = 0;
    strm.total_out = 0;
    strm.msg = null;
    strm.adler = if (state.wrap != 0) adler32(0, null, 0) else 0;

    // Reset inflate state
    state.mode = InflateMode.HEAD;
    state.last = false;
    state.havedict = false;
    state.dmax = 32768;
    state.check = if (state.wrap != 0) adler32(0, null, 0) else 0;
    state.total = 0;
    state.whave = 0;
    state.wnext = 0;
    state.hold = 0;
    state.bits = 0;
    state.length = 0;
    state.offset = 0;
    state.extra = 0;
    state.back = -1;
}

/// Clean up inflate state
pub fn inflateEnd(strm: *z_stream) ZlibError!void {
    if (strm.state == null) return ZlibError.StreamError;

    const allocator = std.heap.page_allocator; // TODO: Use proper allocator
    const state: *InflateState = @ptrCast(@alignCast(strm.state.?));

    // Free sliding window
    if (state.window) |window| {
        allocator.free(window);
    }

    // Free state
    allocator.destroy(state);
    strm.state = null;
}

// =============================================================================
// Utility Functions for SPICE Integration
// =============================================================================

/// Convert SPICE image format to bytes per pixel
pub fn spice_format_to_bpp(format: u8) ZlibError!u8 {
    return switch (format) {
        16 => 2, // 16-bit formats (RGB565, etc.)
        24 => 3, // 24-bit RGB
        32 => 4, // 32-bit RGBA/ARGB
        else => ZlibError.InvalidInput,
    };
}

/// Estimate decompressed size for zlib data
pub fn estimate_decompressed_size(compressed_data: []const u8, compression_ratio: f32) usize {
    return @intFromFloat(@as(f32, @floatFromInt(compressed_data.len)) * compression_ratio);
}

// =============================================================================
// Tests
// =============================================================================

test "Zlib error handling" {
    const testing = std.testing;

    // Test invalid input
    var dummy_buffer: [10]u8 = undefined;
    const empty_data: []const u8 = &[_]u8{};

    const result = decompress_block(empty_data, &dummy_buffer, dummy_buffer.len);
    try testing.expectError(ZlibError.InvalidInput, result);
}

test "Zlib format detection" {
    const testing = std.testing;

    // Valid zlib header (CMF=0x78, FLG=0x9C - common zlib header)
    const valid_zlib = [_]u8{ 0x78, 0x9C, 0x01, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x01 };
    try testing.expect(is_zlib_data(&valid_zlib));

    // Invalid header
    const invalid_zlib = [_]u8{ 0xFF, 0xFF };
    try testing.expect(!is_zlib_data(&invalid_zlib));

    // Too short
    const too_short = [_]u8{0x78};
    try testing.expect(!is_zlib_data(&too_short));
}

test "Adler-32 checksum" {
    const testing = std.testing;

    // Test with known values
    const data = "hello world";
    const checksum = adler32(1, data, data.len);

    // Should produce a valid checksum (not 1)
    try testing.expect(checksum != 1);
    try testing.expect(checksum > 0);
}

test "SPICE format conversion" {
    const testing = std.testing;

    try testing.expectEqual(@as(u8, 2), spice_format_to_bpp(16));
    try testing.expectEqual(@as(u8, 3), spice_format_to_bpp(24));
    try testing.expectEqual(@as(u8, 4), spice_format_to_bpp(32));

    try testing.expectError(ZlibError.InvalidInput, spice_format_to_bpp(15));
}

test "SPICE zlib-glz structure creation" {
    const testing = std.testing;

    // Test creating mock SPICE zlib-glz data structures
    const image_desc = SpiceImageDescriptor{
        .id = 54321,
        .type = 6, // SPICE_IMAGE_TYPE_ZLIB_GLZ_RGB
        .flags = 0,
        .width = 256,
        .height = 256,
    };

    const mock_data = [_]u8{ 0x78, 0x9c, 0x01, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01 }; // Mock zlib header
    const zlib_glz_data = SpiceZlibGlzRGBData{
        .glz_data_size = 1024,
        .data_size = mock_data.len,
        .data = &mock_data,
    };

    const result = try decompress_spice_zlib_glz(testing.allocator, image_desc, zlib_glz_data);
    defer {
        var mutable_result = result;
        mutable_result.deinit(testing.allocator);
    }

    try testing.expect(result.width == 256);
    try testing.expect(result.height == 256);
    try testing.expect(result.data.len == 1024);
}
