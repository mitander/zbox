const std = @import("std");
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const termio = @import("prim.zig");

pub const size = termio.size;
pub const ignoreSignalInput = termio.ignoreSignalInput;
pub const handleSignalInput = termio.handleSignalInput;
pub const cursorShow = termio.cursorShow;
pub const cursorHide = termio.cursorHide;
pub const nextEvent = termio.nextEvent;
pub const setTimeout = termio.setTimeout;
pub const clear = termio.clear;
pub const Event = termio.Event;

pub const Errors = struct {
    pub const Term = termio.Errors;
    pub const Write = termio.Errors.Write || std.os.WriteError;
    pub const Utf8Encode = error{
        Utf8CannotEncodeSurrogateHalf,
        CodepointTooLarge,
    };
};

var state: Buffer = undefined;

pub fn init(allocator: Allocator) Errors.Term.Setup!void {
    state = try Buffer.init(allocator, 24, 80);
    errdefer state.deinit();

    try termio.init(allocator);
    errdefer termio.deinit();
}

pub fn deinit() void {
    state.deinit();
    termio.deinit();
}

/// Compare state of input buffer to a buffer tracking display state
/// and send changes to the terminal.
pub fn push(buffer: Buffer) (Allocator.Error || Errors.Utf8Encode || Errors.Write)!void {
    // clear terminal while resizing window to prevent artifacts.
    if ((buffer.width != state.width) or (buffer.height != state.height)) {
        try termio.clear();
        state.clear();
    }

    // resize
    try state.resize(buffer.height, buffer.width);

    // TODO: figure out what this was used for
    // try term.beginSync();
    // defer try term.endSync();

    var row: usize = 0;
    while (row < buffer.height) : (row += 1) {
        var col: usize = 0;
        var last_touched: usize = buffer.width; // out of bounds, can't match col
        while (col < buffer.width) : (col += 1) {

            // skip if cells are equal
            if (Cell.eql(state.cell(row, col), buffer.cell(row, col))) continue;

            // only send cursor movement sequence if the last modified
            // cell was not the immediately previous cell in this row
            if (last_touched != col) try termio.cursorTo(row, col);

            last_touched = col + 1;

            const cell = buffer.cell(row, col);
            state.cellRef(row, col).* = cell;

            var codepoint: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(cell.char, &codepoint);

            try termio.sendSGR(cell.attribs);
            try termio.send(codepoint[0..len]);
        }
    }
    try termio.flush();
}

/// Structure that represents an invididual text character in a terminal.
pub const Cell = struct {
    char: u21 = ' ',
    attribs: termio.SGR = termio.SGR{},

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

        attribs: termio.SGR = termio.SGR{},
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
        return WriteCursor{
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
        // if dimensions are the same as previous draw we skip it.
        if (self.height == height and self.width == width) return;

        // update current buffer and make copy of old one.
        const old = self.*;
        self.* = .{
            .allocator = old.allocator,
            .width = width,
            .height = height,
            .data = try old.allocator.alloc(Cell, width * height),
        };

        // if any dimension got bigger we need to clear the screen.
        if (width > old.width or height > old.height) self.clear();

        // get minimum dimensions.
        const min_height = math.min(old.height, height);
        const min_width = math.min(old.width, width);

        // copy the rows matching with the updated dimensions.
        var n: usize = 0;
        while (n < min_height) : (n += 1) {
            mem.copy(Cell, self.row(n), old.row(n)[0..min_width]);
        }

        // de-allocate copy
        self.allocator.free(old.data);
    }

    // draw the contents of 'other' on top of the contents of self at the provided
    // offset. anything out of bounds of the destination is ignored. row_num and col_num
    // are still 1-indexed; this means 0 is out of bounds by 1, and -1 is out of bounds
    // by 2. This may change.
    pub fn blit(self: *Buffer, other: Buffer, row_num: isize, col_num: isize) void {
        var self_row_idx = row_num;
        var other_row_idx: usize = 0;

        var self_col_idx = col_num;
        var other_col_idx: usize = 0;

        while (self_row_idx < self.height and other_row_idx < other.height) : ({
            self_row_idx += 1;
            other_row_idx += 1;
        }) {
            if (self_row_idx < 0) continue;

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
