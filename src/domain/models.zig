const std = @import("std");
const Library = @import("library.zig").Library;

pub const Clipping = struct {
    pub const Json = ClippingJson;

    book_id: []const u8,
    page: ?u32,
    location_start: u32,
    location_end: ?u32,
    added_at: i64,
    text: []const u8,
};

pub const Book = struct {
    pub const Json = BookJson;

    id: []const u8,
    title: []const u8,
    author: []const u8,
    latest_clipping_at: i64,
};

pub const ClippingJson = struct {
    book_id: []const u8,
    page: ?u32,
    location_start: u32,
    location_end: ?u32,
    added_at: Iso8601,
    text: []const u8,

    pub fn from(c: Clipping) ClippingJson {
        return .{
            .book_id = c.book_id,
            .page = c.page,
            .location_start = c.location_start,
            .location_end = c.location_end,
            .added_at = .{ .epoch = c.added_at },
            .text = c.text,
        };
    }
};

pub const BookJson = struct {
    id: []const u8,
    title: []const u8,
    author: []const u8,
    clipping_count: usize,

    pub fn from(b: Book, library: *const Library) BookJson {
        return .{
            .id = b.id,
            .title = b.title,
            .author = b.author,
            .clipping_count = library.getClippingCountForBook(b.id),
        };
    }
};

// JSON response types with custom serialization

pub const Iso8601 = struct {
    epoch: i64,

    pub fn jsonStringify(self: Iso8601, jw: anytype) !void {
        const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(self.epoch) };
        const epoch_day = epoch_secs.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_secs = epoch_secs.getDaySeconds();

        var buf: [24]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
        }) catch unreachable;
        try jw.write(str);
    }
};
