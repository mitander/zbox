const std = @import("std");
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const term = @import("prim.zig");

// Exporting some functions directly from prim.
pub const size = term.size;
pub const ignoreSignalInput = term.ignoreSignalInput;
pub const handleSignalInput = term.handleSignalInput;
pub const cursorShow = term.cursorShow;
pub const cursorHide = term.cursorHide;
pub const nextEvent = term.nextEvent;
pub const setTimeout = term.setTimeout;
pub const clear = term.clear;
pub const Event = term.Event;

pub const ErrorSet = struct {
    pub const Term = term.ErrorSet;
    pub const Write = Term.Write || std.os.WriteError;
    pub const Utf8Encode = error{
        Utf8CannotEncodeSurrogateHalf,
        CodepointTooLarge,
    };
};

/// holds last drawn state of the terminal
var state: Buffer = undefined;

/// must be called before any buffers are `push`ed to the terminal.
pub fn init(allocator: Allocator) ErrorSet.Term.Setup!void {
    state = try Buffer.init(allocator, 24, 80);
    errdefer state.deinit();
    try term.setup(allocator);
}

/// should be called prior to program exit
pub fn deinit() void {
    state.deinit();
    term.teardown();
}

/// compare state of input buffer to a buffer tracking display state
/// and send changes to the terminal.
pub fn push(buffer: Buffer) (Allocator.Error || ErrorSet.Utf8Encode || ErrorSet.Write)!void {

    // resizing the state buffer naively can lead to artifacting
    // if we do not clear the terminal here.
    if ((buffer.width != state.width) or (buffer.height != state.height)) {
        try term.clear();
        state.clear();
    }

    try state.resize(buffer.height, buffer.width);
    var row: usize = 0;

    // TODO: figure out what this was used for
    // try term.beginSync();
    // try term.endSync(); (defered)

    while (row < buffer.height) : (row += 1) {
        var col: usize = 0;
        var last_touched: usize = buffer.width; // out of bounds, can't match col
        while (col < buffer.width) : (col += 1) {

            // go to the next character if these are the same.
            if (Cell.eql(
                state.cell(row, col),
                buffer.cell(row, col),
            )) continue;

            // only send cursor movement sequence if the last modified
            // cell was not the immediately previous cell in this row
            if (last_touched != col)
                try term.cursorTo(row, col);

            last_touched = col + 1;

            const cell = buffer.cell(row, col);
            state.cellRef(row, col).* = cell;

            var codepoint: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(cell.char, &codepoint);

            try term.sendSGR(cell.attribs);
            try term.send(codepoint[0..len]);
        }
    }
    try term.flush();
}

/// Structure that represents an invididuall text character in a terminal.
pub const Cell = struct {
    char: u21 = ' ',
    attribs: term.SGR = term.SGR{},
    fn eql(self: Cell, other: Cell) bool {
        return self.char == other.char and self.attribs.eql(other.attribs);
    }
};

/// Structure for handling drawing and printing operations to the terminal.
pub const Buffer = struct {
    data: []Cell,
    height: usize,
    width: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, height: usize, width: usize) Allocator.Error!Buffer {
        var self = Buffer{
            .data = try allocator.alloc(Cell, width * height),
            .width = width,
            .height = height,
            .allocator = allocator,
        };
        self.clear();
        return self;
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.data);
    }

    pub const Writer = std.io.Writer(
        *WriteCursor,
        WriteCursor.Error,
        WriteCursor.writeFn,
    );

    pub const WriteCursor = struct {
        row_num: usize,
        col_num: usize,
        wrap: bool = false,

        attribs: term.SGR = term.SGR{},
        buffer: *Buffer,

        const Error = error{ InvalidUtf8, InvalidCharacter };

        fn writeFn(self: *WriteCursor, bytes: []const u8) Error!usize {
            if (self.row_num >= self.buffer.height) return 0;

            var cp_iter = (try std.unicode.Utf8View.init(bytes)).iterator();
            var bytes_written: usize = 0;
            while (cp_iter.nextCodepoint()) |cp| {
                if (self.col_num >= self.buffer.width and self.wrap) {
                    self.col_num = 0;
                    self.row_num += 1;
                }
                if (self.row_num >= self.buffer.height) return bytes_written;

                switch (cp) {
                    //TODO: handle other line endings and return an error when
                    // encountering unpritable or width-breaking codepoints.
                    '\n' => {
                        self.col_num = 0;
                        self.row_num += 1;
                    },
                    else => {
                        if (self.col_num < self.buffer.width)
                            self.buffer.cellRef(self.row_num, self.col_num).* = .{
                                .char = cp,
                                .attribs = self.attribs,
                            };
                        self.col_num += 1;
                    },
                }
                bytes_written = cp_iter.i;
            }
            return bytes_written;
        }

        pub fn writer(self: *WriteCursor) Writer {
            return .{ .context = self };
        }
    };

    pub fn cursorAt(self: *Buffer, row_num: usize, col_num: usize) WriteCursor {
        return .{
            .row_num = row_num,
            .col_num = col_num,
            .buffer = self,
        };
    }

    pub fn wrappedCursorAt(self: *Buffer, row_num: usize, col_num: usize) WriteCursor {
        var cursor = self.cursorAt(row_num, col_num);
        cursor.wrap = true;
        return cursor;
    }

    pub fn clear(self: *Buffer) void {
        mem.set(Cell, self.data, .{});
    }

    pub fn row(self: anytype, row_num: usize) RowType: {
        switch (@typeInfo(@TypeOf(self))) {
            .Pointer => |p| {
                if (p.child != Buffer) @compileError("expected Buffer");
                if (p.is_const)
                    break :RowType []const Cell
                else
                    break :RowType []Cell;
            },
            else => {
                if (@TypeOf(self) != Buffer) @compileError("expected Buffer");
                break :RowType []const Cell;
            },
        }
    } {
        assert(row_num < self.height);
        const row_idx = row_num * self.width;
        return self.data[row_idx .. row_idx + self.width];
    }

    pub fn cellRef(self: anytype, row_num: usize, col_num: usize) RefType: {
        switch (@typeInfo(@TypeOf(self))) {
            .Pointer => |p| {
                if (p.child != Buffer) @compileError("expected Buffer");
                if (p.is_const)
                    break :RefType *const Cell
                else
                    break :RefType *Cell;
            },
            else => {
                if (@TypeOf(self) != Buffer) @compileError("expected Buffer");
                break :RefType *const Cell;
            },
        }
    } {
        assert(col_num < self.width);

        return &self.row(row_num)[col_num];
    }

    pub fn cell(self: Buffer, row_num: usize, col_num: usize) Cell {
        assert(col_num < self.width);
        return self.row(row_num)[col_num];
    }

    pub fn fill(self: *Buffer, a_cell: Cell) void {
        mem.set(Cell, self.data, a_cell);
    }

    /// grows or shrinks a cell buffer ensuring alignment by line and column
    /// data is lost in shrunk dimensions, and new space is initialized
    /// as the default cell in grown dimensions.
    pub fn resize(self: *Buffer, height: usize, width: usize) Allocator.Error!void {
        if (self.height == height and self.width == width) return;
        //TODO: figure out more ways to minimize unnecessary reallocation and
        //redrawing here. for instance:
        // `if self.width < width and self.height < self.height` no redraw or
        // realloc required
        // more difficult:
        // `if self.width * self.height >= width * height` requires redraw
        // but could possibly use some sort of scratch buffer thing.
        const old = self.*;
        self.* = .{
            .allocator = old.allocator,
            .width = width,
            .height = height,
            .data = try old.allocator.alloc(Cell, width * height),
        };

        if (width > old.width or
            height > old.height) self.clear();

        const min_height = math.min(old.height, height);
        const min_width = math.min(old.width, width);

        var n: usize = 0;
        while (n < min_height) : (n += 1) {
            mem.copy(Cell, self.row(n), old.row(n)[0..min_width]);
        }
        self.allocator.free(old.data);
    }

    // draw the contents of 'other' on top of the contents of self at the provided
    // offset. anything out of bounds of the destination is ignored. row_num and col_num
    // are still 1-indexed; this means 0 is out of bounds by 1, and -1 is out of bounds
    // by 2. This may change.
    pub fn blit(self: *Buffer, other: Buffer, row_num: isize, col_num: isize) void {
        var self_row_idx = row_num;
        var other_row_idx: usize = 0;

        while (self_row_idx < self.height and other_row_idx < other.height) : ({
            self_row_idx += 1;
            other_row_idx += 1;
        }) {
            if (self_row_idx < 0) continue;

            var self_col_idx = col_num;
            var other_col_idx: usize = 0;

            while (self_col_idx < self.width and other_col_idx < other.width) : ({
                self_col_idx += 1;
                other_col_idx += 1;
            }) {
                if (self_col_idx < 0) continue;

                self.cellRef(
                    @intCast(usize, self_row_idx),
                    @intCast(usize, self_col_idx),
                ).* = other.cell(other_row_idx, other_col_idx);
            }
        }
    }

    // TODO: migtht remove this
    pub fn format(
        self: Buffer,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;
        var row_num: usize = 0;
        try writer.print("\n\x1B[4m|", .{});

        while (row_num < self.height) : (row_num += 1) {
            for (self.row(row_num)) |this_cell| {
                var utf8Seq: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(this_cell.char, &utf8Seq) catch unreachable;
                try writer.print("{}|", .{utf8Seq[0..len]});
            }

            if (row_num != self.height - 1)
                try writer.print("\n|", .{});
        }

        try writer.print("\x1B[0m\n", .{});
    }
};

// tests ///////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
test "Buffer.resize()" {
    var buffer = try Buffer.init(std.testing.allocator, 10, 10);
    defer buffer.deinit();

    // newly initialized buffer should have all cells set to default value
    for (buffer.data) |cell| {
        std.testing.expectEqual(Cell{}, cell);
    }
    for (buffer.row(4)[0..3]) |*cell| {
        cell.char = '.';
    }

    try buffer.resize(5, 12);

    // make sure data is preserved between resizes
    for (buffer.row(4)[0..3]) |cell| {
        std.testing.expectEqual(@as(u21, '.'), cell.char);
    }

    // ensure nothing weird was written to expanded rows
    for (buffer.row(2)[3..]) |cell| {
        std.testing.expectEqual(Cell{}, cell);
    }
}

// most useful tests of this are function tests
// see `examples/`
test "buffer.cellRef()" {
    var buffer = try Buffer.init(std.testing.allocator, 1, 1);
    defer buffer.deinit();

    const ref = buffer.cellRef(0, 0);
    ref.* = Cell{ .char = '.' };

    std.testing.expectEqual(@as(u21, '.'), buffer.cell(0, 0).char);
}

test "buffer.cursorAt()" {
    var buffer = try Buffer.init(std.testing.allocator, 10, 10);
    defer buffer.deinit();

    var cursor = buffer.cursorAt(9, 5);
    const n = try cursor.writer().write("hello!!!!!\n!!!!");

    std.debug.print("{}", .{buffer});

    std.testing.expectEqual(@as(usize, 11), n);
}

test "Buffer.blit()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var alloc = &arena.allocator;
    var buffer1 = try Buffer.init(alloc, 10, 10);
    var buffer2 = try Buffer.init(alloc, 5, 5);
    buffer2.fill(.{ .char = '#' });
    std.debug.print("{}", .{buffer2});
    std.debug.print("blit(-2,6)", .{});
    buffer1.blit(buffer2, -2, 6);
    std.debug.print("{}", .{buffer1});
}

test "wrappedWrite" {
    var buffer = try Buffer.init(std.testing.allocator, 5, 5);
    defer buffer.deinit();

    var cursor = buffer.wrappedCursorAt(4, 0);

    const n = try cursor.writer().write("hello!!!!!");

    std.debug.print("{}", .{buffer});

    std.testing.expectEqual(@as(usize, 5), n);
}

test "static anal" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Cell);
    std.testing.refAllDecls(Buffer);
    std.testing.refAllDecls(Buffer.WriteCursor);
}
