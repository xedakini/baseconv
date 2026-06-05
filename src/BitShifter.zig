const std = @import("std");
const CodingDirection = @import("root").CodingDirection;
const SymbolMap = @import("SymbolMap.zig");
const Writer = std.Io.Writer;
const assert = std.debug.assert;
const math = std.math;
const warn = std.debug.print;

const BYTEBITS = 8;
const MAXCHUNKBITS = 64; //we can get by with as few as 2*BYTEBIS, but here choose to buffer more
const IntBufType = @Int(.unsigned, MAXCHUNKBITS);
const SymbolMappingFailure = error.WriteFailed; //XXX good enough? need to keep within Io.Writer.Error set...
const Self = @This();

map: *const SymbolMap,
interface: Writer,
downstream: *Writer,
runner: *const fn (self: *Self, input: []const u8) Writer.Error!void,
flusher: *const fn (self: *Self) Writer.Error!void,
sym_bits: math.IntFittingRange(1, BYTEBITS), //we do not support symbol sets which don't fit withhin one byte
chunk_bits: math.IntFittingRange(1, MAXCHUNKBITS), //number of symbol bits to "chunk" into the bitbuf between flushes
syms_per_chunk: math.IntFittingRange(1, BYTEBITS), //cached computation of chunk_bits / sym_bits
sym_bitmask: IntBufType,
bitbuf: IntBufType = 0, //buffer for gathering bits
bitcnt: math.IntFittingRange(0, MAXCHUNKBITS-1) = 0, //count of currently-active bits in .bitbuf
bytebuf: [64]u8 = undefined, //to avoid calling .downstream.writeByte() on *every* byte, we buffer some here
bytecnt: usize = 0, //how many bytes of .bytebuf are currently valid
input_ccount: usize = 0,

pub fn init(downstream: *Writer, map: *const SymbolMap, dir: CodingDirection) Self {
    //nsym must be a power of 2 between 2 and 256 (inclusive):
    assert(math.isPowerOfTwo(map.nsym));
    const sym_bits = @ctz(map.nsym); //like map.sym_bits, but as an integer
    assert(1 <= sym_bits  and  sym_bits <= BYTEBITS); //in range?
    const chunk_bits = math.lcm(sym_bits, BYTEBITS);
    assert(chunk_bits <= MAXCHUNKBITS); //sanity check
    assert(chunk_bits % sym_bits == 0); //required
    const syms_per_chunk = chunk_bits / sym_bits;
    return .{
        .map = map,
        .downstream = downstream,
        .runner = if (dir == .BytesToSyms) bytes_to_syms else syms_to_bytes,
        .flusher = if (dir == .BytesToSyms) emit_buffered_syms else emit_buffered_bytes,
        .interface = .{
            .end = 0,  .buffer = &.{},
            .vtable = &.{ .drain = drain, .flush = flush, },
        },
        .sym_bits = @intCast(sym_bits),
        .chunk_bits = @intCast(chunk_bits),
        .syms_per_chunk = @intCast(syms_per_chunk),
        .sym_bitmask = @intCast((@as(IntBufType, 1) << @intCast(sym_bits)) - 1),
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

pub fn flush(w: *Writer) Writer.Error!void {
    const self: *Self = @fieldParentPtr("interface", w);
    try self.flusher(self);
    try self.downstream.flush();
}


fn bytes_to_syms(self: *Self, input: []const u8) !void {
    for (input) |c| {
        self.bitbuf = (self.bitbuf << BYTEBITS) | c;
        self.bitcnt += BYTEBITS;
        if (self.bitcnt >= self.chunk_bits)
            try self.emit_buffered_syms();
    }
}

fn emit_buffered_syms(self: *Self) !void {
    if (self.bitcnt == 0) return;
    var symcnt: usize = self.syms_per_chunk;
    if (self.bitcnt < self.chunk_bits) {
        //do padding
        symcnt = math.divCeil(usize, self.bitcnt, self.sym_bits) catch unreachable;
        self.bitbuf <<= @intCast(self.chunk_bits - self.bitcnt);
    }
    self.bitcnt = 0;

    var outbuf: [MAXCHUNKBITS]u8 = undefined; //a MAX input, rendered in base-2 (as worst-case)
    for (0..self.syms_per_chunk) |i| {
        outbuf[self.syms_per_chunk-i-1] = self.map.getsym(@truncate(self.bitbuf & self.sym_bitmask))
            catch unreachable; //failure is a bug in the .map construction
        self.bitbuf >>= self.sym_bits;
    }
    try self.downstream.writeAll(outbuf[0..symcnt]);

    if (symcnt < self.syms_per_chunk) {
        @branchHint(.unlikely);
        // mark silly padding in output stream, if requested
        if (self.map.properties.do_pad)
            if (self.map.properties.pad_char) |pad|
                try self.downstream.splatByteAll(pad, self.syms_per_chunk-symcnt);
    }
}


fn syms_to_bytes(self: *Self, input: []const u8) !void {
    for (input) |input_symbol| {
        self.input_ccount += 1;
        const symbol_index = self.map.symbol_to_index(input_symbol);
        if (symbol_index == .IGNORE) continue;
        const c = @intFromEnum(symbol_index);
        if (c >= self.map.nsym) {
            @branchHint(.unlikely);
            warn("{s}: could not interpret invalid symbol 0x{x} at position {d}\n",
                .{@src().file, input_symbol, self.input_ccount});
            return SymbolMappingFailure;
        }
        self.bitbuf = (self.bitbuf << self.sym_bits) | c;
        self.bitcnt += self.sym_bits;
        if (self.bitcnt >= BYTEBITS) {
            self.bitcnt -= BYTEBITS;
            self.bytebuf[self.bytecnt] = @truncate(self.bitbuf >> self.bitcnt);
            self.bytecnt += 1;
            if (self.bytecnt >= self.bytebuf.len)
                try self.emit_buffered_bytes();
        }
    }
}

fn emit_buffered_bytes(self: *Self) Writer.Error!void {
    try self.downstream.writeAll(self.bytebuf[0..self.bytecnt]);
    self.bytecnt = 0;
    //on final flush, any trailing bits are treated as padding that we don't care about
}
