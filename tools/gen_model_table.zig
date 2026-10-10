//! 模型能力表生成脚本（不进构建，手动跑；看心情更新用）。
//!
//! 用法：
//!   1) 下载 models.dev 数据（需代理时自行设置 HTTP_PROXY/HTTPS_PROXY）：
//!        curl -o models_dev_api.json https://models.dev/api.json
//!   2) 生成表（需显式挂载 config 模块做预设自检）：
//!        zig run --dep config -Mroot=tools/gen_model_table.zig -Mconfig=src/config.zig -- models_dev_api.json
//!      （自检：每个云端预设都必须有映射，本地预设 lmstudio/ollama 豁免——新预设忘了加映射会直接报错）
//!
//! 输入：
//!   - models.dev api.json（参数 1，默认 models_dev_api.json）
//!   - tools/model_corrections.json（人工/AI 实测修正层，永远优先于拉取数据）
//! 输出：
//!   - src/model_table.zig（提交进仓库；编译期常量，运行时零解析）
//!
//! 说明：模型能力表只是"让用户少踩坑"的辅助——表里没有的模型走"全档位+用户自试"，
//! 因此本脚本不追求全覆盖，预设 provider 子集即可。

const std = @import("std");
const Allocator = std.mem.Allocator;
/// SkyNet 的预设表（模块由命令行提供：--dep config -Mconfig=src/config.zig）
const config = @import("config");

/// 预设 id → models.dev provider id（本地服务 lmstudio/ollama 不在表内）
const preset_map = [_]Pair{
    .{ .ours = "openai", .md = "openai" },
    .{ .ours = "opencode", .md = "opencode" },
    .{ .ours = "opencode-go", .md = "opencode-go" },
    .{ .ours = "openrouter", .md = "openrouter" },
    .{ .ours = "deepseek", .md = "deepseek" },
    .{ .ours = "moonshot", .md = "moonshotai-cn" },
    .{ .ours = "zai", .md = "zai" },
    .{ .ours = "groq", .md = "groq" },
    .{ .ours = "mistral", .md = "mistral" },
    .{ .ours = "xai", .md = "xai" },
    .{ .ours = "google", .md = "google" },
    .{ .ours = "cerebras", .md = "cerebras" },
    .{ .ours = "fireworks", .md = "fireworks-ai" },
    .{ .ours = "together", .md = "togetherai" },
    .{ .ours = "nvidia", .md = "nvidia" },
    .{ .ours = "siliconflow", .md = "siliconflow-cn" },
};

const Pair = struct { ours: []const u8, md: []const u8 };

const Kind = enum { effort, toggle };

const Entry = struct {
    provider: []const u8,
    model: []const u8,
    ctx: u64 = 0,
    kind: Kind = .effort,
    efforts: []const []const u8 = &.{},
    /// off（关闭思考）是否用 reasoning_effort:"none" 表达（false = 不发送该字段）
    off_none: bool = false,
};

/// 档位排序用的固定顺序（不认识的词排最后，按字典序）
const effort_order = [_][]const u8{ "minimal", "low", "medium", "high", "xhigh", "max" };

fn effortRank(s: []const u8) usize {
    for (effort_order, 0..) |e, i| {
        if (std.mem.eql(u8, e, s)) return i;
    }
    return effort_order.len;
}

fn sortEfforts(items: [][]const u8) void {
    const Ctx = struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            const ra = effortRank(a);
            const rb = effortRank(b);
            if (ra != rb) return ra < rb;
            return std.mem.order(u8, a, b) == .lt;
        }
    };
    std.mem.sort([]const u8, items, {}, Ctx.lessThan);
}

fn objOf(v: std.json.Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn getField(v: std.json.Value, key: []const u8) ?std.json.Value {
    const o = objOf(v) orelse return null;
    return o.get(key);
}

fn getStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = getField(v, key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

fn getInt(v: std.json.Value, key: []const u8) u64 {
    const f = getField(v, key) orelse return 0;
    return switch (f) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        .float => |x| if (x > 0) @intFromFloat(x) else 0,
        else => 0,
    };
}

fn keyOf(arena: Allocator, provider: []const u8, model: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\x00{s}", .{ provider, model });
}

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;
    const io = init.io;

    // ── 预设自检：config.presets 的每个云端预设都必须有映射 ──
    // （本地服务不在 models.dev 表内，白名单豁免；新预设忘了加映射时此处直接报错）
    {
        const local_whitelist = [_][]const u8{ "lmstudio", "ollama" };
        var missing: usize = 0;
        for (config.presets) |pr| {
            var is_local = false;
            for (local_whitelist) |lw| {
                if (std.mem.eql(u8, pr.id, lw)) {
                    is_local = true;
                    break;
                }
            }
            if (is_local) continue;
            var mapped = false;
            for (preset_map) |pm| {
                if (std.mem.eql(u8, pm.ours, pr.id)) {
                    mapped = true;
                    break;
                }
            }
            if (!mapped) {
                std.debug.print("预设自检失败: 预设 \"{s}\" 没有 models.dev 映射（本地服务请加入 local_whitelist）\n", .{pr.id});
                missing += 1;
            }
        }
        if (missing > 0) return 1;
        std.debug.print("预设自检通过（{d} 个云端预设均有映射）\n", .{config.presets.len - local_whitelist.len});
    }

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer arg_it.deinit();
    _ = arg_it.next();
    const models_path = arg_it.next() orelse "models_dev_api.json";

    const cwd = std.Io.Dir.cwd();
    const models_text = cwd.readFileAlloc(io, models_path, alloc, .limited(128 << 20)) catch |e| {
        std.debug.print("无法读取 {s}: {s}\n（先下载：curl -o {s} https://models.dev/api.json）\n", .{ models_path, @errorName(e), models_path });
        return 1;
    };
    defer alloc.free(models_text);

    const corr_text = cwd.readFileAlloc(io, "tools/model_corrections.json", alloc, .limited(8 << 20)) catch |e| {
        std.debug.print("无法读取 tools/model_corrections.json: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer alloc.free(corr_text);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const models_doc = std.json.parseFromSlice(std.json.Value, arena, models_text, .{}) catch |e| {
        std.debug.print("解析 models.dev 数据失败: {s}\n", .{@errorName(e)});
        return 1;
    };
    const corr_doc = std.json.parseFromSlice(std.json.Value, arena, corr_text, .{}) catch |e| {
        std.debug.print("解析修正文件失败: {s}\n", .{@errorName(e)});
        return 1;
    };

    var map: std.StringArrayHashMapUnmanaged(Entry) = .empty;

    // ── 1. models.dev 数据（预设子集）──
    const root = models_doc.value;
    var n_effort: usize = 0;
    var n_toggle: usize = 0;
    for (preset_map) |pm| {
        const prov = root.object.get(pm.md) orelse {
            std.debug.print("提示: models.dev 无 provider {s}（跳过）\n", .{pm.md});
            continue;
        };
        const models = getField(prov, "models") orelse continue;
        var it = models.object.iterator();
        while (it.next()) |kv| {
            const mid = kv.key_ptr.*;
            const mv = kv.value_ptr.*;

            const ctx = blk: {
                const lim = getField(mv, "limit") orelse break :blk 0;
                break :blk getInt(lim, "context");
            };

            var efforts = std.ArrayListUnmanaged([]const u8){ .items = &.{}, .capacity = 0 };
            var toggle = false;
            var off_none = false;
            if (getField(mv, "reasoning_options")) |ro| {
                if (ro == .array) {
                    for (ro.array.items) |opt| {
                        const t = getStr(opt, "type") orelse continue;
                        if (std.mem.eql(u8, t, "toggle")) toggle = true;
                        if (std.mem.eql(u8, t, "effort")) {
                            if (getField(opt, "values")) |vals| {
                                if (vals == .array) {
                                    for (vals.array.items) |vv| {
                                        const s = switch (vv) {
                                            .string => |x| x,
                                            else => continue,
                                        };
                                        if (s.len == 0) continue;
                                        if (std.mem.eql(u8, s, "none")) {
                                            off_none = true; // off 的表达方式
                                            continue;
                                        }
                                        var dup = false;
                                        for (efforts.items) |e| {
                                            if (std.mem.eql(u8, e, s)) {
                                                dup = true;
                                                break;
                                            }
                                        }
                                        if (!dup) try efforts.append(arena, s);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            sortEfforts(efforts.items);

            const has_effort = efforts.items.len > 0;
            if (!has_effort and !toggle and ctx == 0) continue;

            const kind: Kind = if (has_effort) .effort else .toggle;
            if (has_effort) n_effort += 1 else n_toggle += 1;

            try map.put(arena, try keyOf(arena, pm.ours, mid), .{
                .provider = pm.ours,
                .model = mid,
                .ctx = ctx,
                .kind = kind,
                .efforts = efforts.items,
                .off_none = off_none,
            });
        }
    }

    // ── 2. 修正层（覆盖同名条目；也支持表外新条目）──
    var n_corr: usize = 0;
    if (getField(corr_doc.value, "corrections")) |corr| {
        if (corr == .array) {
            for (corr.array.items) |c| {
                const prov = getStr(c, "provider") orelse continue;
                const mid = getStr(c, "model") orelse continue;
                const k = try keyOf(arena, prov, mid);
                var e = map.get(k) orelse Entry{ .provider = prov, .model = mid };
                if (getField(c, "ctx")) |cv| {
                    if (cv == .integer and cv.integer > 0) e.ctx = @intCast(cv.integer);
                }
                if (getField(c, "off_none")) |ov| {
                    if (ov == .bool) e.off_none = ov.bool;
                }
                if (getField(c, "efforts")) |ev| {
                    if (ev == .array) {
                        var list = std.ArrayListUnmanaged([]const u8){ .items = &.{}, .capacity = 0 };
                        for (ev.array.items) |vv| {
                            const s = switch (vv) {
                                .string => |x| x,
                                else => continue,
                            };
                            if (s.len == 0 or std.mem.eql(u8, s, "none")) continue;
                            try list.append(arena, s);
                        }
                        sortEfforts(list.items);
                        e.efforts = list.items;
                        e.kind = .effort;
                    }
                }
                n_corr += 1;
                try map.put(arena, k, e);
            }
        }
    }

    // ── 3. 排序 + 输出 ──
    var list = std.ArrayListUnmanaged(Entry){ .items = &.{}, .capacity = 0 };
    var it2 = map.iterator();
    while (it2.next()) |kv| try list.append(arena, kv.value_ptr.*);
    const Cmp = struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            const p = std.mem.order(u8, a.provider, b.provider);
            if (p != .eq) return p == .lt;
            return std.mem.order(u8, a.model, b.model) == .lt;
        }
    };
    std.mem.sort(Entry, list.items, {}, Cmp.lessThan);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll(
        \\//! 模型能力表（自动生成，勿手改本文件）。
        \\//!
        \\//! 生成：tools/gen_model_table.zig（读 models.dev 数据 + tools/model_corrections.json）
        \\//! 修正：把实测发现写进 tools/model_corrections.json 后重跑脚本（修正永远优先）。
        \\//!
        \\//! 用途：/thinking 档位菜单、发送前钳制、上下文窗口。
        \\//! 表里没有的模型 → 视为未知（全档位可选 + 用户自行尝试），不影响使用。
        \\
        \\const std = @import("std");
        \\
        \\pub const Kind = enum { effort, toggle };
        \\
        \\pub const Entry = struct {
        \\    provider: []const u8,
        \\    model: []const u8,
        \\    /// 上下文窗口（0 = 无数据，调用方回退默认值）
        \\    ctx: u64 = 0,
        \\    /// effort = 有档位列表；toggle = 只有开/关
        \\    kind: Kind = .effort,
        \\    /// 可选档位（含 off，按档序排列；UI 直接使用）
        \\    levels: []const []const u8 = &.{},
        \\    /// off 是否用 reasoning_effort:"none" 表达（false = 不发送该字段）
        \\    off_none: bool = false,
        \\};
        \\
        \\pub const entries = [_]Entry{
        \\
    );

    for (list.items) |e| {
        try w.print("    .{{ .provider = \"{s}\", .model = \"{s}\", .ctx = {d}, .kind = .{s}, .off_none = {}, .levels = &.{{ ", .{
            e.provider, e.model, e.ctx, @tagName(e.kind), e.off_none,
        });
        // 展示列表 = off + 档位（toggle 型固定为 off/high——high 即"开"）
        try w.writeAll("\"off\"");
        if (e.kind == .toggle) {
            try w.writeAll(", \"high\"");
        } else {
            for (e.efforts) |ef| {
                try w.writeAll(", ");
                try w.print("\"{s}\"", .{ef});
            }
        }
        try w.writeAll(" } },\n");
    }
    try w.writeAll(
        \\};
        \\
        \\/// 查询：按 provider + model 精确匹配（provider 为空时仅按 model 且要求全局唯一）
        \\pub fn lookup(provider: []const u8, model: []const u8) ?*const Entry {
        \\    if (model.len == 0) return null;
        \\    if (provider.len > 0) {
        \\        for (&entries) |*e| {
        \\            if (std.mem.eql(u8, e.provider, provider) and std.mem.eql(u8, e.model, model)) return e;
        \\        }
        \\        return null;
        \\    }
        \\    // 无 provider 信息：仅当 model 全局唯一时命中
        \\    var found: ?*const Entry = null;
        \\    for (&entries) |*e| {
        \\        if (!std.mem.eql(u8, e.model, model)) continue;
        \\        if (found != null) return null; // 多个 provider 同名：不猜
        \\        found = e;
        \\    }
        \\    return found;
        \\}
        \\
    );

    const out_file = cwd.createFile(io, "src/model_table.zig", .{}) catch |e| {
        std.debug.print("无法写入 src/model_table.zig: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer out_file.close(io);
    out_file.writeStreamingAll(io, out.written()) catch |e| {
        std.debug.print("写入失败: {s}\n", .{@errorName(e)});
        return 1;
    };

    std.debug.print("完成: {d} 条（effort {d} / toggle {d}，修正 {d}）→ src/model_table.zig（{d} 字节）\n", .{
        list.items.len, n_effort, n_toggle, n_corr, out.written().len,
    });
    return 0;
}
