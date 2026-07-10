# `baseconv` - a tool for converting data between various representations

There are many specifications of ways to represent raw binary data using
constrained symbol sets.
As an example,
one very old and widely used representation is hexadecimal,
where each byte is interpreted as a pair of 4-bit nybbles,
and these nybbles are mapped into the sixteen symbols
   0123456789abcdef
.

This hexadecimal representation can work fine,
but it doubles the amount of storage or transmission needed for the data
relative to the use of raw bytes.
In the more general case,
one can map the 8-bit (or base-256) interpretation
of data as bytes into representations using other bases,
with symbol sets at least as large as the base being used.
The `baseconv` tool attempts to cover many such
bases that the author has felt a need to work with at one
time or another.

## Supported bases
As reported by `baseconv -l` :

  - 256 (aka 'bytes', 'identity', 'raw')
  - 2 (binary)
  - 4 (quarnary)
  - 8 (octal)
  - 16 (hexadecimal, using traditional 0-9 and a-f mapping)
  - modhex (a base-16 variant, using the Yubico "modhex" symbol set)
  - 32 ([rfc4648](https://www.rfc-editor.org/info/rfc4648/) base32)
  - 32hex ([rfc4648](https://www.rfc-editor.org/info/rfc4648/) base32hex)
  - z32 ([z-base-32](https://philzimmermann.com/docs/human-oriented-base-32-encoding.txt))
  - qr45 (QR code oriented [base45](https://www.rfc-editor.org/info/rfc9285/))
  - [base62glowfall](https://github.com/glowfall/base62) (a variadic length encoding version of base62)
  - 64mime ([base64](https://www.rfc-editor.org/info/rfc4648/) - mime variant)
  - 64url ([base64](https://www.rfc-editor.org/info/rfc4648/) - url variant)
  - z85 ([ZeroMQ](https://rfc.zeromq.org/spec:32/Z85/) base85)
  - ascii85 (Adobe PDF base85, including compression of runs of NUL (zero) bytes)
  - btoa (a base85 encoding, similar to ascii85, but also with spaces compression)
  - base91 (a variadic length encoding of base91)
  - proquint (the [proquint](https://arxiv.org/html/0901.4016) cvcvc pronounceable encoding)
  - bubblebabble (The [Bubble
    Babble](https://web.mit.edu/kenta/www/one/bubblebabble/spec/jrtrjwzi/draft-huima-01.txt) cvcvc pronouncable encoding)

In addition to the above,
several abbreviations and alternate spellings are supported;
one needs to consult the `SymbolMap.zig` source
to discover them all,
though an educated guess might suffice
for discovering the more obvious ones.

Furthermore, `baseconv` supports
"[multibase](https://github.com/multiformats/multibase)"
encodings.
For output,
one specifies the desired multibase entry using a `multibase-`*X*
template to use multibase type *X*.
(For example,
`multibase-h` refers to using the z32 symbol set and `multibase-B`
uses the upper-case rendition of the rfc4648 base-32 representation,
including its use of padding `=` symbols.)
Per the multibase specification,
the first byte of the output will declare what base was used to create
the rest of the output. For input,
one simply requests `-i multibase` ,
and the first byte of the input stream will be consulted to determine
how to interpret the rest of the data.


## Similar tools
None of the `baseconv` supported bases were invented here;
they all are essentially re-implementations of tools
developed elsewhere; `baseconv` just packages them all up
into a single tool.

GNU coreutils contains base32 and a base64 tools.
The `xxd` tool from the `vim` package can be used
to convert to and from hexadecimal representation.
The ancient `od` command can be used to convert
raw bytes to base 8, 10, or 16,
with various formatting options;
however, it does not offer a mechanism to
convert back to raw bytes.

uuencode is an old base-85 tool
(an implementation of which may be found in GNU sharutils).
It includes various features to aid in its purpose of
file transfer over constrained channels,
but which are not directly related to the task of
"base conversions";
consequently `baseconv` does not (currently)
make an attempt at supporting this format,
although there are three other base-85 variants
supported.

## Usage
```
    $ baseconv --help
    USAGE:
        baseconv [OPTIONS] [--] [file ...]

    OPTIONS:
     -i, --ibase STRING               Input base (default: raw)
     -o, --obase STRING               Output base (default: raw)
     -l, --list_bases
     -w, --wrap_column INTEGER        column to wrap on (for output; 0=no wrapping) (default: 78)
     -g, --generate_padding           generate padding markers for output
     -U, --use_upper                  force output to use upper-case alphabetics
     -h, --help
     -V, --version
```
Though in common usage one typically is either encoding raw
data to a desired `--obase`,
or decoding a representation back to raw bytes by
choosing a suitable `--ibase`,
it is perfectly acceptable, and supported,
to make a direct conversion from any supported
`--ibase` to any supported `--obase`
in a single `baseconv` invocation.

Note that the `--wrap-column` is ignored for `-o raw` output;
for all other symbol sets lines will be wrapped to stay within
this limit.
Note that word-oriented conversions
(currently, `proquint` and `bubblebabble`)
will avoid splitting words during line-wrapping,
and so lines may be a little shorter for these output bases.

For base-16 and base-32 output,
`baseconv` defaults to using lower-case letters;
upper-case can be chosen by the `--use-upper` option.

The `baseconv` tool prefers to omit padding symbols on output,
under the premise that they add no information not already
contained in the length of the resulting symbol stream.
However, RFC4648 explicitly requires adding a suitable
number of trailing `=` symbols such that a base32 encoding
will always be a multiple of eight symbols long,
and a base64 encoding will always be a multiple of
four symbols long.
The addition of these padding characters may be
requested with the `--generate_padding` option.
On input, padding characters are ignored just like
whitespace.
