const std = @import("std");
const sdl2 = @cImport(@cInclude("SDL2/SDL.h"));

fn sdl_error() noreturn {
    std.debug.print("SDL error: {s}\n", .{sdl2.SDL_GetError()});
    std.os.exit(1);
}
fn sdl_check(err: c_int) void {
    if (err != 0) sdl_error();
}

pub fn Window(comptime width: i32, comptime height: i32) type {
    return struct {
        const Self = @This();

        win: *sdl2.SDL_Window,
        ren: *sdl2.SDL_Renderer,
        debug: DebugPrinter,
        buffer: *sdl2.SDL_Texture,
        draw_buffer: bool,
        audio_device: sdl2.SDL_AudioDeviceID,

        pub fn init(title: [*c]const u8, scale: i32) Self {
            sdl_check(sdl2.SDL_Init(sdl2.SDL_INIT_VIDEO | sdl2.SDL_INIT_AUDIO));
            _ = sdl2.SDL_SetHint(sdl2.SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR, "0");
            var win: *sdl2.SDL_Window = sdl2.SDL_CreateWindow(title, sdl2.SDL_WINDOWPOS_CENTERED, sdl2.SDL_WINDOWPOS_CENTERED, width * scale, height * scale, sdl2.SDL_WINDOW_SHOWN) orelse sdl_error();
            var ren: *sdl2.SDL_Renderer = sdl2.SDL_CreateRenderer(win, -1, sdl2.SDL_RENDERER_ACCELERATED | sdl2.SDL_RENDERER_PRESENTVSYNC) orelse sdl_error();
            var debug = DebugPrinter.init(ren);
            var buffer = sdl2.SDL_CreateTexture(ren, sdl2.SDL_PIXELFORMAT_RGB24, sdl2.SDL_TEXTUREACCESS_STREAMING, width, height);
            if (buffer == null) sdl_error();
            const desired_audio = sdl2.SDL_AudioSpec{
                .freq = 44100,
                .format = sdl2.AUDIO_S16SYS,
                .channels = 1,
                .samples = 4096,
                .callback = null,
                .userdata = undefined,
                .silence = undefined,
                .size = undefined,
                .padding = undefined,
            };
            const audio_device = sdl2.SDL_OpenAudioDevice(null, 0, &desired_audio, null, 0);
            if (audio_device == 0) sdl_error();
            return Self{ .win = win, .ren = ren, .debug = debug, .buffer = buffer.?, .audio_device = audio_device, .draw_buffer = true };
        }

        pub fn queue_audio(self: *Self, buffer: anytype) void {
            sdl_check(sdl2.SDL_QueueAudio(self.audio_device, &buffer.buffer, @intCast(u32, buffer.len * 2)));
            const queued = sdl2.SDL_GetQueuedAudioSize(self.audio_device);
            if (queued > 44100 / 30 * 2) {
                sdl2.SDL_PauseAudioDevice(self.audio_device, 0);
            }
        }

        pub fn update_buffer(self: *Self, buffer: *[height][width][3]u8) void {
            var pixels: ?*anyopaque = undefined;
            var pitch: i32 = undefined;
            sdl_check(sdl2.SDL_LockTexture(self.buffer, null, &pixels, &pitch));
            for (0..height) |y| {
                std.mem.copy(u8, @ptrCast(*[width * 3]u8, &@ptrCast([*]u8, pixels)[@intCast(usize, pitch) * y]), @ptrCast(*[width * 3]u8, &buffer[y]));
            }
            sdl2.SDL_UnlockTexture(self.buffer);
        }

        pub fn render(self: *Self) void {
            sdl_check(sdl2.SDL_SetRenderDrawColor(self.ren, 0, 0, 0, 255));
            sdl_check(sdl2.SDL_RenderClear(self.ren));

            if (self.draw_buffer) {
                sdl_check(sdl2.SDL_RenderCopy(self.ren, self.buffer, null, null));
            }
        }

        pub fn deinit(self: *Self) void {
            sdl2.SDL_CloseAudioDevice(self.audio_device);
            sdl2.SDL_DestroyTexture(self.buffer);
            self.debug.uninit();
            sdl2.SDL_DestroyRenderer(self.ren);
            sdl2.SDL_DestroyWindow(self.win);
            sdl2.SDL_Quit();
        }
    };
}

const DebugPrinter = struct {
    ren: *sdl2.SDL_Renderer,
    font_tex: *sdl2.SDL_Texture,
    x: i32,
    y: i32,

    fn init(ren: *sdl2.SDL_Renderer) DebugPrinter {
        const font_bmp = @embedFile("./font.bmp");
        const font_rw = sdl2.SDL_RWFromConstMem(font_bmp, font_bmp.len) orelse sdl_error();
        const font_surf = sdl2.SDL_LoadBMP_RW(font_rw, 1) orelse sdl_error();
        const font_tex = sdl2.SDL_CreateTextureFromSurface(ren, font_surf) orelse sdl_error();
        sdl2.SDL_FreeSurface(font_surf);

        return DebugPrinter{ .ren = ren, .font_tex = font_tex, .x = 0, .y = 0 };
    }
    fn uninit(pr: *DebugPrinter) void {
        sdl2.SDL_DestroyTexture(pr.font_tex);
    }

    pub fn reset(pr: *DebugPrinter) void {
        pr.x = 0;
        pr.y = 0;
    }

    pub fn move(pr: *DebugPrinter, x: i32, y: i32) void {
        pr.x = x;
        pr.y = y;
    }

    fn putc(pr: *DebugPrinter, c: u8) void {
        if (c == '\n') {
            pr.x = 0;
            pr.y += 1;
            return;
        }

        const zoom = 2;
        const src = sdl2.SDL_Rect{ .x = ((c - 32) % 18) * 7 + 1, .y = ((c - 32) / 18) * 9 + 1, .w = 5, .h = 7 };
        const dest = sdl2.SDL_Rect{ .x = (pr.x * 6 + 1) * zoom, .y = (pr.y * 9 + 1) * zoom, .w = 5 * zoom, .h = 7 * zoom };
        sdl_check(sdl2.SDL_RenderCopy(pr.ren, pr.font_tex, &src, &dest));
        pr.x += 1;
        if (pr.x == 512 / zoom / 6) {
            pr.x = 0;
            pr.y += 1;
        }
    }

    fn puts(pr: *DebugPrinter, bytes: []const u8) !usize {
        for (bytes) |c| {
            pr.putc(c);
        }
        return bytes.len;
    }

    const DebugWriter = std.io.Writer(*DebugPrinter, error{}, DebugPrinter.puts);

    pub fn writer(pr: *DebugPrinter) DebugWriter {
        return DebugWriter{ .context = pr };
    }

    pub fn print(pr: *DebugPrinter, comptime fmt: []const u8, args: anytype) void {
        std.fmt.format(pr.writer(), fmt, args) catch unreachable;
    }
};
