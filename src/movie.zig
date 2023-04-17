const std = @import("std");
const Allocator = std.mem.Allocator;

const controller = @import("./controller.zig");
const Button = controller.Button;
const ButtonStates = controller.ButtonStates;

const MovieFrame = struct {
    port0: ButtonStates,
};

pub const Movie = struct {
    frames: std.ArrayList(MovieFrame),
};

const MovieLoadError = error{
    UnexpectedFormat,
};

const button_seq = [_]Button{ Button.Right, Button.Left, Button.Down, Button.Up, Button.Start, Button.Select, Button.B, Button.A };

pub fn load_fm2(alloc: Allocator, path: []const u8) !Movie {
    var file = try std.fs.cwd().openFile(path, .{ .mode = std.fs.File.OpenMode.read_only });
    defer file.close();
    var buf_reader = std.io.bufferedReader(file.reader());
    const reader = buf_reader.reader();
    var buf: [256]u8 = undefined;
    var movie = Movie{
        .frames = std.ArrayList(MovieFrame).init(alloc),
    };
    while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        if (line.len == 0) continue;
        if (line[0] == '|') {
            if (line.len != 22)
                return MovieLoadError.UnexpectedFormat;
            var frame = MovieFrame{
                .port0 = ButtonStates.init(),
            };
            for (0..button_seq.len) |i| {
                if (line[3 + i] != '.') {
                    frame.port0.set_button(button_seq[i], true);
                }
            }

            try movie.frames.append(frame);
        } else {
            std.debug.print("Metadata: {s}\n", .{line});
        }
    }
    return movie;
}
