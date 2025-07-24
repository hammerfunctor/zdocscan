//    Copyright (C) 2025 Zhengfei Hu
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
const stb = @import("zstbi");
const testing = std.testing;

const Image = stb.Image;
const Allocator = std.mem.Allocator;

pub const ImageOutputOptions = enum {
    png,
    jpg,
    ppm,
    pbm,
    pbm1,
};

pub const Settings = struct {
    channel: u32,
    channel0: u32 = 3,
    window_size: u32 = 10,
    percentage: u32 = 6,
    // pub fn init(c: u32, w: usize, p: u32) Conf {
    //     return Conf{ .channel = c, .window_size = w, .percentage = p };
    // }
};

pub fn toGrayscale(in: Image) !Image {
    var gray = try stb.Image.createEmpty(in.width, in.height, 1, .{});
    const data = in.data;

    const len = in.width * in.height;
    for (0..len) |i| {
        const r: f64 = @floatFromInt(data[3 * i]);
        const g: f64 = @floatFromInt(data[3 * i + 1]);
        const b: f64 = @floatFromInt(data[3 * i + 2]);
        gray.data[i] = @intFromFloat(0.299 * r + 0.587 * g + 0.114 * b);
    }
    return gray;
}

pub fn writeToFile(img: Image, filename: []const u8, o: ImageOutputOptions) !void {
    switch (o) {
        .jpg => try img.writeToFile(@ptrCast(filename), .{ .jpg = .{ .quality = 90 } }),
        .png => try img.writeToFile(@ptrCast(filename), .png),
        .ppm => {
            var file = try std.fs.cwd().createFile(filename, .{});
            defer file.close();
            var bw = std.io.bufferedWriter(file.writer());
            var fw = bw.writer();
            try fw.print("P6\n{d} {d}\n255\n", .{ img.width, img.height });
            switch (img.num_components) {
                1 => for (0..img.data.len) |i| {
                    try fw.writeByteNTimes(img.data[i], 3);
                },
                3 => for (0..img.data.len) |i| {
                    try fw.writeByte(img.data[i]);
                },
                else => unreachable,
            }
            try bw.flush();
        },
        .pbm => {
            // P4
            const mask = img.data;
            var file = try std.fs.cwd().createFile(filename, .{});
            defer file.close();
            var bw = std.io.bufferedWriter(file.writer());
            var fw = bw.writer();
            try fw.print("P4\n# comment\n#\n#\n{d} {d}\n", .{ img.width, img.height });

            const bn = img.width / 8; // number of complete bytes per row
            const rest = img.width % 8;

            // std.debug.print("width={d}, height={d}, bn={d}, rest={d}", .{ img.width, img.height, bn, rest });
            const bitmask = [8]u8{ 1 << 7, 1 << 6, 1 << 5, 1 << 4, 1 << 3, 1 << 2, 1 << 1, 1 << 0 };
            const extrabyte = rest != 0;
            for (0..img.height) |i| {
                const offset = i * img.width;
                for (0..bn) |j| {
                    const offset1 = offset + 8 * j;
                    var b: u8 = 0;
                    for (0..8) |k|
                        b |= mask[offset1 + k] & bitmask[k];
                    try fw.writeByte(~b);
                }
                const offset1 = offset + 8 * bn;
                var b: u8 = 0;
                if (extrabyte) {
                    // The last byte of the row doesn't care about padding bits on the right
                    for (0..rest) |k|
                        b |= mask[offset1 + k] & bitmask[k];
                    try fw.writeByte(~b);
                }
            }
            try bw.flush();
        },
        .pbm1 => {
            // P1
            const mask = img.data;
            var file = try std.fs.cwd().createFile(filename, .{});
            defer file.close();
            var bw = std.io.bufferedWriter(file.writer());
            var fw = bw.writer();
            try fw.print("P1\n# comment\n#\n{d} {d}\n", .{ img.width, img.height });

            for (0..mask.len) |i| {
                try fw.writeByte(49 - (1 & mask[i]));
                try fw.writeByte(' ');
            }
            try bw.flush();
        },
    }
}

pub fn readImage(imgpath: []const u8, c0: u32) !Image {
    // c is the number of channels, c=1 means grayscale image, c=3 means masking the original image
    const img = try stb.Image.loadFromFile(@ptrCast(imgpath), c0);
    return img;
}

pub fn processFile(a: Allocator, in: Image, s: Settings) !Image {
    var gray = try toGrayscale(in);
    defer gray.deinit();

    const mask = try adaptive_threshold(a, gray, s.window_size, s.percentage);
    defer a.free(mask);

    const c = s.channel;
    const c0 = s.channel0;
    var out = try stb.Image.createEmpty(in.width, in.height, c, .{});

    if (c == 1) {
        for (0..mask.len) |i|
            out.data[i] = mask[i];
    } else if (c == 3) {
        for (0..mask.len) |i| {
            // FIXME: colors in `in' should be unified to certain discrete ones
            out.data[c0 * i] = @max(mask[i], in.data[c0 * i]);
            out.data[c0 * i + 1] = @max(mask[i], in.data[c0 * i + 1]);
            out.data[c0 * i + 2] = @max(mask[i], in.data[c0 * i + 2]);
        }
    } else {
        unreachable;
    }
    return out;
}

// Pass in a grayscale image, return its integral image, whose elements store
// the sum of elements to its left and top in the original image
fn integral_image(a: Allocator, data: []const u8, w: usize, h: usize) ![]u64 {
    var out = try a.alloc(u64, w * h);

    // row cumsum of data
    for (0..w) |i| out[i] = @intCast(data[i]);
    for (1..h) |j| {
        for (0..w) |i| {
            out[w * j + i] = out[w * (j - 1) + i] + data[w * j + i];
        }
    }
    // col cumsum of out itself
    for (1..w) |i| {
        for (0..h) |j|
            out[w * j + i] = out[w * j + i] + out[w * j + i - 1];
    }
    return out;
}

// sum of box within [x0,x1] x [y0,y1], including boundary
fn boxdiff(int_img: []const u64, w: usize, x0: usize, y0: usize, x1: usize, y1: usize) u64 {
    var sum = int_img[w * y1 + x1];
    sum += if (x0 > 0 and y0 > 0) int_img[w * (y0 - 1) + x0 - 1] else 0;
    sum -= if (x0 > 0) int_img[w * y1 + x0 - 1] else 0;
    sum -= if (y0 > 0) int_img[w * (y0 - 1) + x1] else 0;
    return sum;
}

const Index = struct {
    x: i64,
    y: i64,

    pub fn init(x: anytype, y: anytype) Index {
        return Index{
            .x = @intCast(x),
            .y = @intCast(y),
        };
    }

    pub fn fromLin(i: usize, w: usize) Index {
        return Index{ .x = @intCast(i % w), .y = @intCast(i / w) };
    }
    pub fn toLin(self: Index, w: usize) usize {
        return w * @as(usize, @intCast(self.x)) + @as(usize, @intCast(self.y));
    }
    pub fn max(self: Index, other: Index) Index {
        return Index{ .x = @max(self.x, other.x), .y = @max(self.y, other.y) };
    }
    pub fn min(self: Index, other: Index) Index {
        return Index{ .x = @min(self.x, other.x), .y = @min(self.y, other.y) };
    }
    pub fn add(self: Index, other: Index) Index {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }
    pub fn subtract(self: Index, other: Index) Index {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }
};

pub fn adaptive_threshold(a: Allocator, img: Image, wsize: usize, perc: usize) ![]u8 {
    const radius: usize = wsize / 2;
    const window = Index.init(radius, radius);
    const data = img.data;
    const w = img.width;
    const int_img = try integral_image(a, data, w, img.height);
    defer a.free(int_img);
    const p0 = 0;
    const p1 = data.len;
    var mask = try a.alloc(u8, p1);

    for (p0..p1) |p| {
        // if (true) continue;
        const p_tl = Index.fromLin(p0, w).max(Index.fromLin(p, w).subtract(window));
        const p_br = Index.fromLin(p1 - 1, w).min(Index.fromLin(p, w).add(window));

        const total: f64 = @floatFromInt(boxdiff(int_img, w, @intCast(p_tl.x), @intCast(p_tl.y), @intCast(p_br.x), @intCast(p_br.y)));
        const count = (p_br.x - p_tl.x + 1) * (p_br.y - p_tl.y + 1);
        mask[p] = if (@as(f64, @floatFromInt(data[p] * count)) <= total * (1.0 - @as(f64, @floatFromInt(perc)) / 100.0))
            0
        else
            std.math.maxInt(u8);
    }
    return mask;
}

test "integral image and boxdiff test" {
    const a = testing.allocator;
    stb.init(a);
    defer stb.deinit();

    const data0 = [_]u8{ 1, 4, 7, 2, 5, 8, 3, 6, 9 };
    const data1 = [_]u64{ 1, 5, 12, 3, 12, 27, 6, 21, 45 };

    var img = try Image.createEmpty(3, 3, 1, .{});
    defer img.deinit();

    for (0..9) |i|
        img.data[i] = data0[i];

    const out = try integral_image(a, img.data, 3, 3);
    defer a.free(out);
    try testing.expectEqualSlices(u64, out, &data1);

    try testing.expectEqual(boxdiff(out, 3, 1, 0, 2, 2), 39);
    try testing.expectEqual(boxdiff(out, 3, 1, 0, 1, 2), 15);

    const v = std.math.maxInt(u8);
    const out1 = try adaptive_threshold(a, img, 2, 80);
    defer a.free(out1);
    try testing.expectEqualSlices(u8, &([1]u8{v} ** 9), out1);
    const out2 = try adaptive_threshold(a, img, 2, 6);
    defer a.free(out2);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, v, 0, v, v, 0, v, v }, out2);
}
