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
const build_options = @import("build_options");

const adapt = @import("root.zig");
const Settings = adapt.Settings;

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
    \\  -o, --output <str>     Output filename, with ext: pdf(default),djvu,png,jpg,ppm. Note that if output is out.pdf, intermediate image files out-%d.ppm will be generated. Please make sure you do not have anything important like that in the output dir!
    \\  -d, --dir <str>        Output dir, default to be /tmp. Note that directory specified in your output file will be ignored!
    \\  -v, --vec <u32>        Whether to vectorize images when producing a pdf, vectorize it by default
    \\  -c, --channel <u32>    Number of color channels, default values are: pdf(1),djvu(1),png(3),jpg(3),ppm(3), pdf output only accepts c=1
    \\  <str>...
    \\
;

const Backend = enum { pdf, djvu, png, jpg, ppm };

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

    const dir = if (res.args.dir) |d| d else "/tmp"; // FIXME: maybe take care of dir specified in --output?

    var buf = [_]u8{0} ** 1024;
    const b, const outname, const ext = blk: {
        const o = if (res.args.output) |o| std.fs.path.basename(o) else "";
        const ext0 = std.fs.path.extension(o);
        const ext1 = std.ascii.lowerString(&buf, ext0);
        const b, const ext = blk1: {
            if (std.mem.eql(u8, ext1, ".djvu")) break :blk1 .{ Backend.djvu, "djvu" };
            if (std.mem.eql(u8, ext1, ".png")) break :blk1 .{ Backend.png, "png" };
            if (std.mem.eql(u8, ext1, ".jpg")) break :blk1 .{ Backend.jpg, "jpg" };
            if (std.mem.eql(u8, ext1, ".ppm")) break :blk1 .{ Backend.ppm, "ppm" };
            break :blk1 .{ Backend.pdf, "pdf" };
        };
        const outname = if (o.len > ext0.len) o[0 .. o.len - ext0.len] else "output";
        // const output = try std.fmt.allocPrint(allocator, "{s}.{s}", .{outname, ext});
        break :blk .{ b, outname, ext };
    };

    const c = switch (b) {
        .pdf => 1,
        else => if (res.args.channel) |c| (if (c >= 1 and c <= 3) c else 1) else 1,
    };

    const setting: Settings = .{ .channel = c };
    // Process to images using adaptive method
    for (res.positionals[0]) |pos| {
        const isf = std.fs.cwd().access(pos, .{});
        if (isf) |_| {
            var in = try adapt.readImage(pos, setting.channel0);
            defer in.deinit();
            var out = try adapt.processFile(allocator, in, setting);
            defer out.deinit();

            const ext1, const imgop: adapt.ImageOutputOptions = switch (b) {
                .jpg => .{ "jpg", .jpg },
                .png => .{ "png", .png },
                else => .{ "ppm", .ppm },
            };
            const imgname = try std.fmt.allocPrint(allocator, "{s}-{d}.{s}", .{ outname, fileind, ext1 });
            defer allocator.free(imgname);
            const imgpath = try std.fs.path.join(allocator, &.{ dir, imgname });

            std.debug.print("Processing {s} to {s}...\n", .{ pos, imgpath });
            try filenames.append(imgpath);

            fileind += 1;
            try adapt.writeToFile(out, imgpath, imgop);
        } else |_| {}
    }

    if (filenames.items.len == 0) return;

    // Make a document
    if (b == Backend.djvu) {
        var djvm = std.ArrayList([]const u8).init(allocator);
        defer djvm.deinit();
        const output = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ outname, ext });
        defer allocator.free(output);
        const outpath = try std.fs.path.join(allocator, &.{ dir, output });
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
    } else if (b == Backend.pdf) {
        const output = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ outname, ext });
        defer allocator.free(output);
        if (build_options.bundled_potrace) {
            const potrace = @import("potrace.zig");
            const outfile = try std.fs.path.join(allocator, &.{ dir, output });
            defer allocator.free(outfile);
            std.debug.print("Producing {s} ...\n", .{outfile});
            try potrace._main(allocator, outfile, filenames.items);
        } else {
            // calling external `potrace'
            var alist = std.ArrayList([]const u8).init(allocator);
            defer alist.deinit();
            const outpath = try std.fs.path.join(allocator, &.{ dir, output });
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
}
