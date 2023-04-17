const std = @import("std");

const Cart = @import("./mapper.zig").Cart;
const Ppu = @import("./ppu.zig").Ppu;
const Apu = @import("./apu.zig").Apu;
const Controller = @import("./controller.zig").Controller;

const movies = @import("./movie.zig");
const instructions = @import("./disasm.zig").instructions;
const disasm = @import("./disasm.zig").disasm;

const Arg = union(enum) {
    imm: u8,
    add: u16,
    reg_a: void,
    reg_s: void,
};
fn arg_add(x: u16) Arg {
    return Arg{ .add = x };
}
fn arg_imm(x: u8) Arg {
    return Arg{ .imm = x };
}

fn bool_byte(b: bool) u8 {
    return if (b) 1 else 0;
}
fn get_bit(b: u8, n: u8) bool {
    return (b >> n) & 1 == 1;
}
fn twos_compl(b: u8) u8 {
    return ~b +% 1;
}

pub const Nes = struct {
    cart: Cart,
    ppu: Ppu,
    apu: Apu,
    port0: ?Controller,
    port1: ?Controller,
    ram: [2048]u8,
    reg: struct {
        pc: u16, // program counter
        s: u8, // stack pointer (+$0100)
        a: u8, // accumulator
        x: u8, // x index register
        y: u8, // y index register
        p: struct { // processor status (flags)
            c: bool, // carry
            z: bool, // zero
            i: bool, // interrupt disable
            d: bool, // decimal
            v: bool, // overflow
            n: bool, // negative
        },
    },
    old_nmi: bool,
    old_irq: bool,
    cpu_cycle: u64,
    page_crossed: bool,
    found_nyi: bool,
    master_cycle: u64,
    trace: bool,
    frame_no: u64,

    pub fn init(cart: Cart, port0: ?Controller, port1: ?Controller) Nes {
        var nes = Nes{
            .cart = cart,
            .ppu = Ppu.init(cart),
            .apu = Apu.init(),
            .port0 = port0,
            .port1 = port1,
            .ram = [_]u8{0} ** 2048,
            .reg = .{
                .pc = 0x0000,
                .s = 0xfd,
                .a = 0,
                .x = 0,
                .y = 0,
                .p = .{
                    .c = false,
                    .z = false,
                    .i = true,
                    .d = false,
                    .v = false,
                    .n = false,
                },
            },
            .old_nmi = false,
            .old_irq = false,
            .cpu_cycle = 0,
            .page_crossed = false,
            .found_nyi = false,
            .master_cycle = 0,
            .trace = false,
            .frame_no = 0,
        };

        nes.reg.pc = nes.read16_cycle(0xfffc);
        nes.cpu_cycle = 7;

        return nes;
    }

    fn op_nyi(self: *Nes, op: u8) void {
        std.debug.print("UNKNOWN OPCODE  {x:0>2} ({s} {s}) PC={x:0>4} CYC={d}\n", .{ op, instructions[op].mne, instructions[op].mode.str(), self.reg.pc, self.cpu_cycle });
        self.found_nyi = true;
    }

    pub fn get_flags_byte(self: *Nes, b_flag: bool) u8 {
        // zig fmt: off
        return bool_byte(self.reg.p.c)
            | (bool_byte(self.reg.p.z) << 1)
            | (bool_byte(self.reg.p.i) << 2)
            | (bool_byte(self.reg.p.d) << 3)
            | (bool_byte(b_flag) << 4)
            | (1 << 5)
            | (bool_byte(self.reg.p.v) << 6)
            | (bool_byte(self.reg.p.n) << 7);
        // zig fmt: on
    }

    pub fn read_opt(self: *Nes, add: u16) ?u8 {
        if (add < 0x2000) { // RAM
            return self.ram[add & 0x7ff];
        } else if (add < 0x4000) { // PPU
            return self.ppu.cpu_read(0x2000 | (add & 7));
        } else if (add < 0x4020) { // APU + I/O
            if (add == 0x4015) { // APU status
                return self.apu.read(add);
            } else if (add == 0x4016) { // Controller 1
                if (self.port0) |*ctrl| {
                    return ctrl.read();
                } else {
                    return 0;
                }
            } else if (add == 0x4017) { // Controller 2
                if (self.port1) |*ctrl| {
                    return ctrl.read();
                } else {
                    return 0;
                }
            }
            return null;
        } else {
            return self.cart.read_opt(add);
        }
    }

    pub fn read(self: *Nes, add: u16) u8 {
        return self.read_opt(add) orelse undefined;
    }
    fn read_cycle(self: *Nes, add: u16) u8 {
        self.cpu_cycle += 1;
        return self.read(add);
    }

    pub fn read16(self: *Nes, add: u16) u16 {
        const lo = self.read(add);
        const hi = self.read(add +% 1);
        return @as(u16, hi) << 8 | @as(u16, lo);
    }
    fn read16_cycle(self: *Nes, add: u16) u16 {
        self.cpu_cycle += 2;
        return self.read16(add);
    }
    fn read16_page_wrap(self: *Nes, add: u16) u16 {
        const lo = self.read_cycle(add);
        const hi = self.read_cycle((add & 0xff00) | ((add +% 1) & 0xff));
        return @as(u16, hi) << 8 | @as(u16, lo);
    }

    pub fn write(self: *Nes, add: u16, val: u8) void {
        if (add < 0x2000) { // RAM
            self.ram[add & 0x7ff] = val;
        } else if (add < 0x4000) { // PPU
            self.ppu.cpu_write(0x2000 | (add & 7), val);
        } else if (add < 0x4014 or add == 0x4015 or add == 0x4017) { // APU
            self.apu.write(add, val);
        } else if (add == 0x4014) { // OAMDMA
            // Do entire DMA at once; not very accurate but simple
            const base = @intCast(u16, val) << 8;
            for (0..256) |i| {
                self.ppu.oam[self.ppu.oam_addr +% @intCast(u8, i)] = self.read_cycle(base | @intCast(u16, i));
                self.cpu_cycle += 1;
            }
        } else if (add == 0x4016) { // Controller
            if (self.port0) |*ctrl| ctrl.write(val);
            if (self.port1) |*ctrl| ctrl.write(val);
        } else {
            return self.cart.write(add, val);
        }
        self.cpu_cycle += 1;
    }

    fn fetch(self: *Nes) u8 {
        const b = self.read_cycle(self.reg.pc);
        self.reg.pc +%= 1;
        return b;
    }
    fn fetch16(self: *Nes) u16 {
        const lo = self.fetch();
        const hi = self.fetch();
        return (@as(u16, hi) << 8) | @as(u16, lo);
    }

    fn read_arg(self: *Nes, arg: Arg) u8 {
        return switch (arg) {
            Arg.add => |add| self.read_cycle(add),
            Arg.imm => |imm| imm,
            Arg.reg_a => self.reg.a,
            Arg.reg_s => self.reg.s,
        };
    }
    fn write_arg(self: *Nes, arg: Arg, val: u8) void {
        return switch (arg) {
            Arg.add => |add| self.write(add, val),
            Arg.imm => {}, // NOP
            Arg.reg_a => self.reg.a = val,
            Arg.reg_s => self.reg.s = val,
        };
    }

    fn add_index(self: *Nes, base: u16, index: u16) u16 {
        const res = base +% index;
        self.page_crossed = res & 0xff00 != base & 0xff00;
        return res;
    }

    fn fetch_arg_type0(self: *Nes, op: u8, use_y: bool) ?Arg {
        const idx = if (use_y) self.reg.y else self.reg.x;
        return switch (op & 0x1c) {
            0x00 => arg_imm(self.fetch()), // #i
            0x04 => arg_add(self.fetch()), // z
            0x08 => Arg.reg_a, // A
            0x0c => arg_add(self.fetch16()), // a
            0x10 => null,
            0x14 => arg_add(self.fetch() +% idx), // z,x / z,y
            0x18 => null,
            0x1c => arg_add(self.add_index(self.fetch16(), idx)), // a,x / a,y
            else => unreachable,
        };
    }
    fn fetch_arg_type1(self: *Nes, op: u8) Arg {
        switch (op & 0x1c) {
            0x00 => return arg_add(self.read16_page_wrap(self.fetch() +% self.reg.x)), // (z,x)
            0x04 => return arg_add(self.fetch()), // z
            0x08 => return arg_imm(self.fetch()), // #i
            0x0c => return arg_add(self.fetch16()), // a
            0x10 => return arg_add(self.add_index(self.read16_page_wrap(self.fetch()), self.reg.y)), // (z),y
            0x14 => return arg_add(self.fetch() +% self.reg.x), // z,x
            0x18 => return arg_add(self.add_index(self.fetch16(), self.reg.y)), // a,y
            0x1c => return arg_add(self.add_index(self.fetch16(), self.reg.x)), // a,x
            else => unreachable,
        }
    }

    fn set_zn(self: *Nes, b: u8) void {
        self.reg.p.z = b == 0;
        self.reg.p.n = b >> 7 == 1;
    }
    fn adc(self: *Nes, arg: u8) void {
        const lhs = @as(u16, self.reg.a);
        const rhs = @as(u16, arg);
        const c = @as(u16, if (self.reg.p.c) 1 else 0);
        const res = lhs +% rhs +% c;
        self.reg.p.c = res >> 8 == 1;
        self.reg.p.v = (res ^ lhs) & (res ^ rhs) & 0x80 != 0;
        self.reg.a = @intCast(u8, res & 0xff);
        self.set_zn(self.reg.a);
    }

    fn branch(self: *Nes, cond: bool) void {
        const rel = @bitCast(i8, self.fetch());
        if (cond) {
            const target = self.reg.pc +% @bitCast(u16, @as(i16, rel));
            if (target & 0xff00 != self.reg.pc & 0xff00) self.cpu_cycle += 1;
            self.cpu_cycle += 1;
            self.reg.pc = target;
        }
    }

    fn push(self: *Nes, b: u8) void {
        self.write(0x0100 | @intCast(u16, self.reg.s), b);
        self.reg.s -%= 1;
    }
    fn push16(self: *Nes, w: u16) void {
        self.push(@intCast(u8, w >> 8));
        self.push(@intCast(u8, w & 0xff));
    }
    fn pull(self: *Nes) u8 {
        self.reg.s +%= 1;
        const val = self.read_cycle(0x0100 | @intCast(u16, self.reg.s));
        return val;
    }
    fn pull16(self: *Nes) u16 {
        const lo = self.pull();
        const hi = self.pull();
        self.cpu_cycle -= 1; // only 1 extra cpu_cycle
        return (@intCast(u16, hi) << 8) | @intCast(u16, lo);
    }
    fn pull_flags(self: *Nes) void {
        const flags = self.pull();
        self.reg.p.c = flags & 1 == 1;
        self.reg.p.z = (flags >> 1) & 1 == 1;
        self.reg.p.i = (flags >> 2) & 1 == 1;
        self.reg.p.d = (flags >> 3) & 1 == 1;
        self.reg.p.v = (flags >> 6) & 1 == 1;
        self.reg.p.n = flags >> 7 == 1;
    }

    fn interrupt(self: *Nes, is_nmi: bool, is_break: bool) void {
        self.push16(if (is_break) self.reg.pc + 1 else self.reg.pc);
        self.push(self.get_flags_byte(is_break));
        if (is_nmi) {
            self.reg.pc = self.read16_cycle(0xfffa);
        } else {
            self.reg.pc = self.read16_cycle(0xfffe);
        }
        if (!is_break) {
            self.reg.p.i = true;
        }
    }

    fn run_cpu_step(self: *Nes) void {
        const nmi_line: bool = self.ppu.nmi();
        if (nmi_line and !self.old_nmi) {
            self.interrupt(true, false);
        }
        self.old_nmi = nmi_line;

        const irq: bool = self.apu.irq;
        if (irq and !self.reg.p.i) {
            self.interrupt(false, false);
            return;
        }

        if (self.trace) {
            std.debug.print("A={X:0>2} X={X:0>2} Y={X:0>2} P={X:0>2} S={X:0>2}  ${X:0>4}: ", .{ self.reg.a, self.reg.x, self.reg.y, self.get_flags_byte(false), self.reg.s, self.reg.pc });
            disasm(self, self.reg.pc, std.io.getStdErr().writer()) catch unreachable;
            std.debug.print("\n", .{});
        }

        const start_cycle = self.cpu_cycle;
        self.page_crossed = false;
        const op = self.fetch();
        switch (op & 3) {
            0 => {
                switch (op & 0xfc) {
                    0x10 => self.branch(!self.reg.p.n), // BPL
                    0x30 => self.branch(self.reg.p.n), // BMI
                    0x50 => self.branch(!self.reg.p.v), // BVC
                    0x70 => self.branch(self.reg.p.v), // BVS
                    0x90 => self.branch(!self.reg.p.c), // BCC
                    0xb0 => self.branch(self.reg.p.c), // BCS
                    0xd0 => self.branch(!self.reg.p.z), // BNE
                    0xf0 => self.branch(self.reg.p.z), // BEQ

                    0x00 => { // BRK
                        self.interrupt(false, true);
                    },
                    0x20 => { // JSR
                        const next_pc = self.fetch16();
                        self.push16(self.reg.pc -% 1);
                        self.reg.pc = next_pc;
                        self.cpu_cycle += 1;
                    },
                    0x60 => { // RTS
                        self.reg.pc = self.pull16() +% 1;
                        self.cpu_cycle += 4;
                    },
                    0x40 => { // RTI
                        self.pull_flags();
                        self.reg.pc = self.pull16();
                        self.cpu_cycle += 3;
                    },

                    0x24, 0x2c => { // BIT zpg/abs
                        const b = self.read_cycle(if (op & 0xfc == 0x24) self.fetch() else self.fetch16());
                        self.reg.p.n = b >> 7 == 1;
                        self.reg.p.v = (b >> 6) & 1 == 1;
                        self.reg.p.z = (b & self.reg.a) == 0;
                    },

                    0x08 => { // PHP
                        self.push(self.get_flags_byte(true));
                        self.cpu_cycle += 1;
                    },
                    0x28 => { // PLP
                        self.pull_flags();
                        self.cpu_cycle += 2;
                    },
                    0x48 => { // PHA
                        self.push(self.reg.a);
                        self.cpu_cycle += 1;
                    },
                    0x68 => { // PLA
                        self.reg.a = self.pull();
                        self.set_zn(self.reg.a);
                        self.cpu_cycle += 2;
                    },

                    0x18 => self.reg.p.c = false, // CLC
                    0x38 => self.reg.p.c = true, // SEC
                    0x58 => self.reg.p.i = false, // CLI
                    0x78 => self.reg.p.i = true, // SEI
                    0xb8 => self.reg.p.v = false, // CLV
                    0xd8 => self.reg.p.d = false, // CLD
                    0xf8 => self.reg.p.d = true, // SED

                    0x4c => self.reg.pc = self.fetch16(), // JMP abs
                    0x6c => self.reg.pc = self.read16_page_wrap(self.fetch16()), // JMP ind

                    0x84, 0x8c, 0x94 => { // STY
                        const arg = self.fetch_arg_type0(op, false) orelse unreachable;
                        self.write_arg(arg, self.reg.y);
                        if (op & 0x1c == 0x14) self.cpu_cycle += 1;
                    },
                    0x88 => { // DEY
                        self.reg.y -%= 1;
                        self.set_zn(self.reg.y);
                    },
                    0xa0, 0xa4, 0xa8, 0xac, 0xb4, 0xbc => { // LDY
                        const arg = self.fetch_arg_type0(op, false) orelse unreachable;
                        self.reg.y = self.read_arg(arg);
                        self.set_zn(self.reg.y);
                        if (self.page_crossed) self.cpu_cycle += 1;
                        if (op & 0x1c == 0x14) self.cpu_cycle += 1;
                    },
                    0xc0, 0xc4, 0xcc, 0xe0, 0xe4, 0xec => { // CPY/CPX
                        const m = self.read_arg(self.fetch_arg_type0(op, false) orelse unreachable);
                        const r = if (op & 0xe0 == 0xe0) self.reg.x else self.reg.y;
                        self.reg.p.c = r >= m;
                        self.reg.p.z = r == m;
                        self.reg.p.n = (r +% twos_compl(m)) >> 7 == 1;
                    },
                    0x98 => { // TYA
                        self.reg.a = self.reg.y;
                        self.set_zn(self.reg.a);
                    },
                    0xc8 => { // INY
                        self.reg.y +%= 1;
                        self.set_zn(self.reg.y);
                    },
                    0xe8 => { // INX
                        self.reg.x +%= 1;
                        self.set_zn(self.reg.x);
                    },

                    else => {
                        self.op_nyi(op);
                    },
                }
            },
            1 => {
                const arg: Arg = self.fetch_arg_type1(op);
                switch (op & 0xe0) {
                    0x00 => { // ORA
                        self.reg.a |= self.read_arg(arg);
                        self.set_zn(self.reg.a);
                        if (op & 0x1c == 0x00 or op & 0x1c == 0x14) self.cpu_cycle += 1;
                        if (self.page_crossed) self.cpu_cycle += 1;
                    },
                    0x20 => { // AND
                        self.reg.a &= self.read_arg(arg);
                        self.set_zn(self.reg.a);
                        if (op & 0x1c == 0x00 or op & 0x1c == 0x14) self.cpu_cycle += 1;
                        if (self.page_crossed) self.cpu_cycle += 1;
                    },
                    0x40 => { // EOR
                        self.reg.a ^= self.read_arg(arg);
                        self.set_zn(self.reg.a);
                        if (op & 0x1c == 0x00 or op & 0x1c == 0x14) self.cpu_cycle += 1;
                        if (self.page_crossed) self.cpu_cycle += 1;
                    },
                    0x60 => { // ADC
                        self.adc(self.read_arg(arg));
                        if (op & 0x1c == 0x00 or op & 0x1c == 0x14) self.cpu_cycle += 1;
                        if (self.page_crossed) self.cpu_cycle += 1;
                    },
                    0x80 => { // STA
                        self.write_arg(arg, self.reg.a);
                        if (op & 0x1c != 0x04 and op & 0x1c != 0x0c and op & 0x1c != 0x0c) self.cpu_cycle += 1;
                    },
                    0xa0 => { // LDA
                        self.reg.a = self.read_arg(arg);
                        self.set_zn(self.reg.a);
                        if (op & 0x1c == 0x00 or op & 0x1c == 0x14) self.cpu_cycle += 1;
                        if (self.page_crossed) self.cpu_cycle += 1;
                    },
                    0xc0 => { // CMP
                        const m = self.read_arg(arg);
                        self.reg.p.c = self.reg.a >= m;
                        self.reg.p.z = self.reg.a == m;
                        self.reg.p.n = (self.reg.a +% twos_compl(m)) >> 7 == 1;
                        if (op & 0x1c == 0x00 or op & 0x1c == 0x14) self.cpu_cycle += 1;
                        if (self.page_crossed) self.cpu_cycle += 1;
                    },
                    0xe0 => { // SBC
                        self.adc(255 - self.read_arg(arg));
                        if (op & 0x1c == 0x00 or op & 0x1c == 0x14) self.cpu_cycle += 1;
                        if (self.page_crossed) self.cpu_cycle += 1;
                    },
                    else => unreachable,
                }
            },
            2 => {
                const use_y = op & 0xe0 == 0x80 or op & 0xe0 == 0xa0;
                const use_s = op == 0x9a or op == 0xba;
                const arg = if (use_s) Arg.reg_s else self.fetch_arg_type0(op, use_y) orelse return;
                switch (op & 0xe0) {
                    0x00 => { // ASL
                        const b = self.read_arg(arg);
                        const res = b << 1;
                        self.write_arg(arg, res);
                        self.reg.p.c = b >> 7 == 1;
                        self.set_zn(res);
                        self.cpu_cycle += 1;
                        if (op & 0x1c == 0x14 or op & 0x1c == 0x1c) self.cpu_cycle += 1;
                    },
                    0x20 => { // ROL
                        const b = self.read_arg(arg);
                        const res = (b << 1) | bool_byte(self.reg.p.c);
                        self.write_arg(arg, res);
                        self.reg.p.c = b >> 7 == 1;
                        self.set_zn(res);
                        self.cpu_cycle += 1;
                        if (op & 0x1c == 0x14 or op & 0x1c == 0x1c) self.cpu_cycle += 1;
                    },
                    0x40 => { // LSR
                        const b = self.read_arg(arg);
                        const res = b >> 1;
                        self.write_arg(arg, res);
                        self.reg.p.c = b & 1 == 1;
                        self.set_zn(res);
                        self.cpu_cycle += 1;
                        if (op & 0x1c == 0x14 or op & 0x1c == 0x1c) self.cpu_cycle += 1;
                    },
                    0x60 => { // ROR
                        const b = self.read_arg(arg);
                        const res = (b >> 1) | (bool_byte(self.reg.p.c) << 7);
                        self.write_arg(arg, res);
                        self.reg.p.c = b & 1 == 1;
                        self.set_zn(res);
                        self.cpu_cycle += 1;
                        if (op & 0x1c == 0x14 or op & 0x1c == 0x1c) self.cpu_cycle += 1;
                    },
                    0x80 => { // STX/TXA/TXS
                        self.write_arg(arg, self.reg.x);
                        if (op == 0x8a) { // TXA
                            self.set_zn(self.reg.a);
                        }
                        if (op & 0x1c == 0x14) self.cpu_cycle += 1;
                    },
                    0xa0 => { // LDX/TAX/TSX
                        self.reg.x = self.read_arg(arg);
                        self.set_zn(self.reg.x);
                        if (op & 0x1c == 0x14) self.cpu_cycle += 1;
                        if (self.page_crossed) self.cpu_cycle += 1;
                    },
                    0xc0 => { // DEC/DEX
                        if (op == 0xca) { // DEX
                            self.reg.x -%= 1;
                            self.set_zn(self.reg.x);
                        } else { // DEC
                            const b = self.read_arg(arg) -% 1;
                            self.write_arg(arg, b);
                            self.set_zn(b);
                            self.cpu_cycle += 1;
                            if (op & 0x1c == 0x14 or op & 0x1c == 0x1c) self.cpu_cycle += 1;
                        }
                    },
                    0xe0 => { // INC/NOP
                        switch (arg) {
                            .add => {
                                const res = self.read_arg(arg) +% 1;
                                self.write_arg(arg, res);
                                self.set_zn(res);
                                self.cpu_cycle += 1;
                                if (op & 0x1c == 0x14 or op & 0x1c == 0x1c) self.cpu_cycle += 1;
                            },
                            else => {},
                        }
                    },
                    else => self.op_nyi(op),
                }
            },
            else => {
                self.op_nyi(op);
            },
        }
        if (self.cpu_cycle < start_cycle + 2) { // instructions take at least 2 cycles
            self.cpu_cycle = start_cycle + 2;
        }
    }

    fn run_cycle(self: *Nes) void {
        self.master_cycle += 1;
        if (self.cpu_cycle * 12 < self.master_cycle) {
            self.run_cpu_step();
        }
        if (self.ppu.cycle * 4 < self.master_cycle) {
            self.ppu.run_step();
        }
        if (self.apu.cycle * 12 < self.master_cycle) {
            self.apu.run_step();
        }
        if (self.apu.samples * 486 < self.master_cycle) {
            self.apu.sample();
        }
    }

    pub fn run_instr(self: *Nes) void {
        const start_cycle = self.cpu_cycle;
        while (self.cpu_cycle == start_cycle and !self.found_nyi) {
            self.run_cycle();
        }
    }

    pub fn run_frame(self: *Nes, movie: ?movies.Movie) void {
        if (movie) |movie_data| {
            if (self.frame_no < movie_data.frames.items.len) {
                self.port0.?.buttons = movie_data.frames.items[self.frame_no].port0;
                std.debug.print("F{d:0>5} ", .{self.frame_no});
                self.port0.?.buttons.repr(std.io.getStdErr().writer()) catch unreachable;
                std.debug.print("\n", .{});
            }
        }

        self.apu.flush();
        while (self.ppu.in_vblank and !self.found_nyi) {
            self.run_cycle();
        }
        while (!self.ppu.in_vblank and !self.found_nyi) {
            self.run_cycle();
        }
        self.frame_no += 1;
    }
};
