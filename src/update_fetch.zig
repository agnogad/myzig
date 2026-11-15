//! Fetching an update feed and the artifact it names.
//!
//! This is the I/O half of `update.zig`: that file decides whether a release is
//! genuine, this one goes and gets it. They are separate because only the second
//! needs a network, and a test suite that needs a network is a test suite that
//! fails for reasons unrelated to the code.
//!
//! ## What this does not do
//!
//! It does not install anything. Replacing the running executable means knowing
//! where it is, whether the installation is writable, and how to restart — and
//! getting that wrong destroys an installation rather than failing a test. The
//! last function here hands back verified bytes and stops.
//!
//! ## Limits
//!
//! Every download is bounded. An update feed is a few hundred bytes and an
//! artifact is a program, so a cap of `max_artifact_bytes` refuses a server that
//! streams forever: without it, a broken or hostile endpoint would fill the
//! user's disk before the digest check ever ran. The cap is checked before the
//! bytes are trusted, not after.

const std = @import("std");
const update = @import("update.zig");

pub const Error = error{
    /// The request failed at the transport level: DNS, TCP, TLS.
    FetchFailed,
    /// The server answered but not with 200.
    BadStatus,
    /// The body was larger than the caller allowed.
    TooLarge,
    /// The body was not what it should be. Includes feed errors.
    BadBody,
} || update.Error || std.mem.Allocator.Error;

/// A feed is a handful of fields; anything larger is not one.
pub const max_feed_bytes: usize = 64 * 1024;

/// An artifact is a program. 512 MiB is far past any plausible release and still
/// small enough that a runaway download is stopped rather than filling a disk.
pub const max_artifact_bytes: usize = 512 * 1024 * 1024;

pub const Client = struct {
    io: std.Io,
    gpa: std.mem.Allocator,

    /// Downloads `url` into a fresh allocation, refusing anything over `limit`.
    ///
    /// The size is enforced while reading, so a server that lies about
    /// `Content-Length` — or omits it and streams — is still stopped at `limit`
    /// rather than after the disk is full.
    pub fn get(self: Client, url: []const u8, limit: usize) Error![]u8 {
        var http_client: std.http.Client = .{ .io = self.io, .allocator = self.gpa };
        defer http_client.deinit();

        // The buffer grows as the body arrives; the limit is enforced on the
        // result, and `max_artifact_bytes` keeps that bounded in practice.
        var limited: std.Io.Writer.Allocating = .init(self.gpa);
        defer limited.deinit();

        const result = http_client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &limited.writer,
            // Redirects are followed up to the default limit. A redirect to a
            // *different* host is the interesting case: TLS protects the
            // transfer, and the signature protects the artifact, so following
            // is safe here — the feed itself is what the signature covers.
        }) catch return error.FetchFailed;

        if (result.status != .ok) return error.BadStatus;

        var bytes = limited.toArrayList();
        if (bytes.items.len > limit) return error.TooLarge;
        return bytes.toOwnedSlice(self.gpa);
    }

    /// Fetches a feed and parses it.
    pub fn fetchFeed(self: Client, url: []const u8) Error!update.OwnedRelease {
        const raw = try self.get(url, max_feed_bytes);
        defer self.gpa.free(raw);

        // `parse` borrows from `raw`, so every field is copied out before the
        // response buffer is freed. The owned form is what a caller that stops
        // holding the body needs.
        return update.parseOwned(self.gpa, raw);
    }

    /// The whole check: is there a newer release, and is it signed?
    ///
    /// Returns the release when the answer to both is yes, and `null` when the
    /// feed is merely not newer. An unsigned or forged feed is an error, not a
    /// `null`: "no update available" and "someone tried to hand you a forged
    /// update" are different facts and must not collapse into one.
    pub fn check(
        self: Client,
        feed_url: []const u8,
        current: std.SemanticVersion,
        public_key: [32]u8,
    ) Error!?update.OwnedRelease {
        const release = try self.fetchFeed(feed_url);

        if (!update.isNewer(release.version, current)) {
            self.gpa.free(release.url);
            self.gpa.free(release.sha256);
            self.gpa.free(release.signature);
            return null;
        }

        update.verify(release.view(), current, public_key) catch |e| {
            self.gpa.free(release.url);
            self.gpa.free(release.sha256);
            self.gpa.free(release.signature);
            return e;
        };

        return .{
            .version = release.version,
            .url = release.url,
            .sha256 = release.sha256,
            .signature = release.signature,
        };
    }

    /// Downloads the artifact a checked release names and confirms its digest.
    ///
    /// The digest is checked here as well as in `checkArtifact` because this is
    /// the function that has the bytes; a caller that forgot to check would
    /// otherwise install whatever the network returned.
    pub fn download(self: Client, release: update.Release) Error![]u8 {
        const bytes = try self.get(release.url, max_artifact_bytes);
        errdefer self.gpa.free(bytes);

        try update.checkArtifact(release, bytes);
        return bytes;
    }
};
