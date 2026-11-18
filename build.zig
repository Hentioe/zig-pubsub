const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_rc = b.dependency("zig_rc", .{});

    const mod = b.addModule("zig_pub_sub", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    mod.addImport("zig_rc", zig_rc.module("zig_rc"));

    // 示例是独立可执行文件，库模块仍只以 src/root.zig 为公开入口。
    const example = b.addExecutable(.{
        .name = "basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_pub_sub", .module = mod },
            },
        }),
    });

    example.root_module.addImport("zig_rc", zig_rc.module("zig_rc"));

    b.installArtifact(example);

    const run_step = b.step("run", "Run the basic example");
    const run_cmd = b.addRunArtifact(example);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const example_tests = b.addTest(.{
        .root_module = example.root_module,
    });
    const run_example_tests = b.addRunArtifact(example_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_example_tests.step);
}
