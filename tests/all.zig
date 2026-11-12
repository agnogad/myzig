//! Integration tests: these exercise MyZig through its public API only, the
//! way an application would. They run against the in-memory `testing`
//! backend, so they need no display.
const std = @import("std");
const myzig = @import("myzig");

test {
    std.testing.refAllDecls(myzig);
}
