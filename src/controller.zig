const sdl2 = @cImport(@cInclude("SDL2/SDL.h"));

fn bool_byte(b: bool) u8 {
    return if (b) 1 else 0;
}

pub const Controller = struct {
    buttons: struct {
        a: bool,
        b: bool,
        select: bool,
        start: bool,
        up: bool,
        down: bool,
        left: bool,
        right: bool,
    },

    latch: u8,
    shift: [2]u8,

    pub fn init() Controller {
        return Controller{
            .buttons = .{
                .a = false,
                .b = false,
                .select = false,
                .start = false,
                .up = false,
                .down = false,
                .left = false,
                .right = false,
            },
            .latch = 0,
            .shift = .{ 0xff, 0 },
        };
    }

    pub fn set_key(self: *Controller, scancode: sdl2.SDL_Scancode, state: bool) void {
        if (scancode == sdl2.SDL_SCANCODE_W) {
            self.buttons.up = state;
        } else if (scancode == sdl2.SDL_SCANCODE_A) {
            self.buttons.left = state;
        } else if (scancode == sdl2.SDL_SCANCODE_S) {
            self.buttons.down = state;
        } else if (scancode == sdl2.SDL_SCANCODE_D) {
            self.buttons.right = state;
        } else if (scancode == sdl2.SDL_SCANCODE_L) {
            self.buttons.a = state;
        } else if (scancode == sdl2.SDL_SCANCODE_K) {
            self.buttons.b = state;
        } else if (scancode == sdl2.SDL_SCANCODE_J) {
            self.buttons.start = state;
        } else if (scancode == sdl2.SDL_SCANCODE_H) {
            self.buttons.select = state;
        }
    }

    fn update(self: *Controller) void {
        if (self.latch & 1 == 1) {
            self.shift[0] = bool_byte(self.buttons.a) | (bool_byte(self.buttons.b) << 1) | (bool_byte(self.buttons.select) << 2) | (bool_byte(self.buttons.start) << 3) | (bool_byte(self.buttons.up) << 4) | (bool_byte(self.buttons.down) << 5) | (bool_byte(self.buttons.left) << 6) | (bool_byte(self.buttons.right) << 7);
            self.shift[1] = 0; // For now...
        }
    }

    pub fn write(self: *Controller, val: u8) void {
        self.update();
        self.latch = val;
    }

    pub fn read(self: *Controller, port: u1) u8 {
        self.update();
        const bit = self.shift[port] & 1;
        self.shift[port] >>= 1;
        const connected = port == 0;
        if (connected) self.shift[port] |= 0x80;
        return bit;
    }
};
