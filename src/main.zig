const std = @import("std");
const Alloc = std.mem.Allocator;

const ProcDetails = struct {
    name: []const u8,
    vmSwap: usize,
    // const PartialProcDetails = Partial(ProcDetails);
    // this would be an easy fn to make but there isn't much reason
    const PartialProcDetails = struct {
        name: ?[]const u8 = null,
        vmSwap: ?usize = null,
    };
    // ?! can't be done unfortunately
    fn dupe(alloc: *Alloc, opd: PartialProcDetails) !?ProcDetails {
        if (opd.name == null) return null;
        if (opd.vmSwap == null) return null;
        return ProcDetails{
            .name = try std.mem.dupe(alloc, u8, opd.name.?),
            .vmSwap = opd.vmSwap.?,
        };
    }
    fn deinit(pd: *ProcDetails, alloc: *Alloc) void {
        alloc.free(pd.name);
        pd.* = undefined;
    }
};

fn startsWithCut(text: []const u8, start: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, text, start)) {
        return text[start.len..];
    }
    return null;
}
fn endsWithCut(text: []const u8, end: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, text, end)) {
        return text[0 .. text.len - end.len];
    }
    return null;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = &gpa.allocator;

    // TODO bufferedOutStream
    const stdout = std.io.getStdOut().writer();

    // sidenote: on eg linux, couldn't argsAlloc
    // be changed to only allocate one slice and
    // use  std.mem.span(os.argv[0]) eg? because
    // since  you  have  to  call argsFree, that
    // could know to not free on posix
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var resItems = std.ArrayList(ProcDetails).init(alloc);
    defer resItems.deinit();
    defer for (resItems.items) |*item| item.deinit(alloc);

    {
        var procdir = try std.fs.cwd().openDir("/proc", .{ .iterate = true });
        defer procdir.close();
        var iter = procdir.iterate();

        while (try iter.next()) |entry| {
            if (entry.kind != .Directory) continue;

            var od = procdir.openDir(entry.name, .{}) catch |e| switch (e) {
                error.FileNotFound => continue,
                else => return e,
            };
            defer od.close();

            const statusFile = od.readFileAlloc(alloc, "status", std.math.maxInt(usize)) catch |e| switch (e) {
                error.FileNotFound => continue,
                else => return e,
            };
            defer alloc.free(statusFile);

            var resDetails = ProcDetails.PartialProcDetails{};

            // or readUntilDelimiterAlloc but this works too
            var split = std.mem.split(statusFile, "\n");
            while (split.next()) |line| {
                if (startsWithCut(line, "VmSwap:")) |memrem| {
                    if (resDetails.vmSwap != null) continue;
                    const numsexn = std.mem.trim(u8, endsWithCut(memrem, "kB").?, " \t");
                    resDetails.vmSwap = try std.fmt.parseInt(usize, numsexn, 10);
                }
                if (startsWithCut(line, "Name:")) |name| {
                    if (resDetails.name != null) continue;
                    resDetails.name = std.mem.trim(u8, name, " \t");
                }
            }

            if (try ProcDetails.dupe(alloc, resDetails)) |dtls| {
                try resItems.append(dtls);
            } else {
                std.log.debug("Ignoring :: {} :: {}", .{ entry.name, entry.kind });
            }
        }
    }

    std.sort.sort(ProcDetails, resItems.items, {}, struct {
        fn lessThan(ctx: void, lhs: ProcDetails, rhs: ProcDetails) bool {
            return lhs.vmSwap < rhs.vmSwap;
        }
    }.lessThan);

    try stdout.writeAll("{");
    for (resItems.items) |item, i| {
        if (i != 0) try stdout.writeAll(",\n") else try stdout.writeAll("\n");

        const humanize = Humanize{ .bytes = toBytes(item.vmSwap, .kb) };
        const humanized = try std.fmt.allocPrint(alloc, "{}", .{humanize});
        defer alloc.free(humanized);

        try stdout.writeAll("  ");
        try std.json.stringify(item.name, .{}, stdout);
        try stdout.writeAll(": ");
        try std.json.stringify(humanized, .{}, stdout);
    }
    try stdout.writeAll("\n");
    try stdout.writeAll("}\n");
}

// zig fmt: off
const Unit = enum (usize) {
    b, kb, mb, gb, tb, pb, eb, zb, yb,
    fn power(unit: Unit) usize {
        return @enumToInt(unit);
    }
    fn fromPower(powerr: usize) Unit {
        return @intToEnum(Unit, powerr);
    }
};
// zig fmt: on
fn toBytes(num: usize, from: Unit) usize {
    return num * std.math.pow(usize, 1024, from.power());
}
const Humanize = struct {
    bytes: usize,
    pub fn format(value: Humanize, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        const log = if (value.bytes == 0) 0 else @divFloor(std.math.log2_int(usize, value.bytes), 10);
        const runit = Unit.fromPower(log);
        // now print something
        const resv = value.bytes >> log * 10;
        if (log > 1) {
            const resc = (value.bytes >> (log * 10) - 10) & 0b1111111111;
            try writer.print("{}.{:0<4} {}", .{ resv, resc, @tagName(runit) });
        } else {
            try writer.print("{} {}", .{ resv, @tagName(runit) });
        }
    }
};
