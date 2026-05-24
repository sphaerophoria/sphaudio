const std = @import("std");
const sphtud = @import("sphtud");
const pw = @import("pw_bindings");
const DynPipewire2 = @import("dyn_pw");
const DynSpa = @import("dyn_spa");

pub const StreamBuffer = sphtud.util.CircularBuffer(i16);

var pw_lib: ?std.DynLib = null;
var dpw: DynPipewire2 = undefined;

var spa_lib: ?std.DynLib = null;
var dspa: DynSpa = undefined;

const Pipewire = @This();

loop: *pw.pw_loop,

pub fn init() !Pipewire {
    if (pw_lib == null) {
        pw_lib = try std.DynLib.open("libpipewire-0.3.so");
        try sphtud.strong_dyn.load(&pw_lib.?, &dpw);
    }

    if (spa_lib == null) {
        spa_lib = try std.DynLib.open("libspa.so");
        try sphtud.strong_dyn.load(&spa_lib.?, &dspa);
    }

    // Docs say that this can be called multiple times, so just rip it with
    // null/null in the constructor. If someone for some reason does decide
    // to initialize us twice, things should continue to just work
    dpw.pw_init(null, null);

    const pw_loop = dpw.pw_loop_new(null) orelse return error.MakePwLoop;
    errdefer dpw.pw_loop_destroy(pw_loop);

    // This is supposed to be called one time on the thread that will run
    // the event loop. SPA docs say that this is usually for capturing the
    // thread ID.
    //
    // Since we expect to be single threaded, it's more convenient to call
    // this on construction than it is to force users of Pipewire to
    // manually call it when they create the event loop
    //
    // This locks the loop
    dpw.pw_loop_enter(pw_loop);

    return .{
        .loop = pw_loop,
    };
}

pub fn deinit(self: *Pipewire) void {
    // Note that we call pw_loop_enter in the constructor, and you'd think
    // there should be an equivalent pw_loop_leave, but if we're just
    // deiniting the loop who cares?

    dpw.pw_loop_destroy(self.loop);
}

pub fn pollFd(self: Pipewire) std.posix.fd_t {
    return dpw.pw_loop_get_fd(self.loop);
}

pub const AudioStream = struct {
    stream: *pw.pw_stream,
    sb: StreamBuffer,
    num_channels: u8,

    pub fn initPinned(self: *AudioStream, parent: *Pipewire, params: AudioParams) !void {
        const props = dpw.pw_properties_new(pw.PW_KEY_MEDIA_TYPE, "Audio",
                    pw.PW_KEY_MEDIA_CATEGORY, "Playback",
                    pw.PW_KEY_MEDIA_ROLE, "Music",
                    @as([*c]u8, 0));

        // It looks like props ownership is transfered to the stream, whether
        // or not stream initialization succeeds, no cleanup required

        const stream = dpw.pw_stream_new_simple(
                            parent.loop,
                            "audio-src",
                            props,
                            &stream_events,
                            self) orelse return error.MakeStream;
        errdefer dpw.pw_stream_destroy(stream);

        self.* = .{
            .stream = stream,
            .sb = .{
                .items = params.buf,
                .head = 0,
                .tail = 0,
            },
            .num_channels = params.num_channels,
        };

        var builder_buf: [1024]u8 = undefined;
        var b = pw.spa_pod_builder {
            .data = &builder_buf,
            .size = builder_buf.len,
        };
        const audio_format = pw.spa_audio_info_raw {
            .format = pw.SPA_AUDIO_FORMAT_S16,
            .channels = params.num_channels,
            .rate = params.sample_rate,
        };

        // spa_params is a pointer into builder_buf, so no need to release any
        // resources
        var spa_params = dspa.spa_format_audio_raw_build(&b, pw.SPA_PARAM_EnumFormat,
                            &audio_format);

        const connect_res = dpw.pw_stream_connect(stream,
                      pw.PW_DIRECTION_OUTPUT,
                      pw.PW_ID_ANY,
                      pw.PW_STREAM_FLAG_AUTOCONNECT |
                      pw.PW_STREAM_FLAG_MAP_BUFFERS |
                      pw.PW_STREAM_FLAG_RT_PROCESS,
                      @ptrCast(&spa_params), 1);

        if (connect_res != 0) return error.MakeStream;
    }

    pub fn deinit(self: *AudioStream) void {
        dpw.pw_stream_destroy(self.stream);
    }
};

pub const AudioParams = struct {
    num_channels: u8,
    sample_rate: u32,
    buf: []i16,
};

pub fn service(self: *Pipewire) !void {
    // Docs say this returns the number of fds that were dispatched.
    // Looking through spa source code, this goes through
    //
    // pw_loop_iterate
    // -> spa_control_iterate_fast
    // -> iterate vtable
    // -> loop_iterate
    // -> pollfd_wait vtable
    // -> impl_pollfd_wait
    //
    // which can return -errno
    //
    // So I guess we check for < 0
    if (dpw.pw_loop_iterate(self.loop, 0) < 0) {
        return error.Pipewire;
    }
}

fn onProcess(userdata: ?*anyopaque) callconv(.c) void {
    const as: *Pipewire.AudioStream = @ptrCast(@alignCast(userdata));

    const b: *pw.pw_buffer = dpw.pw_stream_dequeue_buffer(as.stream) orelse return;

    const buffer = b.buffer[0];

    if (buffer.n_datas < 1) return;

    const bd = buffer.datas[0];

    const stride = as.num_channels * @sizeOf(i16);

    const max_out_frames = bd.maxsize / stride;
    const max_in_frames = as.sb.count() / 2;
    const requested_frames = b.requested;

    const fill_frames = @min(requested_frames, @min(max_in_frames, max_out_frames));

    const out_slice_ptr: [*]i16 = @ptrCast(@alignCast(bd.data));
    const out_slice: []i16 = out_slice_ptr[0..fill_frames * as.num_channels];

    for (0..fill_frames) |i| {
        for (0..as.num_channels) |j| {
            out_slice[i * as.num_channels + j] = as.sb.pop() orelse unreachable;
        }
    }

    bd.chunk[0].offset = 0;
    bd.chunk[0].stride = stride;
    bd.chunk[0].size = fill_frames * stride;

    _ = dpw.pw_stream_queue_buffer(as.stream, b);
}

const stream_events = pw.pw_stream_events {
        .version = pw.PW_VERSION_STREAM_EVENTS,
        .process = onProcess,
};
