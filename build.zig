const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "SkyNet",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // zigtui
    const zigtui = b.dependency("zigtui", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("zigtui", zigtui.module("zigtui"));
    // fridge（bundle = true 表示内置编译 SQLite，避免依赖系统库）
    const fridge = b.dependency("fridge", .{ .target = target, .optimize = optimize, .bundle = true });
    exe.root_module.addImport("fridge", fridge.module("fridge"));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    // 透传 `zig build run -- <args>` 的参数（0.17 移除了 b.args，改用 Run.addPassthruArgs）
    run_cmd.addPassthruArgs();

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    // 一步验证两类代码路径：测试（test-only）+ exe 完整编译（exe-only，懒分析才会暴露）。
    // 只编译不安装（exe.step = 编译产物步），不会撞运行中实例的文件锁。
    const check_step = b.step("check", "Run tests and compile the app (covers exe-only paths)");
    check_step.dependOn(&run_exe_tests.step);
    check_step.dependOn(&exe.step);
}
