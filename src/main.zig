const std = @import("std");
const zigcli = @import("zigcli");
const build_options = @import("build_options");
const SymbolMap = @import("SymbolMap.zig");
const FilesReader = @import("FilesReader.zig");
const WrappingWriter = @import("WrappingWriter.zig");
const BitShifter = @import("BitShifter.zig");
const Bubblebabble = @import("Bubblebabble.zig");
const Chunker = @import("Chunker.zig");
const Proquint = @import("Proquint.zig");
const Variadic62 = @import("Variadic62.zig");
const Variadic91 = @import("Variadic91.zig");
const Io = std.Io;
const assert = std.debug.assert;
const mem = std.mem;

pub const CodingDirection = enum { BytesToSyms, SymsToBytes };

const FailReason = enum (u8) {
    UserError = 1,
    IoError = 2,
    UnimplementedError = 3,
    InternalError = 4,
};

const FilterState = union (SymbolMap.EncodingType) {
    BitShifter: BitShifter,
    Bubblebabble: Bubblebabble,
    Chunker: Chunker,
    Identity: void, //trivial "transform"
    Proquint: Proquint,
    Variadic62: Variadic62,
    Variadic91: Variadic91,
    Bignum: void, //NYI
};

const cmdline_options = struct {
    ibase: []const u8 = "raw",
    obase: []const u8 = "raw",
    list_bases: bool = false,
    wrap_column:usize = 78, // for output
    generate_padding: bool = false, // for output
    use_upper: bool = false, // for output
    //NYI: strict_padding: ?bool = false, // for input
    //NYI: strict_case: ?bool = false, // for input
    help: bool = false,
    version: bool = false,

    pub const __shorts__ = .{
        .ibase = .i,
        .obase = .o,
        .list_bases = .l,
        .generate_padding = .g,
        .use_upper = .U,
        .wrap_column = .w,
        .help = .h,
        .version = .V,
    };

    pub const __messages__ = .{
        .ibase = "Input base ",
        .obase = "Output base ",
        .wrap_column = "column to wrap on (for output; 0=no wrapping) ",
        .generate_padding = "generate padding markers for output",
        .use_upper = "force output to use upper-case alphabetics",
    };
};

const cli_parse_opts: zigcli.structargs.ParseOptions = .{
    .argument_prompt = "[file ...]",
    .version_string = build_options.version,
    .print_help_and_exit = true,
    .print_help_on_error = true,
};

pub fn main(init: std.process.Init) !void {
    const ignoresig: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL}, .mask = @splat(0), .flags = 0 };
    std.posix.sigaction(.PIPE, &ignoresig, null); //die silently on SIGPIPE
    const io = init.io;
    const gpa = init.gpa;
    const BUFSZ = 8192; //chosen for efficient I/O
    var ibuf: [BUFSZ]u8 = undefined;
    var obuf: [BUFSZ]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &obuf);
    defer stdout.interface.flush() catch { fail(.IoError, "error: stdout flush failed\n", .{}); };
    var sink: *Io.Writer = &stdout.interface;

    const opts = zigcli.structargs.parse(gpa, io, init.minimal.args, cmdline_options, cli_parse_opts)
        catch std.process.exit(1);
    defer opts.deinit();
    if (opts.options.list_bases)
        return SymbolMap.list_bases(&stdout.interface, build_options.version);
    var reader = try FilesReader.init(io, opts.positional_arguments, &ibuf);
    const ibase = try get_ibase(opts.options.ibase, &reader.interface) orelse
        fail(.UserError, "requested input base '{s}' is not recognized\n", .{opts.options.ibase});
    try maybe_emit_multibase_marker(opts.options.obase, sink);
    var obase = SymbolMap.findmap(opts.options.obase) orelse
        fail(.UserError, "requested output base '{s}' is not recognized\n", .{opts.options.obase});
    if (opts.options.use_upper) {
        if (!obase.properties.case_insensitive)
            fail(.UserError, "symbol set for output base is not case insensitive; rejecting '-u' request\n", .{});
        obase.properties.use_upper = true;
    }
    if (opts.options.generate_padding) obase.properties.do_pad = true;

    var wrapper = WrappingWriter.init(sink, opts.options.wrap_column,
            obase.properties.word_len, obase.properties.word_sep);
    if (obase.encoding != .Identity and (opts.options.wrap_column > 0 or
            (obase.properties.word_len > 0 and obase.properties.word_sep != null)))
        sink = &wrapper.interface;
    var to_syms_state = get_filter(sink, &obase, .BytesToSyms);
    sink = get_write_stream(sink, &to_syms_state);
    var to_bytes_state = get_filter(sink, &ibase, .SymsToBytes);
    sink = get_write_stream(sink, &to_bytes_state);
    defer sink.flush() catch fail(.IoError, "error: flush failed\n", .{});

    while (true) {
        const data = reader.interface.peekGreedy(1) catch "";
        if (data.len == 0) break;
        try sink.writeAll(data);
        reader.interface.toss(data.len);
    }
}


pub fn fail(kind: FailReason, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    std.process.exit(@intFromEnum(kind));
}

fn get_filter(downstream: *Io.Writer, map: *const SymbolMap, direction: CodingDirection) FilterState {
    return switch (map.encoding) {
        .BitShifter => .{ .BitShifter = BitShifter.init(downstream, map, direction), },
        .Bubblebabble => .{ .Bubblebabble = Bubblebabble.init(downstream, map, direction), },
        .Chunker => .{ .Chunker = Chunker.init(downstream, map, direction), },
        .Identity => .Identity,
        .Proquint => .{ .Proquint = Proquint.init(downstream, map, direction), },
        .Variadic62 => .{ .Variadic62 = Variadic62.init(downstream, map, direction), },
        .Variadic91 => .{ .Variadic91 = Variadic91.init(downstream, map, direction), },
        .Bignum => fail(.UnimplementedError, "Bignum encodings are NYI\n", .{}),
    };
}

fn get_ibase(ibase: []const u8, reader: *Io.Reader) !?SymbolMap {
    const mb_prefix = "multibase";
    if (!mem.eql(u8, ibase, mb_prefix)) return SymbolMap.findmap(ibase);
    const n = mb_prefix.len;
    var mb_buf: [12]u8 = undefined;
    assert(mb_buf.len >= n+2);
    @memcpy(mb_buf[0..n], mb_prefix);
    mb_buf[n] = '-';
    const b = try reader.takeByte();
    mb_buf[n+1] = b;
    return SymbolMap.findmap(mb_buf[0..n+2]);
}

fn get_write_stream(downstream: *Io.Writer, filter: *FilterState) *Io.Writer {
    return switch (filter.*) {
        .BitShifter => |*u| &u.interface,
        .Bubblebabble => |*u| &u.interface,
        .Chunker => |*u| &u.interface,
        .Identity => downstream,
        .Proquint => |*u| &u.interface,
        .Variadic62 => |*u| &u.interface,
        .Variadic91 => |*u| &u.interface,
        .Bignum => fail(.UnimplementedError, "Bignum encodings are NYI\n", .{}),
    };
}

fn maybe_emit_multibase_marker(obase: []const u8, sink: *Io.Writer) !void {
    const mb = "multibase-";
    if (mem.startsWith(u8, obase, mb)) {
        assert(obase.len == mb.len+1 or obase.len == mb.len);
        const b: u8 = if (obase.len > mb.len) obase[mb.len] else 0;
        try sink.writeByte(b);
    }
}
