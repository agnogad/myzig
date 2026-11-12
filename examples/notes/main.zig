//! A complete application: notes with persistent storage, a menu bar, a tray
//! icon and typed IPC.
//!
//!     zig build notes
//!
//! This exists to be the thing the framework is judged against. The examples
//! beside it each prove one feature in isolation; this one has to make them
//! work together, the way a real program does, and it is what a framework's
//! gaps show up in.
//!
//! ## What it does
//!
//! Lists notes in the page, adds and deletes them from the page or the File
//! menu, saves them as JSON on every change, and offers a tray icon to show the
//! window again after it is closed.
//!
//! ## Where the data lives
//!
//! `$XDG_DATA_HOME/myzig-notes/notes.json`, or `~/.local/share/myzig-notes/`
//! when that is unset. The path is worked out through the framework's own env
//! helper, because Zig 0.17 removed `std.posix.getenv`.

const std = @import("std");
const myzig = @import("myzig");

/// The page and its script, embedded so the program runs from anywhere.
const frontend = [_]myzig.FrontendFile{
    .{
        .path = "index.html",
        .mime = "text/html; charset=utf-8",
        .data = @embedFile("assets/index.html"),
    },
    .{
        .path = "app.js",
        .mime = "text/javascript; charset=utf-8",
        .data = @embedFile("assets/app.js"),
    },
};

const Note = struct {
    /// Allocated from the app's allocator; freed when the note is deleted or
    /// the list is cleared.
    id: u64,
    title: []u8,
    body: []u8,
};

/// Everything the handlers touch. It lives in `main` so it outlives the loop,
/// and every handler runs on the main thread inside that loop, so reaching the
/// windows from here is safe.
const State = struct {
    app: *myzig.App,
    gpa: std.mem.Allocator,
    io: std.Io,
    notes: std.ArrayListUnmanaged(Note) = .empty,
    next_id: u64 = 1,
    /// Set when a change has not been written yet, so a burst of edits becomes
    /// one write.
    dirty: bool = false,
    window: ?myzig.Window = null,
    saved_path: ?[:0]u8 = null,

    fn deinit(self: *State) void {
        for (self.notes.items) |n| {
            self.gpa.free(n.title);
            self.gpa.free(n.body);
        }
        self.notes.deinit(self.gpa);
        if (self.saved_path) |p| self.gpa.free(p);
    }

    fn find(self: *State, id: u64) ?usize {
        for (self.notes.items, 0..) |n, i| {
            if (n.id == id) return i;
        }
        return null;
    }

    /// The note list as JSON, which is both the IPC reply and the file format.
    /// One shape means the page and the disk never disagree about what a note
    /// is.
    fn toJson(self: *State) []const u8 {
        reply_json.clearRetainingCapacity();

        // A list of `[title, body, id]` triples. The inner brackets were
        // missing in the first version, so the page received one flat array of
        // strings and a number and could not read it as a list of notes.
        write(&reply_json, self.gpa, "[") catch return "[]";
        for (self.notes.items, 0..) |n, i| {
            if (i > 0) write(&reply_json, self.gpa, ",") catch return "[]";
            write(&reply_json, self.gpa, "[") catch return "[]";
            writeJsonString(&reply_json, self.gpa, n.title) catch return "[]";
            write(&reply_json, self.gpa, ",") catch return "[]";
            writeJsonString(&reply_json, self.gpa, n.body) catch return "[]";
            var id_buf: [24]u8 = undefined;
            const id_text = std.fmt.bufPrint(&id_buf, ",{d}", .{n.id}) catch return "[]";
            write(&reply_json, self.gpa, id_text) catch return "[]";
            write(&reply_json, self.gpa, "]") catch return "[]";
        }
        write(&reply_json, self.gpa, "]") catch return "[]";

        // The buffer has to outlive the handler, so it lives in a module-level
        // slot rather than being freed here. The next call replaces it.
        return reply_json.items;
    }
};

/// The reply buffer. A `json.Value` returned from a handler must outlive the
/// call, so the text lives here until the next call replaces it.
var reply_json: std.ArrayListUnmanaged(u8) = .empty;
var scratch: [4096]u8 = undefined;

fn write(list: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    try list.appendSlice(gpa, text);
}

fn writeJsonString(list: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    try list.append(gpa, '"');
    for (text) |c| {
        switch (c) {
            '"' => try list.appendSlice(gpa, "\\\""),
            '\\' => try list.appendSlice(gpa, "\\\\"),
            '\n' => try list.appendSlice(gpa, "\\n"),
            '\r' => try list.appendSlice(gpa, "\\r"),
            '\t' => try list.appendSlice(gpa, "\\t"),
            // A control character would make the JSON invalid, so it becomes an
            // escape rather than an invalid file on disk.
            else => if (c < 0x20) {
                var esc: [6]u8 = undefined;
                const s2 = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}) catch continue;
                try list.appendSlice(gpa, s2);
            } else {
                try list.append(gpa, c);
            },
        }
    }
    try list.append(gpa, '"');
}

// ------------------------------------------------------------------ services

fn listNotes(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    _ = args;
    const state: *State = @ptrCast(@alignCast(ctx.?));
    // `successRaw` sends JSON as JSON. `success(.{.string = ...})` would send a
    // string containing JSON, and the page would get text where it expected an
    // array — which is exactly the bug this line fixes.
    return myzig.ipc.Result.successRaw(state.toJson());
}

/// Adds a note and returns its id, or an error the caller can report.
///
/// The page and the File menu both come through here: a menu click that made a
/// note some other way could disagree with the page about what a note is.
fn createNote(state: *State, title: []const u8, body: []const u8) error{OutOfMemory}!u64 {
    const owned_title = try state.gpa.dupe(u8, title);
    errdefer state.gpa.free(owned_title);
    const owned_body = try state.gpa.dupe(u8, body);

    var note = Note{ .id = state.next_id, .title = owned_title, .body = owned_body };
    // An untitled note still needs a name in the list, or the row is blank and
    // impossible to click deliberately.
    if (note.title.len == 0) {
        state.gpa.free(note.title);
        note.title = state.gpa.dupe(u8, "Untitled") catch {
            state.gpa.free(note.body);
            return error.OutOfMemory;
        };
    }
    state.next_id += 1;

    state.notes.append(state.gpa, note) catch {
        state.gpa.free(note.title);
        state.gpa.free(note.body);
        return error.OutOfMemory;
    };
    state.dirty = true;
    // Written now rather than at exit: a program that is killed instead of
    // quit would otherwise lose everything the user typed.
    save(state, state.io);

    // The page is told, so a change made from the menu reaches a page that did
    // not ask for it.
    _ = state.app.emit("notes:changed", .{ .string = state.toJson() });
    return note.id;
}

fn addNote(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    var a = args;
    // Bounded on both sides: a title is a title, and a 2 GB one is a bug in the
    // caller rather than a note to store.
    const title = a.stringBounded(200) catch |e| return myzig.ipc.Args.toResult(e);
    const body = a.stringBounded(8000) catch |e| return myzig.ipc.Args.toResult(e);

    const id = createNote(state, title, body) catch
        return myzig.ipc.Result.fail(.internal, "out of memory");

    const text = std.fmt.bufPrint(&scratch, "{d}", .{id}) catch "0";
    return myzig.ipc.Result.success(.{ .number = text });
}

/// Replaces a note's text. Without this a note could be written once and never
/// corrected, which is not a note application.
fn updateNote(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    var a = args;
    const raw = a.stringBounded(20) catch |e| return myzig.ipc.Args.toResult(e);
    const title = a.stringBounded(200) catch |e| return myzig.ipc.Args.toResult(e);
    const body = a.stringBounded(8000) catch |e| return myzig.ipc.Args.toResult(e);

    const id = std.fmt.parseInt(u64, raw, 10) catch
        return myzig.ipc.Result.fail(.invalid_argument, "note id is not a number");
    const index = state.find(id) orelse
        return myzig.ipc.Result.fail(.invalid_argument, "no note with that id");

    // The new text is allocated before the old is freed, so a failure to
    // allocate leaves the note as it was rather than empty.
    const new_title = state.gpa.dupe(u8, if (title.len == 0) "Untitled" else title) catch
        return myzig.ipc.Result.fail(.internal, "out of memory");
    const new_body = state.gpa.dupe(u8, body) catch {
        state.gpa.free(new_title);
        return myzig.ipc.Result.fail(.internal, "out of memory");
    };

    state.gpa.free(state.notes.items[index].title);
    state.gpa.free(state.notes.items[index].body);
    state.notes.items[index].title = new_title;
    state.notes.items[index].body = new_body;
    state.dirty = true;
    save(state, state.io);

    _ = state.app.emit("notes:changed", .{ .string = state.toJson() });
    return myzig.ipc.Result.success(.null);
}

fn deleteNote(ctx: ?*anyopaque, args: myzig.ipc.Args) myzig.ipc.Result {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    var a = args;
    const raw = a.stringBounded(20) catch |e| return myzig.ipc.Args.toResult(e);
    const id = std.fmt.parseInt(u64, raw, 10) catch
        return myzig.ipc.Result.fail(.invalid_argument, "note id is not a number");

    const index = state.find(id) orelse
        return myzig.ipc.Result.fail(.invalid_argument, "no note with that id");

    const removed = state.notes.orderedRemove(index);
    state.gpa.free(removed.title);
    state.gpa.free(removed.body);
    state.dirty = true;
    save(state, state.io);

    _ = state.app.emit("notes:changed", .{ .string = state.toJson() });
    return myzig.ipc.Result.success(.null);
}

// ------------------------------------------------------------------- storage

/// The data directory, created if it is missing.
fn dataDir(gpa: std.mem.Allocator) ![]u8 {
    const base = myzig.env.get("XDG_DATA_HOME") orelse blk: {
        const home = myzig.env.get("HOME") orelse return error.NoHome;
        break :blk try std.fmt.allocPrint(gpa, "{s}/.local/share", .{home});
    };
    // `XDG_DATA_HOME` is borrowed from the environment, so the joined path is
    // the only thing that needs freeing; the caller owns it either way.
    defer if (myzig.env.get("XDG_DATA_HOME") == null) gpa.free(base);

    return std.fmt.allocPrint(gpa, "{s}/myzig-notes", .{base});
}

fn savePath(gpa: std.mem.Allocator) ![]u8 {
    const dir = try dataDir(gpa);
    defer gpa.free(dir);
    return std.fmt.allocPrint(gpa, "{s}/notes.json", .{dir});
}

/// Writes the notes, creating the directory the first time.
fn save(state: *State, io: std.Io) void {
    const path = savePath(state.gpa) catch {
        myzig.log.err("notes: cannot work out where to save", .{});
        return;
    };
    defer state.gpa.free(path);

    // The directory is created from the path's own parent, so a first run
    // needs no install step.
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        std.Io.Dir.cwd().createDirPath(io, path[0..slash]) catch |e| {
            myzig.log.err("notes: cannot create {s}: {s}", .{ path[0..slash], @errorName(e) });
            return;
        };
    }

    // The file is written the way the page reads it: the same JSON the service
    // returns.
    const json = state.toJson();
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json }) catch |e| {
        myzig.log.err("notes: cannot write {s}: {s}", .{ path, @errorName(e) });
        return;
    };

    if (state.saved_path) |old| state.gpa.free(old);
    // Zig 0.17 removed `dupeZ`, so the terminator is added by hand.
    const owned = state.gpa.alloc(u8, path.len + 1) catch null;
    if (owned) |b| {
        @memcpy(b[0..path.len], path);
        b[path.len] = 0;
        state.saved_path = b[0..path.len :0];
    }
    state.dirty = false;
    myzig.log.debug("notes: saved {d} notes to {s}", .{ state.notes.items.len, path });
}

/// Reads the notes back. A missing file is a first run, not a failure.
fn load(state: *State, io: std.Io) void {
    const path = savePath(state.gpa) catch return;
    defer state.gpa.free(path);

    const text = std.Io.Dir.cwd().readFileAlloc(io, path, state.gpa, .limited(8 * 1024 * 1024)) catch |e| {
        switch (e) {
            error.FileNotFound => myzig.log.debug("notes: no saved notes; starting empty", .{}),
            else => myzig.log.err("notes: cannot read {s}: {s}", .{ path, @errorName(e) }),
        }
        return;
    };
    defer state.gpa.free(text);

    var parser = myzig.json.Parser.init(state.gpa, text);
    const value = parser.parse() catch |e| {
        // A corrupt file is reported and then left alone: overwriting someone's
        // notes because they are unreadable is worse than starting empty.
        myzig.log.err("notes: {s} is not valid JSON ({s}); starting empty", .{ path, @errorName(e) });
        return;
    };
    defer parser.deinit();

    const array = switch (value) {
        .array => |a| a,
        else => {
            myzig.log.err("notes: {s} does not hold a list; starting empty", .{path});
            return;
        },
    };

    for (array) |entry| {
        // Each entry is `[title, body, id]`, the shape `toJson` writes.
        const items = switch (entry) {
            .array => |a| a,
            else => continue,
        };
        if (items.len < 3) continue;

        const title = switch (items[0]) {
            .string => |s| s,
            else => continue,
        };
        const body = switch (items[1]) {
            .string => |s| s,
            else => continue,
        };
        const id_text = switch (items[2]) {
            .number => |n| n,
            else => continue,
        };
        const id = std.fmt.parseInt(u64, id_text, 10) catch continue;

        const owned_title = state.gpa.dupe(u8, title) catch return;
        const owned_body = state.gpa.dupe(u8, body) catch {
            state.gpa.free(owned_title);
            return;
        };
        state.notes.append(state.gpa, .{ .id = id, .title = owned_title, .body = owned_body }) catch {
            state.gpa.free(owned_title);
            state.gpa.free(owned_body);
            return;
        };
        // The next note must not reuse an id, or a delete would remove the
        // wrong one after a restart.
        if (id >= state.next_id) state.next_id = id + 1;
    }

    // Saying what was read is what makes a restart checkable from a log.
    myzig.log.debug("notes: loaded {d} notes from {s}", .{ state.notes.items.len, path });
}

// --------------------------------------------------------------------- menus

const file_items = [_]myzig.MenuItem{
    .{ .command = .{ .id = "file.new", .label = "New Note", .accel = "Ctrl+N" } },
    .{ .command = .{ .id = "file.save", .label = "Save Now", .accel = "Ctrl+S" } },
    .separator,
    .{ .command = .{ .id = "file.hide", .label = "Hide Window", .accel = "Ctrl+H" } },
    .{ .command = .{ .id = "file.quit", .label = "Quit", .role = .quit, .accel = "Ctrl+Q" } },
};

const edit_items = [_]myzig.MenuItem{
    .{ .command = .{ .id = "edit.copy", .label = "Copy All", .role = .copy } },
    .{ .command = .{ .id = "edit.clear", .label = "Delete All Notes" } },
};

const view_items = [_]myzig.MenuItem{
    .{ .command = .{ .id = "view.reload", .label = "Reload", .role = .reload, .accel = "Ctrl+R" } },
    .{ .command = .{ .id = "view.devtools", .label = "Developer Tools", .role = .toggle_devtools, .accel = "F12" } },
};

const help_items = [_]myzig.MenuItem{
    .{ .command = .{ .id = "help.about", .label = "About Notes", .role = .about } },
};

const root_items = [_]myzig.MenuItem{
    .{ .submenu = .{ .id = "menu.file", .label = "File", .items = &file_items } },
    .{ .submenu = .{ .id = "menu.edit", .label = "Edit", .items = &edit_items } },
    .{ .submenu = .{ .id = "menu.view", .label = "View", .items = &view_items } },
    .{ .submenu = .{ .id = "menu.help", .label = "Help", .items = &help_items } },
};

const menu: myzig.Menu = .{ .items = &root_items };

/// Runs a menu command. The command ids are the contract the page also sees
/// through the `menu:command` event, so the page can react to the same ids.
fn onMenu(state: *State, window: u32, payload: myzig.json.Value) void {
    _ = window;
    const id = switch (payload) {
        .string => |s| s,
        else => return,
    };

    if (std.mem.eql(u8, id, "file.new")) {
        // File > New Note makes a note, the same one the page's button makes.
        // It used to emit an event nothing listened to, which looked like a
        // menu item and did nothing.
        _ = createNote(state, "Untitled", "") catch {
            myzig.log.err("notes: out of memory adding a note from the menu", .{});
            return;
        };
        // The page clears a form it was told to clear; without this the title
        // from the last note would stay in the box.
        _ = state.app.emit("notes:form", .{ .string = "reset" });
        return;
    }
    if (std.mem.eql(u8, id, "file.save")) {
        save(state, state.io);
        return;
    }
    if (std.mem.eql(u8, id, "file.hide")) {
        if (state.window) |w| state.app.showWindow(w, false);
        return;
    }
    if (std.mem.eql(u8, id, "edit.copy")) {
        const json = state.toJson();
        if (state.app.writeClipboard(json)) {
            _ = state.app.notify(.{ .title = "Notes", .body = "Copied to the clipboard." });
        }
        return;
    }
    if (std.mem.eql(u8, id, "edit.clear")) {
        for (state.notes.items) |n| {
            state.gpa.free(n.title);
            state.gpa.free(n.body);
        }
        state.notes.clearRetainingCapacity();
        state.dirty = true;
        save(state, state.io);
        _ = state.app.emit("notes:changed", .{ .string = state.toJson() });
        return;
    }
}

// ----------------------------------------------------------------------- run

/// The URL the window opens, which carries the self-test the script asked for.
/// One function so the query string and the page's own checks cannot drift.
fn selftestUrl() []const u8 {
    const v = myzig.env.get("MYZIG_NOTES_SELFTEST") orelse return "myzig://app/index.html";
    if (std.mem.eql(u8, v, "delete")) return "myzig://app/index.html?selftest=delete";
    if (std.mem.eql(u8, v, "menu")) return "myzig://app/index.html?selftest=menu";
    if (std.mem.eql(u8, v, "update")) return "myzig://app/index.html?selftest=update";
    if (std.mem.eql(u8, v, "1")) return "myzig://app/index.html?selftest=1";
    return "myzig://app/index.html";
}

pub fn main(init: std.process.Init) !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const io = init.io;

    var app = try myzig.App.init(gpa, .{
        .name = "Notes",
        .app_id = "dev.myzig.notes",
        .frontend = &frontend,
        // Closing the window leaves the tray icon, so the application keeps
        // running until Quit is chosen.
        .quit_on_last_window_closed = false,
        .io = io,
    });
    defer app.deinit();

    var state = State{ .app = &app, .gpa = gpa, .io = io };
    defer state.deinit();

    load(&state, io);

    try app.bind(.{ .name = "Notes.list", .invoke = listNotes, .ctx = &state, .arity = 0 });
    try app.bind(.{ .name = "Notes.add", .invoke = addNote, .ctx = &state, .arity = 2 });
    try app.bind(.{ .name = "Notes.update", .invoke = updateNote, .ctx = &state, .arity = 3 });
    try app.bind(.{ .name = "Notes.delete", .invoke = deleteNote, .ctx = &state, .arity = 1 });

    const window = try app.createWindow(.{
        .title = "Notes",
        .width = 640,
        .height = 560,
        // A script asks the page to add one note on load through the same call
        // the form makes, so the whole path can be checked without a pointer.
        .url = selftestUrl(),
    });
    state.window = window;

    try app.setMenu(window, menu);

    // The tray is why the window may be hidden: without an icon there would be
    // no way back, so its absence is reported rather than ignored.
    if (!app.createTray("accessories-text-editor", "Notes")) {
        myzig.log.warn("notes: no tray on this desktop; a hidden window has no way back", .{});
    }

    // A verification hook: `MYZIG_NOTES_SELFTEST=1` asks the page to add a note
    // through the same call a click makes, so a script can check the whole path
    // without a pointer. It is off unless the variable is set.

    // Menu clicks arrive as an event both the page and this side can hear. The
    // page decides what to draw; this side does what only Zig can do — save,
    // hide the window, write the clipboard.
    try app.listen("menu:command", State, &state, onMenu);

    // A script can drive a menu command without a menu: the same event a click
    // emits, from the same place, so what is tested is the listener and the
    // command it runs.
    if (myzig.env.get("MYZIG_NOTES_SELFTEST")) |v| {
        if (std.mem.eql(u8, v, "menu")) try app.onReady(&runMenuSelftest, &state);
    }

    try app.run();

    // The application is leaving: whatever changed last has to reach the disk,
    // or a note added a moment before quitting is lost.
    if (state.dirty) save(&state, io);
}

/// Emits the menu command a File > New click would, once the backend is up. It
/// proves the Zig-side listener hears an application event, which is a
/// different path from the page's subscription.
fn runMenuSelftest(ctx: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    // The same event a File > New Note click emits, so what runs is the real
    // command and not a copy of it.
    const sent = state.app.emit("menu:command", .{ .string = "file.new" });
    myzig.log.debug("notes: selftest emitted file.new to {d} page listeners", .{sent});
}

/// The I/O handle a handler needs. A handler is called from the loop, not from
/// `main`, so it reaches the handle through the state rather than a parameter.
fn io_of(state: *State) std.Io {
    return state.io;
}
