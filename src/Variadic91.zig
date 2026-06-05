const std = @import("std");
const CodingDirection = @import("root").CodingDirection;
const SymbolMap = @import("SymbolMap.zig");
const Writer = std.Io.Writer;
const assert = std.debug.assert;
const math = std.math;
const warn = std.debug.print;

const BYTEBITS = 8;
const SymbolMappingFailure = error.WriteFailed; //XXX good enough? need to keep within Io.Writer.Error set...
const Self = @This();

map: *const SymbolMap,
interface: Writer,
downstream: *Writer,
runner: *const fn (self: *Self, input: []const u8) Writer.Error!void,
flusher: *const fn (self: *Self) Writer.Error!void,
bitbuf: u32 = 0, //buffer for gathering bits
nbits: u5 = 0, //current shift-offset of values in .bitbuf
val_buf: u32 = 0,
have_one: bool = false,
input_ccount: usize = 0,

pub fn init(downstream: *Writer, map: *const SymbolMap, dir: CodingDirection) Self {
    assert(map.nsym == 91 and map.symbols.len == map.nsym);
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
        self.bitbuf |= @as(u32, c) << @intCast(self.nbits);
        self.nbits += BYTEBITS;
        if (self.nbits > 13)
            try self.emit_syms();
    }
}

fn put(self: *Self, v: u32) !void {
    const s = self.map.getsym(@intCast(v)) catch return SymbolMappingFailure;
    try self.downstream.writeByte(s);
}

fn emit_syms(self: *Self) !void {
    if (self.nbits == 0) return;
    var v: u32 = self.bitbuf & 0x1fff;
    if (self.nbits > 13) {
        if (v > 88) {
            self.bitbuf >>= 13;
            self.nbits -= 13;
        } else {
            v = self.bitbuf & 0x3fff;
            self.bitbuf >>= 14;
            self.nbits -= 14;
        }
        try self.put(v % 91);
        try self.put(v / 91);
    } else {
        try self.put(v % 91);
        if (self.nbits > 7  or  self.bitbuf > 90)
            try self.put(v / 91);
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
        if (!self.have_one) {
            self.val_buf = c;
            self.have_one = true;
            continue;
        }
        self.val_buf += c * 91;
        self.bitbuf |= self.val_buf << self.nbits;
        self.nbits += if ((self.val_buf & 0x1fff) > 88) 13 else 14;
        while (self.nbits >= BYTEBITS)
            try self.emit_bytes();
    }
}

fn emit_bytes(self: *Self) Writer.Error!void {
    if (!self.have_one) return;
    self.have_one = false;
    if (self.nbits < BYTEBITS) {
        @branchHint(.unlikely); // should only happen during final flush
        const sym: u8 = @truncate(self.bitbuf | (self.val_buf << self.nbits));
        try self.downstream.writeByte(sym);
        return;
    }
    while (self.nbits >= BYTEBITS) {
        const sym: u8 = @truncate(self.bitbuf);
        try self.downstream.writeByte(sym);
        self.bitbuf >>= BYTEBITS;
        self.nbits -= BYTEBITS;
    }
}
