const std = @import("std");

/// 接收订阅消息时可能返回的独立错误集。
/// QueueClosedError 表示队列已关闭；Cancelable 表示接收操作被取消；
/// NotSubscribed 表示句柄对应的订阅节点已不存在于发布者路由中。
pub const RecvError = std.Io.QueueClosedError || std.Io.Cancelable || error{
    NotSubscribed,
};

/// 表示订阅是否挂接在某个发布者的路由中。
pub const State = enum { active, canceled };

/// 订阅句柄按值保存身份；销毁节点后仍可安全地再次用于取消。
pub fn Subscription(comptime Message: type, comptime Tag: type, comptime Owner: type) type {
    // 标准队列按元素大小换算字节数，零大小元素无法安全使用该接口。
    if (@sizeOf(Message) == 0) @compileError("zero-sized messages are not supported by std.Io.Queue");
    return struct {
        /// 发布者的身份，取消时不解引用此指针。
        owner: *Owner,
        /// 主题与单调递增的编号共同定位路由中的唯一订阅。
        topic: Tag,
        id: u64,
        /// 接收使用的节点仅在取消订阅之前有效。
        node: *Node,

        /// 发布者管理的链表节点和队列。
        pub const Node = struct {
            const Self = @This();
            /// 订阅的主题决定该节点所在的路由链表。
            topic: Tag,
            /// 同一发布者的路由锁保护节点的挂接状态。
            state: State = .active,
            /// 唯一编号用于防止旧句柄误取消地址重用后的新订阅。
            id: u64,
            /// 订阅独立持有分配器，使取消后仍能释放队列及节点。
            allocator: std.mem.Allocator,
            /// 队列的固定容量缓冲区，由订阅独占。
            buffer: []Message,
            /// 用于串接同一主题的订阅节点。
            next_for_topic: ?*Self = null,
            /// 队列拥有自己的同步机制，底层存储由订阅独占。
            queue: std.Io.Queue(Message),
            /// 保护接收操作计数，确保队列关闭后不会过早释放节点。
            recv_lock: std.Io.Mutex = .init,
            /// 最后一个接收操作退出时唤醒负责释放节点的任务。
            recv_done: std.Io.Condition = .init,
            /// 已取得节点、但尚未结束的接收操作数。
            active_receivers: usize = 0,

            /// 关闭队列并释放节点；调用方持有发布者写锁，禁止新的接收进入。
            pub fn destroy(self: *Self, io: std.Io) void {
                self.queue.close(io);
                self.recv_lock.lockUncancelable(io);
                // close 唤醒阻塞中的接收者；等它们退出队列后才能释放队列存储。
                while (self.active_receivers != 0) self.recv_done.waitUncancelable(io, &self.recv_lock);
                self.recv_lock.unlock(io);
                const allocator = self.allocator;
                allocator.free(self.buffer);
                allocator.destroy(self);
            }
        };

        /// 关闭订阅队列，但保留节点在发布者路由中。
        /// 关闭后禁止新消息进入；队列中已有消息仍可通过 recv 接收完毕。
        /// 调用方随后应等待接收者退出，再调用 unsubscribe 移除并释放节点。
        pub fn close(self: @This(), io: std.Io) void {
            const owner = self.owner;
            owner.lock.lockSharedUncancelable(io);
            defer owner.lock.unlockShared(io);
            var next = owner.topics[Owner.topicIndex(self.topic)].subscribers;
            while (next) |node| : (next = node.next_for_topic) {
                if (node.id == self.id) {
                    node.queue.close(io);
                    return;
                }
            }
        }

        /// 批量接收消息并写入 buffer，返回实际写入的消息数量。
        /// min 为零时轮询，否则等待至少 min 条消息；关闭或取消时可能提前返回部分消息。
        /// buffer 的长度必须不小于 min；取消或发布者关闭会关闭队列并唤醒等待者。
        /// 发布者实例必须保持有效，直至所有并发操作返回。
        pub fn recv(self: @This(), io: std.Io, buffer: []Message, min: usize) RecvError!usize {
            const owner = self.owner;
            try owner.lock.lockShared(io);
            var next = owner.topics[Owner.topicIndex(self.topic)].subscribers;
            while (next) |node| : (next = node.next_for_topic) {
                if (node.id != self.id) continue;
                // 在路由读锁内登记接收操作，使取消或关闭不能提前释放节点。
                node.recv_lock.lockUncancelable(io);
                node.active_receivers += 1;
                node.recv_lock.unlock(io);
                owner.lock.unlockShared(io);
                defer {
                    node.recv_lock.lockUncancelable(io);
                    node.active_receivers -= 1;
                    if (node.active_receivers == 0) node.recv_done.signal(io);
                    node.recv_lock.unlock(io);
                }
                return node.queue.get(io, buffer, min);
            }
            owner.lock.unlockShared(io);
            return error.NotSubscribed;
        }
    };
}
