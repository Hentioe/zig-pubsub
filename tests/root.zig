// 测试入口集中收集测试文件，避免生产源码目录再承担测试聚合的职责。
comptime {
    _ = @import("pubsub_test.zig");
    _ = @import("deinit_test.zig");
}
