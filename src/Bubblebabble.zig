// Bubblebabble was introduced in a long-expired IETF draft; a copy was found at:
//   https://web.mit.edu/kenta/www/one/bubblebabble/spec/jrtrjwzi/draft-huima-01.txt
// (accessed 2023-09-05, in case one needs to use the Wayback Machine to find it.)
//
// Bubblebabble is used by openssh's ssh-keygen.  It is somewhat similar in
// sprit to proquint, but the details are different enough to merit distinct
// implementations (*sigh*).  [A big part of the implementation difference is
// that bubblebabble has rudimentary error detection capabilities.]
//
//Test vectors:
//   (empty string)  xexax
//   1234567890      xesef-disof-gytuf-katof-movif-baxux
//   Pineapple       xigak-nyryk-humil-bosek-sonax

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
const SymbolMappingFailure = error.WriteFailed; //XXX good enough? need to keep within Io.Writer.Error set...
const Self = @This();

map: *const SymbolMap,
interface: Writer,
downstream: *Writer,
runner: *const fn (self: *Self, input: []const u8) Writer.Error!void,
flusher: *const fn (self: *Self) Writer.Error!void,
nconsonant: u8,
nvowel: u8,
bitbuf: @Int(.unsigned, CHUNKBITS) = 0, //where we accumulate partial inputs
bitcur: math.IntFittingRange(0, CHUNKBITS) = 0, //count of meaningful bits in bitbuf
checksum: u8 = 1,
carry_forward: u8 = 'x',
inbuf: [5]u8 = @splat(0),
in_pos: u3 = 1+CHUNKSYMS, //special "before first input" sentinel value
saw_final: bool = false,
input_ccount: usize = 0,

pub fn init(downstream: *Writer, map: *const SymbolMap, dir: CodingDirection) Self {
    assert(map.symbols.len == 17);
    const vlen = if (map.vowels) |v| v.len else 0;
    assert(vlen == 6);
    return .{
        .map = map,
        .downstream = downstream,
        .runner = if (dir == .BytesToSyms) bytes_to_syms else syms_to_bytes,
        .flusher = if (dir == .BytesToSyms) emit_buffered_syms else emit_bytes,
        .interface = .{
            .end = 0,  .buffer = &.{},
            .vtable = &.{ .drain = drain, .flush = flush, },
        },
        .nconsonant = @intCast(map.symbols.len),
        .nvowel = @intCast(vlen),
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
        self.bitcur += BYTEBITS;
        if (self.bitcur >= CHUNKBITS)
            try self.emit_buffered_syms();
    }
}

fn emit_buffered_syms(self: *Self) !void {
    defer self.bitcur= 0;
    var o: [5]u8 = undefined;
    if (self.bitcur >= CHUNKBITS) {
        @branchHint(.likely);
        const vh = self.bitbuf >> BYTEBITS;
        const vl = self.bitbuf & 0xff;
        o[0] = self.carry_forward;
        o[1] = self.map.getvowel((((vh>>6) & 0x3) + self.checksum) % 6) catch return SymbolMappingFailure;
        o[2] = self.map.getsym((vh>>2) & 0xf) catch return SymbolMappingFailure;
        o[3] = self.map.getvowel(((vh & 0x3) + self.checksum/6) % 6) catch return SymbolMappingFailure;
        o[4] = self.map.getsym((vl>>4) & 0xf) catch return SymbolMappingFailure;
        self.carry_forward = self.map.getsym(vl & 0xf) catch return SymbolMappingFailure;
        self.update_checksum(vh, vl);
        try self.downstream.writeAll(&o);
    } else {
        var a: u16 = self.checksum % 6;
        var b: u16 = 16;
        var c: u16 = self.checksum / 6;
        if (self.bitcur > 0) {
            a = (((self.bitbuf >> 6) & 0x3) + self.checksum) % 6;
            b = (self.bitbuf >> 2) & 0xf;
            c = ((self.bitbuf & 0x3) + self.checksum/6) % 6;
        }
        o[0] = self.carry_forward;
        o[1] = self.map.getvowel(a) catch return SymbolMappingFailure;
        o[2] = self.map.getsym(b) catch return SymbolMappingFailure;
        o[3] = self.map.getvowel(c) catch return SymbolMappingFailure;
        o[4] = 'x';
        try self.downstream.writeAll(&o);
    }
}

fn syms_to_bytes(self: *Self, input: []const u8) !void {
    for (input) |input_symbol| {
        self.input_ccount += 1;
        const symbol_index = self.map.symbol_to_index(input_symbol);
        if (symbol_index == .IGNORE) continue;
        if (self.saw_final) {
            @branchHint(.unlikely);
            warn("extraneous input past final bubblebabble tuple\n", .{});
            return SymbolMappingFailure;
        }
        var v = @intFromEnum(symbol_index);
        if (self.in_pos >= 5) {
            @branchHint(.unlikely); //only the first time through
            if (v != 16) {
                warn("bubblebabble input did not start with 'x'\n", .{});
                return SymbolMappingFailure;
            }
            self.in_pos = 0;
            continue;
        }
        var sym_limit = self.nconsonant; // assume consonant until the following check...
        if (self.in_pos==0 or self.in_pos == 2) { //buffer positions for vowel inputs
            sym_limit = self.nvowel; //got a valid vowel
            v -%= VOWEL_FLAG; //wrapping is not a problem, because the subsequent unsigned comparison will correctly reject
        }
        if (v >= sym_limit) {
            warn("{s}: could not interpret invalid symbol 0x{x} at position {d}\n",
                .{@src().file, input_symbol, self.input_ccount});
            return SymbolMappingFailure;
        }
        self.inbuf[self.in_pos] = @intCast(v);
        self.in_pos += 1;
        if (self.in_pos == CHUNKSYMS-1  and  v == 16) {
            @branchHint(.unlikely);
            //looks like a concluding 'x'
            self.saw_final = true;
            if (self.inbuf[1] < 16) {
                try self.emit_bytes();
            } else if (self.inbuf[0] != self.checksum%6 or self.inbuf[1] != 16
                    or self.inbuf[2] != self.checksum/6 or self.inbuf[3] != 16) {
                warn("final bubblebabble checksum failed\n", .{});
                return SymbolMappingFailure;
            }
            self.in_pos = 0;
        } else if (self.in_pos >= CHUNKSYMS) {
            try self.emit_bytes();
        }
    }
}

fn emit_bytes(self: *Self) !void {
    if (self.in_pos == 0  or  self.in_pos > CHUNKSYMS) return;
    defer self.in_pos = 0;
    var outbuf: [2]u8 = undefined;
    const a = partial_check(self.inbuf[0], self.checksum);
    const b =  self.inbuf[1] & 0xf;
    const c = partial_check(self.inbuf[2], self.checksum/6);
    if (a>=4 or c>=4) {
        warn("internal bubblebabble checksum failed\n", .{});
        return SymbolMappingFailure;
    }
    const b1 = (a << 6) | (b << 2) | c;
    outbuf[0] = @intCast(b1);
    var bufcnt: usize = 1;
    if (self.in_pos == self.inbuf.len) {
        const b2 = (self.inbuf[3] << 4) | self.inbuf[4];
        outbuf[bufcnt] = @intCast(b2);
        bufcnt += 1;
        self.update_checksum(b1, b2);
    }
    try self.downstream.writeAll(outbuf[0..bufcnt]);
}

fn partial_check(v: u16, c: u8) u8 {
    const x = 6*256 + v - c; //constant is to ensure that the subtraction never wraps/overflows
    return @intCast(x % 6);
}

fn update_checksum(self: *Self, v1: u16, v2: u16) void {
    const ck: u16 = self.checksum;
    self.checksum = @intCast((5*ck + 7*v1 + v2) % 36);
}
