//! Develop's window, as widgets: the title bar, the toolbar (Run / Stop
//! and the run's status), the Zig code editor in the upper pane, the
//! command-line output console in the lower pane, and the file path and
//! save state along the bottom.

const std = @import("std");
const ui = @import("ui");
const runner = @import("runner.zig");
const syntax = @import("syntax.zig");

pub const min_size = [2]u32{ 520, 360 };
pub const open_size = [2]u32{ 1024, 720 };

/// Whether what is shown is saved.
pub const Saved = union(enum) {
    saved,
    changed,
    failed: []const u8,
};

pub const Develop = struct {
    path: []const u8,
    doc: ?*ui.TextDocument,
    message: []const u8 = "",
    saved: Saved = .saved,
    status: runner.Status = .idle,
    output: []const u8 = "",
    on_changed: ?ui.Callback = null,
    on_run: ?ui.Callback = null,
    on_stop: ?ui.Callback = null,
    on_clear: ?ui.Callback = null,
    on_close: ?ui.Callback = null,
    on_maximize: ?ui.Callback = null,
    on_drag: ?ui.Callback = null,
    maximized: bool = true,

    pub fn build(self: *const Develop, cx: *ui.Context) ui.Widget {
        const t = cx.theme();
        const is_running = self.status == .running;

        const action_button = if (is_running)
            cx.make(ui.OutlinedButton{
                .icon = .stop,
                .label = "Stop",
                .on_press = self.on_stop,
            })
        else
            cx.make(ui.OutlinedButton{
                .icon = .play_arrow,
                .label = "Run",
                .on_press = if (self.doc != null) self.on_run else null,
            });

        const status_widget: ui.Widget = switch (self.status) {
            .idle => cx.make(ui.Empty{}),
            .running => cx.make(ui.Row{
                .spacing = 8,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(ui.Spinner{ .size = 18 }),
                    cx.make(ui.Text{
                        .text = "Running\u{2026}",
                        .style = .{ .size = 15, .color = t.on_surface_variant },
                        .wrap = false,
                    }),
                },
            }),
            .exited => |code| cx.make(ui.Text{
                .text = if (code == 0) "Finished (exit 0)" else cx.fmt("Failed (exit {d})", .{code}),
                .style = .{ .size = 15, .color = if (code == 0) t.on_surface_variant else t.@"error" },
                .wrap = false,
            }),
            .signaled => |sig| cx.make(ui.Text{
                .text = cx.fmt("Killed (signal {d})", .{sig}),
                .style = .{ .size = 15, .color = t.@"error" },
                .wrap = false,
            }),
            .stopped => cx.make(ui.Text{
                .text = "Stopped",
                .style = .{ .size = 15, .color = t.on_surface_variant },
                .wrap = false,
            }),
            .failed => |why| cx.make(ui.Text{
                .text = why,
                .style = .{ .size = 15, .color = t.@"error" },
                .wrap = false,
                .ellipsis = true,
            }),
        };

        const toolbar = cx.make(ui.Padding{
            .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 4 },
            .child = cx.make(ui.Row{
                .spacing = 12,
                .cross_axis_alignment = .center,
                .children = &.{
                    action_button,
                    cx.make(ui.Expanded{ .child = status_widget }),
                    if (self.output.len > 0 or (self.status != .idle and self.status != .running))
                        cx.make(ui.OutlinedButton{
                            .icon = .delete,
                            .label = "Clear",
                            .on_press = self.on_clear,
                        })
                    else
                        cx.make(ui.Empty{}),
                },
            }),
        });

        const editor_body = if (self.doc) |d|
            cx.make(ui.TextArea{
                .doc = d,
                .size = 17,
                .autofocus = true,
                .on_changed = self.on_changed,
                .highlighter = syntax.zig,
            })
        else
            cx.make(ui.Center{
                .child = cx.make(ui.Padding{
                    .padding = .all(24),
                    .child = cx.make(ui.Text{
                        .text = self.message,
                        .style = .{ .size = 18, .color = t.on_surface_variant },
                        .text_align = .center,
                    }),
                }),
            });

        const output_placeholder = if (is_running)
            "Compiling and running\u{2026}"
        else
            "Press Run to compile and run this Zig program.";

        const output_text = cx.make(ui.Text{
            .text = if (self.output.len > 0) self.output else output_placeholder,
            .style = .{
                .size = 15,
                .color = if (self.output.len > 0) t.on_surface else t.on_surface_variant,
            },
            .wrap = true,
        });

        const output_pane = cx.make(ui.Decorated{
            .color = t.surface_container,
            .border = .{ .width = 1, .color = t.outline_variant },
            .radius = .all(4),
            .child = cx.make(ui.Column{
                .cross_axis_alignment = .stretch,
                .children = &.{
                    cx.make(ui.Padding{
                        .padding = .{ .left = 12, .right = 12, .top = 6, .bottom = 4 },
                        .child = cx.make(ui.Text{
                            .text = "Output",
                            .style = .{ .size = 13, .color = t.on_surface_variant },
                            .wrap = false,
                        }),
                    }),
                    cx.make(ui.Expanded{
                        .child = cx.make(ui.ScrollView{
                            .child = cx.make(ui.Padding{
                                .padding = .{ .left = 12, .right = 12, .bottom = 8 },
                                .child = output_text,
                            }),
                        }),
                    }),
                },
            }),
        });

        const saved_label: []const u8 = switch (self.saved) {
            .saved => "Saved",
            .changed => "Saving\u{2026}",
            .failed => |why| cx.fmt("Not saved: {s}", .{why}),
        };

        return cx.make(ui.Column{
            .cross_axis_alignment = .stretch,
            .children = &.{
                cx.make(ui.TitleBar{
                    .title = "Develop",
                    .on_close = self.on_close,
                    .on_maximize = self.on_maximize,
                    .on_drag = self.on_drag,
                    .maximized = self.maximized,
                }),
                toolbar,
                cx.make(ui.Expanded{
                    .flex = 3,
                    .child = cx.make(ui.Padding{
                        .padding = .{ .left = 12, .right = 12, .top = 4, .bottom = 4 },
                        .child = editor_body,
                    }),
                }),
                cx.make(ui.Expanded{
                    .flex = 2,
                    .child = cx.make(ui.Padding{
                        .padding = .{ .left = 12, .right = 12, .top = 4, .bottom = 6 },
                        .child = output_pane,
                    }),
                }),
                if (self.doc != null)
                    cx.make(ui.Padding{
                        .padding = .{ .left = 16, .right = 16, .bottom = 8 },
                        .child = cx.make(ui.Row{
                            .spacing = 16,
                            .children = &.{
                                cx.make(ui.Expanded{
                                    .child = cx.make(ui.Text{
                                        .text = self.path,
                                        .style = .{ .size = 14, .color = t.on_surface_variant },
                                        .wrap = false,
                                        .ellipsis = true,
                                    }),
                                }),
                                cx.make(ui.Text{
                                    .text = saved_label,
                                    .style = .{ .size = 14, .color = if (self.saved == .failed) t.@"error" else t.on_surface_variant },
                                    .wrap = false,
                                }),
                            },
                        }),
                    })
                else
                    cx.make(ui.Empty{}),
            },
        });
    }
};

// --- Tests ---------------------------------------------------------------------

const testing = std.testing;
const font = @import("font");
const file = @import("file.zig");

fn overflows(node: *ui.Node) bool {
    if (node.overflow.any()) return true;
    for (node.children.items) |ch| if (overflows(ch)) return true;
    return false;
}

fn findType(n: *ui.Node, comptime T: type) ?*ui.Node {
    if (n.widget.is(T)) return n;
    for (n.children.items) |ch| if (findType(ch, T)) |f| return f;
    return null;
}

fn findText(n: *ui.Node, text: []const u8) ?*ui.Node {
    if (n.widget.as(ui.Text)) |tx| if (std.mem.eql(u8, tx.text, text)) return n;
    for (n.children.items) |ch| if (findText(ch, text)) |f| return f;
    return null;
}

test "Develop layout fits without overflow and updates across run states" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    var doc = try ui.TextDocument.init(testing.allocator, file.starter_code);
    defer doc.deinit();

    var d: Develop = .{
        .path = file.default_path,
        .doc = &doc,
    };
    for ([_][2]u32{ min_size, .{ 1280, 720 }, .{ 1920, 1036 } }) |size| {
        u.frame(size[0], size[1], 0, d);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findText(u.root.?, "Develop") != null);
    try testing.expect(findText(u.root.?, "Run") != null);
    try testing.expect(findText(u.root.?, "Output") != null);
    try testing.expect(findText(u.root.?, "Saved") != null);

    // Editor has focus and Zig syntax highlighting.
    try testing.expect(u.focused != null and u.focused.?.widget.is(ui.TextArea));
    const area = findType(u.root.?, ui.TextArea).?;
    const st = area.state(ui.TextArea.State);
    try testing.expectEqual(doc.text().len, st.colours.items.len);
    try testing.expectEqual(ui.Highlight.keyword, st.colours.items[0]);

    // Running state shows Stop and Spinner without overflowing.
    d.status = .running;
    for ([_][2]u32{ min_size, .{ 1280, 720 } }) |size| {
        u.frame(size[0], size[1], 1, d);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findText(u.root.?, "Stop") != null);
    try testing.expect(findText(u.root.?, "Running\u{2026}") != null);

    // Output and exit status show in the console and toolbar without overflowing.
    d.status = .{ .exited = 0 };
    d.output = "Hello from Dazzle!\n";
    for ([_][2]u32{ min_size, .{ 1280, 720 } }) |size| {
        u.frame(size[0], size[1], 2, d);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findText(u.root.?, "Finished (exit 0)") != null);
    try testing.expect(findText(u.root.?, "Hello from Dazzle!\n") != null);
    try testing.expect(findText(u.root.?, "Clear") != null);
}
