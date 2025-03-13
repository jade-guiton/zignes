const std = @import("std");

const Sweep = struct {
    period: u3,
    timer: u3,
    muted: bool,
    negate: bool,
    shift: u3,
    reload: bool,
};

const pulse_seqs = [4][8]u1{
    .{ 0, 1, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 1, 0, 0, 0, 0, 0 },
    .{ 0, 1, 1, 1, 1, 0, 0, 0 },
    .{ 1, 0, 0, 1, 1, 1, 1, 1 },
};

const triangle_seq = [32]u4{ 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

const length_ctr_table = [32]u8{ 10, 254, 20, 2, 40, 4, 80, 6, 160, 8, 60, 10, 14, 12, 26, 14, 12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30 };

const noise_periods = [16]u12{ 4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068 };

fn Pulse(comptime is_pulse2: bool) type {
    return struct {
        const Self = @This();

        enabled: bool,
        duty: u2,
        loop: bool,
        no_env: bool,
        volume: u4,
        timer_period: u11,
        timer: u11,
        sweep: ?Sweep,
        sequence_pos: u3,
        length_ctr: u8,
        env_start: bool,
        env_timer: u4,
        env_decay: u4,

        fn init() Self {
            return Self{
                .enabled = true,
                .duty = 2,
                .loop = false,
                .no_env = true,
                .volume = 0,
                .timer_period = 0,
                .timer = 0,
                .sweep = null,
                .sequence_pos = 0,
                .length_ctr = 0,
                .env_start = false,
                .env_timer = 0,
                .env_decay = 0,
            };
        }

        fn set_reg(self: *Self, reg: u2, val: u8) void {
            if (reg == 0) {
                self.duty = @intCast(val >> 6);
                self.loop = (val >> 5) & 1 == 1;
                self.no_env = (val >> 4) & 1 == 1;
                self.volume = @intCast(val & 0x0f);
            } else if (reg == 1) {
                if (val & 0x80 != 0) {
                    self.sweep = .{
                        .period = @intCast((val >> 4) & 7),
                        .timer = 0,
                        .muted = false,
                        .negate = (val >> 3) & 1 == 1,
                        .shift = @intCast(val & 7),
                        .reload = true,
                    };
                } else {
                    self.sweep = null;
                }
            } else if (reg == 2) {
                self.timer_period = (self.timer_period & 0x700) | val;
            } else if (reg == 3) {
                self.timer_period = (self.timer_period & 0xff) | (@as(u11, @intCast(val & 7)) << 8);
                if (self.enabled) {
                    self.length_ctr = length_ctr_table[val >> 3];
                }
                self.sequence_pos = 0;
                self.timer = 0;
                self.env_start = true;
            }
        }

        fn clock_linear(self: *Self) void {
            if (self.env_start) {
                self.env_start = false;
                self.env_decay = 15;
                self.env_timer = self.volume;
            } else if (self.env_timer == 0) {
                self.env_timer = self.volume;
                if (self.env_decay == 0) {
                    if (self.loop) {
                        self.env_decay = 15;
                    }
                } else {
                    self.env_decay -= 1;
                }
            } else {
                self.env_timer -= 1;
            }
        }

        fn clock_length(self: *Self) void {
            if (self.length_ctr != 0 and !self.loop) {
                self.length_ctr -= 1;
            }
            if (self.sweep) |*sweep| {
                var change_amount: u12 = @intCast(self.timer_period >> sweep.shift);
                if (sweep.negate) {
                    change_amount = ~change_amount;
                    if (is_pulse2) {
                        change_amount +%= 1;
                    }
                }
                const target_period = self.timer_period +% change_amount;

                sweep.muted = self.timer_period < 8 or target_period >= 0x800;
                if (sweep.timer == 0 and !sweep.muted) {
                    self.timer_period = @intCast(target_period);
                }
                if (sweep.timer == 0 or sweep.reload) {
                    sweep.timer = sweep.period;
                    sweep.reload = false;
                } else {
                    sweep.timer -= 1;
                }
            }
        }

        fn sample(self: *Self) f32 {
            if (!self.enabled or self.timer_period < 8 or self.length_ctr == 0 or (self.sweep != null and self.sweep.?.muted)) return 0.0;
            const seq_out = pulse_seqs[self.duty][self.sequence_pos];
            const volume = if (self.no_env) self.volume else self.env_decay;
            return @floatFromInt(seq_out * volume);
        }
    };
}

const Triangle = struct {
    enabled: bool,
    timer_period: u11,
    timer: u11,
    sequence_pos: u5,
    length_ctr: u8,
    control: bool,
    linear_reload_value: u7,
    linear_reload: bool,
    linear_ctr: u7,

    fn init() Triangle {
        return Triangle{
            .enabled = true,
            .timer_period = 0,
            .timer = 0,
            .sequence_pos = 0,
            .length_ctr = 0,
            .control = false,
            .linear_reload_value = 0,
            .linear_reload = false,
            .linear_ctr = 0,
        };
    }

    fn set_reg(self: *Triangle, reg: u2, val: u8) void {
        if (reg == 0) {
            self.control = (val >> 7) & 1 == 1;
            self.linear_reload_value = @intCast(val & 0x7f);
        } else if (reg == 2) {
            self.timer_period = (self.timer_period & 0x700) | val;
        } else if (reg == 3) {
            self.timer_period = (self.timer_period & 0xff) | (@as(u11, @intCast(val & 7)) << 8);
            if (self.enabled) {
                self.length_ctr = length_ctr_table[val >> 3];
            }
            self.timer = 0;
            self.linear_reload = true;
        }
    }

    fn clock_linear(self: *Triangle) void {
        if (self.linear_reload) {
            self.linear_ctr = self.linear_reload_value;
        } else if (self.linear_ctr != 0) {
            self.linear_ctr -= 1;
        }
        if (!self.control) {
            self.linear_reload = false;
        }
    }

    fn clock_length(self: *Triangle) void {
        if (self.length_ctr != 0 and !self.control) {
            self.length_ctr -= 1;
        }
    }

    fn sample(self: *Triangle) f32 {
        if (self.timer_period < 2) return 7.0;
        const seq_out = triangle_seq[self.sequence_pos];
        return @floatFromInt(seq_out);
    }
};

const Noise = struct {
    enabled: bool,
    loop: bool,
    no_env: bool,
    volume: u4,
    timer_period: u12,
    timer: u12,
    length_ctr: u8,
    env_start: bool,
    env_timer: u4,
    env_decay: u4,

    shift_reg: u15,
    mode: u1,

    fn init() Noise {
        return Noise{
            .enabled = true,
            .loop = false,
            .no_env = true,
            .volume = 0,
            .timer_period = 0,
            .timer = 0,
            .length_ctr = 0,
            .env_start = false,
            .env_timer = 0,
            .env_decay = 0,

            .shift_reg = 1,
            .mode = 0,
        };
    }

    fn set_reg(self: *Noise, reg: u2, val: u8) void {
        if (reg == 0) {
            self.loop = (val >> 5) & 1 == 1;
            self.no_env = (val >> 4) & 1 == 1;
            self.volume = @intCast(val & 0x0f);
        } else if (reg == 1) {
            // nothing here
        } else if (reg == 2) {
            self.timer_period = noise_periods[val & 0x0f];
            self.mode = @intCast(val >> 7);
        } else if (reg == 3) {
            if (self.enabled) {
                self.length_ctr = length_ctr_table[val >> 3];
            }
            self.timer = 0;
            self.env_start = true;
        }
    }

    fn clock_linear(self: *Noise) void {
        if (self.env_start) {
            self.env_start = false;
            self.env_decay = 15;
            self.env_timer = self.volume;
        } else if (self.env_timer == 0) {
            self.env_timer = self.volume;
            if (self.env_decay == 0) {
                if (self.loop) {
                    self.env_decay = 15;
                }
            } else {
                self.env_decay -= 1;
            }
        } else {
            self.env_timer -= 1;
        }
    }

    fn clock_length(self: *Noise) void {
        // std.debug.print("Noise.clock_length\n", .{});
        if (self.length_ctr != 0 and !self.loop) {
            self.length_ctr -= 1;
            // std.debug.print("New length ctr: {d}\n", .{self.length_ctr});
        }
    }

    fn sample(self: *Noise) f32 {
        if (!self.enabled or self.length_ctr == 0) return 0.0;
        const volume = if (self.no_env) self.volume else self.env_decay;
        return @floatFromInt((self.shift_reg & 1) * volume);
    }
};

fn LowPass(comptime freq: f32) type {
    const x = std.math.tau / 44100.0 * freq;
    const alpha = x / (1 + x);
    return struct {
        const Self = @This();

        prev_output: f32,

        fn init() Self {
            return .{ .prev_output = 0 };
        }

        fn apply(self: *Self, input: f32) f32 {
            const output = alpha * input + (1 - alpha) * self.prev_output;
            self.prev_output = output;
            return output;
        }
    };
}
fn HighPass(comptime freq: f32) type {
    const x = std.math.tau / 44100.0 * freq;
    const alpha = 1 / (1 + x);
    return struct {
        const Self = @This();

        prev_output: f32,
        prev_input: f32,

        fn init() Self {
            return .{ .prev_output = 0, .prev_input = 0 };
        }

        fn apply(self: *Self, input: f32) f32 {
            const output = alpha * self.prev_output + alpha * (input - self.prev_input);
            self.prev_input = input;
            self.prev_output = output;
            return output;
        }
    };
}

pub const Apu = struct {
    cycle: u64,
    samples: u64,
    buffer: std.BoundedArray(i16, 1024),
    pulse1: Pulse(false),
    pulse2: Pulse(true),
    triangle: Triangle,
    noise: Noise,
    seq_mode: u1,
    seq_timer: u16,
    irq_inhibit: bool,
    irq: bool,

    pub fn init() Apu {
        return Apu{
            .cycle = 0,
            .samples = 0,
            .buffer = .{ .buffer = undefined, .len = 0 },
            .pulse1 = Pulse(false).init(),
            .pulse2 = Pulse(true).init(),
            .triangle = Triangle.init(),
            .noise = Noise.init(),
            .seq_mode = 0,
            .seq_timer = 0,
            .irq_inhibit = true,
            .irq = false,
        };
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
            self.pulse1.set_reg(@intCast(add - 0x4000), val);
        } else if (add < 0x4008) {
            self.pulse2.set_reg(@intCast(add - 0x4004), val);
        } else if (add < 0x400c) {
            self.triangle.set_reg(@intCast(add - 0x4008), val);
        } else if (add < 0x4010) {
            self.noise.set_reg(@intCast(add - 0x400c), val);
        } else if (add == 0x4015) {
            self.pulse1.enabled = val & 1 == 1;
            if (!self.pulse1.enabled) self.pulse1.length_ctr = 0;
            self.pulse2.enabled = (val >> 1) & 1 == 1;
            if (!self.pulse2.enabled) self.pulse2.length_ctr = 0;
            self.triangle.enabled = (val >> 2) & 1 == 1;
            if (!self.triangle.enabled) self.triangle.length_ctr = 0;
            self.noise.enabled = (val >> 3) & 1 == 1;
            if (!self.noise.enabled) self.noise.length_ctr = 0;
        } else if (add == 0x4017) {
            self.seq_mode = @intCast((val >> 7) & 1);
            self.irq_inhibit = (val >> 6) & 1 == 1;
            self.seq_timer = 0;
            self.clock_linear();
            self.clock_length();
        }
    }

    fn clock_linear(self: *Apu) void {
        self.pulse1.clock_linear();
        self.pulse2.clock_linear();
        self.triangle.clock_linear();
        self.noise.clock_linear();
    }

    fn clock_length(self: *Apu) void {
        self.pulse1.clock_length();
        self.pulse2.clock_length();
        self.triangle.clock_length();
        self.noise.clock_length();
    }

    pub fn run_step(self: *Apu) void {
        if (self.cycle % 2 == 0) {
            if (self.seq_timer == 14914 and self.seq_mode == 0) {
                if (!self.irq_inhibit) {
                    self.irq = true;
                }
                self.clock_linear();
                self.clock_length();
                self.seq_timer = 0;
            } else if (self.seq_timer == 18640 and self.seq_mode == 1) {
                self.clock_linear();
                self.clock_length();
                self.seq_timer = 0;
            } else {
                if (self.seq_timer == 3728) {
                    self.clock_linear();
                } else if (self.seq_timer == 7456) {
                    self.clock_linear();
                    self.clock_length();
                } else if (self.seq_timer == 11185) {
                    self.clock_linear();
                }
                self.seq_timer += 1;
            }

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

            if (self.noise.timer == 0) {
                self.noise.timer = self.noise.timer_period;
                const feedback_bit = @as(u3, if (self.noise.mode == 1) 6 else 1);
                const feedback = (self.noise.shift_reg & 1) ^ ((self.noise.shift_reg >> feedback_bit) & 1);
                self.noise.shift_reg = ((self.noise.shift_reg >> 1) & 0x3fff) | (feedback << 14);
            } else {
                self.noise.timer -= 1;
            }
        }

        if (self.triangle.timer == 0) {
            self.triangle.timer = self.triangle.timer_period;
            if (self.triangle.linear_ctr != 0 and self.triangle.length_ctr != 0) {
                self.triangle.sequence_pos +%= 1;
            }
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
        const noise = self.noise.sample();
        const dmc: f32 = 0.0;
        const tnd_out = 159.79 / (1 / (triangle / 8227 + noise / 12241 + dmc / 22638) + 100);

        const output = (pulse_out + tnd_out) * 0.25;
        self.buffer.append(@intFromFloat(@trunc(output * 32_767))) catch {};
        self.samples += 1;
    }

    pub fn flush(self: *Apu) void {
        self.buffer.len = 0;
    }
};
