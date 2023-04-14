const std = @import("std");

const Sweep = struct {
    period: u3,
    negate: bool,
    shift: u3,
};

const pulse_seqs = [4][8]u1{
    .{ 0, 1, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 1, 0, 0, 0, 0, 0 },
    .{ 0, 1, 1, 1, 1, 0, 0, 0 },
    .{ 1, 0, 0, 1, 1, 1, 1, 1 },
};

const triangle_seq = [32]u4{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

const Pulse = struct {
    duty: u2,
    loop: bool,
    no_env: bool,
    volume: u4,
    timer_period: u11,
    timer: u11,
    sweep: ?Sweep,
    sequence_pos: u3,
    length_ctr: u5,

    fn init() Pulse {
        return Pulse{
            .duty = 2,
            .loop = false,
            .no_env = true,
            .volume = 0,
            .timer_period = 0,
            .timer = 0,
            .sweep = null,
            .sequence_pos = 0,
            .length_ctr = 0,
        };
    }

    fn set_reg(self: *Pulse, reg: u2, val: u8) void {
        if (reg == 0) {
            self.duty = @intCast(u2, val >> 6);
            self.loop = (val >> 5) & 1 == 1;
            self.no_env = (val >> 4) & 1 == 1;
            self.volume = @intCast(u4, val & 0x0f);
        } else if (reg == 1) {
            if (val & 0x80 != 0) {
                self.sweep = .{
                    .period = @intCast(u3, (val >> 4) & 7),
                    .negate = (val >> 3) & 1 == 1,
                    .shift = @intCast(u3, val & 7),
                };
            } else {
                self.sweep = null;
            }
        } else if (reg == 2) {
            self.timer_period = (self.timer_period & 0x700) | val;
        } else if (reg == 3) {
            self.timer_period = (self.timer_period & 0xff) | (@intCast(u11, val & 7) << 8);
            self.length_ctr = @intCast(u5, val >> 3);
            self.sequence_pos = 0;
            self.timer = 0;
        }
    }

    fn sample(self: *Pulse) f32 {
        if (self.timer_period < 8 or self.length_ctr == 0) return 0.0;
        const seq_out = pulse_seqs[self.duty][self.sequence_pos];
        return @intToFloat(f32, seq_out * self.volume);
    }
};

const Triangle = struct {
    timer_period: u11,
    timer: u11,
    sequence_pos: u5,
    length_ctr: u5,

    fn init() Triangle {
        return Triangle{
            .timer_period = 0,
            .timer = 0,
            .sequence_pos = 0,
            .length_ctr = 0,
        };
    }

    fn set_reg(self: *Triangle, reg: u2, val: u8) void {
        if (reg == 0) {
            // nyi
        } else if (reg == 2) {
            self.timer_period = (self.timer_period & 0x700) | val;
        } else if (reg == 3) {
            self.timer_period = (self.timer_period & 0xff) | (@intCast(u11, val & 7) << 8);
            self.length_ctr = @intCast(u5, val >> 3);
            self.sequence_pos = 0;
            self.timer = 0;
        }
    }

    fn sample(self: *Triangle) f32 {
        if (self.timer_period < 8 or self.length_ctr == 0) return 0.0;
        const seq_out = triangle_seq[self.sequence_pos];
        return @intToFloat(f32, seq_out);
    }
};

pub const Apu = struct {
    cycle: u64,
    samples: u64,
    buffer: std.BoundedArray(i16, 1024),
    pulse1: Pulse,
    pulse2: Pulse,
    triangle: Triangle,

    pub fn init() Apu {
        return Apu{
            .cycle = 0,
            .samples = 0,
            .buffer = .{ .buffer = undefined, .len = 0 },
            .pulse1 = Pulse.init(),
            .pulse2 = Pulse.init(),
            .triangle = Triangle.init(),
        };
    }
    pub fn reset(self: *Apu) void {
        self.cycle = 0;
        self.samples = 0;
        self.pulse1 = Pulse.init();
        self.pulse2 = Pulse.init();
        self.triangle = Triangle.init();
    }
    pub fn read(self: *Apu, add: u16) u8 {
        _ = add;
        _ = self;
        return 0;
    }
    pub fn write(self: *Apu, add: u16, val: u8) void {
        if (add < 0x4000) {
            unreachable;
        } else if (add < 0x4004) {
            self.pulse1.set_reg(@intCast(u2, add - 0x4000), val);
        } else if (add < 0x4008) {
            self.pulse2.set_reg(@intCast(u2, add - 0x4004), val);
        } else if (add < 0x400c) {
            self.triangle.set_reg(@intCast(u2, add - 0x4008), val);
        }
    }

    pub fn run_step(self: *Apu) void {
        if (self.pulse1.timer == 0) {
            self.pulse1.timer = self.pulse1.timer_period;
            self.pulse1.sequence_pos +%= 1;
        } else {
            self.pulse1.timer -= 1;
        }
        if (self.pulse2.timer == 0) {
            self.pulse2.timer = self.pulse2.timer_period;
            self.pulse2.sequence_pos +%= 1;
        } else {
            self.pulse2.timer -= 1;
        }
        if (self.triangle.timer == 0) {
            self.triangle.timer = self.triangle.timer_period;
            self.triangle.sequence_pos +%= 1;
        } else {
            self.triangle.timer -= 1;
        }
        self.cycle += 1;
    }

    pub fn sample(self: *Apu) void {
        const pulse1 = self.pulse1.sample();
        const pulse2 = self.pulse2.sample();
        const pulse_out = 95.88 / (8128 / (pulse1 + pulse2) + 100);

        const triangle = self.triangle.sample();
        const noise: f32 = 0.0;
        const dmc: f32 = 0.0;
        const tnd_out = 159.79 / (1 / (triangle / 8227 + noise / 12241 + dmc / 22638) + 100);

        const output = (pulse_out + tnd_out) * 0.25;
        self.buffer.append(@floatToInt(i16, @trunc(output * 32_768))) catch unreachable;
        self.samples += 1;
    }

    pub fn flush(self: *Apu) void {
        self.buffer.len = 0;
    }
};
