const std = @import("std");
const clap = @import("clap");
const stb = @import("zstbi");

const adapt = @import("root.zig");
const Settings = adapt.Settings;

const paramString =
    \\-h, --help             Display this help and exit.
    \\-b, --backend <str>    Specify backend: jpg, png, ppm
    \\-r, --root <str>       Specify filename root as <root>-<d>.ext
    \\-p, --post <str>       Post process the produced image files to: pdf, djvu
    \\-o, --output <str>     Output filename of postprocessing, only basename of which is taken
    \\-d, --dir <str>        Output dir
    \\-v, --vec <u32>        Whether to vectorize images when producing a pdf, vectorize it by default
    \\-c, --channel <u32>    Number of channels for intermediate images, respected unless output is vectorized pdf
    \\<str>...
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

    if (res.args.help != 0)
        std.debug.print(paramString, .{});
    const backend = if (res.args.backend) |b| b else "png";
    _ = backend; // This is actually ignored
    const post = if (res.args.post) |p| p else "pdf";
    const output = if (res.args.output) |o| o else "output.pdf";
    const nameroot = if (res.args.root) |r| r else "img";
    const dir = if (res.args.dir) |d| d else "/tmp";
    const vec = if (res.args.vec) |v| v != 0 else true;
    const c = if (std.mem.eql(u8, post, "pdf") and vec) 1 else if (res.args.channel) |c| c else 1;

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
            if (ind == filenames.items.len) { // only wait for the last run
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

        std.debug.print("Producing {s}...\n", .{outpath});
    } else if (std.mem.eql(u8, post, "pdf")) {
        var alist = std.ArrayList([]const u8).init(allocator);
        defer alist.deinit();
        const outpath = try std.fs.path.join(allocator, &.{ dir, std.fs.path.basename(output) });
        defer allocator.free(outpath);
        if (vec) {
            try alist.appendSlice(&.{ "potrace", "-b", "pdf", "-o", outpath, "--" });
        } else {
            // img2pdf --output /tmp/out.pdf --pagesize 8.5inx11in IMG_20240604_173016_01.jpg IMG_20241022_185626_019.jpg IMG_20241022_185630_916.jpg
            try alist.appendSlice(&.{ "img2pdf", "--output", outpath, "--pagesize", "8.5inx11in" });
        }
        try alist.appendSlice(filenames.items);
        var cmd = std.process.Child.init(alist.items, allocator);
        cmd.spawn() catch |e| {
            std.debug.print("Failed spawning process pdfunite: {any}\n", .{e});
            unreachable;
        };
        std.debug.print("Producing {s}...\n", .{outpath});
    }
}
