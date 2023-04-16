const std = @import("std");
const sdl2 = @cImport(@cInclude("SDL2/SDL.h"));

const Nes = @import("./nes.zig").Nes;
const loader = @import("./loader.zig");
const disasm = @import("./disasm.zig").disasm;

fn sdl_error() noreturn {
    std.debug.print("SDL error: {s}\n", .{sdl2.SDL_GetError()});
    std.os.exit(1);
}
fn sdl_check(err: c_int) void {
    if (err != 0) sdl_error();
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

    fn reset(pr: *DebugPrinter) void {
        pr.x = 0;
        pr.y = 0;
    }

    fn move(pr: *DebugPrinter, x: i32, y: i32) void {
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

    fn writer(pr: *DebugPrinter) DebugWriter {
        return DebugWriter{ .context = pr };
    }

    fn print(pr: *DebugPrinter, comptime fmt: []const u8, args: anytype) void {
        std.fmt.format(pr.writer(), fmt, args) catch unreachable;
    }
};

fn bool_int(b: bool) i32 {
    return if (b) 1 else 0;
}

pub fn main() !u8 {
    sdl_check(sdl2.SDL_Init(sdl2.SDL_INIT_VIDEO | sdl2.SDL_INIT_AUDIO));
    defer sdl2.SDL_Quit();

    _ = sdl2.SDL_SetHint(sdl2.SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR, "0");

    var win: *sdl2.SDL_Window = sdl2.SDL_CreateWindow("Zig NES Emulator", sdl2.SDL_WINDOWPOS_CENTERED, sdl2.SDL_WINDOWPOS_CENTERED, 768, 696, sdl2.SDL_WINDOW_SHOWN) orelse sdl_error();
    defer sdl2.SDL_DestroyWindow(win);

    var ren: *sdl2.SDL_Renderer = sdl2.SDL_CreateRenderer(win, -1, sdl2.SDL_RENDERER_ACCELERATED | sdl2.SDL_RENDERER_PRESENTVSYNC) orelse sdl_error();
    defer sdl2.SDL_DestroyRenderer(ren);

    var debug = DebugPrinter.init(ren);
    defer debug.uninit();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    if (args.len != 2) {
        std.debug.print("Use: ./nes <rom path>\n", .{});
        return 1;
    }
    const rom_path = args[1];
    std.debug.print("Loading ROM {s}...\n", .{rom_path});

    var cart = loader.load_cart_file(alloc, rom_path) catch |err| {
        std.debug.print("Could not load NES ROM: {}\n", .{err});
        return 1;
    };
    defer cart.deinit(alloc);
    var nes = Nes.init(cart);

    var buffer = sdl2.SDL_CreateTexture(ren, sdl2.SDL_PIXELFORMAT_RGB24, sdl2.SDL_TEXTUREACCESS_STREAMING, 256, 240);

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

    var debug_mode = false;
    var paused = true;
    var cur_page: u8 = 0xff;

    var last_frame = sdl2.SDL_GetTicks64();
    var dt: u64 = @divTrunc(1000, 60);

    var last_second = last_frame;
    var frame_ctr = @as(i32, 0);
    var fps = @as(i32, -1);

    var running = true;
    while (running) {
        var event: sdl2.SDL_Event = undefined;
        while (sdl2.SDL_PollEvent(&event) != 0) {
            if (event.type == sdl2.SDL_WINDOWEVENT and event.window.event == sdl2.SDL_WINDOWEVENT_CLOSE) {
                running = false;
            } else if (event.type == sdl2.SDL_KEYDOWN) {
                if (event.key.keysym.sym == sdl2.SDLK_p) { // pause
                    paused = !paused;
                } else if (event.key.keysym.sym == sdl2.SDLK_o) { // debug mode
                    debug_mode = !debug_mode;
                    nes.trace = debug_mode;
                } else if (event.key.keysym.sym == sdl2.SDLK_i and paused) { // step frame
                    nes.run_frame();
                } else if (event.key.keysym.sym == sdl2.SDLK_u and paused and debug_mode) { // step cycle
                    nes.run_instr();
                } else {
                    nes.controller.set_key(event.key.keysym.scancode, true);
                }
            } else if (event.type == sdl2.SDL_KEYUP) {
                nes.controller.set_key(event.key.keysym.scancode, false);
            }
        }

        if (!paused) {
            nes.run_frame();
        }

        sdl_check(sdl2.SDL_QueueAudio(audio_device, &nes.apu.buffer.buffer, @intCast(u32, nes.apu.buffer.len * 2)));
        const queued = sdl2.SDL_GetQueuedAudioSize(audio_device);
        nes.apu.flush();
        if (queued > 44100 / 15 * 2) {
            sdl2.SDL_PauseAudioDevice(audio_device, 0);
        }

        sdl_check(sdl2.SDL_SetRenderDrawColor(ren, 0, 0, 0, 255));
        sdl_check(sdl2.SDL_RenderClear(ren));

        if (!debug_mode) {
            var pixels: ?*anyopaque = undefined;
            var pitch: i32 = undefined;
            sdl_check(sdl2.SDL_LockTexture(buffer, null, &pixels, &pitch));
            for (0..240) |y| {
                std.mem.copy(u8, @ptrCast(*[256 * 3]u8, &@ptrCast([*]u8, pixels)[@intCast(usize, pitch) * y]), @ptrCast(*[256 * 3]u8, &nes.ppu.buffer[y]));
            }
            sdl2.SDL_UnlockTexture(buffer);
            const src_rect = sdl2.SDL_Rect{ .x = 8, .y = 0, .w = 256, .h = 232 };
            sdl_check(sdl2.SDL_RenderCopy(ren, buffer, &src_rect, null));
        }

        debug.reset();
        debug.print("{d} FPS", .{fps});
        if (paused) {
            debug.print(" (paused)", .{});
        }
        debug.print("\n", .{});

        if (debug_mode) {
            cur_page = @intCast(u8, nes.reg.pc >> 8);

            debug.print("A={x:0>2} X={x:0>2} Y={x:0>2} S={x:0>2}\n", .{ nes.reg.a, nes.reg.x, nes.reg.y, nes.reg.s });
            debug.print("C={d} Z={d} I={d} D={d} V={d} N={d}\n", .{
                bool_int(nes.reg.p.c), bool_int(nes.reg.p.z), bool_int(nes.reg.p.i),
                bool_int(nes.reg.p.d), bool_int(nes.reg.p.v), bool_int(nes.reg.p.n),
            });
            debug.print("PC={x:0>4}\n", .{nes.reg.pc});
            debug.print("Next instr: ", .{});
            disasm(&nes, nes.reg.pc, debug.writer()) catch unreachable;
            debug.print("\n", .{});
            debug.print("\n", .{});
            debug.print("Page {x:0>2}\n", .{cur_page});
            var row: u8 = 0;
            while (row < 16) : (row += 1) {
                const base_addr = @intCast(u16, cur_page) << 8 | row << 4;
                debug.print("{x:0>4} ", .{base_addr});
                var col: u8 = 0;
                while (col < 16) : (col += 1) {
                    const val = nes.read_opt(base_addr | col);
                    if (col % 4 == 0 and col != 0) {
                        debug.print(" ", .{});
                    }
                    if (val) |byte| {
                        debug.print("{x:0>2}", .{byte});
                    } else {
                        debug.print("??", .{});
                    }
                }
                debug.print("\n", .{});
            }
        }

        sdl2.SDL_RenderPresent(ren);

        frame_ctr += 1;
        const now = sdl2.SDL_GetTicks64();
        dt = now - last_frame;
        last_frame = now;
        while (now > last_second + 1000) {
            last_second += 1000;
            fps = frame_ctr;
            frame_ctr = 0;
        }
    }

    return 0;
}
