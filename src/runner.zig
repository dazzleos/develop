//! Compiling and running the user's Zig program in a child process with the
//! bundled Zig compiler (`zig/zig` and `zig/lib` in `dazzle-develop`'s app
//! folder), capturing its combined `stdout` and `stderr` over a pipe without
//! blocking the UI.

const std = @import("std");
const linux = std.os.linux;
const app = @import("app");
const sys = @import("sys");

/// The most output kept from a run.
pub const max_output = 64 * 1024;

pub const Status = union(enum) {
    idle,
    running,
    exited: u8,
    signaled: u32,
    stopped,
    failed: []const u8,
};

pub const Runner = struct {
    gpa: std.mem.Allocator,
    output: std.ArrayList(u8) = .empty,
    pid: ?linux.pid_t = null,
    pipe_fd: ?linux.fd_t = null,
    status: Status = .idle,
    /// Where the compiler's cache and temporary files go.
    work_dir: []const u8 = "/data/user/.develop",
    /// Overrides for testing on the build machine.
    zig_override: ?[:0]const u8 = null,
    lib_override: ?[]const u8 = null,

    pub fn init(gpa: std.mem.Allocator) Runner {
        return .{ .gpa = gpa };
    }

    pub fn deinit(r: *Runner) void {
        r.stop();
        r.output.deinit(r.gpa);
    }

    pub fn text(r: *const Runner) []const u8 {
        return r.output.items;
    }

    pub fn isRunning(r: *const Runner) bool {
        return r.pid != null;
    }

    pub fn clear(r: *Runner) void {
        r.output.clearRetainingCapacity();
        if (r.pid == null) r.status = .idle;
    }

    /// Starts `zig run <source_path>` in a child process. Stops any run
    /// already under way first.
    pub fn start(r: *Runner, source_path: [:0]const u8, environ: std.process.Environ) void {
        if (r.pid != null) r.stop();
        r.output.clearRetainingCapacity();

        var zig_buf: [512]u8 = undefined;
        const zig_path = r.zig_override orelse (sys.appFile(&zig_buf, "zig/zig") catch {
            r.status = .{ .failed = "The Zig compiler is not installed" };
            return;
        });
        if (linux.errno(linux.access(zig_path, linux.X_OK)) != .SUCCESS) {
            r.status = .{ .failed = "The Zig compiler is not installed" };
            return;
        }

        var lib_buf: [512]u8 = undefined;
        const lib_dir: []const u8 = r.lib_override orelse (sys.appFile(&lib_buf, "zig/lib") catch "/data/apps/dazzle-develop/zig/lib");

        var work_z_buf: [512]u8 = undefined;
        var cache_buf: [512]u8 = undefined;
        var tmp_buf: [512]u8 = undefined;
        const work_z = std.mem.printSentinel(&work_z_buf, "{s}", .{r.work_dir}, 0) catch {
            r.status = .{ .failed = "Cannot prepare the build folder" };
            return;
        };
        const cache_dir = std.mem.printSentinel(&cache_buf, "{s}/cache", .{r.work_dir}, 0) catch {
            r.status = .{ .failed = "Cannot prepare the build folder" };
            return;
        };
        const tmp_dir = std.mem.printSentinel(&tmp_buf, "{s}/tmp", .{r.work_dir}, 0) catch {
            r.status = .{ .failed = "Cannot prepare the build folder" };
            return;
        };
        _ = linux.mkdir(work_z, 0o755);
        _ = linux.mkdir(cache_dir, 0o755);
        _ = linux.mkdir(tmp_dir, 0o755);

        var fds: [2]linux.fd_t = undefined;
        if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) {
            r.status = .{ .failed = "Cannot open a pipe for the program's output" };
            return;
        }

        const rc = linux.fork();
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            else => {
                sys.close(fds[0]);
                sys.close(fds[1]);
                r.status = .{ .failed = "Cannot start the compiler process" };
                return;
            },
        }
        if (rc == 0) {
            _ = linux.setsid();
            sys.close(fds[0]);
            if (sys.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true })) |null_fd| {
                _ = linux.dup2(null_fd, 0);
                sys.close(null_fd);
            } else |_| {}
            _ = linux.dup2(fds[1], 1);
            _ = linux.dup2(fds[1], 2);
            sys.close(fds[1]);

            if (std.fs.path.dirname(source_path)) |dir| {
                var dir_buf: [512]u8 = undefined;
                if (std.mem.printSentinel(&dir_buf, "{s}", .{dir}, 0)) |dir_z| {
                    _ = linux.chdir(dir_z);
                } else |_| {}
            }

            var home_env_buf: [512]u8 = undefined;
            var tmp_env_buf: [512]u8 = undefined;
            var local_cache_env_buf: [512]u8 = undefined;
            var global_cache_env_buf: [512]u8 = undefined;
            var lib_env_buf: [512]u8 = undefined;
            var wayland_env: app.ChildEnv = undefined;

            var envp: [12:null]?[*:0]const u8 = @splat(null);
            var env_i: usize = 0;
            if (std.mem.printSentinel(&home_env_buf, "HOME={s}", .{std.fs.path.dirname(source_path) orelse "/data/user"}, 0)) |s| {
                envp[env_i] = s.ptr;
                env_i += 1;
            } else |_| {}
            if (std.mem.printSentinel(&tmp_env_buf, "TMPDIR={s}", .{tmp_dir}, 0)) |s| {
                envp[env_i] = s.ptr;
                env_i += 1;
            } else |_| {}
            if (std.mem.printSentinel(&local_cache_env_buf, "ZIG_LOCAL_CACHE_DIR={s}", .{cache_dir}, 0)) |s| {
                envp[env_i] = s.ptr;
                env_i += 1;
            } else |_| {}
            if (std.mem.printSentinel(&global_cache_env_buf, "ZIG_GLOBAL_CACHE_DIR={s}", .{cache_dir}, 0)) |s| {
                envp[env_i] = s.ptr;
                env_i += 1;
            } else |_| {}
            if (std.mem.printSentinel(&lib_env_buf, "ZIG_LIB_DIR={s}", .{lib_dir}, 0)) |s| {
                envp[env_i] = s.ptr;
                env_i += 1;
            } else |_| {}
            envp[env_i] = "NO_COLOR=1";
            env_i += 1;
            envp[env_i] = "TERM=dumb";
            env_i += 1;
            for (wayland_env.init(environ, null)) |v| {
                envp[env_i] = v;
                env_i += 1;
            }

            const argv = [_:null]?[*:0]const u8{
                zig_path.ptr,
                "run",
                source_path.ptr,
            };
            _ = linux.execve(zig_path, &argv, &envp);
            const msg = "cannot execute zig compiler\n";
            _ = linux.write(2, msg.ptr, msg.len);
            linux.exit(127);
        }

        sys.close(fds[1]);
        r.pid = @intCast(rc);
        r.pipe_fd = fds[0];
        r.status = .running;
    }

    /// Reads any available output from the pipe without blocking.
    fn drainAvailable(r: *Runner) bool {
        const fd = r.pipe_fd orelse return false;
        var changed = false;
        var buf: [4096]u8 = undefined;
        while (true) {
            var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
            const prc = linux.poll(&pfd, 1, 0);
            if (linux.errno(prc) != .SUCCESS or prc == 0) break;
            if (pfd[0].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) == 0) break;
            const n = linux.read(fd, &buf, buf.len);
            switch (linux.errno(n)) {
                .SUCCESS => {
                    if (n == 0) {
                        sys.close(fd);
                        r.pipe_fd = null;
                        break;
                    }
                    r.appendOutput(buf[0..n]);
                    changed = true;
                },
                .INTR => continue,
                .AGAIN => break,
                else => {
                    sys.close(fd);
                    r.pipe_fd = null;
                    break;
                },
            }
        }
        return changed;
    }

    pub fn appendOutput(r: *Runner, bytes: []const u8) void {
        if (r.output.items.len >= max_output) return;
        const room = max_output - r.output.items.len;
        r.output.appendSlice(r.gpa, bytes[0..@min(bytes.len, room)]) catch {};
    }

    /// Polls for new output and child exit. Returns whether what is shown
    /// changed.
    pub fn poll(r: *Runner) bool {
        const changed = r.drainAvailable();
        const pid = r.pid orelse return changed;
        var wstatus: u32 = 0;
        const rc = linux.wait4(pid, @ptrCast(&wstatus), linux.W.NOHANG, null);
        if (linux.errno(rc) == .SUCCESS and rc == 0) return changed;

        _ = r.drainAvailable();
        if (r.pipe_fd) |fd| {
            sys.close(fd);
            r.pipe_fd = null;
        }
        _ = linux.kill(-pid, .KILL);
        r.pid = null;
        if (linux.W.IFEXITED(wstatus)) {
            r.status = .{ .exited = linux.W.EXITSTATUS(wstatus) };
        } else if (linux.W.IFSIGNALED(wstatus)) {
            r.status = .{ .signaled = @intFromEnum(linux.W.TERMSIG(wstatus)) };
        } else {
            r.status = .{ .exited = 1 };
        }
        return true;
    }

    /// Stops the running compiler and any program it started.
    pub fn stop(r: *Runner) void {
        if (r.pid) |pid| {
            _ = linux.kill(-pid, .KILL);
            _ = linux.kill(pid, .KILL);
            var wstatus: u32 = 0;
            _ = linux.wait4(pid, @ptrCast(&wstatus), 0, null);
            r.pid = null;
        }
        if (r.pipe_fd) |fd| {
            sys.close(fd);
            r.pipe_fd = null;
        }
        if (r.status == .running) r.status = .stopped;
    }
};

const testing = std.testing;

test "runner captures output and exit status from a child process" {
    var dir_buf: [64]u8 = undefined;
    const dir = try std.mem.printSentinel(&dir_buf, "/tmp/dazzle-develop-runner-test-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdir(dir, 0o755);
    defer sys.files.removeTree(dir);

    var fake_zig_buf: [128]u8 = undefined;
    const fake_zig = try std.mem.printSentinel(&fake_zig_buf, "{s}/fake-zig.sh", .{dir}, 0);
    try sys.files.writeNew(fake_zig, "#!/bin/sh\necho \"ran $1 on $2\"\nexit 0\n");
    _ = linux.chmod(fake_zig, 0o755);

    var src_buf: [128]u8 = undefined;
    const src = try std.mem.printSentinel(&src_buf, "{s}/main.zig", .{dir}, 0);
    try sys.files.writeNew(src, "pub fn main() void {}\n");

    var runner: Runner = .init(testing.allocator);
    defer runner.deinit();
    runner.work_dir = dir;
    runner.zig_override = fake_zig;
    runner.lib_override = dir;

    runner.start(src, .empty);
    try testing.expect(runner.isRunning());

    while (runner.isRunning()) {
        if (runner.pipe_fd) |fd| {
            var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
            _ = linux.poll(&pfd, 1, 50);
        }
        _ = runner.poll();
    }

    try testing.expectEqual(Status{ .exited = 0 }, runner.status);
    var want_buf: [160]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "ran run on {s}\n", .{src});
    try testing.expectEqualStrings(want, runner.text());
}
