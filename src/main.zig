const std = @import("std");
const sdl2 = @cImport(@cInclude("SDL2/SDL.h"));

const Window = @import("./window.zig").Window;
const Nes = @import("./nes.zig").Nes;
const controller = @import("./controller.zig");
const Controller = controller.Controller;
const Button = controller.Button;

const loader = @import("./loader.zig");
const disasm = @import("./disasm.zig").disasm;
const movies = @import("./movie.zig");
const Movie = movies.Movie;

const Action = union(enum) {
    pause: void,
    frame_step: void,
    boost: void,
    controller0: Button,
};
const Keybind = std.meta.Tuple(&.{ sdl2.SDL_Scancode, Action });
const keybinds = [_]Keybind{
    .{ sdl2.SDL_SCANCODE_P, .pause },
    .{ sdl2.SDL_SCANCODE_O, .frame_step },
    .{ sdl2.SDL_SCANCODE_I, .boost },
    .{ sdl2.SDL_SCANCODE_W, .{ .controller0 = Button.Up } },
    .{ sdl2.SDL_SCANCODE_A, .{ .controller0 = Button.Left } },
    .{ sdl2.SDL_SCANCODE_S, .{ .controller0 = Button.Down } },
    .{ sdl2.SDL_SCANCODE_D, .{ .controller0 = Button.Right } },
    .{ sdl2.SDL_SCANCODE_L, .{ .controller0 = Button.A } },
    .{ sdl2.SDL_SCANCODE_K, .{ .controller0 = Button.B } },
    .{ sdl2.SDL_SCANCODE_J, .{ .controller0 = Button.Start } },
    .{ sdl2.SDL_SCANCODE_H, .{ .controller0 = Button.Select } },
};

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    if (args.len != 2 and args.len != 3) {
        std.debug.print("Use: ./nes <rom path> [<movie path>]\n", .{});
        return 1;
    }

    var movie: ?Movie = null;
    if (args.len == 3) {
        const movie_path = args[2];
        if (std.mem.endsWith(u8, movie_path, ".fm2")) {
            std.debug.print("Loading FM2 movie {s}...\n", .{movie_path});
            movie = movies.load_fm2(alloc, movie_path) catch |err| {
                std.debug.print("Could not load movie: {}\n", .{err});
                return 1;
            };
        } else {
            std.debug.print("Unknown extension for movie file, cannot load\n", .{});
            return 1;
        }
    }

    const rom_path = args[1];
    std.debug.print("Loading ROM {s}...\n", .{rom_path});
    var cart = loader.load_cart_file(alloc, rom_path) catch |err| {
        std.debug.print("Could not load NES ROM: {}\n", .{err});
        return 1;
    };
    defer cart.deinit(alloc);

    var nes = Nes.init(cart, Controller.init(), null);

    var win = Window(256, 224, 3).init("Zig NES Emulator");
    defer win.deinit();

    var paused = true;
    var boost = false;

    var last_frame = sdl2.SDL_GetTicks64();
    var dt: u64 = @divTrunc(1000, 60);

    var last_second = last_frame;
    var last_frame_no: u64 = 0;
    var fps = @as(i32, 0);

    var running = true;
    while (running) {
        var event: sdl2.SDL_Event = undefined;
        while (sdl2.SDL_PollEvent(&event) != 0) {
            if (event.type == sdl2.SDL_WINDOWEVENT and event.window.event == sdl2.SDL_WINDOWEVENT_CLOSE) {
                running = false;
            } else if (event.type == sdl2.SDL_KEYDOWN or event.type == sdl2.SDL_KEYUP) {
                const down = event.type == sdl2.SDL_KEYDOWN;
                const maybe_action = find_action: {
                    for (keybinds) |keybind| {
                        if (keybind[0] == event.key.keysym.scancode) {
                            break :find_action keybind[1];
                        }
                    }
                    break :find_action null;
                };
                if (maybe_action) |action| {
                    switch (action) {
                        .controller0 => |button| {
                            if (movie != null) continue;
                            if (nes.port0) |*port0| {
                                port0.set_button(button, down);
                            }
                        },
                        .pause => if (down) {
                            paused = !paused;
                        },
                        .frame_step => if (down and paused) {
                            nes.run_frame(movie);
                        },
                        .boost => boost = down,
                    }
                }
            }
        }

        if (!paused) {
            if (boost) {
                while (sdl2.SDL_GetTicks64() - last_frame < 15) {
                    nes.run_frame(movie);
                }
            } else {
                nes.run_frame(movie);
            }
        }

        win.update_buffer(nes.ppu.buffer[8..232]);
        win.queue_audio(nes.apu.buffer);

        win.render();

        win.debug.reset();
        win.debug.print("{d} FPS", .{fps});
        if (paused) {
            win.debug.print(" (paused)", .{});
        } else if (boost) {
            win.debug.print(" (boost)", .{});
        }

        win.debug.print("\nF{d:0>5} ", .{nes.frame_no});
        nes.port0.?.buttons.repr(win.debug.writer()) catch unreachable;

        sdl2.SDL_RenderPresent(win.ren);

        const now = sdl2.SDL_GetTicks64();
        dt = now - last_frame;
        last_frame = now;
        while (now > last_second + 1000) {
            last_second += 1000;
            fps = @intCast(nes.frame_no - last_frame_no);
            last_frame_no = nes.frame_no;
        }
    }

    return 0;
}
