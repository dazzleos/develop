//! Dazzle's Develop app: write Zig programs, compile and run them on Dazzle
//! using the bundled Zig compiler, and see their output.
//!
//!     dazzle-develop [file.zig]
//!
//! Without a file argument it opens `/data/user/main.zig` (creating it with
//! a starter program if it is not there yet). Changes are saved as you type
//! and before each run.

const std = @import("std");
const sys = @import("sys");
const locale = @import("locale");
const ui = @import("ui");
const file = @import("file.zig");
const runner_mod = @import("runner.zig");
const syntax = @import("syntax.zig");
const view = @import("view.zig");

const print = sys.print;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    var args = init.args.iterate();
    _ = args.skip();
    const arg_path: ?[:0]const u8 = if (args.next()) |p| std.mem.span(p.ptr) else null;
    run(init, arg_path) catch |err| {
        print(sys.log_error ++ "dazzle-develop: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

const Session = struct {
    path: [:0]const u8,
    doc: ?ui.TextDocument = null,
    saved_version: u64 = 0,
    save_failure: ?[]const u8 = null,
    changed_at: ?u64 = null,
    runner: runner_mod.Runner,
    environ: std.process.Environ,
    dirty: bool = true,

    fn onChanged(s: *Session) void {
        s.changed_at = sys.nowNs();
    }

    fn onRun(s: *Session) void {
        s.changed_at = null;
        s.saveNow();
        s.runner.start(s.path, s.environ);
        s.dirty = true;
    }

    fn onStop(s: *Session) void {
        s.runner.stop();
        s.dirty = true;
    }

    fn onClear(s: *Session) void {
        s.runner.clear();
        s.dirty = true;
    }

    fn saveNow(s: *Session) void {
        const d = s.doc orelse return;
        if (d.version == s.saved_version) return;
        if (file.save(s.path, d.text())) {
            s.saved_version = d.version;
            s.save_failure = null;
        } else |err| {
            s.save_failure = file.describeSaveError(err);
            print(sys.log_warning ++ "dazzle-develop: cannot save {s}: {s}\n", .{ s.path, @errorName(err) });
        }
    }
};

fn run(init: std.process.Init.Minimal, arg_path: ?[:0]const u8) !void {
    locale.current = locale.load().language;
    const gpa = std.heap.page_allocator;
    const path: [:0]const u8 = arg_path orelse file.default_path;
    const a = try ui.App.open(gpa, init.environ, .{
        .title = "Develop",
        .app_id = "dazzle-develop",
        .size = view.open_size,
        .min_size = view.min_size,
    });
    defer a.close();

    var session: Session = .{
        .path = path,
        .runner = .init(gpa),
        .environ = init.environ,
    };
    defer session.runner.deinit();
    defer if (session.doc) |*d| d.deinit();

    var message: []const u8 = "";
    if (file.openOrCreate(gpa, path, arg_path == null)) |text| {
        defer gpa.free(text);
        session.doc = try ui.TextDocument.init(gpa, text);
    } else |err| message = file.describeOpenError(err);
    defer session.saveNow();

    while (true) {
        a.win.wake_fd = session.runner.pipe_fd;
        var timeout: u64 = if (session.runner.isRunning())
            100 * std.time.ns_per_ms
        else
            60 * std.time.ns_per_s;
        if (session.changed_at) |at| timeout = @min(timeout, (at + file.save_delay_ns) -| sys.nowNs() + std.time.ns_per_ms);
        if (!try a.step(timeout)) return;
        const now = sys.nowNs();
        a.takeInput();
        if (session.changed_at) |at| if (now >= at + file.save_delay_ns) {
            session.changed_at = null;
            session.saveNow();
            session.dirty = true;
        };
        if (session.runner.poll()) {
            session.dirty = true;
        }
        if (session.dirty) {
            session.dirty = false;
            a.dirty = true;
        }

        const d: ?*ui.TextDocument = if (session.doc) |*dd| dd else null;
        const saved: view.Saved = if (session.save_failure) |why|
            .{ .failed = why }
        else if (d != null and d.?.version != session.saved_version)
            .changed
        else
            .saved;
        try a.draw(now, view.Develop{
            .path = path,
            .doc = d,
            .message = message,
            .saved = saved,
            .status = session.runner.status,
            .output = session.runner.text(),
            .on_changed = .of(&session, Session.onChanged),
            .on_run = .of(&session, Session.onRun),
            .on_stop = .of(&session, Session.onStop),
            .on_clear = .of(&session, Session.onClear),
        });
    }
}

test {
    _ = file;
    _ = runner_mod;
    _ = syntax;
    _ = view;
}
