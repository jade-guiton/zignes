const std = @import("std");
const Cart = @import("./mapper.zig").Cart;

const render_palette = @ptrCast(*const [64][3]u8, @embedFile("palette.pal"));

fn copy_bits(comptime nb_bits: comptime_int, comptime src_off: comptime_int, comptime dst_off: comptime_int, dst_ptr: anytype, src: anytype) void {
    const Src = @TypeOf(src);
    const src_info = @typeInfo(Src);
    if (src_info != .Int) @compileError("src must be an integer");
    if (src_info.Int.signedness != .unsigned) @compileError("src must be an unsigned integer");
    const src_bits = src_info.Int.bits;
    _ = src_bits;

    const DstPtr = @TypeOf(dst_ptr);
    const dst_ptr_info = @typeInfo(DstPtr);
    if (dst_ptr_info != .Pointer) @compileError("dst_ptr must be a pointer");
    if (dst_ptr_info.Pointer.size != .One) @compileError("dst_ptr must be a single item pointer");
    const Dst = dst_ptr_info.Pointer.child;
    const dst_info = @typeInfo(Dst);
    if (dst_info != .Int) @compileError("dst must be an integer");
    if (dst_info.Int.signedness != .unsigned) @compileError("dst must be an unsigned integer");
    const dst_bits = dst_info.Int.bits;
    _ = dst_bits;

    const bit_mask = (1 << nb_bits) - 1;
    const dst_mask = ~@as(Dst, bit_mask << dst_off);
    dst_ptr.* = (dst_ptr.* & dst_mask) | (@intCast(Dst, (src >> src_off) & bit_mask) << dst_off);
}

const LineSprite = struct {
    pat: [8]u2,
    pal: u2,
    prio: bool,
    x: u16,
    is_spr0: bool,
};

const power_up_period = 88974;

pub const Ppu = struct {
    cart: Cart,

    oam: [256]u8,
    pal: [32]u8,

    line_sprites: [8]LineSprite,
    line_sprite_cnt: u8,
    line_at_pal: u2,
    line_pt_lo: u8,
    line_pt_hi: u8,
    buffer: [240][256][3]u8,

    ctrl: struct {
        add_inc: u1,
        spr_pat_table: u1,
        bg_pat_table: u1,
        spr_size: u1,
        vbl_nmi: bool,
    },
    pending_vblank_clear: bool,
    mask: u8,
    status: u8,
    oam_addr: u8,
    ppu_data_buf: u8,
    cur_ppu_addr: u15,
    temp_ppu_addr: u15,
    fine_x_scroll: u3,
    ppu_latch: bool,

    cycle: u64,
    line: u16,
    dot: u16,
    even_frame: bool,
    in_vblank: bool,

    pub fn init(cart: Cart) Ppu {
        return Ppu{
            .cart = cart,
            .oam = [_]u8{0} ** 256,
            .pal = [_]u8{0} ** 32,
            .line_sprites = undefined,
            .line_sprite_cnt = 0,
            .line_at_pal = 0,
            .line_pt_lo = 0,
            .line_pt_hi = 0,
            .buffer = [_][256][3]u8{[_][3]u8{[3]u8{ 0, 0, 0 }} ** 256} ** 240,
            .ctrl = .{
                .add_inc = 0,
                .spr_pat_table = 0,
                .bg_pat_table = 0,
                .spr_size = 0,
                .vbl_nmi = false,
            },
            .pending_vblank_clear = false,
            .mask = 0,
            .status = 0,
            .oam_addr = 0,
            .ppu_data_buf = 0,
            .cur_ppu_addr = 0,
            .temp_ppu_addr = 0,
            .fine_x_scroll = 0,
            .ppu_latch = false,
            .cycle = 0,
            .line = 0,
            .dot = 0,
            .even_frame = false,
            .in_vblank = false,
        };
    }
    pub fn nmi(self: *Ppu) bool {
        return (self.status >> 7 == 1) and self.ctrl.vbl_nmi;
    }

    pub fn cpu_read(self: *Ppu, add: u16) u8 {
        switch (add) {
            0x2002 => { // PPUSTATUS
                const val = self.status;
                self.status &= 0x7f; // Clear VBlank flag
                self.ppu_latch = false;
                self.pending_vblank_clear = true;
                return val;
            },
            0x2004 => return self.oam[self.oam_addr], // OAMDATA
            0x2007 => { // PPUDATA
                var val: u8 = undefined;
                const ppu_addr = @intCast(u14, self.cur_ppu_addr & 0x3fff);
                if (add < 0x3f00) { // Go through buffer
                    val = self.ppu_data_buf;
                    self.ppu_data_buf = self.read(ppu_addr);
                } else { // Palette data
                    val = self.read(ppu_addr);
                    self.ppu_data_buf = self.cart.ppu_read(ppu_addr);
                }

                const inc = if (self.ctrl.add_inc == 1) @as(u15, 32) else @as(u15, 1);
                self.cur_ppu_addr +%= inc;
                return val;
            },
            else => return 0,
        }
    }
    pub fn cpu_write(self: *Ppu, add: u16, val: u8) void {
        switch (add) {
            0x2000 => { // PPUCTRL
                if (self.cycle <= power_up_period) return;
                self.ctrl = .{
                    .add_inc = @intCast(u1, (val >> 2) & 1),
                    .spr_pat_table = @intCast(u1, (val >> 3) & 1),
                    .bg_pat_table = @intCast(u1, (val >> 4) & 1),
                    .spr_size = @intCast(u1, (val >> 5) & 1),
                    .vbl_nmi = (val >> 7) & 1 == 1,
                };
                copy_bits(2, 0, 10, &self.temp_ppu_addr, val);
            },
            0x2001 => { // PPUMASK
                if (self.cycle <= power_up_period) return;
                self.mask = val;
            },
            0x2003 => { // OAMADDR
                self.oam_addr = val;
            },
            0x2004 => { // OAMDATA
                self.oam[self.oam_addr] = val;
                self.oam_addr +%= 1;
            },
            0x2005 => { // PPUSCROLL
                if (self.cycle <= power_up_period) return;
                if (self.ppu_latch) {
                    copy_bits(5, 3, 5, &self.temp_ppu_addr, val);
                    copy_bits(3, 0, 12, &self.temp_ppu_addr, val);
                } else {
                    copy_bits(5, 3, 0, &self.temp_ppu_addr, val);
                    self.fine_x_scroll = @intCast(u3, val & 7);
                }
                self.ppu_latch = !self.ppu_latch;
            },
            0x2006 => { // PPUADDR
                if (self.cycle <= power_up_period) return;
                if (self.ppu_latch) {
                    self.temp_ppu_addr &= 0x7f00;
                    self.temp_ppu_addr |= val;
                    self.cur_ppu_addr = self.temp_ppu_addr;
                } else {
                    self.temp_ppu_addr &= 0x00ff;
                    self.temp_ppu_addr |= @intCast(u15, val & 0x3f) << 8;
                }
                self.ppu_latch = !self.ppu_latch;
            },
            0x2007 => { // PPUDATA
                self.write(@intCast(u14, self.cur_ppu_addr & 0x3fff), val);
                const inc = if (self.ctrl.add_inc == 1) @as(u15, 32) else @as(u15, 1);
                self.cur_ppu_addr +%= inc;
            },
            else => {},
        }
    }

    fn read(self: *Ppu, add: u14) u8 {
        if (add >= 0x4000) unreachable;
        if (add < 0x3f00) { // Pattern tables + Nametables
            return self.cart.ppu_read(add);
        } else { // Palette RAM
            var pal_idx = add & 0x1f;
            if (pal_idx & 3 == 0) pal_idx &= 0x0f;
            return self.pal[pal_idx];
        }
    }
    fn write(self: *Ppu, add: u14, val: u8) void {
        if (add >= 0x4000) unreachable;
        if (add < 0x3f00) { // Pattern tables + Nametables
            return self.cart.ppu_write(add, val);
        } else { // Palette RAM
            var pal_idx = add & 0x1f;
            if (pal_idx & 3 == 0) pal_idx &= 0x0f;
            self.pal[pal_idx] = val;
        }
    }

    fn idle(self: *Ppu, dots: u16) void {
        self.line += dots / 341;
        self.dot += dots % 341;
        if (self.dot >= 341) {
            self.dot -= 341;
            self.line += 1;
        }
        if (self.line >= 262) {
            self.line -= 262;
        }
        self.cycle += dots;
    }

    pub fn run_step(self: *Ppu) void {
        const bg_en = (self.mask >> 3) & 1 == 1;
        const spr_en = (self.mask >> 4) & 1 == 1;

        // Note: All the timings are wrong. Good enough for now.

        if (self.line < 240) { // Visible scanlines
            if (self.dot == 0) {
                // Sprite evaluation + tile data fetch
                const tall_sprites = self.ctrl.spr_size == 1;
                const sprite_h: u8 = if (tall_sprites) 16 else 8;
                self.line_sprite_cnt = 0;
                for (0..64) |spr_i| {
                    var y = self.oam[spr_i * 4];
                    if (y >= 0xef) continue;
                    y += 1;
                    if (y > self.line or y + sprite_h <= self.line) continue;
                    var bottom = tall_sprites and self.line - y >= 8;
                    var row = @intCast(u14, (self.line - y) & 7);

                    var tile_bank: u14 = undefined;
                    var tile = @intCast(u14, self.oam[spr_i * 4 + 1]);
                    if (tall_sprites) {
                        tile_bank = tile & 1;
                        tile &= 0xfe;
                    } else {
                        tile_bank = self.ctrl.spr_pat_table;
                    }

                    var sprite: LineSprite = undefined;
                    sprite.is_spr0 = spr_i == 0;
                    const attr = self.oam[spr_i * 4 + 2];
                    sprite.pal = @intCast(u2, attr & 3);
                    sprite.prio = (attr >> 5) & 1 == 1;
                    const flip_x = (attr >> 6) & 1 == 1;
                    const flip_y = (attr >> 7) & 1 == 1;

                    if (flip_y) {
                        if (tall_sprites) bottom = !bottom;
                        row = 7 - row;
                    }
                    if (bottom) tile += 1;

                    sprite.x = self.oam[spr_i * 4 + 3];

                    const pt_add = tile_bank * 0x1000;
                    const pt_lo = self.read(pt_add + tile * 16 + row);
                    const pt_hi = self.read(pt_add + tile * 16 + 8 + row);
                    for (0..8) |i| {
                        const pi = if (flip_x) @intCast(u3, i) else @intCast(u3, 7 - i);
                        sprite.pat[i] = @intCast(u2, (((pt_hi >> pi) & 1) << 1) | ((pt_lo >> pi) & 1));
                    }

                    self.line_sprites[self.line_sprite_cnt] = sprite;
                    self.line_sprite_cnt += 1;
                    if (self.line_sprite_cnt == 8) break;
                }

                self.idle(1);
            } else if (self.dot <= 256) {
                const y = @intCast(u64, self.line);
                const x = self.dot - 1;

                if (bg_en and ((x + self.fine_x_scroll) % 8 == 0 or self.dot == 1)) { // Fetch tile
                    const nt_add = @intCast(u14, 0x2000 + (self.cur_ppu_addr & 0x0fff));
                    const nt_byte = @intCast(u14, self.read(nt_add));
                    const tile_x = self.cur_ppu_addr & 0x1f;
                    const tile_y = (self.cur_ppu_addr >> 5) & 0x1f;
                    const at_add = @intCast(u14, 0x23c0 + (self.cur_ppu_addr & 0x0c00) + tile_y / 4 * 8 + tile_x / 4);
                    const at_byte = self.read(at_add);
                    const at_area = @intCast(u3, tile_y % 4 / 2 * 2 + tile_x % 4 / 2);
                    self.line_at_pal = @intCast(u2, (at_byte >> (at_area * 2)) & 3);

                    const pt_add = @intCast(u14, self.ctrl.bg_pat_table) * 0x1000;
                    const pix_y = @intCast(u14, self.cur_ppu_addr >> 12);
                    self.line_pt_lo = self.read(pt_add + nt_byte * 16 + pix_y);
                    self.line_pt_hi = self.read(pt_add + nt_byte * 16 + 8 + pix_y);

                    // coarse x increment
                    if ((self.cur_ppu_addr & 0x001f) == 31) { // if coarse x == 31
                        self.cur_ppu_addr &= ~@as(u15, 0x001f); // coarse x = 0
                        self.cur_ppu_addr ^= 0x0400; // switch horizontal nametable
                    } else {
                        self.cur_ppu_addr +%= 1;
                    }
                }

                const bg_col = self.read(0x3f00) & 0x3f; // Universal background color

                var spr_pix: u2 = 0;
                var spr_pal: u2 = undefined;
                var spr_prio: bool = undefined;
                var is_spr0: bool = false;
                var in_spr: bool = false;
                if (spr_en) { // Sprites
                    var i: u8 = self.line_sprite_cnt;
                    while (i > 0) {
                        i -= 1;
                        const spr = self.line_sprites[i];
                        if (x < spr.x or x >= spr.x + 8) continue;
                        in_spr = true;
                        const col = x - spr.x;
                        if (spr.pat[col] != 0) {
                            spr_pix = spr.pat[col];
                            spr_prio = spr.prio;
                            spr_pal = spr.pal;
                            is_spr0 = spr.is_spr0;
                        }
                    }
                }

                var bg_pix: u2 = 0;
                if (bg_en) { // Background
                    const pix_x = @intCast(u3, x & 0x7) +% self.fine_x_scroll;
                    const lo = (self.line_pt_lo >> (7 - pix_x)) & 1;
                    const hi = (self.line_pt_hi >> (7 - pix_x)) & 1;
                    bg_pix = @intCast(u2, (hi << 1) | lo);
                }

                const mask_bg = self.dot > 8 or ((self.mask >> 1) & 1) == 1;
                const mask_spr = self.dot > 8 or ((self.mask >> 2) & 1) == 1;

                var col: u8 = undefined;
                if (bg_pix != 0 and (spr_pix == 0 or spr_prio) and mask_bg) {
                    col = self.read(0x3f00 + @intCast(u14, 4 * @intCast(u16, self.line_at_pal) + @intCast(u16, bg_pix))) & 0x3f;
                } else if (spr_pix != 0 and mask_spr) {
                    col = self.read(0x3f00 + @intCast(u14, 4 * (4 + @intCast(u16, spr_pal)) + @intCast(u16, spr_pix))) & 0x3f;
                } else {
                    col = bg_col;
                }
                self.buffer[y][x] = render_palette[col];

                // Sprite 0 hit
                if (spr_pix != 0 and is_spr0 and bg_pix != 0 and (self.mask >> 3) & 3 == 3 and mask_bg and mask_spr and self.dot != 256) {
                    self.status |= 0x40;
                }

                if (self.dot == 256 and bg_en) { // Increment vertical position
                    if ((self.cur_ppu_addr & 0x7000) != 0x7000) { // if fine Y < 7
                        self.cur_ppu_addr +%= 0x1000; // increment fine Y
                    } else {
                        self.cur_ppu_addr &= ~@as(u15, 0x7000); // fine Y = 0
                        var coarse_y = @intCast(u5, (self.cur_ppu_addr & 0x03e0) >> 5);
                        if (coarse_y == 29) {
                            coarse_y = 0;
                            self.cur_ppu_addr ^= 0x0800; // switch vertical nametable
                        } else if (coarse_y == 31) {
                            coarse_y = 0;
                        } else {
                            coarse_y +%= 1;
                        }
                        // set new coarse y
                        self.cur_ppu_addr &= ~@as(u15, 0x03e0);
                        self.cur_ppu_addr |= @intCast(u15, coarse_y) << 5;
                    }
                }

                self.idle(1);
            } else if (self.dot <= 320) {
                if (self.dot == 257 and bg_en) { // Copy horizontal position bits
                    copy_bits(5, 0, 0, &self.cur_ppu_addr, self.temp_ppu_addr);
                    copy_bits(1, 10, 10, &self.cur_ppu_addr, self.temp_ppu_addr);
                }

                self.oam_addr = 0;
                self.idle(8);
            } else if (self.dot <= 336) {
                self.idle(8);
            } else if (self.dot == 337) {
                self.idle(4);
            } else unreachable;
        } else if (self.line == 240) { // Post-render scanline (idle)
            if (self.dot == 0) {
                self.idle(341);
            } else unreachable;
        } else if (self.line < 261) { // VBlank
            if (self.dot == 0) {
                self.idle(1);
            } else if (self.dot == 1) {
                if (!self.pending_vblank_clear) {
                    self.status |= 0x80; // Set VBlank flag
                }
                self.in_vblank = true;
                self.idle(341 * 20 - 1);
            } else unreachable;
        } else { // Pre-render scanline
            if (self.dot == 0) {
                self.even_frame = !self.even_frame;
                self.in_vblank = false;
                self.status &= 0xbf; // Clear Sprite 0 hit
                self.idle(1);
            } else if (self.dot == 1) {
                self.status &= 0x7f; // Clear VBlank flag
                self.idle(256);
            } else if (self.dot == 257) {
                if (bg_en) {
                    // Copy horizontal position bits
                    copy_bits(5, 0, 0, &self.cur_ppu_addr, self.temp_ppu_addr);
                    copy_bits(1, 10, 10, &self.cur_ppu_addr, self.temp_ppu_addr);
                }

                self.oam_addr = 0;
                self.idle(23);
            } else if (280 <= self.dot and self.dot <= 304) {
                if (bg_en) {
                    // Copy vertical bits
                    copy_bits(5, 5, 5, &self.cur_ppu_addr, self.temp_ppu_addr);
                    copy_bits(4, 11, 11, &self.cur_ppu_addr, self.temp_ppu_addr);
                }

                self.idle(1);
                if (self.dot == 305) {
                    self.idle(36);
                    if ((bg_en or spr_en) and !self.even_frame) {
                        // Skip one cycle
                        self.dot += 1;
                    }
                }
            } else {
                unreachable;
            }
        }
        self.pending_vblank_clear = false;
    }
};
