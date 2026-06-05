// https://arxiv.org/html/0901.4016
// A Proposal for Proquints: Identifiers that are Readable, Spellable, and Pronounceable
// (defines a bijection between cvcvc proquint words and 16-bit chunks)
// cf a referemce implementation (in C, perhap also perl?):  http://github.com/dsw/proquint

const std = @import("std");
const CodingDirection = @import("root").CodingDirection;
const SymbolMap = @import("SymbolMap.zig");
const VOWEL_FLAG = SymbolMap.VOWEL_FLAG;
const Writer = std.Io.Writer;
const assert = std.debug.assert;
const math = std.math;
const warn = std.debug.print;

const BYTEBITS = 8;
const CHUNKSYMS = 5;
const CHUNKBYTES = 2;
const CHUNKBITS = CHUNKBYTES*BYTEBITS;
const NCONSONANT = 16; // we rely on a split alphabet, with 16 consonants
const NVOWEL = 4;      // ... and 4 vowels
const SymbolMappingFailure = error.WriteFailed; //XXX good enough? need to keep within Io.Writer.Error set...
const Self = @This();

comptime { assert(math.isPowerOfTwo(NCONSONANT)); }
const CONSONANT_BITS: u8 = @ctz(@as(u8,NCONSONANT)); //log2(NCONSONANT)
comptime { assert(math.isPowerOfTwo(NVOWEL)); }
const VOWEL_BITS: u8 = @ctz(@as(u8,NVOWEL)); //log2(NCONSONANT)
comptime { assert(CONSONANT_BITS*3 + VOWEL_BITS*2 == CHUNKBITS); } // chunk is CvCvC pattern

map: *const SymbolMap,
interface: Writer,
downstream: *Writer,
runner: *const fn (self: *Self, input: []const u8) Writer.Error!void,
flusher: *const fn (self: *Self) Writer.Error!void,
bitbuf: @Int(.unsigned, CHUNKBITS) = 0, //where we accumulate partial inputs
bitcur: math.IntFittingRange(0, CHUNKBITS) = 0, //count of meaningful bits in bitbuf
input_ccount: usize = 0,

pub fn init(downstream: *Writer, map: *const SymbolMap, dir: CodingDirection) Self {
    assert(map.symbols.len == NCONSONANT);
    const vlen = if (map.vowels) |v| v.len else 0;
    assert(vlen == NVOWEL);
    return .{
        .map = map,
        .downstream = downstream,
        .runner = if (dir == .BytesToSyms) bytes_to_syms else syms_to_bytes,
        .flusher = if (dir == .BytesToSyms) emit_syms else emit_bytes,
        .interface = .{
            .end = 0,  .buffer = &.{},
            .vtable = &.{ .drain = drain, .flush = flush, },
        },
    };
}

pub fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    const self: *Self = @fieldParentPtr("interface", w);
    const splatidx = data.len - 1;
    var nconsumed: usize = 0;
    for (data[0..splatidx]) |v| { try self.runner(self, v); nconsumed += v.len; }
    const splatvec = data[splatidx];
    for (0..splat) |_| { try self.runner(self, splatvec); nconsumed += splatvec.len; }
    return nconsumed;
}

pub fn flush(w: *Writer) !void {
    const self: *Self = @fieldParentPtr("interface", w);
    try self.flusher(self);
    try self.downstream.flush();
}


fn bytes_to_syms(self: *Self, input: []const u8) Writer.Error!void {
    for (input) |c| {
        self.bitbuf = (self.bitbuf << BYTEBITS) | c;
        self.bitcur += BYTEBITS;
        if (self.bitcur >= CHUNKBITS)
            try self.emit_syms();
    }
}

fn emit_syms(self: *Self) !void {
    if (self.bitcur == 0) return;
    var v = self.bitbuf;
    var o: [5]u8 = undefined;
    var end: usize = o.len; //default, for full buffer
    if (self.bitcur < CHUNKBITS) {
        @branchHint(.unlikely);
        //partial final buffer
        v <<= BYTEBITS;
        end -= 2;
    }
    o[0] = self.map.getsym(0xf & (v>>12)) catch return SymbolMappingFailure;
    o[1] = self.map.getvowel(0x3 & (v>>10)) catch return SymbolMappingFailure;
    o[2] = self.map.getsym(0xf & (v>>6)) catch return SymbolMappingFailure;
    o[3] = self.map.getvowel(0x3 & (v>>4)) catch return SymbolMappingFailure;
    o[4] = self.map.getsym(0xf & (v>>0)) catch return SymbolMappingFailure;
    try self.downstream.writeAll(o[0..end]);
    self.bitcur = 0;
}


fn syms_to_bytes(self: *Self, input: []const u8) Writer.Error!void {
    for (input) |input_symbol| {
        self.input_ccount += 1;
        const symbol_index = self.map.symbol_to_index(input_symbol);
        if (symbol_index == .IGNORE) continue;
        var c = @intFromEnum(symbol_index);
        var shiftcnt: u3 = 0;
        if (self.bitcur==4 or self.bitcur==10) { //bit positions for vowel inputs
            c -%= VOWEL_FLAG; //wrapping is not a problem, because of the "<" below:
            if (c < NVOWEL) shiftcnt = VOWEL_BITS; //got a valid vowel
        } else if (c < NCONSONANT) {
            shiftcnt = CONSONANT_BITS; //got a valid consonant
        }
        if (shiftcnt == 0) {
            warn("{s}: could not interpret invalid symbol 0x{x} at position {d}\n",
                .{@src().file, input_symbol, self.input_ccount});
            return SymbolMappingFailure;
        }
        self.bitbuf = (self.bitbuf << shiftcnt) | c;
        self.bitcur += shiftcnt;
        if (self.bitcur >= CHUNKBITS)
            try self.emit_bytes();
    }
}

fn emit_bytes(self: *Self) !void {
    if (self.bitcur == 0) return;
    defer self.bitcur = 0;
    var outbuf: [2]u8 = undefined;
    var nout: usize = 2;
    if (self.bitcur < CHUNKBITS) {
        @branchHint(.unlikely);
        //.bitcur has been guarded to be in (0,CHUNKBITS), so the -% below
        //will never actually wrap (but it keeps the compiler happy)
        self.bitbuf <<= @intCast(CHUNKBITS -% self.bitcur);
        if (self.bitcur <= 10) nout = 1;
    }
    outbuf[0] = @truncate(self.bitbuf >> BYTEBITS);
    outbuf[1] = @truncate(self.bitbuf);
    try self.downstream.writeAll(outbuf[0..nout]);
}
