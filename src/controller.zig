const sdl2 = @cImport(@cInclude("SDL2/SDL.h"));

fn bool_byte(b: bool) u8 {
    return if (b) 1 else 0;
}

pub const Button = enum { Up, Left, Down, Right, A, B, Start, Select };

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
    shift: u8,

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
            .shift = 0xff,
        };
    }

    pub fn set_button(self: *Controller, button: Button, state: bool) void {
        switch (button) {
            .Up => self.buttons.up = state,
            .Left => self.buttons.left = state,
            .Down => self.buttons.down = state,
            .Right => self.buttons.right = state,
            .A => self.buttons.a = state,
            .B => self.buttons.b = state,
            .Start => self.buttons.start = state,
            .Select => self.buttons.select = state,
        }
        self.update();
    }

    fn update(self: *Controller) void {
        if (self.latch & 1 == 1) {
            self.shift = bool_byte(self.buttons.a) | (bool_byte(self.buttons.b) << 1) | (bool_byte(self.buttons.select) << 2) | (bool_byte(self.buttons.start) << 3) | (bool_byte(self.buttons.up) << 4) | (bool_byte(self.buttons.down) << 5) | (bool_byte(self.buttons.left) << 6) | (bool_byte(self.buttons.right) << 7);
        }
    }

    pub fn write(self: *Controller, val: u8) void {
        self.update();
        self.latch = val;
    }

    pub fn read(self: *Controller) u8 {
        self.update();
        const bit = self.shift & 1;
        self.shift >>= 1;
        self.shift |= 0x80;
        return bit;
    }
};
