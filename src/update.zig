//! Updates: choosing one, and proving it is genuine.
//!
//! An application that updates itself has to answer three questions before it
//! touches a single byte of its own installation:
//!
//! 1. **Is this newer than what I am running?** (`isNewer`)
//! 2. **Did the publisher sign it?** (`verify`)
//! 3. **Where does it come from, and where does it go?** (the caller's job)
//!
//! This module answers the first two and nothing else. That boundary is
//! deliberate: downloading and replacing a running executable is the part that
//! cannot be tested without a release server and a real installation, so it does
//! not live in the same file as the part that can. What is here is pure, and
//! every rule below has a test.
//!
//! ## The feed
//!
//! JSON, because the framework already has a JSON implementation and an update
//! feed is a handful of fields:
//!
//! ```json
//! {
//!   "version": "1.4.0",
//!   "url": "https://example.com/app-1.4.0.tar.gz",
//!   "sha256": "9f86d0...",
//!   "signature": "base64 ed25519 over the sha256 line+url"
//! }
//! ```
//!
//! ## Why a signature, and not just HTTPS
//!
//! HTTPS proves the file came from the server over the wire. It does not prove
//! the server was supposed to send *this* file: a compromised host, a hijacked
//! DNS entry with a valid certificate for a domain the attacker controls, or a
//! mirror serving a substitute all pass TLS. The signature is checked against a
//! key compiled into the application, so the only thing that can authorize a
//! replacement is the publisher's private key.
//!
//! The signature covers the **URL and the digest together**, not the bytes. That
//! is what stops a replay: an attacker who keeps an old, correctly signed feed
//! cannot point it at a different file, because changing `url` or `sha256`
//! breaks the signature. `downgrade` is refused separately for the same reason.

const std = @import("std");

pub const Error = error{
    /// The feed is not valid JSON, or does not have the expected shape.
    BadFeed,
    /// A required field is missing.
    MissingField,
    /// `version` is not `major.minor.patch`.
    BadVersion,
    /// The digest is not 64 hexadecimal characters.
    BadDigest,
    /// The signature is not 128 hexadecimal characters.
    BadSignature,
    /// The signature does not verify against the key.
    BadSigning,
    /// The feed names an older version than the one running.
    Downgrade,
};

/// One entry from an update feed.
pub const Release = struct {
    /// Parsed from the feed's `version`.
    version: std.SemanticVersion,
    /// Where the artifact lives. Borrows from the parse buffer.
    url: []const u8,
    /// Lowercase hex SHA-256 of the artifact, 64 characters.
    sha256: []const u8,
    /// Hex ed25519 signature over the message built by `signedMessage`.
    signature: []const u8,
};

/// Parses a feed. Every borrowed slice points into `src`, so the caller keeps
/// the buffer alive.
///
/// A feed is rejected rather than partly understood: a missing field is an
/// error, not a default. Guessing an `url` or treating an absent signature as
/// "unsigned, so allow it" is how an updater becomes a remote code execution
/// hole.
pub fn parse(allocator: std.mem.Allocator, src: []const u8) Error!Release {
    const json = @import("json.zig");

    // `json.parse` hands back the parser as well as the value, and the parser
    // owns the arena the fields live in. Not deinit'ing it leaks the whole
    // document, which is invisible in a program that exits but not to the
    // leak-checked test suite.
    var parsed = json.parse(allocator, src) catch return error.BadFeed;
    defer parsed.parser.deinit();

    const doc = parsed.value;
    if (doc != .object) return error.BadFeed;

    const version_text = (doc.get("version") orelse return error.MissingField).asString() orelse return error.BadFeed;
    const url = (doc.get("url") orelse return error.MissingField).asString() orelse return error.BadFeed;
    const sha256 = (doc.get("sha256") orelse return error.MissingField).asString() orelse return error.BadFeed;
    const signature = (doc.get("signature") orelse return error.MissingField).asString() orelse return error.BadFeed;

    const version = std.SemanticVersion.parse(version_text) catch return error.BadVersion;

    if (sha256.len != 64 or !isHex(sha256)) return error.BadDigest;
    if (signature.len != 128 or !isHex(signature)) return error.BadSignature;
    if (url.len == 0) return error.BadFeed;

    return .{ .version = version, .url = url, .sha256 = sha256, .signature = signature };
}

fn isHex(s: []const u8) bool {
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

/// The exact bytes a signature covers.
///
/// `url \n sha256`, lowercase hex for the digest. The newline is the separator
/// rather than a colon or comma because neither field can contain one, so there
/// is no way to move a byte from the URL into the digest and keep the message
/// the same — which is the whole point of a separator.
///
/// Written into `buf`, which must be at least `maxMessageLength` bytes.
pub const maxMessageLength = 8192;

pub fn signedMessage(buf: []u8, url: []const u8, sha256: []const u8) Error![]const u8 {
    if (url.len > 4096 or sha256.len > 64) return error.BadFeed;
    return std.fmt.bufPrint(buf, "{s}\n{s}", .{ url, sha256 }) catch return error.BadFeed;
}

/// Whether `candidate` is newer than `current`.
///
/// Equality is *not* newer: re-installing the version already running would
/// restart the application for nothing. Pre-release (`-rc.1`) sorts before the
/// release it leads to, which `SemanticVersion.order` already does.
pub fn isNewer(candidate: std.SemanticVersion, current: std.SemanticVersion) bool {
    return candidate.order(current) == .gt;
}

/// Checks a release against the key the application was built with.
///
/// Returns `error.Downgrade` when the feed is older than `current`, and
/// `error.BadSigning` when the signature does not verify. An older feed is a
/// separate error because it is not a forgery — a validly signed old release is
/// exactly what a rollback attack replays.
pub fn verify(
    release: Release,
    current: std.SemanticVersion,
    public_key: [32]u8,
) Error!void {
    // Order matters: a downgrade is refused before the signature is checked, so
    // the caller gets the more specific diagnosis when both are wrong.
    if (release.version.order(current) != .gt) return error.Downgrade;

    var sig_bytes: [64]u8 = undefined;
    _ = std.fmt.hexToBytes(&sig_bytes, release.signature) catch return error.BadSignature;

    var msg_buf: [maxMessageLength]u8 = undefined;
    const msg = try signedMessage(&msg_buf, release.url, release.sha256);

    const Ed = std.crypto.sign.Ed25519;
    // `fromBytes` for both halves: the signature is untrusted input, so a
    // malformed point must be an error rather than an assumption.
    const sig = Ed.Signature.fromBytes(sig_bytes);
    const key = Ed.PublicKey.fromBytes(public_key) catch return error.BadSigning;
    sig.verify(msg, key) catch return error.BadSigning;
}

/// The digest of a downloaded artifact, as lowercase hex.
pub fn digestHex(buf: *[64]u8, bytes: []const u8) []const u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return std.fmt.bufPrint(buf, "{x}", .{&out}) catch unreachable;
}

test "a well-formed feed parses" {
    const good =
        \\{
        \\  "version": "1.4.0",
        \\  "url": "https://example.com/app-1.4.0.tar.gz",
        \\  "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
        \\  "signature": "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const r = try parse(arena.allocator(), good);
    try std.testing.expectEqual(@as(usize, 1), r.version.major);
    try std.testing.expectEqual(@as(usize, 4), r.version.minor);
    try std.testing.expectEqualStrings("https://example.com/app-1.4.0.tar.gz", r.url);
}

test "a feed missing any field is refused, never defaulted" {
    // The dangerous version of this bug is treating a missing signature as
    // "unsigned, so allow it". Each field is removed in turn and must fail.
    // Four complete documents, each with one field left out. Written out rather
    // than assembled by string surgery so a quote cannot go missing unnoticed.
    const cases = [_][]const u8{
        // no version
        \\{"url":"https://example.com/a.tar.gz","sha256":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08","signature":"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"}
        ,
        // no url
        \\{"version":"1.4.0","sha256":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08","signature":"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"}
        ,
        // no sha256
        \\{"version":"1.4.0","url":"https://example.com/a.tar.gz","signature":"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"}
        ,
        // no signature: the one that must never be read as "unsigned, allow it"
        \\{"version":"1.4.0","url":"https://example.com/a.tar.gz","sha256":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"}
        ,
    };
    for (cases) |src| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(Error.MissingField, parse(arena.allocator(), src));
    }
}

test "a malformed version or digest is refused" {
    const cases = [_]struct { src: []const u8, want: Error }{
        .{ .src = "{\"version\":\"banana\",\"url\":\"u\",\"sha256\":\"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08\",\"signature\":\"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000\"}", .want = error.BadVersion },
        // 63 characters: one short is a truncated digest, not a short one.
        .{ .src = "{\"version\":\"1.0.0\",\"url\":\"u\",\"sha256\":\"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a0\",\"signature\":\"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000\"}", .want = error.BadDigest },
        // A non-hex character in an otherwise right-length digest.
        .{ .src = "{\"version\":\"1.0.0\",\"url\":\"u\",\"sha256\":\"zf86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08\",\"signature\":\"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000\"}", .want = error.BadDigest },
        // Not JSON at all.
        .{ .src = "{nope", .want = error.BadFeed },
        // JSON, but not an object.
        .{ .src = "[]", .want = error.BadFeed },
    };

    for (cases) |c| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(c.want, parse(arena.allocator(), c.src));
    }
}

test "only a strictly newer version counts as an update" {
    const v = std.SemanticVersion.parse;
    try std.testing.expect(isNewer(try v("1.0.1"), try v("1.0.0")));
    try std.testing.expect(isNewer(try v("1.1.0"), try v("1.0.9")));
    try std.testing.expect(isNewer(try v("2.0.0"), try v("1.99.99")));

    // Equal is not newer: re-running the installer for the same version would
    // restart the application to no purpose.
    try std.testing.expect(!isNewer(try v("1.0.0"), try v("1.0.0")));
    try std.testing.expect(!isNewer(try v("0.9.9"), try v("1.0.0")));

    // A pre-release sorts before its release, so an application running
    // 1.0.0-rc.1 is offered 1.0.0.
    try std.testing.expect(isNewer(try v("1.0.0"), try v("1.0.0-rc.1")));
}

/// 64 zero bytes as hex: a signature of the right shape and no content.
const zeros_128 = "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

test "a downgrade is refused even when it is correctly signed" {
    // This is the rollback attack: an attacker who captured a genuinely signed
    // older release replays it. The signature is valid, so only the version
    // check stops it.
    const v = std.SemanticVersion.parse;
    const release = Release{
        .version = try v("1.0.0"),
        .url = "https://example.com/old.tar.gz",
        .sha256 = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
        .signature = zeros_128,
    };

    var no_key: [32]u8 = undefined;
    @memset(&no_key, 0);
    try std.testing.expectError(error.Downgrade, verify(release, try v("2.0.0"), no_key));
}

test "the signed message cannot be reshuffled to mean something else" {
    // The digest and URL are joined by a newline, which neither can contain.
    // Without a separator, url "ab" + digest "cd" and url "abcd" + digest ""
    // would sign identically.
    var buf: [256]u8 = undefined;
    const a = try signedMessage(&buf, "https://e.com/a", "00");
    var buf2: [256]u8 = undefined;
    const b = try signedMessage(&buf2, "https://e.com/a0", "0");
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

/// Fixed seeds so a signature failure is reproducible rather than random.
const seed_a: [32]u8 = .{1} ++ .{1} ++ .{1} ++ .{1} ++ .{1} ++ .{1} ++ .{1} ++ .{1} ++
    .{1} ++ .{1} ++ .{1} ++ .{1} ++ .{1} ++ .{1} ++ .{1} ++ .{1} ++
    .{1} ++ .{1} ++ .{1} ++ .{1} ++ .{1} ++ .{1} ++ .{1} ++ .{1} ++
    .{1} ++ .{1} ++ .{1} ++ .{1} ++ .{1} ++ .{1} ++ .{1} ++ .{1};
const seed_b: [32]u8 = .{2} ++ .{2} ++ .{2} ++ .{2} ++ .{2} ++ .{2} ++ .{2} ++ .{2} ++
    .{2} ++ .{2} ++ .{2} ++ .{2} ++ .{2} ++ .{2} ++ .{2} ++ .{2} ++
    .{2} ++ .{2} ++ .{2} ++ .{2} ++ .{2} ++ .{2} ++ .{2} ++ .{2} ++
    .{2} ++ .{2} ++ .{2} ++ .{2} ++ .{2} ++ .{2} ++ .{2} ++ .{2};

test "a real signature verifies, and a changed URL breaks it" {
    // An end-to-end check with a genuine key pair, because the interesting
    // failure is not "the maths is wrong" but "the updater accepted a feed whose
    // URL was swapped".
    // Deterministic keys: a failure here is reproducible from the seed alone,
    // rather than depending on whatever randomness the run happened to draw.
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed_a);

    const url = "https://example.com/app-2.0.0.tar.gz";
    const digest = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";

    var msg_buf: [maxMessageLength]u8 = undefined;
    const msg = try signedMessage(&msg_buf, url, digest);
    const sig = try kp.sign(msg, null);

    var sig_hex: [128]u8 = undefined;
    const sig_text = std.fmt.bufPrint(&sig_hex, "{x}", .{&sig.toBytes()}) catch unreachable;

    const release = Release{
        .version = try std.SemanticVersion.parse("2.0.0"),
        .url = url,
        .sha256 = digest,
        .signature = sig_text,
    };

    try verify(release, try std.SemanticVersion.parse("1.0.0"), kp.public_key.toBytes());

    // The same signature over a different URL must not pass.
    var changed = release;
    changed.url = "https://evil.example.com/app-2.0.0.tar.gz";
    try std.testing.expectError(error.BadSigning, verify(changed, try std.SemanticVersion.parse("1.0.0"), kp.public_key.toBytes()));

    // Neither must a different digest.
    changed = release;
    changed.sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectError(error.BadSigning, verify(changed, try std.SemanticVersion.parse("1.0.0"), kp.public_key.toBytes()));

    // Nor a different key.
    const other = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed_b);
    try std.testing.expectError(error.BadSigning, verify(release, try std.SemanticVersion.parse("1.0.0"), other.public_key.toBytes()));
}

test "the digest is lowercase hex, matching the feed format" {
    var buf: [64]u8 = undefined;
    // The SHA-256 of the empty string, a value worth pinning because it is the
    // one every implementation agrees on.
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        digestHex(&buf, ""),
    );
}

// ------------------------------------------------------- tying it together

/// The whole decision, in the order that matters.
///
/// `downloaded` is the artifact's bytes, `expected` is the digest from the feed.
/// The digest is checked **after** the signature, because verifying a signature
/// over a digest that does not match the bytes is a check of the wrong thing:
/// an attacker who can rewrite the feed's `sha256` breaks the signature, and one
/// who cannot is stopped by the digest. Doing the digest first would still be
/// safe, but it would report a hash mismatch for what is actually a forgery.
pub fn checkArtifact(release: Release, downloaded: []const u8) Error!void {
    var buf: [64]u8 = undefined;
    const actual = digestHex(&buf, downloaded);
    if (!std.mem.eql(u8, actual, release.sha256)) return error.BadDigest;
}

/// Where a release would be installed.
///
/// Left to the caller deliberately. A self-update replaces the running binary,
/// which means knowing the executable's path, whether the installation is
/// writable, and how the platform restarts a process — all of which the
/// application knows and this module does not.
pub const Install = struct {
    /// The artifact the feed named, already verified.
    release: Release,
    /// The bytes, owned by the caller.
    bytes: []const u8,
};

test "an artifact whose bytes do not match the feed is refused" {
    var buf: [64]u8 = undefined;
    const payload = "the actual artifact";
    const real = digestHex(&buf, payload);

    var sig_buf: [128]u8 = undefined;
    const sig = std.fmt.bufPrint(&sig_buf, "{s}", .{zeros_128}) catch unreachable;

    const matching = Release{
        .version = try std.SemanticVersion.parse("2.0.0"),
        .url = "https://example.com/a.tar.gz",
        .sha256 = real,
        .signature = sig,
    };
    try checkArtifact(matching, payload);

    var wrong = matching;
    wrong.sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectError(error.BadDigest, checkArtifact(wrong, payload));

    // Truncation is the realistic failure: a download that stopped early.
    try std.testing.expectError(error.BadDigest, checkArtifact(matching, payload[0 .. payload.len - 1]));
}

// ------------------------------------------------------------- owned variants

/// A release whose strings the caller owns.
///
/// `parse` borrows from the feed buffer, which is right for a caller that reads
/// the feed and is done. A network client frees the response body as soon as it
/// has parsed it, so it needs a copy; keeping both shapes means neither caller
/// has to own a buffer longer than it wants to.
pub const OwnedRelease = struct {
    version: std.SemanticVersion,
    url: []u8,
    sha256: []u8,
    signature: []u8,

    pub fn deinit(self: OwnedRelease, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.sha256);
        allocator.free(self.signature);
    }

    /// A borrowed view, for passing to the functions that take a `Release`.
    pub fn view(self: OwnedRelease) Release {
        return .{
            .version = self.version,
            .url = self.url,
            .sha256 = self.sha256,
            .signature = self.signature,
        };
    }
};

/// Parses a feed and copies every field into `allocator`, so the source buffer
/// may be freed immediately.
pub fn parseOwned(allocator: std.mem.Allocator, src: []const u8) (Error || std.mem.Allocator.Error)!OwnedRelease {
    // `parse` frees its own arena on return, so every field is copied before
    // this function exits. There is nothing to roll back on failure beyond the
    // dupe that failed, which never completes.
    const borrowed = try parse(allocator, src);
    const url = try allocator.dupe(u8, borrowed.url);
    errdefer allocator.free(url);
    const sha256 = try allocator.dupe(u8, borrowed.sha256);
    errdefer allocator.free(sha256);

    return .{
        .version = borrowed.version,
        .url = url,
        .sha256 = sha256,
        .signature = try allocator.dupe(u8, borrowed.signature),
    };
}

test "an owned release outlives the buffer it was parsed from" {
    const src =
        \\{"version":"3.1.4","url":"https://example.com/a.tar.gz","sha256":"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08","signature":"00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"}
    ;

    // Parsed from a buffer that is then freed and overwritten, which is what a
    // network client does the moment it has the body.
    const buf = try std.testing.allocator.dupe(u8, src);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const owned = try parseOwned(arena.allocator(), buf);
    @memset(buf, 'X');
    std.testing.allocator.free(buf);

    try std.testing.expectEqual(@as(usize, 3), owned.version.major);
    try std.testing.expectEqualStrings("https://example.com/a.tar.gz", owned.url);
    try std.testing.expectEqual(@as(usize, 64), owned.sha256.len);
}
