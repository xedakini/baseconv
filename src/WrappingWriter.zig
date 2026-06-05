const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const warn = std.debug.print;
const Self = @This();

interface: Writer,
downstream: *Writer,
linewrap_col: u64,
word_len: u64,
word_sep: u8,
cur_col: u64 = 0,
cur_wordpos: u64 = 0,

const interface_vtable: Writer.VTable = .{
    .drain = drain,
    .flush = flush,
};

pub fn init(downstream: *Writer, linewrap_col: usize, word_len: usize, word_sep: ?u8) Self {
    const wsep = word_sep orelse 0;
    var wlen = if (wsep == 0) 0 else word_len;
    if (0 < linewrap_col and linewrap_col <= wlen) wlen = 0;
    return .{
        .downstream = downstream,
        .linewrap_col = if (0 < linewrap_col and linewrap_col < word_len) word_len else linewrap_col,
        .word_len = wlen,
        .word_sep = wsep,
        .interface = .{
            .buffer = &.{},
            .end = 0,
            .vtable = &interface_vtable,
        },
    };
}

fn putSlice(self: *Self, v: []const u8) !void {
    for (v) |c| {
        const want_wordsplit: bool = self.word_len > 0 and self.cur_wordpos >= self.word_len;
        const max_col = if (want_wordsplit) self.cur_col+1 else self.cur_col;
        if (c == '\n') {
            @branchHint(.unlikely);
            self.cur_col, self.cur_wordpos = .{0, 0};
        } else if (max_col >= self.linewrap_col and self.linewrap_col > 0) {
            try self.downstream.writeByte('\n');
            self.cur_col, self.cur_wordpos = .{0, 0};
        } else if (want_wordsplit) {
            const word_sep = self.word_sep;
            try self.downstream.writeByte(word_sep);
            self.cur_col += 1;
            self.cur_wordpos = 0;
        }
        try self.downstream.writeByte(c);
        self.cur_col += 1;
        self.cur_wordpos += 1;
    }
}

fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    const this: *Self = @fieldParentPtr("interface", w);
    assert(data.len > 0);
    var nout: usize = 0;
    for (data[0..(data.len-1)]) |v| {
        try this.putSlice(v);
        nout += v.len;
    }
    const v = data[data.len-1];
    for (0..splat) |_| {
        try this.putSlice(v);
        nout += v.len;
    }
    return nout;
}

fn flush(w: *Writer) Writer.Error!void {
    const this: *Self = @fieldParentPtr("interface", w);
    if (this.cur_col > 0 and this.linewrap_col > 0) try this.downstream.writeByte('\n');
    try this.downstream.flush();
}
