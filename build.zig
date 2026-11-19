//! Develop, an app for writing and running Zig programs, for Dazzle: built
//! with Dazzle's modules and tools (see Dazzle's build.zig, `addApp`).
//!
//!     zig build                 the program, and its archive and catalogue (zig-out/apps)
//!     zig build test            its tests, on this computer
//!
//! With a Dazzle (or kete) checkout of your own beside it:
//! `zig build --fork=../dazzle`.

const std = @import("std");
const dazzle = @import("dazzle");

/// The ARM Linux Zig compiler bundled into the app, pinned by version and
/// checksum (fetched into build/zig, once).
const zig_version = "0.17.1";
const zig_archive = "zig-arm-linux-" ++ zig_version ++ ".tar.xz";
const zig_sha256 = "45b5262ef4d4d1e70d21683b2ef4c1b765b067f34a13e2aa57d5f92bb02382a9";

pub fn build(b: *std.Build) void {
    const root = b.root.root_dir.path orelse ".";
    const dir = b.pathJoin(&.{ root, b.root.sub_path, "build/zig" });
    const zig_root = b.fmt("{s}/zig-arm-linux-{s}", .{ dir, zig_version });
    _ = dazzle.addApp(b, .{
        .name = "dazzle-develop",
        .icon = .code,
        .title = "Develop",
        .description = "Write and run Zig programs",
        .about = "Write programs in Zig and run them on this computer: an editor beside the output, with the Zig compiler built in.",
        .notices = &.{ "MaterialIcons", "Zig" },
        .extra_step = fetchZig(b, dir),
        .extra_args = &.{
            b.fmt("--exe=zig/zig={s}/zig", .{zig_root}),
            b.fmt("zig/LICENSE={s}/LICENSE", .{zig_root}),
            "--exclude=zig/lib/libc",
            "--exclude=zig/lib/libcxx",
            "--exclude=zig/lib/libcxxabi",
            "--exclude=zig/lib/libunwind",
            "--exclude=zig/lib/tsan",
            b.fmt("--dir=zig/lib={s}/lib", .{zig_root}),
        },
    });
}

/// Downloads the compiler (if it is not there), checks it, and unpacks it
/// into `dir`.
fn fetchZig(b: *std.Build, dir: []const u8) *std.Build.Step {
    const run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -e
        \\mkdir -p "$1"
        \\cd "$1"
        \\if [ ! -x "zig-arm-linux-$2/zig" ]; then
        \\  if [ ! -f "$3" ]; then
        \\    curl -fL --retry 3 -o "$3.part" "https://ziglang.org/download/$2/$3"
        \\    mv "$3.part" "$3"
        \\  fi
        \\  echo "$4  $3" | sha256sum -c -
        \\  tar -xJf "$3"
        \\fi
        ,
        "fetch-zig",
        dir,
        zig_version,
        zig_archive,
        zig_sha256,
    });
    run.has_side_effects = true;
    return &run.step;
}
