const std = @import("std");
const sphtud = @import("sphtud");
const sphaudio = @import("sphaudio");

const PwService = struct {
    expansion: sphtud.util.ExpansionAlloc,
    pool: sphtud.util.ObjectPool(sphaudio.Pipewire.AudioStream, usize),
    impl: sphaudio.Pipewire,

    fn init(arena: std.mem.Allocator, expansion: sphtud.util.ExpansionAlloc, loop: *sphtud.io.Loop, service_id: usize) !PwService {
        const impl = try sphaudio.Pipewire.init();

        try loop.register(.{
            .id = service_id,
            .handle = impl.pollFd(),
            .read = true,
            .write = false,
        });

        return .{
            .expansion = expansion,
            .pool = try .init(
                arena,
                expansion,
                4,
                1024,
            ),
            .impl = impl,
        };
    }

    fn deinit(self: *PwService) void {
        // Note that we call pw_loop_enter in the constructor, and you'd think
        // there should be an equivalent pw_loop_leave, but if we're just
        // deiniting the loop who cares?

        var it = self.pool.iter();
        while (it.next()) |elem| {
            elem.val.deinit();
        }

        self.impl.deinit();
    }

    const AudioStreamHandle = struct {
        id: usize,
    };

    fn newAudioStream(self: *PwService, params: sphaudio.Pipewire.AudioParams) !AudioStreamHandle {
        const ret = try self.pool.acquire(self.expansion);
        errdefer self.pool.release(self.expansion, ret.handle);

        try ret.val.initPinned(&self.impl, params);
        errdefer ret.val.deinit();

        return .{ .id = ret.handle };
    }

    pub fn getStreamBuffer(self: *PwService, handle: AudioStreamHandle) *sphaudio.Pipewire.StreamBuffer {
        return &self.pool.get(handle.id).sb;
    }

    pub fn service(self: *PwService) !void {
        try self.impl.service();
    }
};


pub fn main() !void {
    var alloc_buf: [1 * 1024 * 1024]u8 = undefined;
    var buf_alloc = sphtud.alloc.BufAllocator.init(&alloc_buf);

    const arena = buf_alloc.allocator();
    const expansion = buf_alloc.expansion();

    var chain_buf: [100]usize = undefined;
    var loop = try sphtud.io.Loop.init(&chain_buf);

    var pws = try PwService.init(arena, expansion, &loop, 0);
    defer pws.deinit();

    var sample_buf: [512 * 1024 / 4]i16 = undefined;

    const num_channels = 2;
    const sample_rate = 44100;
    const samples_per_440 = sample_rate / 440;
    const samples_per_880 = sample_rate / 880;

    const stream = try pws.newAudioStream(.{
        .buf = &sample_buf,
        .num_channels = num_channels,
        .sample_rate = sample_rate,
    });

    var timer = try sphtud.io.TimerService.init(arena, expansion, &loop, 1);

    const timer_handle = try timer.add(.fromMilliseconds(200), 2);
    var acc: usize = 0;

    while (true) {
        const event = try loop.poll(-1) orelse continue;

        switch (event) {
            0 => {
                try pws.service();
            },
            1 => {
                try timer.service(&loop);
            },
            2 => {
                const buf = pws.getStreamBuffer(stream);
                const num_samples = (buf.items.len - buf.count()) / 2;

                for (0..num_samples) |_| {
                    const sample_f32 =
                        std.math.sin(@as(f32, @floatFromInt(acc)) * std.math.pi * 2 / samples_per_440) / 2.0 +
                        std.math.sin(@as(f32, @floatFromInt(acc)) * std.math.pi * 2 / samples_per_880) / 2.0;

                    const sample: i16 = @intFromFloat(sample_f32 * std.math.maxInt(i16));
                    for (0..num_channels) |_| {
                        buf.pushNoClobber(sample) catch unreachable;
                    }

                    acc += 1;
                    acc = acc % 44100;
                }

                try timer.rearm(timer_handle, .fromMilliseconds(200));
            },
            else => unreachable,
        }
    }
}
