//! Native UI toolkit: layout, painting and input in pure Zig.
//!
//! The toolkit has three layers, each testable on its own:
//!
//! * `geometry` — rectangles, colours, blending. No platform.
//! * `layout` — turns a tree of views into rectangles.
//! * `canvas` — a list of filled rectangles and glyph runs, which a backend
//!   either rasterises into a buffer or hands to the GPU.
//!
//! A window with `content = .native` gets a surface from the backend and draws
//! into it. Nothing here touches GTK, WebView2 or AppKit: a backend only
//! receives finished drawing commands.

pub const geometry = @import("geometry.zig");
pub const Rect = geometry.Rect;
pub const Edges = geometry.Edges;
pub const Color = geometry.Color;
pub const layout = @import("layout.zig");
pub const canvas = @import("canvas.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
