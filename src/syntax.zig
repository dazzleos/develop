//! Colouring Zig source code in Develop's editor (`kete.TextArea`).

const std = @import("std");
const kete = @import("kete");

const Highlight = kete.TextArea.Highlight;

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isIdent(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

fn identEnd(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and isIdent(text[i])) i += 1;
    return i;
}

fn numberEnd(text: []const u8, from: usize) usize {
    var i = from;
    const hex = i + 1 < text.len and text[i] == '0' and (text[i + 1] == 'x' or text[i + 1] == 'X');
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (std.ascii.isAlphanumeric(c) or c == '_') continue;
        if (c == '.' and i + 1 < text.len and std.ascii.isDigit(text[i + 1])) continue;
        if ((c == '+' or c == '-') and !hex and i > from and (text[i - 1] == 'e' or text[i - 1] == 'E')) continue;
        break;
    }
    return i;
}

fn quotedEnd(text: []const u8, from: usize) usize {
    const q = text[from];
    var i = from + 1;
    while (i < text.len) : (i += 1) switch (text[i]) {
        '\\' => i += 1,
        '\n' => return i,
        else => if (text[i] == q) return i + 1,
    };
    return text.len;
}

fn lineEnd(text: []const u8, from: usize) usize {
    return std.mem.indexOfScalarPos(u8, text, from, '\n') orelse text.len;
}

fn nextNonSpace(text: []const u8, from: usize) ?u8 {
    var i = from;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return if (i < text.len) text[i] else null;
}

fn mark(out: []Highlight, from: usize, to: usize, h: Highlight) void {
    @memset(out[from..@min(to, out.len)], h);
}

fn isOneOf(word: []const u8, comptime words: []const []const u8) bool {
    inline for (words) |w| if (std.mem.eql(u8, word, w)) return true;
    return false;
}

const zig_keywords = [_][]const u8{
    "addrspace", "align",          "allowzero", "and",      "anyframe", "asm",    "break",       "callconv",
    "catch",     "comptime",       "const",     "continue", "defer",    "else",   "enum",        "errdefer",
    "error",     "export",         "extern",    "fn",       "for",      "if",     "inline",      "linksection",
    "noalias",   "noinline",       "nosuspend", "opaque",   "or",       "orelse", "packed",      "pub",
    "resume",    "return",         "struct",    "suspend",  "switch",   "test",   "threadlocal", "try",
    "union",     "usingnamespace", "var",       "volatile", "while",
};

const zig_types = [_][]const u8{
    "bool",    "void",     "type",         "anytype",        "anyerror",     "anyopaque", "noreturn",
    "usize",   "isize",    "comptime_int", "comptime_float", "f16",          "f32",       "f64",
    "f80",     "f128",     "c_int",        "c_uint",         "c_long",       "c_ulong",   "c_char",
    "c_short", "c_ushort", "c_longlong",   "c_ulonglong",    "c_longdouble",
};

/// Comments, strings (and multi-line ones), characters, numbers, keywords,
/// types (the built-in ones, and names starting with a capital), builtins
/// (@import), constants (true, null, undefined, ...), and functions.
pub fn zig(text: []const u8, out: []Highlight) void {
    var i: usize = 0;
    var after_fn = false;
    while (i < text.len) {
        const c = text[i];
        if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            const end = lineEnd(text, i);
            mark(out, i, end, .comment);
            i = end;
        } else if (c == '\\' and i + 1 < text.len and text[i + 1] == '\\') {
            const end = lineEnd(text, i);
            mark(out, i, end, .string);
            i = end;
        } else if (c == '"' or c == '\'') {
            const end = quotedEnd(text, i);
            mark(out, i, end, .string);
            i = end;
        } else if (std.ascii.isDigit(c)) {
            const end = numberEnd(text, i);
            mark(out, i, end, .number);
            i = end;
        } else if (c == '@' and i + 1 < text.len and text[i + 1] == '"') {
            const end = quotedEnd(text, i + 1);
            if (after_fn) mark(out, i, end, .function);
            after_fn = false;
            i = end;
        } else if (c == '@' and i + 1 < text.len and isIdentStart(text[i + 1])) {
            const end = identEnd(text, i + 1);
            mark(out, i, end, .builtin);
            i = end;
        } else if (isIdentStart(c)) {
            const end = identEnd(text, i);
            const word = text[i..end];
            const dotted = i > 0 and text[i - 1] == '.';
            const h: Highlight = if (after_fn)
                .function
            else if (!dotted and isOneOf(word, &zig_keywords))
                .keyword
            else if (!dotted and isOneOf(word, &.{ "true", "false", "null", "undefined", "unreachable" }))
                .constant
            else if (!dotted and (isOneOf(word, &zig_types) or isIntType(word)))
                .type
            else if (nextNonSpace(text, end) == '(')
                .function
            else if (std.ascii.isUpper(word[0]))
                .type
            else
                .plain;
            mark(out, i, end, h);
            after_fn = !dotted and std.mem.eql(u8, word, "fn");
            i = end;
        } else {
            if (c != ' ' and c != '\t' and c != '\n') after_fn = false;
            i += 1;
        }
    }
}

fn isIntType(word: []const u8) bool {
    if (word.len < 2 or (word[0] != 'u' and word[0] != 'i')) return false;
    for (word[1..]) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

const testing = std.testing;

test "Zig syntax highlighting" {
    const src = "const x: u8 = @intCast(y); // n";
    var hs: [src.len]Highlight = @splat(.plain);
    zig(src, &hs);
    try testing.expectEqual(Highlight.keyword, hs[0]);
    try testing.expectEqual(Highlight.type, hs[9]);
    try testing.expectEqual(Highlight.builtin, hs[14]);
    try testing.expectEqual(Highlight.comment, hs[src.len - 1]);
}
