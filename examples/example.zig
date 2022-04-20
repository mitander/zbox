const std = @import("std");
const zbox = @import("zbox");
const options = @import("build_options");

pub fn main() anyerror!void {
    // allocator
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var ally = arena.allocator();

    // parse args
    var args = std.process.args();
    _ = args.skip(); // ignore executable name

    // get filename from arg
    const filename = args.next() orelse {
        std.debug.print("No file supplied.\n", .{});
        std.debug.print("Usage: shark [filename]\n", .{});
        std.os.exit(1);
    };

    // read content of file
    var file = std.fs.cwd().openFile(filename, .{}) catch |err| return err;
    defer file.close();
    var file_content = try file.readToEndAlloc(ally, std.math.maxInt(usize));
    // std.log.debug("Read file content:\n{s}", .{file_content});

    // initialize zbox
    try zbox.init(ally);
    defer zbox.deinit();

    // kill process on ctrl-c
    try zbox.handleSignalInput();

    // get window size
    var size = try zbox.size();

    // init buffer
    var editor_canvas = try zbox.Buffer.init(ally, size.height, size.width);
    defer editor_canvas.deinit();

    var cursor = editor_canvas.cursorAt(0, 0);
    try cursor.writer().writeAll(file_content);

    // init
    var canvas = try zbox.Buffer.init(ally, size.height, size.width);
    defer canvas.deinit();

    // draw loop
    while (true) {
        // update the size of canvas
        size = try zbox.size();
        try canvas.resize(size.height, size.width);

        // draw
        canvas.clear();
        canvas.blit(editor_canvas, 0, 0);
        try zbox.push(canvas);

        // sleep
        std.os.nanosleep(0, 80_000_000);
    }
}

test "static anal" {
    std.testing.refAllDecls(@This());
}
