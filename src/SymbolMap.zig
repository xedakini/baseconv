const std = @import("std");
const fail = @import("root").fail;
const ascii = std.ascii;
const math = std.math;
const mem = std.mem;
const warn = std.debug.print;
const String = []const u8; //a utf-8 encoded text string

pub const EncodingType = enum {
    BitShifter,
    Bubblebabble,
    Chunker,
    Identity,
    Proquint,
    Variadic62,
    Variadic91,
    Bignum, //requires slurping whole input, which I'm not ready to support yet
    //Dictionary, Emoji, //may or may not ever implement
};

const SymbolType = u16;
pub const VOWEL_FLAG: SymbolType = 0x1000;
const SYMBOL = enum (SymbolType) {
    // 0..=255: the value of a single byte
    // or with |VOWEL_FLAG to mark the byte as a "vowel" in CvCvC systems
    INVALID = 256, //most common entry in inverse mappings
    IGNORE, //silently ignore the presence of this symbol
    COMPRESSED_ZEROES, //special btoa/ascii85 symbol ('z')
    COMPRESSED_SPACES, //special btoa symbol ('y')
    EOF, //special btoa symbol ('x')
    _
};

const SymbolSetProperties = struct {
    skip_enumerate: bool = false, //omit enumerating this from --list output
    case_insensitive: bool = false, //alphabet works fine with any mix of case
    use_upper: bool = false, //for a case_insensitive alphabet, output upper case (instead of default lower)
    do_pad: bool = false, //for base32 and base64, this requests that we add the silly "=" padding markers
    pad_char: ?u8 = null, //character to use when marking padding on output, if padding is requested
    word_len: u8 = 0, //on output (for non-raw), how many symbols cluster in a "word"
    word_sep: ?u8 = null, //use this to seperate output words (based on .wordlen)
    spaces_compress: ?u8 = null, //a feature of some base85 variants
    zeroes_compress: ?u8 = null, //a feature of some base85 variants
    eof: ?u8 = null, //a middle-of-stream indicator for EOF
    chunk_syms: u8 = 0, //number of symbols in a "chunk" [for the .Chunker variants]
    reverse: bool = false, //treat symbols _within_ a chunk as little-endian (instead of default bigendian)
};


name: String,
description: String,
encoding: EncodingType,
symbols: String, //full alphabet for non-CvCvC systems, consonants in CvCvC systems
nsym: usize,
sym_bits: f32,
vowels: ?String = null, //for CvCvC systems
nvowels: usize,
symbol_by_index: [256]SYMBOL = @splat(.INVALID),
properties: SymbolSetProperties = .{},
state: [64]u8 = @splat(0),
nstate: usize = 0, //number of active bytes in .state
const Self = @This();

fn init(name: String, alphabet: String, description: String, encoding: EncodingType, properties: SymbolSetProperties) Self {
    var r: Self = .{
        .name = name,
        .description = description,
        .encoding = encoding,
        .symbols = alphabet,
        .nsym = alphabet.len,
        .sym_bits = 3 + math.log2(@as(f32, @floatFromInt(alphabet.len))),
        .nvowels = 0,
        .properties = properties,
    };
    r.initialize_index_map();
    return r;
}

fn init_cv(name: String, consonants: String, vowels: String, description: String,
            encoding: EncodingType, properties: SymbolSetProperties) Self {
    var r: Self = .{
        .name = name,
        .description = description,
        .encoding = encoding,
        .symbols = consonants,
        .nsym = consonants.len,
        .sym_bits = 3 + math.log2(@as(f32, @floatFromInt(consonants.len))),
        .vowels = vowels,
        .nvowels = vowels.len,
        .properties = properties,
    };
    r.initialize_index_map();
    return r;
}

fn is_case_insensitive(self: *Self) bool {
    const map = self.symbol_by_index;
    for ('a'..'z') |c| {
        if (map[c] != .INVALID and map[ascii.toUpper(c)] != .INVALID)
            return false;
    }
    return true;
}

fn initialize_index_map(self: *Self) void {
    @setEvalBranchQuota(4000); //we loop a fair bit in this initialization code...
    if (self.symbols.ptr == &IDENTITY) return;
    if (self.properties.pad_char) |p| self.symbol_by_index[p] = .IGNORE;
    for (" \t\r\n") |c| self.set_index_map(c,  .IGNORE);
    self.set_index_by_symbolpos(self.symbols, 0);
    self.set_index_by_symbolpos(self.vowels, VOWEL_FLAG);
    self.properties.case_insensitive = self.is_case_insensitive();
}

fn merge_props(base: *SymbolSetProperties, new: *const SymbolSetProperties) void {
    const ref = SymbolSetProperties { };
    // for each field in "new" which is not the default value,
    // overwrite said field in the "base" version
    inline for (std.meta.fields(SymbolSetProperties)) |f| {
        if (@field(new, f.name) != @field(ref, f.name))
            @field(base, f.name) = @field(new, f.name);
    }
}

fn multibase_lookup(key: []const u8) ?*const MultibaseEntry {
    const prefix = "multibase-";
    if ( ! mem.startsWith(u8, key, prefix)) return null;
    const mbtype = if (key.len > prefix.len) key[prefix.len] else 0;
    for (&multibase_map) |triple|
        if (triple[0] == mbtype) return &triple;
    warn("unknown/unsupported multibase key 0x{x}\n", .{mbtype});
    return null;
}

fn set_index_by_symbolpos(self: *Self, symlist: ?[]const u8, flag: SymbolType) void {
    const unwrapped_symlist = symlist orelse return;
    for (unwrapped_symlist, 0..) |s, i| {
        const idx: SYMBOL =  @enumFromInt(i | flag);
        self.symbol_by_index[s] = idx;
        if (self.properties.case_insensitive) {
            self.symbol_by_index[ascii.toUpper(s)] = idx;
            self.symbol_by_index[ascii.toLower(s)] = idx;
        }
    }
}

fn set_index_map(self: *Self, sym: ?u8, mapping: SYMBOL) void {
    if (sym) |s| {
        if (self.symbol_by_index[s] != .INVALID)
            fail(.InternalError, "symbol 0x{x} is multiply defined in {s}\n", .{s, self.name});
        self.symbol_by_index[s] = mapping;
    }
}

fn update_index_map(self: *Self) void {
    self.set_index_map(self.properties.word_sep, .IGNORE);
    self.set_index_map(self.properties.zeroes_compress, .COMPRESSED_ZEROES);
    self.set_index_map(self.properties.spaces_compress, .COMPRESSED_SPACES);
    self.set_index_map(self.properties.eof, .EOF);
}


pub fn findmap(name: []const u8) ?Self {
    //linear scans are sufficient here: the tables are not all that big,
    //and this fn is not called by any inner loop
    var key = name;
    var mb_wants_upper = false;
    if (multibase_lookup(key)) |triple| {
        key = triple[1];
        mb_wants_upper = triple[2];
    }

    var alias_props: ?SymbolSetProperties = null;
    for (&aliasmap) |triple| {
        if (mem.eql(u8, triple[0], key)) {
            key = triple[1];
            alias_props = triple[2];
            break;
        }
    }

    for (&allmap) |*map| {
        if (mem.eql(u8, map.name, key)) {
            var retval = map.*;
            if (alias_props) |*p| merge_props(&retval.properties, p);
            if (mb_wants_upper) retval.properties.use_upper = true;
            if (retval.properties.use_upper and ! retval.properties.case_insensitive) {
                warn("alphabet `{s}' is not case insensitive\n", .{retval.name});
                retval.properties.use_upper = false;
            }
            retval.update_index_map();
            return retval;
        }
    }
    return null;
}

pub inline fn getsym(self: *const Self, i: SymbolType) !u8 {
    if (i >= self.symbols.len) return error.UnrepresentableSymbol;
    const s = self.symbols[i];
    return if (self.properties.use_upper) ascii.toUpper(s) else s;
}

pub inline fn getvowel(self: *const Self, i: SymbolType) !u8 {
    const vowels = self.vowels orelse return error.VowelMappingNotFound;
    if (i >= vowels.len) return error.UnrepresentableSymbol;
    const s = vowels[i];
    return if (self.properties.use_upper) ascii.toUpper(s) else s;
}

pub fn list_bases(out: *std.Io.Writer, version: []const u8) !void {
    try out.writeAll(version);
    try out.writeAll("\n\nSupported bases:\n");
    try out.writeAll("\t256 (aka 'bytes', 'identity', 'raw')\n");
    for (allmap) |map| {
        if (map.properties.skip_enumerate or map.encoding == .Bignum) continue; //".Bignum" is unlikely to be implemented
        try out.print("\t{s} ({s})\n", .{map.name, map.description});
    }
    try out.print("\t{s} ({s})\n", .{"btoa", "a base85 encoding, similar to ascii85, but with spaces compression"});
    try out.print("\n" ++
        \\Multibase (https://github.com/multiformats/multibase) is supported in the following way:
        \\ "-i multibase"
        \\       will read the first byte of the input stream and interpret that as
        \\       the multibase identifier, and process the input accordingly.
        \\       One can also specify "-i multibase-X" to specifically choose
        \\       the "X" multibase encoding, but in this case *without* consuming
        \\       the first byte of the input stream for this purpose.
        \\ "-o multibase-X"
        \\       will encode the output stream according the the multibase identifier "X",
        \\       emitting the "X" as the first byte of the output stream to identify it.
        \\       For raw bytes, since the \0 character will not pass through argv,
        \\       use "multibase-" (with no suffix).
        \\
        \\Note that for bases up to 36, output defaults to lowercase, but '--use-upper'
        \\can be specified to change this. For input, bases up to 36 are parsed
        \\insensitive to case.
        // [NYI:] Arbitrary symbol sets can be chosen by prefixing
        // with a '*'; for example '-i "*abcd"' as an alternative symbol set for '4hex'.
        ++ "\n", .{});
}

pub inline fn symbol_to_index(self: *const Self, c: u8) SYMBOL {
    return self.symbol_by_index[c];
}


const IDENTITY = init_identity: {
    var a: [256]u8 = undefined;
    for (0..a.len) |i|  a[i] = i;
    break :init_identity a;
};
const U = IDENTITY['A'..'Z'+1];
const L = IDENTITY['a'..'z'+1];
const D = IDENTITY['0'..'9'+1];
const DLU = D++L++U;
const DUL = D++U++L;
const ULD = U++L++D;

const allmap = [_]Self {
    Self.init("2", DLU[0..2], "binary", .BitShifter, .{}),
    Self.init("4", DLU[0..4], "quarnary", .BitShifter, .{}),
    Self.init("8", DLU[0..8], "octal", .BitShifter, .{}),
    Self.init("16", DLU[0..16], "hexadecimal", .BitShifter, .{}),
    Self.init("modhex", "cbdefghijklnrtuv", "Yubico modhex", .BitShifter, .{}), //Yubico's "scan-code friendly" mapping
    Self.init("32", L++"234567", "rfc4648 base32", .BitShifter, .{.pad_char='=',}), //avoids "confusing" digits
    Self.init("32hex", DLU[0..32], "rfc4648 base32hex", .BitShifter, .{.pad_char='=',}), //traditional mapping
    Self.init("z32", "ybndrfg8ejkmcpqxot1uwisza345h769", "z-base-32", .BitShifter, .{}), //per https://philzimmermann.com/docs/human-oriented-base-32-encoding.txt
    Self.init("qr45", D++U++" $%*+-./:", "QR code oriented base45 (RFC 9285)", .Chunker, .{.chunk_syms=3, .reverse=true}), //used for compact QR coding of binary data
    Self.init("base58xrp", "rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz", "base58 - xrp/ripple", .Bignum, .{}),//where is this documented?
    Self.init("base58btc", "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz", "base58 - bitcoin", .Bignum, .{}),//where is this documented?
    // base58flickr: alias to base58btc; where is this documented?
    Self.init("base58ipfs", "123456789abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ", "base58 ipfs CID", .Bignum, .{}),//where is this documented?
    Self.init("base62glowfall", ULD, "a variadic length encoding version of base62", .Variadic62, .{}),
    Self.init("base62jxskiss", ULD, "a variadic length encoding version of base62, backwards reading", .Variadic62, .{.reverse=true, .skip_enumerate=true}), //NYI: must process input backwards — slurping whole input if not seekable
    Self.init("base62bignum", DUL, "bignum version of base62", .Bignum, .{}),//likely what Tahoe-LAFS uses for base62?
    Self.init("64url", ULD++"-_", "base64 - url", .BitShifter, .{.pad_char='=',}),
    Self.init("64mime", ULD++"+/", "base64 - mime", .BitShifter, .{.pad_char='=',}),
    Self.init("ascii85", IDENTITY['!'..'!'+85], "Adobe PDF base85", .Chunker, .{.chunk_syms=5, .zeroes_compress='z', .eof='~'}), //XXX technically, .eof is supposed to be "~>" substring
    Self.init("z85", DLU ++ ".-:+=^!/*?&<>()[]{}@%$#", "ZeroMQ base85", .Chunker, .{.chunk_syms=5}), //https://rfc.zeromq.org/spec:32/Z85/
    Self.init("rfc1924", DUL ++ "!#$%&()*+-;<=>?@^_`{|}~", "rfc1924 base85", .Chunker, .{.chunk_syms=20, .skip_enumerate=true}), //NYI: must use u128 to hold chunk //spec only covers the case of exactly one full chunk
    Self.init("base91", ULD ++ "!#$%&()*+,./:;<=>?@[]^_`{|}~\"", "a variadic length encoding of base91", .Variadic91, .{}), //omitted: \-"
    Self.init("raw", &IDENTITY, "raw 8-bit bytes", .Identity, .{.skip_enumerate=true,}),
    Self.init_cv("proquint", "bdfghjklmnprstvz", "aiou", "the proquint cvcvc pronounceable encoding", .Proquint, .{.word_len=5, .word_sep='-', .case_insensitive=true}),
    Self.init_cv("bubblebabble", "bcdfghklmnprstvzx", "aeiouy", "The bubblebabble cvcvc pronounceable encoding", .Bubblebabble, .{.word_len=5, .word_sep='-', .case_insensitive=true}),
    // base256emoji( ... ), //per https://github.com/multiformats/multibase/blob/master/rfcs/Base256Emoji.md
    // //diceware/OPIE words (various flavors/dictionaries) {.type=.Dictionary}
    // //any other "well-known" bases? variant alphabets?
};

const aliasmap = [_] struct{String, String, ?SymbolSetProperties} { //key, allmap_reference, extra_properties
    .{"binary", "2", null},  .{"base2", "2", null},  .{"hex2", "2", null},  .{"2hex", "2", null},
    .{"quarnary", "4", null},  .{"base4", "4", null},  .{"hex4", "4", null},  .{"4hex", "4", null},
    .{"base8", "8", null},  .{"hex8", "8", null},  .{"8hex", "8", null},  .{"octal", "8", null},  .{"octonary", "8", null},  .{"octonal", "8", null},
    .{"decimal", "base10", null},  .{"denary", "base10", null},
    .{"hex", "16", null},  .{"base16", "16", null},  .{"hex16", "16", null},  .{"16hex", "16", null},
    .{"hexadecimal", "16", null},  .{"sexadecimal", "16", null},  .{"hexadekamal", "16", null},  .{"senidary", "16", null},  .{"sedecimal", "16", null},
    .{"base32", "32", null},  .{"base32rfc4648", "32", null},  .{"base32hex", "32hex", null},  .{"base32hex", "32hex", null},
    .{"base32z", "z32", null},  .{"z-base-32", "z32", null},  .{"base32z", "z32", null},
    .{"45", "qr45", null},  .{"QR45", "qr45", null},  .{"rfc9285", "qr45", null},  .{"base45", "qr45", null},
    .{"bitcoin", "base58btc", null},
    .{"xrp", "base58xrp", null},  .{"ripple", "base58xrp", null},
    .{"flickr", "base58flickr", null},  .{"flicker", "base58flickr", null},
    .{"ipfscid", "base58ipfs", null},
    .{"62", "base62glowfall", null},  .{"62v", "base62glowfall", null},  .{"62variadic", "base62glowfall", null},  .{"62varcode", "base62glowfall", null},
    .{"62vr", "base62jxskiss", null},  .{"62variadic-reversed", "base62jxskiss", null},  .{"62varcode-reversed", "base62jxskiss", null},
    .{"64", "64mime", null},  .{"base64mime", "64mime", null},  .{"base64", "64mime", null},  .{"mime", "64mime", null},
    .{"base64url", "64url", null},  .{"url", "64url", null},
    .{"85", "ascii85", null},
    .{"91", "base91", null},  .{"91v", "base91", null},  .{"91variadic", "base91", null},  .{"91varcode", "base91", null},
    .{"256", "raw", null},  .{"bytes", "raw", null},  .{"identity", "raw", null},
    //augmented forms (i.e., with extra .properties):
    .{"32hexpad", "32", .{.do_pad=true}},
    .{"32pad", "32", .{.do_pad=true}},
    .{"64pad", "64mime", .{.do_pad=true}}, .{"64mimepad", "64mime", .{.do_pad=true}},
    .{"64urlpad", "64url", .{.do_pad=true}},
    .{"btoa", "ascii85", .{.zeroes_compress='z', .spaces_compress='y', .eof='x'}},
};

const MultibaseEntry = struct {u8, String, bool}; //key, allmap_reference, do_upper
const multibase_map = [_]MultibaseEntry {
    // https://github.com/multiformats/multibase
    // "Multibase-prefixes are encoding agnostic. "z" is "z", not 0x7a ("z" encoded as ASCII/UTF-8).
    // For example, in UTF-32, "z" would be [0x7a, 0x00, 0x00, 0x00]."
    .{0,   "256", false},
    .{'0', "2", false},
    .{'7', "8", false},
    .{'9', "base10", false},
    .{'b', "32", false},
    .{'B', "32", true},
    .{'c', "32pad", false},
    .{'C', "32pad", true},
    .{'f', "16", false},
    .{'F', "16", true},
    .{'h', "z32", false},
    .{'k', "base36", false},
    .{'K', "base36", true},
    .{'m', "64mime", false},
    .{'M', "64pad", false},
    .{'p', "proquint", false},
    .{'t', "32hexpad", false},
    .{'T', "32hexpad", true},
    .{'u', "64url", false},
    .{'U', "64urlpad", false},
    .{'v', "32hex", false},
    .{'V', "32hex", true},
    .{'z', "base58btc", false},
    .{'Z', "base58flickr", false},
    //.{'🚀', "base256emoji", false}, //no current plans to ever implement
};
