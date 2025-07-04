//    Copyright (C) 2025  Zhengfei Hu
//
//    This program is free software: you can redistribute it and/or modify
//    it under the terms of the GNU General Public License as published by
//    the Free Software Foundation, either version 3 of the License, or
//    (at your option) any later version.
//
//    This program is distributed in the hope that it will be useful,
//    but WITHOUT ANY WARRANTY; without even the implied warranty of
//    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//    GNU General Public License for more details.
//
//    You should have received a copy of the GNU General Public License
//    along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const c = @cImport({
    @cInclude("potrace_main.h");
});

pub fn _main(a: std.mem.Allocator, outfile: []u8, infiles: []const []const u8) !void {
    const input: []const []const u8 = &.{ "./a", "-b", "pdf", "-o", outfile };

    var c_strings = std.ArrayList([*c]u8).init(a);
    defer {
        // Free each individual string
        for (c_strings.items) |c_str| {
            if (c_str != null) {
                a.free(std.mem.span(c_str)); // Free based on length up to null
            }
        }
        c_strings.deinit();
    }

    for (input) |s| {
        const c_str = try a.alloc(u8, s.len + 1);
        @memcpy(c_str[0..s.len], s);
        c_str[s.len] = 0; // null-terminate
        try c_strings.append(c_str.ptr); // store as [*c]u8
    }
    for (infiles) |s| {
        const c_str = try a.alloc(u8, s.len + 1);
        @memcpy(c_str[0..s.len], s);
        c_str[s.len] = 0; // null-terminate
        try c_strings.append(c_str.ptr); // store as [*c]u8
    }

    // for (c_strings.items) |s| {
    //     std.debug.print(" {s} ", .{s});
    // }

    const av: [*c][*c]u8 = c_strings.items.ptr;
    _ = c.potrace_main(@intCast(c_strings.items.len), av);
}
