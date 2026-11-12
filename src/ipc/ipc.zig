//! Typed IPC between Zig and pages.
//!
//! * `protocol` — the wire format, owned here on both sides.
//! * `decode` — turning JSON arguments into Zig values, with range checks.
//! * `service` — the registry of callable methods.
//! * `exchange` — routing calls, replies, events and cancels per window.
//!
//! Application code rarely touches these directly: `myzig generate` writes the
//! adapter for each service method, and `App.bindAll` registers it. Hand-written
//! services use `service.Method` and `decode.Args`.

pub const protocol = @import("protocol.zig");
pub const decode = @import("decode.zig");
pub const service = @import("service.zig");
pub const exchange = @import("exchange.zig");

pub const Result = protocol.Result;
pub const Code = protocol.Code;
pub const Args = decode.Args;
pub const Exchange = exchange.Exchange;

test {
    @import("std").testing.refAllDecls(@This());
    _ = protocol;
    _ = decode;
    _ = service;
    _ = exchange;
}
