//! The web view: the injected bridge, its configuration, and the settings a
//! window's page sees.
//!
//! An application normally never touches this module. It is public so that
//! tooling can build the same script the backend injects — for example to test
//! a page in a plain browser, or to bundle a copy of the bridge alongside a
//! frontend that is served from disk during development.

const std = @import("std");

pub const bridge = @import("bridge.zig");

/// The name the page uses to reach the framework: `window.myzig`.
pub const global_name = bridge.global_name;

/// The `webkit.messageHandlers` entry the bridge posts to. The same name is
/// used on every platform, so a page does not need to know which one it runs
/// on.
pub const message_handler_name = bridge.message_handler_name;

/// The bridge template as it is embedded in the framework, with its `@@…@@`
/// placeholders still in place.
pub const template = bridge.template;

/// Builds the bridge script for one window.
///
/// The returned slice is owned by the caller. `secret` is a per-process value
/// the backend compares against every inbound message, so a page open in an
/// unrelated browser cannot post to the framework's message handler.
pub fn script(
    allocator: std.mem.Allocator,
    secret: u64,
    window_id: u32,
) ![]u8 {
    return bridge.scriptWithConfig(allocator, secret, window_id);
}

test "the bridge built by this module is the one the backend injects" {
    const built = try script(std.testing.allocator, 1234, 7);
    defer std.testing.allocator.free(built);

    try std.testing.expect(std.mem.indexOf(u8, built, "var WINDOW_ID = 7;") != null);
    // No placeholder may survive: a leftover token is a syntax error in the
    // page, and the page reports it far from its cause.
    try std.testing.expect(std.mem.indexOf(u8, built, "@@") == null);
    try std.testing.expect(std.mem.indexOf(u8, built, global_name) != null);
}
