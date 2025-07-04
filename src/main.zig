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
const clap = @import("clap");
const stb = @import("zstbi");

const adapt = @import("root.zig");
const Settings = adapt.Settings;

const potrace = @import("potrace.zig");
const backend_pdf = potrace.backend_pdf;

const preHelpString =
    \\
    \\    This program is distributed in the hope that it will be useful,
    \\    but WITHOUT ANY WARRANTY; without even the implied warranty of
    \\    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    \\    GNU General Public License for more details.
    \\
    \\ zdocscan [options] <a.ppm>
    \\
;
const paramString =
    \\  -h, --help             Display this help and exit.
    \\  -b, --backend <str>    Specify backend: jpg, png, ppm
    \\  -r, --root <str>       Specify filename root as <root>-<d>.ext
    \\  -p, --post <str>       Post process the produced image files to: pdf, djvu, pdfe(calling external potrace to generate pdf file)
    \\  -o, --output <str>     Output filename of postprocessing, only basename of which is taken
    \\  -d, --dir <str>        Output dir
    \\  -v, --vec <u32>        Whether to vectorize images when producing a pdf, vectorize it by default
    \\  -c, --channel <u32>    Number of channels for intermediate images, respected unless output is vectorized pdf
    \\  <str>...
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    stb.init(allocator);
    defer stb.deinit();

    const params = comptime clap.parseParamsComptime(paramString);

    // Initialize our diagnostics, which can be used for reporting useful errors.
    // This is optional. You can also pass `.{}` to `clap.parse` if you don't
    // care about the extra information `Diagnostics` provides.
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        // Report useful error and exit.
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    var fileind: usize = 0;
    var filenames = std.ArrayList([]const u8).init(allocator);
    defer filenames.deinit();
    defer for (filenames.items) |f| allocator.free(f);

    if (res.args.help != 0) {
        std.debug.print(preHelpString, .{});
        std.debug.print(paramString, .{});
    }
    const backend = if (res.args.backend) |b| b else "png";
    _ = backend; // Ignored, we don't need other formats
    const c = if (res.args.channel) |c| c else 1;

    const post, const output = blk: {
        const outext = if (res.args.output) |o| std.fs.path.extension(o) else "";
        const outname = if (res.args.output) |o| o[0 .. o.len - outext.len] else "output";
        if (c != 1) {
            // only accept djvu when c!=1
            std.debug.print(">>> When number of color channels is other than 1, ONLY djvu document will be attempted! <<<\n", .{});
            const output = try std.fmt.allocPrint(allocator, "{s}.djvu", .{outname});
            break :blk .{ "djvu", output };
        }
        if (res.args.post) |p| {
            if (std.mem.eql(u8, p, "djvu")) {
                const output = try std.fmt.allocPrint(allocator, "{s}.djvu", .{outname});
                break :blk .{ "djvu", output };
            }
            if (std.mem.eql(u8, p, "pdfe")) {
                const output = try std.fmt.allocPrint(allocator, "{s}.pdf", .{outname});
                break :blk .{ "pdfe", output };
            }
        }
        if (std.mem.eql(u8, outext[1..], "djvu")) {
            const output = try std.fmt.allocPrint(allocator, "{s}.djvu", .{outname});
            break :blk .{ "djvu", output };
        }
        // Otherwise, for c=1 we always assume a pdf document
        const output = try std.fmt.allocPrint(allocator, "{s}.pdf", .{outname});
        break :blk .{ "pdf", output };
    };
    defer allocator.free(output);

    const nameroot = if (res.args.root) |r| r else "img";
    const dir = if (res.args.dir) |d| d else "/tmp";

    const setting: Settings = .{ .channel = c };
    // Process to images using adaptive method
    for (res.positionals[0]) |pos| {
        const isf = std.fs.cwd().access(pos, .{});
        if (isf) |_| {
            var in = try adapt.readImage(pos, setting.channel0);
            defer in.deinit();

            var out = try adapt.processFile(allocator, in, setting);
            defer out.deinit();

            const ext = "ppm";
            const imgname = try std.fmt.allocPrint(allocator, "{s}-{d}.{s}", .{ nameroot, fileind, ext });
            defer allocator.free(imgname);
            const imgpath = try std.fs.path.join(allocator, &.{ dir, imgname });

            std.debug.print("Processing {s} to {s}...\n", .{ pos, imgpath });
            try filenames.append(imgpath);

            fileind += 1;
            try adapt.writeToFile(out, imgpath, .ppm);
        } else |_| {}
    }

    if (filenames.items.len == 0) return;
    // Make a document
    if (std.mem.eql(u8, post, "djvu")) {
        var djvm = std.ArrayList([]const u8).init(allocator);
        defer djvm.deinit();
        const outpath = try std.fs.path.join(allocator, &.{ dir, std.fs.path.basename(output) });
        defer allocator.free(outpath);

        try djvm.appendSlice(&.{ "djvm", "-c", outpath });
        defer for (djvm.items[3..]) |f| allocator.free(f);

        for (filenames.items, 0..) |i, ind| {
            const pagepath = try std.fmt.allocPrint(allocator, "{s}.djvu", .{i});
            try djvm.append(pagepath);
            var cmd = std.process.Child.init(&.{ "c44", i, pagepath }, allocator);
            if (ind == filenames.items.len - 1) { // only wait for the last run
                _ = cmd.spawnAndWait() catch |e| {
                    std.debug.print("Failed spawning process c44: {any}\n", .{e});
                    unreachable;
                };
            } else {
                cmd.spawn() catch |e| {
                    std.debug.print("Failed spawning process c44: {any}\n", .{e});
                    unreachable;
                };
            }
        }
        var cmd = std.process.Child.init(djvm.items, allocator);
        cmd.spawn() catch |e| {
            std.debug.print("Failed spawning process djvm: {any}\n", .{e});
            unreachable;
        };

        std.debug.print("Producing {s} ...\n", .{outpath});
    } else if (std.mem.eql(u8, post, "pdf")) {
        const outfile = try std.fs.path.join(allocator, &.{ dir, std.fs.path.basename(output) });
        defer allocator.free(outfile);
        std.debug.print("Producing {s} ...\n", .{outfile});
        try potrace._main(allocator, outfile, filenames.items);
    } else if (std.mem.eql(u8, post, "pdfe")) {
        // calling external `potrace'
        var alist = std.ArrayList([]const u8).init(allocator);
        defer alist.deinit();
        const outpath = try std.fs.path.join(allocator, &.{ dir, std.fs.path.basename(output) });
        defer allocator.free(outpath);
        try alist.appendSlice(&.{ "potrace", "-b", "pdf", "-o", outpath, "--" });
        try alist.appendSlice(filenames.items);
        var cmd = std.process.Child.init(alist.items, allocator);
        cmd.spawn() catch |e| {
            std.debug.print("Failed spawning process: {any}\n", .{e});
            unreachable;
        };
        std.debug.print("Producing {s}...\n", .{outpath});
    }
}
