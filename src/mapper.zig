const std = @import("std");
const Allocator = @import("std").mem.Allocator;

pub const Cart = struct {
    ptr: *anyopaque,
    deinit_fn: *const fn (*anyopaque, Allocator) void,
    read_opt_fn: *const fn (*anyopaque, u16) ?u8,
    write_fn: *const fn (*anyopaque, u16, u8) void,
    ppu_read_fn: *const fn (*anyopaque, u14) u8,
    ppu_write_fn: *const fn (*anyopaque, u14, u8) void,

    pub fn init(ptr: anytype) Cart {
        const Ptr = @TypeOf(ptr);
        const ptr_info = @typeInfo(Ptr);
        if (ptr_info != .Pointer) @compileError("ptr must be a pointer");
        if (ptr_info.Pointer.size != .One) @compileError("ptr must be a single item pointer");
        const alignment = ptr_info.Pointer.alignment;
        const Impl = struct {
            pub fn deinit(self_opaque: *anyopaque, alloc: Allocator) void {
                const self = @ptrCast(Ptr, @alignCast(alignment, self_opaque));
                if (@hasDecl(ptr_info.Pointer.child, "deinit")) {
                    self.deinit(alloc);
                }
                alloc.destroy(self);
            }
            pub fn read_opt(self_opaque: *anyopaque, add: u16) ?u8 {
                const self = @ptrCast(Ptr, @alignCast(alignment, self_opaque));
                return ptr_info.Pointer.child.read_opt(self, add);
            }
            pub fn write(self_opaque: *anyopaque, add: u16, val: u8) void {
                const self = @ptrCast(Ptr, @alignCast(alignment, self_opaque));
                return ptr_info.Pointer.child.write(self, add, val);
            }
            pub fn ppu_read(self_opaque: *anyopaque, add: u14) u8 {
                const self = @ptrCast(Ptr, @alignCast(alignment, self_opaque));
                return ptr_info.Pointer.child.ppu_read(self, add);
            }
            pub fn ppu_write(self_opaque: *anyopaque, add: u14, val: u8) void {
                const self = @ptrCast(Ptr, @alignCast(alignment, self_opaque));
                return ptr_info.Pointer.child.ppu_write(self, add, val);
            }
        };
        return .{
            .ptr = ptr,
            .deinit_fn = Impl.deinit,
            .read_opt_fn = Impl.read_opt,
            .write_fn = Impl.write,
            .ppu_read_fn = Impl.ppu_read,
            .ppu_write_fn = Impl.ppu_write,
        };
    }

    pub fn deinit(self: *Cart, alloc: Allocator) void {
        self.deinit_fn(self.ptr, alloc);
    }

    pub inline fn read_opt(self: *Cart, add: u16) ?u8 {
        return self.read_opt_fn(self.ptr, add);
    }
    pub inline fn write(self: *Cart, add: u16, val: u8) void {
        return self.write_fn(self.ptr, add, val);
    }

    pub inline fn ppu_read(self: *Cart, add: u14) u8 {
        return self.ppu_read_fn(self.ptr, add);
    }
    pub inline fn ppu_write(self: *Cart, add: u14, val: u8) void {
        return self.ppu_write_fn(self.ptr, add, val);
    }
};

pub const NtMirroring = enum {
    Hor,
    Ver,
    OneLower,
    OneUpper,
    Four,
};

pub const Nrom = struct {
    prg_rom0: ?*[16 * 1024]u8,
    prg_rom1: ?*[16 * 1024]u8,
    prg_ram: ?*[8 * 1024]u8,
    chr0: ?*[4 * 1024]u8,
    chr1: ?*[4 * 1024]u8,
    is_chr_ram: bool,
    nt_mirroring: NtMirroring,
    vram: [2048]u8,

    pub fn init(self: *Nrom, prg_rom0: ?*[16 * 1024]u8, prg_rom1: ?*[16 * 1024]u8, prg_ram: ?*[8 * 1024]u8, chr0: ?*[4 * 1024]u8, chr1: ?*[4 * 1024]u8, is_chr_ram: bool, nt_mirroring: NtMirroring) void {
        self.prg_rom0 = prg_rom0;
        self.prg_rom1 = prg_rom1;
        self.prg_ram = prg_ram;
        self.chr0 = chr0;
        self.chr1 = chr1;
        self.is_chr_ram = is_chr_ram;
        self.nt_mirroring = nt_mirroring;
        self.vram = [_]u8{0} ** 2048;
    }
    pub fn deinit(self: *Nrom, alloc: Allocator) void {
        if (self.prg_rom0) |prg_rom0|
            alloc.free(prg_rom0);
        if (self.prg_rom1) |prg_rom1|
            alloc.free(prg_rom1);
        if (self.prg_ram) |prg_ram|
            alloc.free(prg_ram);
        if (self.chr0) |chr0|
            alloc.free(chr0);
        if (self.chr1) |chr1|
            alloc.free(chr1);
    }

    pub fn read_opt(self: *Nrom, add: u16) ?u8 {
        if (add < 0x6000) {
            return null;
        } else if (add < 0x8000) {
            if (self.prg_ram) |prg_ram| {
                return prg_ram[add - 0x6000];
            } else {
                return null;
            }
        } else if (add < 0xc000) {
            return self.prg_rom0.?[add - 0x8000];
        } else {
            if (self.prg_rom1) |prg_rom1| {
                return prg_rom1[add - 0xc000];
            } else {
                return self.prg_rom0.?[add - 0xc000];
            }
        }
    }
    pub fn write(self: *Nrom, add: u16, val: u8) void {
        if (0x6000 <= add and add < 0x8000) {
            if (self.prg_ram) |prg_ram| {
                prg_ram[add - 0x6000] = val;
            }
        }
    }

    fn nt_mirror(self: *Nrom, add: u14) u14 {
        var add2 = add;
        add2 &= 0x0fff;
        switch (self.nt_mirroring) {
            NtMirroring.Ver => add2 &= 0x07ff,
            NtMirroring.Hor => {
                add2 &= 0x0bff;
                if (add2 >= 0x0800) add2 -= 0x400;
            },
            NtMirroring.OneLower => add2 &= 0x03ff,
            NtMirroring.OneUpper => add2 = 0x400 + (add2 & 0x03ff),
            else => unreachable,
        }
        return add2;
    }

    pub fn ppu_read(self: *Nrom, add: u14) u8 {
        if (add < 0x1000) { // Left pattern table
            return self.chr0.?[add];
        } else if (add < 0x2000) { // Right pattern table
            return self.chr1.?[add - 0x1000];
        } else if (add < 0x4000) { // Nametables
            return self.vram[self.nt_mirror(add)];
        } else {
            unreachable;
        }
    }
    pub fn ppu_write(self: *Nrom, add: u14, val: u8) void {
        if (add < 0x1000) { // Left pattern table
            if (self.is_chr_ram) self.chr0.?[add] = val;
        } else if (add < 0x2000) { // Right pattern table
            if (self.is_chr_ram) self.chr1.?[add - 0x1000] = val;
        } else if (add < 0x3f00) { // Nametables
            self.vram[self.nt_mirror(add)] = val;
        }
    }

    pub fn cart(self: *Nrom) Cart {
        return Cart.init(self);
    }
};

pub const Mmc1 = struct {
    nrom: Nrom,
    prg_rom_banks: std.BoundedArray([16 * 1024]u8, 16),
    prg_ram_banks: [4][8 * 1024]u8,
    chr_banks: [32][4 * 1024]u8,

    sh_reg: u5,
    sh_reg_cnt: u4,
    prg_mode: u2,
    chr_mode: u1,
    chr0_sel: u5,
    chr1_sel: u5,
    prg_sel: u5,

    pub fn init(self: *Mmc1, prg_rom_banks: std.BoundedArray([16 * 1024]u8, 16), prg_ram_banks: [4][8 * 1024]u8, chr_banks: [32][4 * 1024]u8, is_chr_ram: bool, nt_mirroring: NtMirroring) void {
        self.prg_rom_banks = prg_rom_banks;
        self.prg_ram_banks = prg_ram_banks;
        self.chr_banks = chr_banks;
        self.nrom.init(&self.prg_rom_banks.buffer[0], &self.prg_rom_banks.buffer[self.prg_rom_banks.len - 1], &self.prg_ram_banks[0], &self.chr_banks[0], &self.chr_banks[1], is_chr_ram, nt_mirroring);
        self.sh_reg = 0;
        self.sh_reg_cnt = 0;
        self.prg_mode = 3;
        self.chr_mode = 0;
        self.chr0_sel = 0;
        self.chr1_sel = 0;
        self.prg_sel = 0;
    }

    fn update_mapping(self: *Mmc1) void {
        if (self.chr_mode == 0) { // 8K mode
            const bank = self.chr0_sel & 0x1e;
            self.nrom.chr0 = &self.chr_banks[bank];
            self.nrom.chr1 = &self.chr_banks[bank + 1];
        } else { // 4K mode
            self.nrom.chr0 = &self.chr_banks[self.chr0_sel];
            self.nrom.chr1 = &self.chr_banks[self.chr1_sel];
        }
        var bank = self.prg_sel & 0xf;
        switch (self.prg_mode) {
            0, 1 => { // 32K mode
                bank = bank & 0x1e;
                self.nrom.prg_rom0 = &self.prg_rom_banks.buffer[bank];
                self.nrom.prg_rom1 = &self.prg_rom_banks.buffer[bank + 1];
            },
            2 => {
                self.nrom.prg_rom0 = &self.prg_rom_banks.buffer[0];
                self.nrom.prg_rom1 = &self.prg_rom_banks.buffer[bank];
            },
            3 => {
                self.nrom.prg_rom0 = &self.prg_rom_banks.buffer[bank];
                self.nrom.prg_rom1 = &self.prg_rom_banks.buffer[self.prg_rom_banks.len - 1];
            },
        }
    }

    pub fn read_opt(self: *Mmc1, add: u16) ?u8 {
        return self.nrom.read_opt(add);
    }
    pub fn write(self: *Mmc1, add: u16, val: u8) void {
        if (add < 0x8000) {
            self.nrom.write(add, val);
        } else { // Mapper control
            if (val >> 7 == 1) {
                self.sh_reg = 0;
                self.sh_reg_cnt = 0;
            } else {
                // self.sh_reg = (self.sh_reg << 1) | @intCast(u5, (val & 1));
                self.sh_reg |= @intCast(u5, (val & 1)) << @intCast(u3, self.sh_reg_cnt);
                self.sh_reg_cnt += 1;
                if (self.sh_reg_cnt == 5) {
                    const reg = @intCast(u2, (add >> 13) & 3);
                    switch (reg) {
                        0 => { // Control
                            self.nrom.nt_mirroring = switch (@intCast(u2, self.sh_reg & 3)) {
                                0 => NtMirroring.OneLower,
                                1 => NtMirroring.OneUpper,
                                2 => NtMirroring.Ver,
                                3 => NtMirroring.Hor,
                            };
                            self.prg_mode = @intCast(u2, (self.sh_reg >> 2) & 3);
                            self.chr_mode = @intCast(u1, (self.sh_reg >> 4) & 1);
                        },
                        1 => { // CHR bank 0
                            self.chr0_sel = self.sh_reg;
                        },
                        2 => { // CHR bank 1
                            self.chr1_sel = self.sh_reg;
                        },
                        3 => { // PRG bank
                            self.prg_sel = self.sh_reg;
                        },
                    }
                    self.sh_reg = 0;
                    self.sh_reg_cnt = 0;
                    self.update_mapping();
                }
            }
        }
    }
    pub fn ppu_read(self: *Mmc1, add: u14) u8 {
        return self.nrom.ppu_read(add);
    }
    pub fn ppu_write(self: *Mmc1, add: u14, val: u8) void {
        self.nrom.ppu_write(add, val);
    }

    pub fn cart(self: *Mmc1) Cart {
        return Cart.init(self);
    }
};

pub const UxRom = struct {
    nrom: Nrom,
    prg_rom_banks: std.BoundedArray([16 * 1024]u8, 16),
    chr0: [4 * 1024]u8,
    chr1: [4 * 1024]u8,

    pub fn init(self: *UxRom, prg_rom_banks: std.BoundedArray([16 * 1024]u8, 16), chr0: [4 * 1024]u8, chr1: [4 * 1024]u8, is_chr_ram: bool, nt_mirroring: NtMirroring) void {
        self.prg_rom_banks = prg_rom_banks;
        self.chr0 = chr0;
        self.chr1 = chr1;
        self.nrom.init(&self.prg_rom_banks.buffer[0], &self.prg_rom_banks.buffer[self.prg_rom_banks.len - 1], null, &self.chr0, &self.chr1, is_chr_ram, nt_mirroring);
    }

    pub fn read_opt(self: *UxRom, add: u16) ?u8 {
        return self.nrom.read_opt(add);
    }
    pub fn write(self: *UxRom, add: u16, val: u8) void {
        if (add < 0x8000) {
            self.nrom.write(add, val);
        } else { // Bank select
            self.nrom.prg_rom0 = &self.prg_rom_banks.buffer[val & 0x0f];
        }
    }
    pub fn ppu_read(self: *UxRom, add: u14) u8 {
        return self.nrom.ppu_read(add);
    }
    pub fn ppu_write(self: *UxRom, add: u14, val: u8) void {
        self.nrom.ppu_write(add, val);
    }
    pub fn cart(self: *UxRom) Cart {
        return Cart.init(self);
    }
};
