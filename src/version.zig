//! MyZig's version.

const std = @import("std");

pub const semver = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 0,
};

pub const version_string = "0.1.0";

/// The IPC protocol version. The generated TypeScript client checks it and
/// refuses to talk to a runtime it does not match, so a stale client fails
/// loudly instead of misbehaving.
pub const protocol_version: u32 = 1;

test "version string matches semver" {
    try std.testing.expectEqual(0, semver.major);
    try std.testing.expectEqual(1, semver.minor);
    try std.testing.expectEqual(0, semver.patch);
    // The literal must agree with the structured value, so an update cannot
    // forget one of them.
    var buf: [32]u8 = undefined;
    const rendered = std.fmt.bufPrint(&buf, "{d}.{d}.{d}", .{ semver.major, semver.minor, semver.patch }) catch unreachable;
    try std.testing.expectEqualStrings(version_string, rendered);
}
