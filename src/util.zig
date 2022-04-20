const std = @import("std");

pub fn todo() noreturn {
    if (std.builtin.mode == .Debug) {
        std.debug.panic("TODO: implement me", .{});
    } else {
        @compileError("TODO: implement me");
    }
}
pub fn debug(comptime template: []const u8, args: anytype) void {
    if (!@hasDecl(@import("root"), "log")) return;
    std.log.scoped(.zbox).debug(template, args);
}

pub fn utf8ToWide(utf8: []const u8, chars: []u21) ![]u21 {
    var iter = (try std.unicode.Utf8View.init(utf8)).iterator();
    var offset: usize = 0;
    while (iter.nextCodepoint()) |cp| : (offset += 1)
        chars[offset] = cp;

    var new_chars = chars;
    new_chars.len = offset;
    return new_chars;
}

test "static anal" {
    std.testing.refAllDecls(@This());
}
