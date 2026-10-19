//! Verifies minisign signatures (https://jedisct1.github.io/minisign/). Only supports the
//! prehashed algorithm, which is what the ZSF signs its tarballs with.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;
const base64 = std.base64.standard.Decoder;

pub const PublicKey = struct {
    key_id: [8]u8,
    key: Ed25519.PublicKey,

    pub fn decode(b64: []const u8) error{InvalidPublicKey}!PublicKey {
        var bytes: [42]u8 = undefined;
        decodeBase64(&bytes, b64) catch return error.InvalidPublicKey;
        if (!std.mem.eql(u8, bytes[0..2], "Ed")) return error.InvalidPublicKey;
        return .{
            .key_id = bytes[2..10].*,
            .key = Ed25519.PublicKey.fromBytes(bytes[10..42].*) catch return error.InvalidPublicKey,
        };
    }
};

pub const Signature = struct {
    key_id: [8]u8,
    signature: Ed25519.Signature,
    /// a slice of the text passed to parse
    trusted_comment: []const u8,
    global_signature: Ed25519.Signature,

    pub const ParseError = error{ InvalidSignatureFile, UnsupportedAlgorithm };

    pub fn parse(text: []const u8) ParseError!Signature {
        var lines = std.mem.splitScalar(u8, text, '\n');
        if (!std.mem.startsWith(u8, nextLine(&lines), "untrusted comment: ")) return error.InvalidSignatureFile;

        var sig_bytes: [74]u8 = undefined;
        decodeBase64(&sig_bytes, nextLine(&lines)) catch return error.InvalidSignatureFile;
        // "Ed" is the legacy algorithm that signs the file contents directly
        if (!std.mem.eql(u8, sig_bytes[0..2], "ED")) return error.UnsupportedAlgorithm;

        const trusted_line = nextLine(&lines);
        const trusted_prefix = "trusted comment: ";
        if (!std.mem.startsWith(u8, trusted_line, trusted_prefix)) return error.InvalidSignatureFile;

        var global_bytes: [64]u8 = undefined;
        decodeBase64(&global_bytes, nextLine(&lines)) catch return error.InvalidSignatureFile;

        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len != 0) return error.InvalidSignatureFile;
        }
        return .{
            .key_id = sig_bytes[2..10].*,
            .signature = .fromBytes(sig_bytes[10..74].*),
            .trusted_comment = trusted_line[trusted_prefix.len..],
            .global_signature = .fromBytes(global_bytes),
        };
    }

    /// Verifies the trusted comment was signed by `key`, this doesn't verify the file.
    pub fn verifyTrustedComment(sig: Signature, key: PublicKey) error{BadSignature}!void {
        if (!std.mem.eql(u8, &sig.key_id, &key.key_id)) return error.BadSignature;
        var verifier = sig.global_signature.verifier(key.key) catch return error.BadSignature;
        verifier.update(&sig.signature.toBytes());
        verifier.update(sig.trusted_comment);
        verifier.verify() catch return error.BadSignature;
    }

    /// Returns the "file" field the ZSF puts in its trusted comments. Only meaningful after
    /// verifyTrustedComment succeeds.
    pub fn trustedFile(sig: Signature) ?[]const u8 {
        var fields = std.mem.splitScalar(u8, sig.trusted_comment, '\t');
        while (fields.next()) |field| {
            if (std.mem.startsWith(u8, field, "file:")) return field["file:".len..];
        }
        return null;
    }

    /// Verifies `hash` (the Blake2b512 hash of the file) was signed by `key`.
    pub fn verifyHash(sig: Signature, key: PublicKey, hash: *const [Blake2b512.digest_length]u8) error{BadSignature}!void {
        if (!std.mem.eql(u8, &sig.key_id, &key.key_id)) return error.BadSignature;
        sig.signature.verify(hash, key.key) catch return error.BadSignature;
    }
};

pub const Hasher = Blake2b512;

fn nextLine(lines: *std.mem.SplitIterator(u8, .scalar)) []const u8 {
    return std.mem.trimEnd(u8, lines.next() orelse "", "\r");
}

fn decodeBase64(out: []u8, b64: []const u8) !void {
    if (try base64.calcSizeForSlice(b64) != out.len) return error.InvalidLength;
    try base64.decode(out, b64);
}

const zsf_public_key = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U";
// https://ziglang.org/download/0.14.1/zig-x86_64-linux-0.14.1.tar.xz.minisig
const zsf_signature =
    "untrusted comment: signature from minisign secret key\n" ++
    "RUSGOq2NVecA2d2lir8hBZQBgqU4dezcQtz9T8Ss7rWcR7eGXze5FFz26g7rUlAkm2Sa+93+tsH8K5jQl4UaMZLEOLvsCetPsAo=\n" ++
    "trusted comment: timestamp:1748009016\tfile:zig-x86_64-linux-0.14.1.tar.xz\thashed\n" ++
    "VZx4p6rTfwd4qPZMPIstinMLfBRB/wLBWqJLGiYFrh+sXWlZ/XLmCVY1Uopb3sIGTDyBn/573CdkvAttWYlADQ==\n";

test "ZSF signature" {
    const key: PublicKey = try .decode(zsf_public_key);
    const sig: Signature = try .parse(zsf_signature);
    try sig.verifyTrustedComment(key);
    try std.testing.expectEqualStrings("zig-x86_64-linux-0.14.1.tar.xz", sig.trustedFile().?);

    // a mirror can't change which file the signature claims to be for
    const forged_text = try std.mem.replaceOwned(u8, std.testing.allocator, zsf_signature, "0.14.1.tar", "0.15.1.tar");
    defer std.testing.allocator.free(forged_text);
    const forged: Signature = try .parse(forged_text);
    try std.testing.expectEqualStrings("zig-x86_64-linux-0.15.1.tar.xz", forged.trustedFile().?);
    try std.testing.expectError(error.BadSignature, forged.verifyTrustedComment(key));
}

test "sign and verify" {
    const key_pair = try Ed25519.KeyPair.generateDeterministic(@splat(7));
    const key_id: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const content = "the file content";
    var hash: [Hasher.digest_length]u8 = undefined;
    Hasher.hash(content, &hash, .{});
    const trusted_comment = "timestamp:0\tfile:a.tar.xz";

    const encoder = std.base64.standard.Encoder;
    var key_b64: [encoder.calcSize(42)]u8 = undefined;
    _ = encoder.encode(&key_b64, &("Ed".* ++ key_id ++ key_pair.public_key.toBytes()));
    const sig_bytes = (try key_pair.sign(&hash, null)).toBytes();
    var sig_b64: [encoder.calcSize(74)]u8 = undefined;
    _ = encoder.encode(&sig_b64, &("ED".* ++ key_id ++ sig_bytes));
    const global_bytes = (try key_pair.sign(&(sig_bytes ++ trusted_comment.*), null)).toBytes();
    var global_b64: [encoder.calcSize(64)]u8 = undefined;
    _ = encoder.encode(&global_b64, &global_bytes);

    var text_buf: [512]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buf, "untrusted comment: x\r\n{s}\r\ntrusted comment: {s}\r\n{s}\r\n", .{
        sig_b64, trusted_comment, global_b64,
    });

    const key: PublicKey = try .decode(&key_b64);
    const sig: Signature = try .parse(text);
    try sig.verifyTrustedComment(key);
    try std.testing.expectEqualStrings("a.tar.xz", sig.trustedFile().?);
    try sig.verifyHash(key, &hash);

    var other_hash: [Hasher.digest_length]u8 = undefined;
    Hasher.hash("the file contenT", &other_hash, .{});
    try std.testing.expectError(error.BadSignature, sig.verifyHash(key, &other_hash));

    // a different key with the same key id
    const other_pair = try Ed25519.KeyPair.generateDeterministic(@splat(8));
    _ = encoder.encode(&key_b64, &("Ed".* ++ key_id ++ other_pair.public_key.toBytes()));
    const other_key: PublicKey = try .decode(&key_b64);
    try std.testing.expectError(error.BadSignature, sig.verifyTrustedComment(other_key));
    try std.testing.expectError(error.BadSignature, sig.verifyHash(other_key, &hash));
}

test "legacy signatures are rejected" {
    const legacy = try std.mem.replaceOwned(u8, std.testing.allocator, zsf_signature, "RUSGOq2N", "RWSGOq2N");
    defer std.testing.allocator.free(legacy);
    try std.testing.expectError(error.UnsupportedAlgorithm, Signature.parse(legacy));
}
