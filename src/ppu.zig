const std = @import("std");
const Cart = @import("./mapper.zig").Cart;

const render_palette = @ptrCast(*const [64][3]u8, @embedFile("palette.pal"));

const LineSprite = struct {
    pat: [8]u2,
    pal: u2,
    prio: bool,
    x: u16,
    is_spr0: bool,
};

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

    ctrl: u8,
    pending_vblank_clear: bool,
    mask: u8,
    status: u8,
    oam_addr: u8,
    ppu_addr: u16,
    ppu_addr_hi: u8,
    ppu_data_buf: u8,
    scroll_x: u8,
    scroll_y: u8,
    ppu_latch: bool,

    cycle: u64,
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
            .ctrl = 0,
            .pending_vblank_clear = false,
            .mask = 0,
            .status = 0,
            .oam_addr = 0,
            .ppu_addr = 0,
            .ppu_addr_hi = 0,
            .ppu_data_buf = 0,
            .scroll_x = 0,
            .scroll_y = 0,
            .ppu_latch = false,
            .cycle = 0,
            .in_vblank = false,
        };
    }
    pub fn nmi(self: *Ppu) bool {
        return (self.status >> 7 == 1) and (self.ctrl >> 7 == 1);
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
                if (add < 0x3f00) { // Go through buffer
                    val = self.ppu_data_buf;
                    self.ppu_data_buf = self.read(self.ppu_addr);
                } else { // Palette data
                    val = self.read(self.ppu_addr);
                    self.ppu_data_buf = self.cart.ppu_read(self.ppu_addr);
                }

                const inc = if ((self.ctrl >> 2) & 1 == 1) @as(u16, 32) else @as(u16, 1);
                self.ppu_addr = (self.ppu_addr +% inc) & 0x3fff;
                return val;
            },
            else => return 0,
        }
    }
    pub fn cpu_write(self: *Ppu, add: u16, val: u8) void {
        switch (add) {
            0x2000 => { // PPUCTRL
                self.ctrl = val;
            },
            0x2001 => { // PPUMASK
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
                if (self.ppu_latch) {
                    self.scroll_y = val;
                } else {
                    self.scroll_x = val;
                }
                self.ppu_latch = !self.ppu_latch;
            },
            0x2006 => { // PPUADDR
                if (self.ppu_latch) {
                    self.ppu_addr = ((@intCast(u16, self.ppu_addr_hi) << 8) | val) & 0x3fff;
                    // WTF 1:
                    self.scroll_x = (self.scroll_x & 0xe0) | (val & 0x1f);
                    self.scroll_y = (self.scroll_y & 0xc7) | (((val >> 5) & 7) << 3);
                } else {
                    self.ppu_addr_hi = val;
                    // WTF 2:
                    self.scroll_y = (self.scroll_y & 0x3c) | ((val & 3) << 6) | ((val >> 6) & 3);
                    self.ctrl = (self.ctrl & 0xfc) | ((val >> 2) & 3);
                }
                self.ppu_latch = !self.ppu_latch;
            },
            0x2007 => { // PPUDATA
                self.write(self.ppu_addr, val);
                const inc = if ((self.ctrl >> 2) & 1 == 1) @as(u16, 32) else @as(u16, 1);
                self.ppu_addr = (self.ppu_addr + inc) & 0x3fff;
            },
            else => {},
        }
    }

    fn read(self: *Ppu, add: u16) u8 {
        if (add >= 0x4000) unreachable;
        if (add < 0x3f00) { // Pattern tables + Nametables
            return self.cart.ppu_read(add);
        } else { // Palette RAM
            var pal_idx = add & 0x1f;
            if (pal_idx & 3 == 0) pal_idx &= 0x0f;
            return self.pal[pal_idx];
        }
    }
    fn write(self: *Ppu, add: u16, val: u8) void {
        if (add >= 0x4000) unreachable;
        if (add < 0x3f00) { // Pattern tables + Nametables
            return self.cart.ppu_write(add, val);
        } else { // Palette RAM
            var pal_idx = add & 0x1f;
            if (pal_idx & 3 == 0) pal_idx &= 0x0f;
            self.pal[pal_idx] = val;
        }
    }

    pub fn frame_no(self: *Ppu) u64 {
        return self.cycle / 341 / 262;
    }

    pub fn run_step(self: *Ppu) void {
        const line_no = self.cycle / 341;
        const line_cycle = self.cycle % 341;
        const line = @intCast(i32, line_no % 262) - 1;

        // Note: All the timings are wrong. Good enough for now.

        if (line == -1) { // Pre-render scanline
            if (line_cycle == 0) {
                self.in_vblank = false;
                self.cycle += 1;
            } else if (line_cycle == 1) {
                self.status &= 0x3f; // Clear VBlank flag and Sprite 0 hit
                self.cycle += 256;
            } else if (line_cycle == 257) {
                self.oam_addr = 0;
                self.cycle += 84;
            } else {
                unreachable;
            }
        } else if (line < 240) { // Visible scanlines
            if (line_cycle == 0) {
                // Sprite evaluation + tile data fetch
                const tall_sprites = (self.ctrl >> 5) & 1 == 1;
                const sprite_h: u8 = if (tall_sprites) 16 else 8;
                self.line_sprite_cnt = 0;
                for (0..64) |spr_i| {
                    var y = self.oam[spr_i * 4];
                    if (y >= 0xef) continue;
                    y += 1;
                    if (y > line or y + sprite_h <= line) continue;
                    var bottom = tall_sprites and line - y >= 8;
                    var row = @intCast(u16, (line - y) & 7);

                    var tile_bank: u16 = undefined;
                    var tile = @intCast(u16, self.oam[spr_i * 4 + 1]);
                    if (tall_sprites) {
                        tile_bank = tile & 1;
                        tile &= 0xfe;
                    } else {
                        tile_bank = (self.ctrl >> 3) & 1;
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

                self.cycle += 1;
            } else if (line_cycle <= 256) {
                const y = @intCast(u64, line);
                const x = line_cycle - 1;

                const y_off = y + self.scroll_y;
                const x_off = x + self.scroll_x;

                if (x_off % 8 == 0 or line_cycle == 1) { // Fetch tile
                    var tile_y = @intCast(u16, y_off / 8);
                    var tile_x = @intCast(u16, x_off / 8);
                    var nt_sel: u2 = @intCast(u2, self.ctrl & 3);
                    const pix_y = @intCast(u16, y_off % 8);

                    if (tile_x >= 32) nt_sel ^= 1;
                    if (tile_y >= 30) nt_sel ^= 2;
                    tile_x &= 31;
                    tile_y %= 30;

                    const nt_add = 0x2000 + @intCast(u16, nt_sel) * 0x0400;
                    const nt_byte = @intCast(u16, self.read(nt_add + tile_y * 32 + tile_x));

                    const at_byte = self.read(nt_add + 0x03c0 + tile_y / 4 * 8 + tile_x / 4);
                    const at_area = @intCast(u3, tile_y % 4 / 2 * 2 + tile_x % 4 / 2);
                    self.line_at_pal = @intCast(u2, (at_byte >> (at_area * 2)) & 3);

                    const pt_add = @intCast(u16, (self.ctrl >> 4) & 1) * 0x1000;
                    self.line_pt_lo = self.read(pt_add + nt_byte * 16 + pix_y);
                    self.line_pt_hi = self.read(pt_add + nt_byte * 16 + 8 + pix_y);
                }

                const bg_col = self.read(0x3f00) & 0x3f; // Universal background color

                var spr_pix: u2 = 0;
                var spr_pal: u2 = undefined;
                var spr_prio: bool = undefined;
                var is_spr0: bool = false;
                var in_spr: bool = false;
                if ((self.mask >> 4) & 1 == 1) { // Sprites
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
                if ((self.mask >> 3) & 1 == 1) { // Background
                    const pix_x = @intCast(u3, x_off & 0x7);
                    const lo = (self.line_pt_lo >> (7 - pix_x)) & 1;
                    const hi = (self.line_pt_hi >> (7 - pix_x)) & 1;
                    bg_pix = @intCast(u2, (hi << 1) | lo);
                }

                const mask_bg = line_cycle > 8 or (self.mask >> 1) & 1 == 1;
                const mask_spr = line_cycle > 8 or (self.mask >> 2) & 1 == 1;

                var col: u8 = undefined;
                if (bg_pix != 0 and (spr_pix == 0 or spr_prio) and mask_bg) {
                    col = self.read(0x3f00 + @intCast(u16, 4 * @intCast(u16, self.line_at_pal) + @intCast(u16, bg_pix))) & 0x3f;
                } else if (spr_pix != 0 and mask_spr) {
                    col = self.read(0x3f00 + @intCast(u16, 4 * (4 + @intCast(u16, spr_pal)) + @intCast(u16, spr_pix))) & 0x3f;
                } else {
                    col = bg_col;
                }
                self.buffer[y][x] = render_palette[col];

                // Sprite 0 hit
                if (spr_pix != 0 and is_spr0 and bg_pix != 0 and (self.mask >> 3) & 3 == 3 and mask_bg and mask_spr and line_cycle != 256) {
                    self.status |= 0x40;
                }

                self.cycle += 1;
            } else if (line_cycle <= 320) {
                self.oam_addr = 0;
                self.cycle += 8;
            } else if (line_cycle <= 336) {
                self.cycle += 8;
            } else if (line_cycle == 337) {
                self.cycle += 4;
            } else unreachable;
        } else if (line == 240) { // Post-render scanline (idle)
            if (line_cycle == 0) {
                self.cycle += 341;
            } else unreachable;
        } else { // VBlank
            if (line_cycle == 0) {
                self.cycle += 1;
            } else if (line_cycle == 1) {
                if (!self.pending_vblank_clear) {
                    self.status |= 0x80; // Set VBlank flag
                }
                self.in_vblank = true;
                self.cycle += 341 * 20 - 1;
            } else unreachable;
        }
        self.pending_vblank_clear = false;
    }
};
