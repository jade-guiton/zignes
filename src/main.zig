const std = @import("std");
const sdl2 = @cImport(@cInclude("SDL2/SDL.h"));

const Window = @import("./window.zig").Window;
const Nes = @import("./nes.zig").Nes;
const controller = @import("./controller.zig");
const Controller = controller.Controller;
const Button = controller.Button;
const loader = @import("./loader.zig");
const disasm = @import("./disasm.zig").disasm;

const Action = union(enum) {
    pause: void,
    frame_step: void,
    controller0: Button,
};
const Keybind = std.meta.Tuple(&.{ sdl2.SDL_Scancode, Action });
const keybinds = [_]Keybind{
    .{ sdl2.SDL_SCANCODE_P, .pause },
    .{ sdl2.SDL_SCANCODE_O, .frame_step },
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
    var nes = Nes.init(cart, Controller.init(), null);

    var win = Window(256, 224).init("Zig NES Emulator", 3);
    defer win.deinit();

    var paused = true;

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
                            if (nes.port0) |*port0| {
                                port0.set_button(button, down);
                            }
                        },
                        .pause => if (down) {
                            paused = !paused;
                        },
                        .frame_step => if (down and paused) {
                            nes.run_frame();
                        },
                    }
                }
            }
        }

        if (!paused) {
            nes.run_frame();
        }

        win.update_buffer(nes.ppu.buffer[8..232]);
        win.queue_audio(nes.apu.buffer);
        nes.apu.flush();

        win.render();

        win.debug.reset();
        win.debug.print("{d} FPS", .{fps});
        if (paused) {
            win.debug.print(" (paused)", .{});
        }
        win.debug.print("\n", .{});

        sdl2.SDL_RenderPresent(win.ren);

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
