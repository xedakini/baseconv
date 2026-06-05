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
const MAX_CHUNK_BYTES = 8; //the code below is not prepared to work with larger chunks
const MAX_CHUNK_SYMS = 12; //the code below is not prepared to work with larger chunks
const ChunkType = @Int(.unsigned, BYTEBITS*MAX_CHUNK_BYTES);
const Counter = u8;
const SymbolMappingFailure = error.WriteFailed; //XXX good enough? need to keep within Io.Writer.Error set...
const Self = @This();

//XXX note that the handling of .properties.reverse in the current code is written
//to handle QR45 encoding; it may or may not make sense in the more general case...

map: *const SymbolMap,
interface: Writer,
downstream: *Writer,
runner: *const fn (self: *Self, input: []const u8) Writer.Error!void,
flusher: *const fn (self: *Self) Writer.Error!void,
nsym: Counter,
log2_nsym: f32,
chunk_bytes: Counter,
chunk_syms: Counter,
bufbits: ChunkType = 0, //the integer ultimately representing the base-NSYM positional representation of a chunk
bufsyms: [MAX_CHUNK_SYMS]u8 = undefined, // because of the need to handle the .reverse property, we buffer pending symbols here
bufcnt: Counter = 0, //the count of inputs (bytes or syms, depending) currently encoded into bufbits
input_ccount: usize = 0,

pub fn init(downstream: *Writer, map: *const SymbolMap, dir: CodingDirection) Self {
    const nsym = map.nsym;
    assert(0 < nsym and nsym == map.symbols.len);
    const log2_nsym = math.log2(@as(f32, @floatFromInt(nsym)));
    const chunk_syms = map.properties.chunk_syms;
    assert(0 < chunk_syms);
    const chunk_bytes: u8 = @floor(chunk_syms * log2_nsym / 8);
    assert(0 < chunk_bytes and chunk_bytes <= MAX_CHUNK_BYTES);
    return .{
        .map = map,
        .downstream = downstream,
        .runner = if (dir == .BytesToSyms) bytes_to_syms else syms_to_bytes,
        .flusher = if (dir == .BytesToSyms) emit_syms else emit_bytes,
        .interface = .{
            .end = 0,  .buffer = &.{},
            .vtable = &.{ .drain = drain, .flush = flush, },
        },
        .nsym = @intCast(nsym),
        .log2_nsym = log2_nsym,
        .chunk_bytes = chunk_bytes,
        .chunk_syms = chunk_syms,
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
        self.bufbits = (self.bufbits << BYTEBITS) | c;
        self.bufcnt += 1;
        if (self.bufcnt >= self.chunk_bytes)
            try self.emit_syms();
    }
}

fn emit_syms(self: *Self) !void {
    if (self.bufcnt == 0) return;
    defer self.bufbits, self.bufcnt = .{0, 0};
    var sym_count: usize = self.chunk_syms;
    var v = self.bufbits;
    if (self.bufcnt < self.chunk_bytes) {
        @branchHint(.unlikely);
        //calculate the number of non-padding symbols in the chunk:
        sym_count = @ceil(self.bufcnt * BYTEBITS / self.log2_nsym);
    }
    if (sym_count == self.chunk_syms) {
        @branchHint(.likely);
        // check for, and handle, compression opportunities
        const p = self.map.properties;
        if (try self.emit_compressed(v, 0, p.zeroes_compress)) return;
        if (try self.emit_compressed(v, 0x20202020, p.spaces_compress)) return;
    }

    const reverse = self.map.properties.reverse;
    if (!reverse)
        v <<= @intCast(BYTEBITS * (self.chunk_bytes - self.bufcnt)); //apply padding
    var outbuf: [MAX_CHUNK_SYMS]u8 = undefined;
    const icount = if (reverse) sym_count else self.chunk_syms;
    for (0..icount) |i| {
        const d: @TypeOf(v) = v % self.nsym;
        v /= self.nsym;
        const index = if (reverse) i else self.chunk_syms-1-i;
        outbuf[index] = self.map.getsym(@truncate(d))
            catch unreachable; //failure is a bug in the .map construction
    }
    try self.downstream.writeAll(outbuf[0..sym_count]);
}

fn emit_compressed(self: *Self, input: ChunkType, reference: ChunkType, symbol: ?u8) !bool {
    if (input == reference) {
        @branchHint(.unlikely);
        if (symbol) |s| {
            try self.downstream.writeByte(s);
            return true;
        }
    }
    return false;
}


fn syms_to_bytes(self: *Self, input: []const u8) !void {
    if (MAX_CHUNK_SYMS < self.chunk_syms) {
        @branchHint(.cold);
        fail(.InternalError, "Chunker.syms_to_bytes() cannot handle {d}-symbol chunks\n", .{self.chunk_syms});
    }
    for (input) |input_symbol| {
        self.input_ccount += 1;
        const symbol_index = self.map.symbol_to_index(input_symbol);
        switch (symbol_index) {
            .IGNORE => {}, //no-op
            .EOF => break, //XXX FIXME need to signal "no further input will be read"
            .COMPRESSED_ZEROES => try self.downstream.splatByteAll(0, self.chunk_bytes),
            .COMPRESSED_SPACES => try self.downstream.splatByteAll(' ', self.chunk_bytes),
            else => {
                const c = @intFromEnum(symbol_index);
                if (c >= self.nsym) {
                    @branchHint(.unlikely);
                    warn("{s}: could not interpret invalid symbol 0x{x} at position {d}\n",
                        .{@src().file, input_symbol, self.input_ccount});
                    return SymbolMappingFailure;
                }
                self.bufsyms[self.bufcnt] = @intCast(c);
                self.bufcnt += 1;
                if (self.bufcnt >= self.chunk_syms)
                    try self.emit_bytes();
            }
        }
    }
}

fn emit_bytes(self: *Self) !void {
    if (self.bufcnt == 0) return;
    defer self.bufcnt = 0;
    var outbuf: [MAX_CHUNK_BYTES]u8 = undefined;
    var nbytes = self.chunk_bytes;
    if (self.bufcnt < self.chunk_syms) {
        @branchHint(.unlikely);
        nbytes = @floor(self.log2_nsym * @as(f32, @floatFromInt(self.bufcnt)) / BYTEBITS);
    }
    assert(nbytes < outbuf.len);

    var v: ChunkType = 0;
    if (self.map.properties.reverse) {
        for (0 .. self.bufcnt) |i|
            v = v*self.nsym + self.bufsyms[self.bufcnt-1-i];
        for (0..nbytes) |i|
            outbuf[i] = @truncate(v >> @intCast((nbytes-1-i) * BYTEBITS));
    } else {
        @memset(self.bufsyms[self.bufcnt..self.chunk_syms], self.nsym-1); //"pad" to full chunk using NSYM-1 "digits"
        for (0 .. self.chunk_syms) |i|
            v = v*self.nsym + self.bufsyms[i];
        for (0..nbytes) |i|
            outbuf[i] = @truncate(v >> @intCast((self.chunk_bytes-1-i) * BYTEBITS));
    }
    try self.downstream.writeAll(outbuf[0..nbytes]);
}
