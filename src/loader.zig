const std = @import("std");
const Allocator = std.mem.Allocator;

const mappers = @import("./mapper.zig");
const NtMirroring = mappers.NtMirroring;

const CartLoadError = error{
    UnexpectedEof,
    InvalidNesFile,
    UnsupportedRom,
};

pub fn load_cart_file(alloc: Allocator, path: []const u8) !mappers.Cart {
    var file = try std.fs.cwd().openFile(path, .{ .mode = std.fs.File.OpenMode.read_only });
    defer file.close();
    var buf_reader = std.io.bufferedReader(file.reader());
    return load_cart(alloc, buf_reader.reader());
}

pub fn load_cart_memory(alloc: Allocator, buf: []const u8) !mappers.Cart {
    var stream = std.io.fixedBufferStream(buf);
    return load_cart(alloc, stream.reader());
}

fn read_alloc(alloc: Allocator, in_stream: anytype, size: usize) ![]u8 {
    const prg_rom = try alloc.alloc(u8, size);
    if (try in_stream.readAll(prg_rom) != prg_rom.len) {
        return CartLoadError.UnexpectedEof;
    }
    return prg_rom;
}
fn read_alloc_static(alloc: Allocator, in_stream: anytype, comptime size: usize) !*[size]u8 {
    const prg_rom = @ptrCast(*[size]u8, try alloc.alloc(u8, size));
    if (try in_stream.readAll(prg_rom) != prg_rom.len) {
        return CartLoadError.UnexpectedEof;
    }
    return prg_rom;
}
fn read_static(in_stream: anytype, comptime size: usize) ![size]u8 {
    var prg_rom = [_]u8{0} ** size;
    if (try in_stream.readAll(&prg_rom) != prg_rom.len) {
        return CartLoadError.UnexpectedEof;
    }
    return prg_rom;
}

fn load_cart(alloc: Allocator, in_stream: anytype) !mappers.Cart {
    var header: [16]u8 = undefined;
    if (try in_stream.readAll(&header) != 16) {
        return CartLoadError.UnexpectedEof;
    }

    if (!std.mem.eql(u8, header[0..4], "NES\x1a")) {
        return CartLoadError.InvalidNesFile;
    }
    const prg_rom_size = header[4];
    const chr_rom_size = header[5];
    const ver_mirroring = header[6] & 1 == 1;
    const four_screen = (header[6] >> 3) & 1 == 1;
    const nt_mirroring = if (four_screen) NtMirroring.Four else if (ver_mirroring) NtMirroring.Ver else NtMirroring.Hor;
    const has_prg_ram = (header[6] >> 1) & 1 == 1;
    const has_trainer = (header[6] >> 2) & 1 == 1;
    var mapper_no = (header[7] & 0xf0) | (header[6] >> 4);
    std.debug.print("PRG size = {d}, CHR size = {d}, Mapper = {x:0>2}\n", .{ prg_rom_size, chr_rom_size, mapper_no });

    if (has_trainer) return CartLoadError.UnsupportedRom;

    switch (mapper_no) {
        0 => { // NROM
            if ((prg_rom_size != 1 and prg_rom_size != 2) or chr_rom_size > 1 or nt_mirroring == NtMirroring.Four)
                return CartLoadError.UnsupportedRom;

            var prg_rom0 = try read_alloc_static(alloc, in_stream, 16 * 1024);
            var prg_rom1: ?*[16 * 1024]u8 = null;
            if (prg_rom_size == 2) {
                prg_rom1 = try read_alloc_static(alloc, in_stream, 16 * 1024);
            }

            var prg_ram: ?*[8 * 1024]u8 = null;
            if (has_prg_ram) {
                prg_ram = @ptrCast(*[8 * 1024]u8, try alloc.alloc(u8, 8 * 1024));
            }

            var chr0: *[4 * 1024]u8 = undefined;
            var chr1: *[4 * 1024]u8 = undefined;
            var is_chr_ram: bool = false;
            if (chr_rom_size == 0) {
                chr0 = @ptrCast(*[4 * 1024]u8, try alloc.alloc(u8, 4 * 1024));
                chr1 = @ptrCast(*[4 * 1024]u8, try alloc.alloc(u8, 4 * 1024));
                is_chr_ram = true;
            } else {
                chr0 = try read_alloc_static(alloc, in_stream, 4 * 1024);
                chr1 = try read_alloc_static(alloc, in_stream, 4 * 1024);
            }

            var mapper = try alloc.create(mappers.Nrom);
            mapper.init(prg_rom0, prg_rom1, prg_ram, chr0, chr1, is_chr_ram, nt_mirroring);
            return mapper.cart();
        },
        1 => { // MMC1
            if (prg_rom_size > 16 or (chr_rom_size != 16 and chr_rom_size != 0) or nt_mirroring == NtMirroring.Four)
                return CartLoadError.UnsupportedRom;

            var prg_rom_banks: std.BoundedArray([16 * 1024]u8, 16) = undefined;
            prg_rom_banks.len = prg_rom_size;
            for (0..prg_rom_size) |i| {
                prg_rom_banks.set(i, try read_static(in_stream, 16 * 1024));
            }

            var prg_ram_banks: [4][8 * 1024]u8 = undefined;

            var chr_banks: [32][4 * 1024]u8 = undefined;
            var is_chr_ram = true;
            if (chr_rom_size == 16) {
                for (0..16) |i| {
                    chr_banks[i] = try read_static(in_stream, 4 * 1024);
                }
                is_chr_ram = false;
            }

            var mapper = try alloc.create(mappers.Mmc1);
            mapper.init(prg_rom_banks, prg_ram_banks, chr_banks, is_chr_ram, nt_mirroring);
            return mapper.cart();
        },
        else => return CartLoadError.UnsupportedRom,
    }
}
