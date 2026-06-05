const std = @import("std");
const Io = std.Io;
const File = Io.File;
const Reader = Io.Reader;
const mem = std.mem;
const warn = std.debug.print;

files: []const [:0]const u8,
active_source: File,
active_source_valid: bool,
stdin: File,
io: Io,
cwd: Io.Dir,
interface: Reader = undefined,
const Self = @This();

pub fn init(io: Io, args: []const [:0]const u8, buffer: []u8) !Self {
    const stdin = File.stdin();
    var r = Self{
        .files = args[0..0],
        .active_source = stdin,
        .active_source_valid = true,
        .stdin = stdin,
        .io = io,
        .cwd = Io.Dir.cwd(),
        .interface = .{
            .buffer = buffer,  .end = 0,  .seek = 0,
            .vtable = &.{ .stream = Self.stream, },
        },
    };
    if (args.len > 0) {
        r.files = args;
        r.next_file();
    }
    return r;
}

fn next_file(self: *Self) void {
    if (self.active_source.handle != self.stdin.handle)
        self.active_source.close(self.io);
    self.active_source_valid = false;
    if (self.files.len == 0)
        return;
    const fname = mem.sliceTo(self.files[0], 0);
    self.files = self.files[1..];
    if (mem.eql(u8, fname, "-") or mem.eql(u8, fname, "/dev/stdin")) {
        self.active_source = self.stdin;
        self.active_source_valid = false;
    } else {
        if (self.cwd.openFile(self.io, fname, .{})) |f| {
            self.active_source = f;
            self.active_source_valid = true;
        } else |e| {
            warn("could not open file {s}: {t}\n", .{fname, e});
            // active_source_valid == false, so we will exit after flushing
        }
    }
}

fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Reader.StreamError!usize {
    const this: *Self = @fieldParentPtr("interface", r);
    const data = limit.slice(try w.writableSliceGreedy(1));
    var vec: [1][]u8 = .{data};
    while (this.active_source_valid) {
        if (this.active_source.readStreaming(this.io, &vec)) |n| {
            return n;
        } else |err| switch (err) {
            error.EndOfStream => this.next_file(),
            else => return error.ReadFailed,
        }
    }
    return error.EndOfStream;
}
