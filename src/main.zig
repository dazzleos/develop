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
const font = @import("font");
const vc4 = @import("vc4");
const app = @import("app");
const ui = @import("ui");
const wayland = @import("wayland");
const file = @import("file.zig");
const runner_mod = @import("runner.zig");
const syntax = @import("syntax.zig");
const view = @import("view.zig");

const print = sys.print;

/// The clear colour: the dark theme's surface.
const background = 0xff141218;

var frame: vc4.render.Frame = undefined;

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
    var dev = vc4.device.openRender() catch |err| {
        print(sys.log_error ++ "dazzle-develop: no GPU ({s})\n", .{@errorName(err)});
        return err;
    };
    const path: [:0]const u8 = arg_path orelse file.default_path;
    const win = try openWindow(gpa, init, &dev, "Develop");
    var width = win.width;
    var height = win.height;

    var font_buf: [512]u8 = undefined;
    var f: ?font.Font = blk: {
        const data = sys.readFileAlloc(gpa, sys.fontFile(&font_buf, font.default_font_file), 32 * 1024 * 1024) catch break :blk null;
        break :blk font.Font.init(data) catch null;
    };
    const window_ui = try ui.Ui.create(gpa, if (f) |*fnt| fnt else null);
    window_ui.clipboard = .of(&win.clipboard);
    try window_ui.attachGpu(dev);

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

    var controls: app.Controls = .{ .win = win };
    win.setMinSize(view.min_size[0], view.min_size[1]);

    var idle = false;
    var suspended = false;
    while (true) {
        win.wake_fd = session.runner.pipe_fd;
        const waited = if (idle) blk: {
            var timeout: u64 = if (window_ui.needs_frame and !suspended)
                16 * std.time.ns_per_ms
            else if (session.runner.isRunning())
                100 * std.time.ns_per_ms
            else
                60 * std.time.ns_per_s;
            if (session.changed_at) |at| timeout = @min(timeout, (at + file.save_delay_ns) -| sys.nowNs() + std.time.ns_per_ms);
            break :blk win.wait(timeout);
        } else win.poll();
        waited catch |err| {
            if (err == error.ServerError) print(sys.log_error ++ "dazzle-develop: compositor error: {s}\n", .{win.conn.errorMessage()});
            session.saveNow();
            return err;
        };
        if (win.closed or controls.quit) {
            session.saveNow();
            return;
        }
        if (try win.applyConfigure()) |size| {
            width = size[0];
            height = size[1];
            session.dirty = true;
        }
        if (win.suspended != suspended) {
            suspended = win.suspended;
            if (suspended) win.releaseSpareBuffers() else session.dirty = true;
        }
        const now = sys.nowNs();
        window_ui.keyboard = win.layout;
        for (win.takeInput()) |e| switch (e) {
            .motion => |pos| window_ui.pointerMotion(pos),
            .button => |b| window_ui.pointerButton(b.pos, b.code, b.pressed),
            .key => |k| window_ui.keyEvent(k.code, k.pressed),
            .scroll => |sc| window_ui.pointerScroll(sc.pos, sc.dx, sc.dy),
            .leave => window_ui.pointerLeave(),
            .touch_down => |t| window_ui.touchDown(t.id, t.pos),
            .touch_motion => |t| window_ui.touchMotion(t.id, t.pos),
            .touch_up => |id| window_ui.touchUp(id),
            .touch_cancel => window_ui.touchCancel(),
            .relative_motion, .pointer_locked => {},
        };
        if (session.changed_at) |at| if (now >= at + file.save_delay_ns) {
            session.changed_at = null;
            session.saveNow();
            session.dirty = true;
        };
        if (session.runner.poll()) {
            session.dirty = true;
        }

        idle = true;
        if (!suspended and (session.dirty or window_ui.needs_frame)) {
            session.dirty = false;
            const d: ?*ui.TextDocument = if (session.doc) |*dd| dd else null;
            const saved: view.Saved = if (session.save_failure) |why|
                .{ .failed = why }
            else if (d != null and d.?.version != session.saved_version)
                .changed
            else
                .saved;
            window_ui.fullscreen = win.fullscreen;
            window_ui.frame(width, height, now, view.Develop{
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
                .on_close = .of(&controls, app.Controls.close),
                .on_maximize = .of(&controls, app.Controls.toggleMaximized),
                .on_drag = .of(&controls, app.Controls.drag),
                .maximized = win.maximized,
            });
            if (window_ui.changed()) {
                idle = false;
                const target = try win.beginFrame();
                const region = window_ui.repaint(win.bufferAge());
                frame.begin(target, .{ .clear = background });
                ui.Ui.limit(&frame, &region);
                try window_ui.render(&frame, win.flusher());
                try win.render(&frame);
                var damage: [ui.damage.Region.max_rects]vc4.render.Viewport = undefined;
                const changed = window_ui.damaged();
                for (changed, damage[0..changed.len]) |r, *v| v.* = .{
                    .x = @intFromFloat(r.x),
                    .y = @intFromFloat(r.y),
                    .width = @intFromFloat(r.w),
                    .height = @intFromFloat(r.h),
                };
                try win.showDamaged(damage[0..changed.len]);
            }
        }
    }
}

fn openWindow(gpa: std.mem.Allocator, init: std.process.Init.Minimal, dev: *vc4.Device, title: []const u8) !*app.Window {
    const Environ = std.process.Environ;
    var path_buf: [128]u8 = undefined;
    const path = wayland.client.socketPath(&path_buf, Environ.getPosix(init.environ, "XDG_RUNTIME_DIR"), Environ.getPosix(init.environ, "WAYLAND_DISPLAY")) catch {
        print("dazzle-develop: WAYLAND_DISPLAY needs XDG_RUNTIME_DIR\n", .{});
        return error.NoCompositor;
    };
    const win = app.Window.open(gpa, .device(dev), path, .{ .title = title, .size = view.open_size }) catch |err| {
        print(sys.log_warning ++ "dazzle-develop: cannot open a window on {s} ({s})\n", .{ path, @errorName(err) });
        return err;
    };
    try win.setAppId("dazzle-develop");
    return win;
}

test {
    _ = file;
    _ = runner_mod;
    _ = syntax;
    _ = view;
}
