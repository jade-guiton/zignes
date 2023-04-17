const sdl2 = @cImport(@cInclude("SDL2/SDL.h"));

fn bool_byte(b: bool) u8 {
    return if (b) 1 else 0;
}

pub const Button = enum { Up, Left, Down, Right, A, B, Start, Select };

pub const ButtonStates = struct {
    a: bool,
    b: bool,
    select: bool,
    start: bool,
    up: bool,
    down: bool,
    left: bool,
    right: bool,

    pub fn init() ButtonStates {
        return ButtonStates{
            .a = false,
            .b = false,
            .select = false,
            .start = false,
            .up = false,
            .down = false,
            .left = false,
            .right = false,
        };
    }

    pub fn set_button(self: *ButtonStates, button: Button, state: bool) void {
        switch (button) {
            .Up => self.up = state,
            .Left => self.left = state,
            .Down => self.down = state,
            .Right => self.right = state,
            .A => self.a = state,
            .B => self.b = state,
            .Start => self.start = state,
            .Select => self.select = state,
        }
    }

    pub fn repr(self: *ButtonStates, writer: anytype) !void {
        try writer.writeByte(if (self.left) 'L' else '.');
        try writer.writeByte(if (self.right) 'R' else '.');
        try writer.writeByte(if (self.up) 'U' else '.');
        try writer.writeByte(if (self.down) 'D' else '.');
        try writer.writeByte(if (self.a) 'A' else '.');
        try writer.writeByte(if (self.b) 'B' else '.');
        try writer.writeByte(if (self.start) 'S' else '.');
        try writer.writeByte(if (self.select) 's' else '.');
    }
};

pub const Controller = struct {
    buttons: ButtonStates,

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
        self.buttons.set_button(button, state);
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
