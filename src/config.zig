const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// 会话亲和方言：不同厂商给 prompt 缓存路由用的请求头各不相同
pub const Affinity = enum {
    none,
    /// opencode 网关：x-opencode-session + x-opencode-client
    opencode,
    /// OpenAI 系：session_id + x-client-request-id + x-session-affinity
    openai,
    /// OpenRouter：x-session-id
    openrouter,
    /// Fireworks 等：x-session-affinity
    fireworks,
};

/// prompt 缓存保留时长（none 表示不发缓存参数）
pub const CacheRetention = enum { none, short, long };

pub const HeaderKV = struct {
    name: []const u8 = "",
    value: []const u8 = "",
};

/// 内置提供商预设：地址 / API Key 环境变量 / 请求方言
pub const Preset = struct {
    id: []const u8,
    display: []const u8,
    endpoint: []const u8,
    api_key_env: []const u8 = "",
    affinity: Affinity = .none,
    cache_key: bool = false,
    retention: CacheRetention = .none,
    include_usage: bool = true,
};

pub const presets = [_]Preset{
    .{ .id = "openai", .display = "OpenAI", .endpoint = "https://api.openai.com/v1", .api_key_env = "OPENAI_API_KEY", .affinity = .openai, .cache_key = true, .retention = .short },
    .{ .id = "opencode", .display = "OpenCode Zen", .endpoint = "https://opencode.ai/zen/v1", .api_key_env = "OPENCODE_API_KEY", .affinity = .opencode },
    .{ .id = "opencode-go", .display = "OpenCode Zen Go", .endpoint = "https://opencode.ai/zen/go/v1", .api_key_env = "OPENCODE_API_KEY", .affinity = .opencode },
    .{ .id = "openrouter", .display = "OpenRouter", .endpoint = "https://openrouter.ai/api/v1", .api_key_env = "OPENROUTER_API_KEY", .affinity = .openrouter, .cache_key = true, .retention = .short },
    .{ .id = "deepseek", .display = "DeepSeek", .endpoint = "https://api.deepseek.com/v1", .api_key_env = "DEEPSEEK_API_KEY" },
    .{ .id = "moonshot", .display = "Moonshot / Kimi", .endpoint = "https://api.moonshot.cn/v1", .api_key_env = "MOONSHOT_API_KEY" },
    .{ .id = "zai", .display = "Z.ai (GLM)", .endpoint = "https://api.z.ai/api/paas/v4", .api_key_env = "ZHIPU_API_KEY" },
    .{ .id = "groq", .display = "Groq", .endpoint = "https://api.groq.com/openai/v1", .api_key_env = "GROQ_API_KEY" },
    .{ .id = "mistral", .display = "Mistral", .endpoint = "https://api.mistral.ai/v1", .api_key_env = "MISTRAL_API_KEY", .cache_key = true, .retention = .short },
    .{ .id = "xai", .display = "xAI (Grok)", .endpoint = "https://api.x.ai/v1", .api_key_env = "XAI_API_KEY", .cache_key = true, .retention = .short },
    .{ .id = "google", .display = "Google (OpenAI 兼容)", .endpoint = "https://generativelanguage.googleapis.com/v1beta/openai", .api_key_env = "GEMINI_API_KEY" },
    .{ .id = "cerebras", .display = "Cerebras", .endpoint = "https://api.cerebras.ai/v1", .api_key_env = "CEREBRAS_API_KEY", .cache_key = true, .retention = .short },
    .{ .id = "fireworks", .display = "Fireworks", .endpoint = "https://api.fireworks.ai/inference/v1", .api_key_env = "FIREWORKS_API_KEY", .affinity = .fireworks },
    .{ .id = "together", .display = "Together", .endpoint = "https://api.together.xyz/v1", .api_key_env = "TOGETHER_API_KEY" },
    .{ .id = "nvidia", .display = "NVIDIA NIM", .endpoint = "https://integrate.api.nvidia.com/v1", .api_key_env = "NVIDIA_API_KEY" },
    .{ .id = "siliconflow", .display = "SiliconFlow", .endpoint = "https://api.siliconflow.cn/v1", .api_key_env = "SILICONFLOW_API_KEY" },
    .{ .id = "lmstudio", .display = "LM Studio (本地)", .endpoint = "http://127.0.0.1:1234/v1" },
    .{ .id = "ollama", .display = "Ollama (本地)", .endpoint = "http://127.0.0.1:11434/v1" },
};

pub fn findPreset(id: []const u8) ?*const Preset {
    if (id.len == 0) return null;
    for (&presets) |*p| {
        if (std.mem.eql(u8, p.id, id)) return p;
    }
    return null;
}

/// 端点主机名是否为 opencode.ai（无预设时的兜底探测）
pub fn isOpenCodeHost(endpoint: []const u8) bool {
    const scheme_end = std.mem.indexOf(u8, endpoint, "://") orelse return false;
    const rest = endpoint[scheme_end + 3 ..];
    var host_end = rest.len;
    if (std.mem.indexOfAny(u8, rest, "/:?#")) |i| host_end = i;
    var host = rest[0..host_end];
    // 去掉可能的 userinfo
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    return std.ascii.eqlIgnoreCase(host, "opencode.ai");
}

fn parseAffinity(s: []const u8) ?Affinity {
    if (std.mem.eql(u8, s, "none")) return .none;
    if (std.mem.eql(u8, s, "opencode")) return .opencode;
    if (std.mem.eql(u8, s, "openai")) return .openai;
    if (std.mem.eql(u8, s, "openrouter")) return .openrouter;
    if (std.mem.eql(u8, s, "fireworks")) return .fireworks;
    return null;
}

fn parseRetention(s: []const u8) ?CacheRetention {
    if (std.mem.eql(u8, s, "none")) return .none;
    if (std.mem.eql(u8, s, "short")) return .short;
    if (std.mem.eql(u8, s, "long")) return .long;
    return null;
}

/// 主机名是否指向 DeepSeek 官方 API（直连时需要 thinking 开关字段）
pub fn isDeepSeekHost(endpoint: []const u8) bool {
    const scheme_end = std.mem.indexOf(u8, endpoint, "://") orelse return false;
    const rest = endpoint[scheme_end + 3 ..];
    var host_end = rest.len;
    if (std.mem.indexOfAny(u8, rest, "/:?#")) |i| host_end = i;
    var host = rest[0..host_end];
    if (std.mem.lastIndexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..];
    return std.ascii.indexOfIgnoreCase(host, "deepseek.com") != null;
}

/// 请求行为（预设 + 显式覆盖 + 主机名兜底三者合成）
pub const Behavior = struct {
    affinity: Affinity = .none,
    /// 是否在 body 里发 prompt_cache_key
    cache_key: bool = false,
    retention: CacheRetention = .none,
    /// 是否请求流式 usage（stream_options.include_usage）。
    /// 默认开启（几乎所有 OpenAI 兼容网关都接受 stream_options；不认的会忽略未知字段）。
    /// 没有真实 usage 时无法显示缓存命中率、压缩阈值只能退化为估算。
    include_usage: bool = true,
    extra_headers: []const HeaderKV = &.{},
    /// 思考强度："" 不发 / "off" / "low" / "high" / "max"
    reasoning_effort: []const u8 = "",
    /// DeepSeek 系：额外发 thinking:{type} 开关（直连 deepseek.com 或 deepseek 预设）
    deepseek_thinking: bool = false,
};

pub fn behavior(p: *const Provider) Behavior {
    var b = Behavior{};
    if (findPreset(p.preset)) |pr| {
        b.affinity = pr.affinity;
        b.cache_key = pr.cache_key;
        b.retention = pr.retention;
        b.include_usage = pr.include_usage;
    } else if (isOpenCodeHost(p.endpoint)) {
        b.affinity = .opencode;
    }
    if (std.mem.eql(u8, p.preset, "deepseek") or isDeepSeekHost(p.endpoint)) {
        b.deepseek_thinking = true;
    }

    // options 显式覆盖（空串 / "auto" 表示不覆盖）
    if (parseAffinity(p.opt_session_affinity)) |a| b.affinity = a;
    if (std.mem.eql(u8, p.opt_prompt_cache_key, "on")) {
        b.cache_key = true;
    } else if (std.mem.eql(u8, p.opt_prompt_cache_key, "off")) {
        b.cache_key = false;
    }
    if (parseRetention(p.opt_cache_retention)) |r| {
        b.retention = r;
    } else if (b.cache_key and b.retention == .none) {
        b.retention = .short;
    }
    // 流式 usage 覆盖：on/off 强制；空/"auto" 保持预设默认（当前默认全开）
    if (std.mem.eql(u8, p.opt_include_usage, "on")) {
        b.include_usage = true;
    } else if (std.mem.eql(u8, p.opt_include_usage, "off")) {
        b.include_usage = false;
    }
    b.extra_headers = p.opt_headers;
    return b;
}

pub const Provider = struct {
    name: []u8,
    endpoint: []u8,
    api_key: []u8,
    /// 预设 id（空 = 自定义）
    preset: []u8 = &.{},
    /// api_key 为空时回退读取的环境变量名（空 = 用预设默认）
    api_key_env: []u8 = &.{},
    /// 显式指定会话亲和方言：""/"auto" = 自动
    opt_session_affinity: []u8 = &.{},
    /// 显式开关 prompt_cache_key：""/"auto" = 自动，"on"/"off" 强制
    opt_prompt_cache_key: []u8 = &.{},
    /// 显式缓存保留策略：""/"auto" = 自动，"none"/"short"/"long"
    opt_cache_retention: []u8 = &.{},
    /// 显式开关流式 usage：""/"auto" = 自动（默认发），"on"/"off" 强制
    /// （个别网关不认 stream_options 时设为 "off"）
    opt_include_usage: []u8 = &.{},
    /// 显式指定上下文窗口大小（0 = 用启发式表）
    opt_context_window: u64 = 0,
    opt_headers: []HeaderKV = &.{},

    /// 有效 API Key 环境变量名（用户指定优先，否则取预设默认）
    pub fn effectiveApiKeyEnv(self: *const Provider) []const u8 {
        if (self.api_key_env.len > 0) return self.api_key_env;
        if (findPreset(self.preset)) |pr| return pr.api_key_env;
        return "";
    }

    pub fn deinit(self: *Provider, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.endpoint);
        allocator.free(self.api_key);
        freeOptional(allocator, self.preset);
        freeOptional(allocator, self.api_key_env);
        freeOptional(allocator, self.opt_session_affinity);
        freeOptional(allocator, self.opt_prompt_cache_key);
        freeOptional(allocator, self.opt_cache_retention);
        freeOptional(allocator, self.opt_include_usage);
        freeHeaders(allocator, self.opt_headers);
        self.opt_headers = &.{};
    }
};

fn freeOptional(allocator: Allocator, s: []u8) void {
    if (s.len > 0) allocator.free(s);
}

fn freeHeaders(allocator: Allocator, headers: []HeaderKV) void {
    for (headers) |h| {
        freeOptional(allocator, @constCast(h.name));
        freeOptional(allocator, @constCast(h.value));
    }
    if (headers.len > 0) allocator.free(headers);
}

const HeaderJson = struct {
    name: []const u8 = "",
    value: []const u8 = "",
};

const OptionsJson = struct {
    session_affinity: []const u8 = "",
    prompt_cache_key: []const u8 = "",
    cache_retention: []const u8 = "",
    include_usage: []const u8 = "",
    context_window: u64 = 0,
    headers: []const HeaderJson = &.{},
};

const ProviderJson = struct {
    name: []const u8 = "",
    preset: []const u8 = "",
    endpoint: []const u8 = "",
    api_key: []const u8 = "",
    api_key_env: []const u8 = "",
    options: OptionsJson = .{},
};

const CurrentJson = struct {
    provider: []const u8 = "",
    model: []const u8 = "",
};

const ConfigJson = struct {
    providers: []const ProviderJson = &.{},
    current: CurrentJson = .{},
    /// 全局思考强度：` / off / low / high / max
    thinking: []const u8 = "",
};

/// 新增/更新提供商用的字段集合
pub const ProviderSpec = struct {
    name: []const u8,
    endpoint: []const u8,
    api_key: []const u8 = "",
    preset: []const u8 = "",
    api_key_env: []const u8 = "",
    opt_session_affinity: []const u8 = "",
    opt_prompt_cache_key: []const u8 = "",
    opt_cache_retention: []const u8 = "",
    opt_include_usage: []const u8 = "",
    opt_context_window: u64 = 0,
    opt_headers: []const HeaderKV = &.{},
};

const SaveHeader = struct {
    name: []const u8,
    value: []const u8,
};

const SaveOptions = struct {
    session_affinity: ?[]const u8 = null,
    prompt_cache_key: ?[]const u8 = null,
    cache_retention: ?[]const u8 = null,
    include_usage: ?[]const u8 = null,
    context_window: ?i64 = null,
    headers: ?[]const SaveHeader = null,
};

const SaveProvider = struct {
    name: []const u8,
    endpoint: []const u8,
    api_key: []const u8,
    preset: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null,
    options: ?SaveOptions = null,
};

const SaveCurrent = struct {
    provider: []const u8,
    model: []const u8,
};

const SaveConfig = struct {
    providers: []const SaveProvider,
    current: SaveCurrent,
    thinking: ?[]const u8 = null,
};

fn dupeOptional(allocator: Allocator, s: []const u8) ![]u8 {
    if (s.len == 0) return &.{};
    return allocator.dupe(u8, s);
}

fn dupeHeaders(allocator: Allocator, headers: []const HeaderKV) ![]HeaderKV {
    if (headers.len == 0) return &.{};
    const out = try allocator.alloc(HeaderKV, headers.len);
    errdefer allocator.free(out);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |h| {
            freeOptional(allocator, @constCast(h.name));
            freeOptional(allocator, @constCast(h.value));
        }
    }
    for (headers, 0..) |h, i| {
        out[i] = .{
            .name = try dupeOptional(allocator, h.name),
            .value = try dupeOptional(allocator, h.value),
        };
        filled = i + 1;
    }
    return out;
}

fn buildProvider(allocator: Allocator, spec: ProviderSpec) !Provider {
    var p = Provider{
        .name = try allocator.dupe(u8, spec.name),
        .endpoint = undefined,
        .api_key = undefined,
    };
    errdefer allocator.free(p.name);

    p.endpoint = try allocator.dupe(u8, spec.endpoint);
    errdefer allocator.free(p.endpoint);
    p.api_key = try dupeOptional(allocator, spec.api_key);
    errdefer freeOptional(allocator, p.api_key);
    p.preset = try dupeOptional(allocator, spec.preset);
    errdefer freeOptional(allocator, p.preset);
    p.api_key_env = try dupeOptional(allocator, spec.api_key_env);
    errdefer freeOptional(allocator, p.api_key_env);
    p.opt_session_affinity = try dupeOptional(allocator, spec.opt_session_affinity);
    errdefer freeOptional(allocator, p.opt_session_affinity);
    p.opt_prompt_cache_key = try dupeOptional(allocator, spec.opt_prompt_cache_key);
    errdefer freeOptional(allocator, p.opt_prompt_cache_key);
    p.opt_cache_retention = try dupeOptional(allocator, spec.opt_cache_retention);
    errdefer freeOptional(allocator, p.opt_cache_retention);
    p.opt_include_usage = try dupeOptional(allocator, spec.opt_include_usage);
    errdefer freeOptional(allocator, p.opt_include_usage);
    p.opt_headers = try dupeHeaders(allocator, spec.opt_headers);
    return p;
}

pub const Config = struct {
    providers: std.ArrayListUnmanaged(Provider) = .{ .items = &.{}, .capacity = 0 },
    /// 当前使用提供商的名称（为空表示未选择）
    current_provider_name: []u8 = &.{},
    /// 当前使用的模型名（为空表示未选择）
    current_model: []u8 = &.{},
    /// 全局思考强度：` 不发 / off / low / high / max
    thinking: []u8 = &.{},

    pub fn load(self: *Config, io: Io, allocator: Allocator) void {
        self.loadFile(io, allocator, "config.json");
    }

    /// 从指定路径加载配置（CLI 的 -config 用）；默认路径缺失时会生成默认配置
    pub fn loadFile(self: *Config, io: Io, allocator: Allocator, path: []const u8) void {
        const dir = Io.Dir.cwd();
        const content = dir.readFileAlloc(io, path, allocator, .limited(1 << 20)) catch {
            // 仅默认配置路径缺失时生成默认配置（避免在任意路径下写出 config.json）
            if (std.mem.eql(u8, path, "config.json")) self.save(io, allocator);
            return;
        };
        defer allocator.free(content);

        var parsed = std.json.parseFromSlice(ConfigJson, allocator, content, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer parsed.deinit();
        const v = parsed.value;

        for (v.providers) |pj| {
            if (pj.endpoint.len == 0) continue;
            var headers: []HeaderKV = &.{};
            var headers_buf: [16]HeaderKV = undefined;
            var count: usize = 0;
            for (pj.options.headers) |h| {
                if (count >= headers_buf.len) break;
                if (h.name.len == 0) continue;
                headers_buf[count] = .{ .name = h.name, .value = h.value };
                count += 1;
            }
            headers = headers_buf[0..count];
            _ = self.appendProvider(allocator, .{
                .name = if (pj.name.len > 0) pj.name else "未命名",
                .endpoint = pj.endpoint,
                .api_key = pj.api_key,
                .preset = pj.preset,
                .api_key_env = pj.api_key_env,
                .opt_session_affinity = pj.options.session_affinity,
                .opt_prompt_cache_key = pj.options.prompt_cache_key,
                .opt_cache_retention = pj.options.cache_retention,
                .opt_include_usage = pj.options.include_usage,
                .opt_context_window = pj.options.context_window,
                .opt_headers = headers,
            });
        }

        if (self.providers.items.len > 0) {
            // 按名称匹配当前提供商；找不到时回退到第一个
            const matched = for (self.providers.items) |p| {
                if (std.mem.eql(u8, p.name, v.current.provider)) break true;
            } else false;
            self.setCurrentProvider(allocator, if (matched) v.current.provider else self.providers.items[0].name);
            if (v.current.model.len > 0) {
                self.setCurrentModel(allocator, v.current.model);
            }
            if (v.thinking.len > 0) {
                self.setThinking(allocator, v.thinking);
            }
        }
    }

    pub fn setCurrentProvider(self: *Config, allocator: Allocator, name: []const u8) void {
        const copy = allocator.dupe(u8, name) catch return;
        allocator.free(self.current_provider_name);
        self.current_provider_name = copy;
    }

    pub fn setCurrentModel(self: *Config, allocator: Allocator, model: []const u8) void {
        const copy = allocator.dupe(u8, model) catch return;
        allocator.free(self.current_model);
        self.current_model = copy;
    }

    /// 设置全局思考强度（""/off/low/high/max）
    pub fn setThinking(self: *Config, allocator: Allocator, value: []const u8) void {
        const copy = allocator.dupe(u8, value) catch return;
        allocator.free(self.thinking);
        self.thinking = copy;
    }

    pub fn appendProvider(self: *Config, allocator: Allocator, spec: ProviderSpec) bool {
        const p = buildProvider(allocator, spec) catch return false;
        self.providers.append(allocator, p) catch {
            var doomed = p;
            doomed.deinit(allocator);
            return false;
        };
        return true;
    }

    /// 覆盖提供商字段（失败时保持原值）
    pub fn updateProvider(self: *Config, allocator: Allocator, idx: usize, spec: ProviderSpec) bool {
        if (idx >= self.providers.items.len) return false;
        const p = buildProvider(allocator, spec) catch return false;
        self.providers.items[idx].deinit(allocator);
        self.providers.items[idx] = p;
        return true;
    }

    pub fn removeProvider(self: *Config, allocator: Allocator, idx: usize) void {
        if (idx >= self.providers.items.len) return;
        var removed = self.providers.orderedRemove(idx);
        removed.deinit(allocator);
    }

    pub fn save(self: *Config, io: Io, allocator: Allocator) void {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();

        var save_list = std.ArrayListUnmanaged(SaveProvider){ .items = &.{}, .capacity = 0 };
        defer save_list.deinit(allocator);

        var header_lists = std.ArrayListUnmanaged([]SaveHeader){ .items = &.{}, .capacity = 0 };
        defer {
            for (header_lists.items) |hl| {
                if (hl.len > 0) allocator.free(hl);
            }
            header_lists.deinit(allocator);
        }

        for (self.providers.items) |p| {
            var save_headers: ?[]const SaveHeader = null;
            if (p.opt_headers.len > 0) {
                const hl = allocator.alloc(SaveHeader, p.opt_headers.len) catch return;
                for (p.opt_headers, 0..) |h, i| {
                    hl[i] = .{ .name = h.name, .value = h.value };
                }
                header_lists.append(allocator, hl) catch {
                    allocator.free(hl);
                    return;
                };
                save_headers = hl;
            }
            save_list.append(allocator, .{
                .name = p.name,
                .endpoint = p.endpoint,
                .api_key = p.api_key,
                .preset = if (p.preset.len > 0) p.preset else null,
                .api_key_env = if (p.api_key_env.len > 0) p.api_key_env else null,
                .options = .{
                    .session_affinity = if (p.opt_session_affinity.len > 0) p.opt_session_affinity else null,
                    .prompt_cache_key = if (p.opt_prompt_cache_key.len > 0) p.opt_prompt_cache_key else null,
                    .cache_retention = if (p.opt_cache_retention.len > 0) p.opt_cache_retention else null,
                    .include_usage = if (p.opt_include_usage.len > 0) p.opt_include_usage else null,
                    .context_window = if (p.opt_context_window > 0) @intCast(p.opt_context_window) else null,
                    .headers = save_headers,
                },
            }) catch return;
        }

        var stringify: std.json.Stringify = .{
            .writer = &out.writer,
            .options = .{ .whitespace = .indent_2, .emit_null_optional_fields = false },
        };
        stringify.write(SaveConfig{
            .providers = save_list.items,
            .current = .{
                .provider = self.current_provider_name,
                .model = self.current_model,
            },
            .thinking = if (self.thinking.len > 0) self.thinking else null,
        }) catch return;

        const dir = Io.Dir.cwd();
        const file = dir.createFile(io, "config.json", .{}) catch return;
        defer file.close(io);
        file.writeStreamingAll(io, out.written()) catch return;
    }

    pub fn deinit(self: *Config, allocator: Allocator) void {
        for (self.providers.items) |*p| {
            p.deinit(allocator);
        }
        self.providers.deinit(allocator);
        self.providers = .{ .items = &.{}, .capacity = 0 };
        allocator.free(self.current_provider_name);
        self.current_provider_name = &.{};
        allocator.free(self.current_model);
        self.current_model = &.{};
        allocator.free(self.thinking);
        self.thinking = &.{};
    }
};

test "预设表：可查找且字段合理" {
    const openai = findPreset("openai") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("https://api.openai.com/v1", openai.endpoint);
    try std.testing.expectEqual(Affinity.openai, openai.affinity);
    try std.testing.expect(openai.cache_key);

    const zen = findPreset("opencode") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Affinity.opencode, zen.affinity);
    try std.testing.expectEqualStrings("OPENCODE_API_KEY", zen.api_key_env);

    try std.testing.expect(findPreset("") == null);
    try std.testing.expect(findPreset("no-such-preset") == null);
}

/// 所有预设默认请求流式 usage（无真实 usage 时缓存命中率/压缩阈值都不可用）
fn allPresetsDefaultIncludeUsage() bool {
    for (&presets) |*p| {
        if (!p.include_usage) return false;
    }
    return true;
}

test "behavior：预设 + 覆盖 + 主机名兜底" {
    // 预设：OpenAI 方言 + 缓存 key
    var p = Provider{
        .name = @constCast("openai"),
        .endpoint = @constCast("https://api.openai.com/v1"),
        .api_key = @constCast("k"),
        .preset = @constCast("openai"),
    };
    var b = behavior(&p);
    try std.testing.expectEqual(Affinity.openai, b.affinity);
    try std.testing.expect(b.cache_key);
    try std.testing.expectEqual(CacheRetention.short, b.retention);
    try std.testing.expect(b.include_usage);

    // 无预设但主机是 opencode.ai → 兜底 opencode 方言；usage 默认仍开启
    p.preset = @constCast("");
    p.endpoint = @constCast("https://opencode.ai/zen/go/v1");
    b = behavior(&p);
    try std.testing.expectEqual(Affinity.opencode, b.affinity);
    try std.testing.expect(!b.cache_key);
    try std.testing.expect(b.include_usage);

    // 任意自定义端点（无预设）：usage 默认开启（默认全发，预设可显式关）
    p.endpoint = @constCast("http://127.0.0.1:9999/v1");
    b = behavior(&p);
    try std.testing.expect(b.include_usage);
    try std.testing.expect(allPresetsDefaultIncludeUsage());

    // 显式覆盖：关缓存 key、改方言、强制 long
    p.opt_session_affinity = @constCast("openrouter");
    p.opt_prompt_cache_key = @constCast("off");
    p.opt_cache_retention = @constCast("long");
    b = behavior(&p);
    try std.testing.expectEqual(Affinity.openrouter, b.affinity);
    try std.testing.expect(!b.cache_key);
    try std.testing.expectEqual(CacheRetention.long, b.retention);

    // 流式 usage 覆盖：off 可关（严格网关逃生门），on 可强制，auto/空 保持默认
    p.opt_include_usage = @constCast("off");
    b = behavior(&p);
    try std.testing.expect(!b.include_usage);
    p.opt_include_usage = @constCast("on");
    b = behavior(&p);
    try std.testing.expect(b.include_usage);
    p.opt_include_usage = @constCast("auto");
    b = behavior(&p);
    try std.testing.expect(b.include_usage);
    p.opt_include_usage = @constCast("");

    // 自定义头部透传
    const headers = [_]HeaderKV{.{ .name = "X-Test", .value = "1" }};
    p.opt_headers = @constCast(&headers);
    b = behavior(&p);
    try std.testing.expectEqual(@as(usize, 1), b.extra_headers.len);
    try std.testing.expectEqualStrings("X-Test", b.extra_headers[0].name);

    // DeepSeek 探测：deepseek 预设或直连主机 → deepseek_thinking
    var dp = Provider{
        .name = @constCast("d"),
        .endpoint = @constCast("https://api.deepseek.com/v1"),
        .api_key = @constCast("k"),
        .preset = @constCast(""),
    };
    try std.testing.expect(behavior(&dp).deepseek_thinking);
    dp.endpoint = @constCast("https://gw.example.com/v1");
    try std.testing.expect(!behavior(&dp).deepseek_thinking);
    dp.preset = @constCast("deepseek");
    try std.testing.expect(behavior(&dp).deepseek_thinking);
}

test "env 回退名：用户指定优先于预设" {
    var p = Provider{
        .name = @constCast("x"),
        .endpoint = @constCast("https://example.com/v1"),
        .api_key = @constCast(""),
        .preset = @constCast("openai"),
    };
    try std.testing.expectEqualStrings("OPENAI_API_KEY", p.effectiveApiKeyEnv());
    p.api_key_env = @constCast("MY_OPENAI_KEY");
    try std.testing.expectEqualStrings("MY_OPENAI_KEY", p.effectiveApiKeyEnv());
    p.preset = @constCast("");
    p.api_key_env = @constCast("");
    try std.testing.expectEqualStrings("", p.effectiveApiKeyEnv());
}

test "config：JSON 解析新字段并应用" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "providers": [
        \\    {
        \\      "name": "company-gw",
        \\      "preset": "openrouter",
        \\      "endpoint": "https://gw.example.com/v1",
        \\      "api_key": "",
        \\      "api_key_env": "COMPANY_KEY",
        \\      "options": {
        \\        "session_affinity": "openai",
        \\        "prompt_cache_key": "on",
        \\        "cache_retention": "long",
        \\        "include_usage": "off",
        \\        "headers": [{ "name": "X-Org", "value": "acme" }]
        \\      }
        \\    }
        \\  ],
        \\  "current": { "provider": "company-gw", "model": "m1" }
        \\}
    ;
    var parsed = try std.json.parseFromSlice(ConfigJson, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const pj = parsed.value.providers[0];
    try std.testing.expectEqualStrings("openrouter", pj.preset);
    try std.testing.expectEqualStrings("COMPANY_KEY", pj.api_key_env);
    try std.testing.expectEqualStrings("openai", pj.options.session_affinity);
    try std.testing.expectEqualStrings("long", pj.options.cache_retention);
    try std.testing.expectEqualStrings("off", pj.options.include_usage);
    try std.testing.expectEqualStrings("X-Org", pj.options.headers[0].name);

    // 解析出的 include_usage 覆盖经 behavior 生效
    var p = Provider{
        .name = @constCast("company-gw"),
        .endpoint = @constCast("https://gw.example.com/v1"),
        .api_key = @constCast(""),
        .preset = @constCast("openrouter"),
        .opt_include_usage = @constCast(pj.options.include_usage),
    };
    try std.testing.expect(!behavior(&p).include_usage);
}
