//! Develop's window, as widgets: the title bar, the toolbar (Run / Stop
//! and the run's status), the Zig code editor in the upper pane, the
//! command-line output console in the lower pane, and the file path and
//! save state along the bottom.

const std = @import("std");
const kete = @import("kete");
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
    doc: ?*kete.TextDocument,
    message: []const u8 = "",
    saved: Saved = .saved,
    status: runner.Status = .idle,
    output: []const u8 = "",
    on_changed: ?kete.Callback = null,
    on_run: ?kete.Callback = null,
    on_stop: ?kete.Callback = null,
    on_clear: ?kete.Callback = null,

    pub const State = struct {
        dismissed: bool = false,
        last_err_buf: [128]u8 = undefined,
        last_err_len: u8 = 0,

        fn dismiss(st: *State) void {
            st.dismissed = true;
        }
    };

    pub fn build(self: *const Develop, cx: *kete.BuildContext, state: *State) kete.Widget {
        const t = cx.theme();
        const is_running = self.status == .running;

        const action_button = if (is_running)
            cx.make(kete.OutlinedButton{
                .icon = .stop,
                .label = "Stop",
                .on_press = self.on_stop,
            })
        else
            cx.make(kete.OutlinedButton{
                .icon = .play_arrow,
                .label = "Run",
                .on_press = if (self.doc != null) self.on_run else null,
            });

        const status_widget: kete.Widget = switch (self.status) {
            .idle => cx.make(kete.SizedBox.empty),
            .running => cx.make(kete.Row{
                .spacing = 8,
                .cross_axis_alignment = .center,
                .children = &.{
                    cx.make(kete.Spinner{ .size = 18 }),
                    cx.make(kete.Text{
                        .text = "Running\u{2026}",
                        .style = .{ .size = 15, .color = t.on_surface_variant },
                        .wrap = false,
                    }),
                },
            }),
            .exited => |code| cx.make(kete.Text{
                .text = if (code == 0) "Finished (exit 0)" else cx.fmt("Failed (exit {d})", .{code}),
                .style = .{ .size = 15, .color = if (code == 0) t.on_surface_variant else t.@"error" },
                .wrap = false,
            }),
            .signaled => |sig| cx.make(kete.Text{
                .text = cx.fmt("Killed (signal {d})", .{sig}),
                .style = .{ .size = 15, .color = t.@"error" },
                .wrap = false,
            }),
            .stopped => cx.make(kete.Text{
                .text = "Stopped",
                .style = .{ .size = 15, .color = t.on_surface_variant },
                .wrap = false,
            }),
            .failed => |why| cx.make(kete.Text{
                .text = why,
                .style = .{ .size = 15, .color = t.@"error" },
                .wrap = false,
                .ellipsis = true,
            }),
        };

        const toolbar = cx.make(kete.Padding{
            .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 4 },
            .child = cx.make(kete.Row{
                .spacing = 12,
                .cross_axis_alignment = .center,
                .children = &.{
                    action_button,
                    cx.make(kete.Expanded{ .child = status_widget }),
                    if (self.output.len > 0 or (self.status != .idle and self.status != .running))
                        cx.make(kete.OutlinedButton{
                            .icon = .delete,
                            .label = "Clear",
                            .destructive = true,
                            .on_press = self.on_clear,
                        })
                    else
                        cx.make(kete.SizedBox.empty),
                },
            }),
        });

        const editor_body = if (self.doc) |d|
            cx.make(kete.TextArea{
                .doc = d,
                .size = 17,
                .autofocus = true,
                .on_changed = self.on_changed,
                .highlighter = syntax.zig,
            })
        else
            cx.make(kete.Align{
                .child = cx.make(kete.Padding{
                    .padding = .all(24),
                    .child = cx.make(kete.Text{
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

        const output_text = cx.make(kete.Text{
            .text = if (self.output.len > 0) self.output else output_placeholder,
            .style = .{
                .size = 15,
                .color = if (self.output.len > 0) t.on_surface else t.on_surface_variant,
            },
            .wrap = true,
        });

        const output_pane = cx.make(kete.RoundedBox{
            .color = t.surface_container,
            .border_width = 1,
            .border_color = t.outline_variant,
            .radius = .all(4),
            .child = cx.make(kete.Column{
                .cross_axis_alignment = .stretch,
                .children = &.{
                    cx.make(kete.Padding{
                        .padding = .{ .left = 12, .right = 12, .top = 6, .bottom = 4 },
                        .child = cx.make(kete.Text{
                            .text = "Output",
                            .style = .{ .size = 13, .color = t.on_surface_variant },
                            .wrap = false,
                        }),
                    }),
                    cx.make(kete.Expanded{
                        .child = cx.make(kete.ScrollView{
                            .child = cx.make(kete.Padding{
                                .padding = .{ .left = 12, .right = 12, .bottom = 8 },
                                .child = output_text,
                            }),
                        }),
                    }),
                },
            }),
        });

        const err_msg: []const u8 = switch (self.saved) {
            .failed => |why| cx.fmt("Not saved: {s}", .{why}),
            else => "",
        };
        if (err_msg.len == 0) {
            state.dismissed = false;
            state.last_err_len = 0;
        } else if (!std.mem.eql(u8, state.last_err_buf[0..state.last_err_len], err_msg)) {
            const n: u8 = @intCast(@min(err_msg.len, state.last_err_buf.len));
            @memcpy(state.last_err_buf[0..n], err_msg[0..n]);
            state.last_err_len = n;
            state.dismissed = false;
        }
        const snackbar_msg = if (state.dismissed) "" else err_msg;

        const saved_label: []const u8 = switch (self.saved) {
            .saved => "Saved",
            .changed => "Saving\u{2026}",
            .failed => "",
        };

        return cx.make(kete.Column{
            .cross_axis_alignment = .stretch,
            .children = &.{
                toolbar,
                cx.make(kete.Expanded{
                    .child = cx.make(kete.Snackbar{
                        .message = snackbar_msg,
                        .on_dismiss = .of(state, State.dismiss),
                        .child = cx.make(kete.Column{
                            .cross_axis_alignment = .stretch,
                            .children = &.{
                                cx.make(kete.Expanded{
                                    .flex = 3,
                                    .child = cx.make(kete.Padding{
                                        .padding = .{ .left = 12, .right = 12, .top = 4, .bottom = 4 },
                                        .child = editor_body,
                                    }),
                                }),
                                cx.make(kete.Expanded{
                                    .flex = 2,
                                    .child = cx.make(kete.Padding{
                                        .padding = .{ .left = 12, .right = 12, .top = 4, .bottom = 6 },
                                        .child = output_pane,
                                    }),
                                }),
                            },
                        }),
                    }),
                }),
                if (self.doc != null)
                    cx.make(kete.Padding{
                        .padding = .{ .left = 16, .right = 16, .bottom = 8 },
                        .child = cx.make(kete.Row{
                            .spacing = 16,
                            .children = &.{
                                cx.make(kete.Expanded{
                                    .child = cx.make(kete.Text{
                                        .text = self.path,
                                        .style = .{ .size = 14, .color = t.on_surface_variant },
                                        .wrap = false,
                                        .ellipsis = true,
                                    }),
                                }),
                                cx.make(kete.Text{
                                    .text = saved_label,
                                    .style = .{ .size = 14, .color = t.on_surface_variant },
                                    .wrap = false,
                                }),
                            },
                        }),
                    })
                else
                    cx.make(kete.SizedBox.empty),
            },
        });
    }
};

// --- Tests ---------------------------------------------------------------------

const testing = std.testing;
const font = kete.font;
const file = @import("file.zig");

fn overflows(node: *kete.WidgetNode) bool {
    if (node.overflow.any()) return true;
    for (node.children.items) |ch| if (overflows(ch)) return true;
    return false;
}

fn findType(n: *kete.WidgetNode, comptime T: type) ?*kete.WidgetNode {
    if (n.widget.is(T)) return n;
    for (n.children.items) |ch| if (findType(ch, T)) |f| return f;
    return null;
}

fn findText(n: *kete.WidgetNode, text: []const u8) ?*kete.WidgetNode {
    if (n.widget.as(kete.Text)) |tx| if (std.mem.eql(u8, tx.text, text)) return n;
    for (n.children.items) |ch| if (findText(ch, text)) |f| return f;
    return null;
}

test "Develop layout fits without overflow and updates across run states" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    var doc = try kete.TextDocument.init(testing.allocator, file.starter_code);
    defer doc.deinit();

    var d: Develop = .{
        .path = file.default_path,
        .doc = &doc,
    };
    for ([_][2]u32{ min_size, .{ 1280, 720 }, .{ 1920, 1036 } }) |size| {
        u.frame(size[0], size[1], 0, d);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findText(u.root.?, "Run") != null);
    try testing.expect(findText(u.root.?, "Output") != null);
    try testing.expect(findText(u.root.?, "Saved") != null);

    // Editor has focus and Zig syntax highlighting.
    try testing.expect(u.focused != null and u.focused.?.widget.is(kete.TextArea));
    const area = findType(u.root.?, kete.TextArea).?;
    const st = area.state(kete.TextArea.State);
    try testing.expectEqual(doc.text().len, st.colours.items.len);
    try testing.expectEqual(kete.TextArea.Highlight.keyword, st.colours.items[0]);

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
