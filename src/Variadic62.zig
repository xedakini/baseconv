// implementation of https://github.com/glowfall/base62 .

// There also exists a variant https://github.com/jxskiss/base62 (written
// in Go). This is very similar to the "glowfall" Java implementation
// (referenced above), except that for some odd reason "jxskiss" decided to
// scan the input stream backwards from the end‽  Consequently we would first
// need to slurp the input into memory.  Since the primary use case for base-62
// is for identifiers, hashes, and public keys (and not more general purpose
// streams which might be huge), this is usually fine, but it still seems
// inconvenient and like a gratuitous incompatability...
// Since, at least at this time, I'm not interested in any "file slurping",
// the jxskiss variant will remain unimplemented.


const std = @import("std");
const root = @import("root");
const SymbolMap = @import("SymbolMap.zig");
const Writer = std.Io.Writer;
const assert = std.debug.assert;
const math = std.math;
const warn = std.debug.print;
const fail = root.fail;
const CodingDirection = root.CodingDirection;

const BYTEBITS = 8;
const SymbolMappingFailure = error.WriteFailed; //XXX good enough? need to keep within Io.Writer.Error set...
const Self = @This();

map: *const SymbolMap,
interface: Writer,
downstream: *Writer,
runner: *const fn (self: *Self, input: []const u8) Writer.Error!void,
flusher: *const fn (self: *Self) Writer.Error!void,
bitbuf: u16 = 0, //buffer for gathering bits
nbits: u4 = 0, //current shift-offset of values in .bitbuf
input_ccount: usize = 0,

pub fn init(downstream: *Writer, map: *const SymbolMap, dir: CodingDirection) Self {
    if (map.properties.reverse)
        fail(.UnimplementedError, "The base62jxskiss algorithm is unimplemented\n", .{});
    assert(map.nsym == 62 and map.symbols.len == map.nsym);
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
        self.bitbuf |= @as(u16, c) << self.nbits;
        self.nbits += BYTEBITS;
        while (self.nbits >= 6)
            try self.emit_syms();
    }
}

fn emit_syms(self: *Self) !void {
    if (self.nbits == 0) return;
    var b: u16 = self.bitbuf;
    const n: @TypeOf(self.nbits) = if ((b & 0x1e) == 0x1e) 5 else 6;
    if (self.nbits >= 6) {
        @branchHint(.likely);
        self.bitbuf >>= n;
        self.nbits -= n;
    } else {
        self.nbits = 0;
    }
    b &= if (n==5) 0x1f else 0x3f;
    // assert(b < 62);
    const sym = self.map.getsym(b) catch return SymbolMappingFailure;
    try self.downstream.writeByte(sym);
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
        if (c & 0x1e == 0x1e) {
            self.bitbuf = (self.bitbuf >> 5) | (c << 11);
            self.nbits += 5;
        } else {
            self.bitbuf = (self.bitbuf >> 6) | (c << 10);
            self.nbits += 6;
        }
        if (self.nbits >= BYTEBITS) {
            // would like to use "16-self.nbits" (which will safely be within u4 range),
            // but the compiler is balking; rewrite it in a less clear way that means
            // the same thing to keep the compiler's type-checking happy *sigh*
            const v = self.bitbuf >> (1 +% ~self.nbits);
            try self.downstream.writeByte(@truncate(v));
            self.nbits -= BYTEBITS;
        }
    }
}

fn emit_bytes(self: *Self) Writer.Error!void {
    _ = self;
    //any trailing bits are treated as padding that we don't care about
}
