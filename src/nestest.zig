const std = @import("std");

const loader = @import("./loader.zig");
const Nes = @import("./nes.zig").Nes;
const disasm = @import("./disasm.zig").disasm;

const NesTestLog = struct {
    pc: u16,
    a: u8,
    x: u8,
    y: u8,
    p: u8,
    s: u8,
    cyc: u64,
};

const TestError = error{TestLogParseError};
fn hex_after(line: []const u8, prefix: []const u8) !u8 {
    const idx = try (std.mem.indexOf(u8, line, prefix) orelse TestError.TestLogParseError);
    return std.fmt.parseInt(u8, line[idx + prefix.len .. idx + prefix.len + 2], 16);
}

test "Pass NESTest (automatic, official only)" {
    const alloc = std.testing.allocator;

    var log_stream = std.io.fixedBufferStream(@embedFile("nestest.log"));
    const log_reader = log_stream.reader();
    var log_line_buf: [100]u8 = undefined;
    var logs = std.ArrayList(NesTestLog).init(alloc);
    defer logs.deinit();
    while (try log_reader.readUntilDelimiterOrEof(&log_line_buf, '\n')) |line| {
        if (std.mem.indexOf(u8, line, "*") != null) {
            // reached part with invalid opcodes, stop
            break;
        }
        const pc = try std.fmt.parseInt(u16, line[0..4], 16);
        const a = try hex_after(line, "A:");
        const x = try hex_after(line, "X:");
        const y = try hex_after(line, "Y:");
        const p = try hex_after(line, "P:");
        const s = try hex_after(line, "SP:");
        const idx = try (std.mem.indexOf(u8, line, "CYC:") orelse TestError.TestLogParseError);
        const cyc = try std.fmt.parseInt(u64, line[idx + 4 ..], 10);
        try logs.append(NesTestLog{ .pc = pc, .a = a, .x = x, .y = y, .p = p, .s = s, .cyc = cyc });
    }

    var cart = try loader.load_cart_memory(alloc, @embedFile("nestest.nes"));
    defer cart.deinit(alloc);
    var nes = Nes.init(cart, null, null);
    nes.reg.pc = 0xc000;

    for (logs.items) |log| {
        const p = nes.get_flags_byte(false);
        // std.debug.print("PC={X:0>4}  A={X:0>2} X={X:0>2} Y={X:0>2} P={b:0>8} S={X:0>2} CYC={d}\n", .{ nes.reg.pc, nes.reg.a, nes.reg.x, nes.reg.y, p, nes.reg.s, nes.cpu_cycle });
        try std.testing.expectEqual(log.pc, nes.reg.pc);
        try std.testing.expectEqual(log.a, nes.reg.a);
        try std.testing.expectEqual(log.x, nes.reg.x);
        try std.testing.expectEqual(log.y, nes.reg.y);
        try std.testing.expectEqual(log.p, p);
        try std.testing.expectEqual(log.s, nes.reg.s);
        try std.testing.expectEqual(log.cyc, nes.cpu_cycle);
        nes.run_instr();
    }

    std.debug.print("NESTest (automatic, official only) passed!\n", .{});
}
