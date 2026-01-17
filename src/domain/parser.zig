const std = @import("std");
const models = @import("models.zig");
const Clipping = models.Clipping;
const Book = models.Book;
const Allocator = std.mem.Allocator;

pub const ParseResult = struct {
    clippings: []Clipping,
    books: []Book,
};

pub fn parse(allocator: Allocator, raw: []const u8) !ParseResult {
    var clippings: std.ArrayListUnmanaged(Clipping) = .empty;
    var books_map: std.StringHashMapUnmanaged(Book) = .empty;
    defer books_map.deinit(allocator);

    var blocks = std.mem.splitSequence(u8, raw, "==========");
    while (blocks.next()) |block| {
        const trimmed = std.mem.trim(u8, block, " \t\n\r");
        if (trimmed.len == 0) continue;

        if (parseBlock(allocator, trimmed)) |clipping| {
            try clippings.append(allocator, clipping);

            if (books_map.getPtr(clipping.book_id)) |book| {
                if (clipping.added_at > book.latest_clipping_at) {
                    book.latest_clipping_at = clipping.added_at;
                }
            } else {
                const book = try extractBook(allocator, trimmed, clipping.added_at);
                try books_map.put(allocator, book.id, book);
            }
        } else |_| {
            continue;
        }
    }

    var books: std.ArrayListUnmanaged(Book) = .empty;
    var book_iter = books_map.valueIterator();
    while (book_iter.next()) |book| {
        try books.append(allocator, book.*);
    }

    return ParseResult{
        .clippings = try clippings.toOwnedSlice(allocator),
        .books = try books.toOwnedSlice(allocator),
    };
}

fn parseBlock(allocator: Allocator, block: []const u8) !Clipping {
    var lines = std.mem.splitScalar(u8, block, '\n');

    const title_line = lines.next() orelse return error.MalformedBlock;
    const meta_line = lines.next() orelse return error.MalformedBlock;

    var text_parts: std.ArrayListUnmanaged(u8) = .empty;
    defer text_parts.deinit(allocator);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            if (text_parts.items.len > 0) {
                try text_parts.append(allocator, ' ');
            }
            try text_parts.appendSlice(allocator, trimmed);
        }
    }

    const text = try allocator.dupe(u8, text_parts.items);
    if (text.len == 0) return error.EmptyClipping;

    const book_id = try generateBookId(allocator, title_line);
    const meta = try parseMeta(meta_line);

    return Clipping{
        .book_id = book_id,
        .page = meta.page,
        .location_start = meta.location_start,
        .location_end = meta.location_end,
        .added_at = meta.added_at,
        .text = text,
    };
}

fn extractBook(allocator: Allocator, block: []const u8, added_at: i64) !Book {
    var lines = std.mem.splitScalar(u8, block, '\n');
    const title_line = lines.next() orelse return error.MalformedBlock;

    const title_author = try parseTitleAuthor(allocator, title_line);
    const id = try generateBookId(allocator, title_line);

    return Book{
        .id = id,
        .title = title_author.title,
        .author = title_author.author,
        .latest_clipping_at = added_at,
    };
}

const TitleAuthor = struct {
    title: []const u8,
    author: []const u8,
};

fn parseTitleAuthor(allocator: Allocator, line: []const u8) !TitleAuthor {
    const trimmed = std.mem.trim(u8, line, " \t\r\xef\xbb\xbf");

    if (std.mem.lastIndexOf(u8, trimmed, " (")) |paren_start| {
        if (trimmed[trimmed.len - 1] == ')') {
            const title = try allocator.dupe(u8, trimmed[0..paren_start]);
            const author = try allocator.dupe(u8, trimmed[paren_start + 2 .. trimmed.len - 1]);
            return TitleAuthor{ .title = title, .author = author };
        }
    }

    return TitleAuthor{
        .title = try allocator.dupe(u8, trimmed),
        .author = try allocator.dupe(u8, "Unknown"),
    };
}

fn generateBookId(allocator: Allocator, title_line: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, title_line, " \t\r\xef\xbb\xbf");
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(trimmed);
    const hash = hasher.final();

    const id = try allocator.alloc(u8, 16);
    _ = std.fmt.bufPrint(id, "{x:0>16}", .{hash}) catch unreachable;
    return id;
}

const Meta = struct {
    page: ?u32,
    location_start: u32,
    location_end: ?u32,
    added_at: i64,
};

fn parseMeta(line: []const u8) !Meta {
    var page: ?u32 = null;
    var location_start: u32 = 0;
    var location_end: ?u32 = null;
    var added_at: i64 = 0;

    var parts = std.mem.splitScalar(u8, line, '|');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r");

        if (std.mem.indexOf(u8, trimmed, "page")) |_| {
            page = parsePageNumber(trimmed);
        } else if (std.mem.indexOf(u8, trimmed, "Location")) |_| {
            const loc = parseLocation(trimmed);
            location_start = loc.start;
            location_end = loc.end;
        } else if (std.mem.indexOf(u8, trimmed, "Added on")) |_| {
            added_at = parseDate(trimmed);
        }
    }

    return Meta{
        .page = page,
        .location_start = location_start,
        .location_end = location_end,
        .added_at = added_at,
    };
}

fn parsePageNumber(part: []const u8) ?u32 {
    var i: usize = 0;
    while (i < part.len) : (i += 1) {
        if (std.ascii.isDigit(part[i])) {
            var end = i;
            while (end < part.len and std.ascii.isDigit(part[end])) : (end += 1) {}
            return std.fmt.parseInt(u32, part[i..end], 10) catch null;
        }
    }
    return null;
}

const Location = struct {
    start: u32,
    end: ?u32,
};

fn parseLocation(part: []const u8) Location {
    var start: u32 = 0;
    var end: ?u32 = null;

    if (std.mem.indexOf(u8, part, "Location")) |loc_idx| {
        const after_loc = part[loc_idx + 8 ..];
        const trimmed = std.mem.trim(u8, after_loc, " ");

        if (std.mem.indexOf(u8, trimmed, "-")) |dash_idx| {
            start = std.fmt.parseInt(u32, trimmed[0..dash_idx], 10) catch 0;
            var end_idx = dash_idx + 1;
            while (end_idx < trimmed.len and std.ascii.isDigit(trimmed[end_idx])) : (end_idx += 1) {}
            end = std.fmt.parseInt(u32, trimmed[dash_idx + 1 .. end_idx], 10) catch null;
        } else {
            var end_idx: usize = 0;
            while (end_idx < trimmed.len and std.ascii.isDigit(trimmed[end_idx])) : (end_idx += 1) {}
            start = std.fmt.parseInt(u32, trimmed[0..end_idx], 10) catch 0;
        }
    }

    return Location{ .start = start, .end = end };
}

fn parseDate(part: []const u8) i64 {
    if (std.mem.indexOf(u8, part, "Added on")) |idx| {
        const date_str = std.mem.trim(u8, part[idx + 8 ..], " ");
        return parseDateString(date_str);
    }
    return 0;
}

fn parseDateString(date_str: []const u8) i64 {
    // Format: "Monday, June 13, 2022 11:37:32 PM"
    var parts = std.mem.splitScalar(u8, date_str, ',');

    _ = parts.next(); // Skip day name

    const month_day = std.mem.trim(u8, parts.next() orelse return 0, " ");
    const year_time = std.mem.trim(u8, parts.next() orelse return 0, " ");

    var md_parts = std.mem.splitScalar(u8, month_day, ' ');
    const month_str = md_parts.next() orelse return 0;
    const day_str = md_parts.next() orelse return 0;

    var yt_parts = std.mem.splitScalar(u8, year_time, ' ');
    const year_str = yt_parts.next() orelse return 0;
    const time_str = yt_parts.next() orelse return 0;
    const ampm = yt_parts.next() orelse "AM";

    const month = monthToNumber(month_str);
    const day = std.fmt.parseInt(u8, day_str, 10) catch return 0;
    const year = std.fmt.parseInt(u16, year_str, 10) catch return 0;

    var time_parts = std.mem.splitScalar(u8, time_str, ':');
    var hour = std.fmt.parseInt(u8, time_parts.next() orelse "0", 10) catch 0;
    const minute = std.fmt.parseInt(u8, time_parts.next() orelse "0", 10) catch 0;
    const second = std.fmt.parseInt(u8, time_parts.next() orelse "0", 10) catch 0;

    if (std.mem.eql(u8, ampm, "PM") and hour != 12) {
        hour += 12;
    } else if (std.mem.eql(u8, ampm, "AM") and hour == 12) {
        hour = 0;
    }

    const epoch_day = epochDaysFromDate(year, month, day);
    const day_seconds: i64 = @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);

    return epoch_day * 86400 + day_seconds;
}

fn monthToNumber(month: []const u8) u8 {
    const months = [_][]const u8{
        "January", "February", "March",     "April",   "May",      "June",
        "July",    "August",   "September", "October", "November", "December",
    };
    for (months, 1..) |m, i| {
        if (std.mem.eql(u8, month, m)) return @intCast(i);
    }
    return 1;
}

fn epochDaysFromDate(year: u16, month: u8, day: u8) i64 {
    var y: i64 = @intCast(year);
    var m: i64 = @intCast(month);
    const d: i64 = @intCast(day);

    if (m <= 2) {
        y -= 1;
        m += 12;
    }

    const era = @divFloor(y, 400);
    const yoe = @mod(y, 400);
    const doy = @divFloor((153 * (m - 3) + 2), 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;

    return era * 146097 + doe - 719468;
}

test "parse title and author" {
    const allocator = std.testing.allocator;
    const result = try parseTitleAuthor(allocator, "HBR Guide to Making Better Decisions (Harvard Business Review)");
    defer allocator.free(result.title);
    defer allocator.free(result.author);

    try std.testing.expectEqualStrings("HBR Guide to Making Better Decisions", result.title);
    try std.testing.expectEqualStrings("Harvard Business Review", result.author);
}

test "parse location range" {
    const result = parseLocation("Location 574-578");
    try std.testing.expectEqual(@as(u32, 574), result.start);
    try std.testing.expectEqual(@as(?u32, 578), result.end);
}

test "parse single location" {
    const result = parseLocation("Location 1347");
    try std.testing.expectEqual(@as(u32, 1347), result.start);
    try std.testing.expectEqual(@as(?u32, null), result.end);
}

test "parse date string" {
    const epoch = parseDateString("Monday, June 13, 2022 11:37:32 PM");
    try std.testing.expectEqual(@as(i64, 1655163452), epoch);
}

test "parse date string AM" {
    const epoch = parseDateString("Wednesday, July 20, 2022 8:26:51 PM");
    try std.testing.expect(epoch > 0);
}

test "parse page number" {
    const page = parsePageNumber("Your Highlight on page 44");
    try std.testing.expectEqual(@as(?u32, 44), page);
}

test "parse page number none" {
    const page = parsePageNumber("Your Highlight at location");
    try std.testing.expectEqual(@as(?u32, null), page);
}

test "generate book id is deterministic" {
    const allocator = std.testing.allocator;
    const id1 = try generateBookId(allocator, "Test Book (Author)");
    defer allocator.free(id1);
    const id2 = try generateBookId(allocator, "Test Book (Author)");
    defer allocator.free(id2);

    try std.testing.expectEqualStrings(id1, id2);
    try std.testing.expectEqual(@as(usize, 16), id1.len);
}

test "parse full block" {
    const allocator = std.testing.allocator;
    const block =
        \\HBR Guide to Making Better Decisions (Harvard Business Review)
        \\- Your Highlight on page 44 | Location 574-578 | Added on Monday, June 13, 2022 11:37:32 PM
        \\
        \\Who should recommend a course of action?
    ;

    const clipping = try parseBlock(allocator, block);
    defer allocator.free(clipping.book_id);
    defer allocator.free(clipping.text);

    try std.testing.expectEqual(@as(?u32, 44), clipping.page);
    try std.testing.expectEqual(@as(u32, 574), clipping.location_start);
    try std.testing.expectEqual(@as(?u32, 578), clipping.location_end);
    try std.testing.expectEqual(@as(i64, 1655163452), clipping.added_at);
    try std.testing.expectEqualStrings("Who should recommend a course of action?", clipping.text);
}

test "parse skips empty clippings" {
    const allocator = std.testing.allocator;
    const raw =
        \\Book Title (Author)
        \\- Your Highlight on page 1 | Location 100 | Added on Monday, June 13, 2022 11:37:32 PM
        \\
        \\
        \\==========
        \\Book Title (Author)
        \\- Your Highlight on page 2 | Location 200 | Added on Monday, June 13, 2022 11:37:32 PM
        \\
        \\Some actual text here
        \\==========
    ;

    const result = try parse(allocator, raw);
    defer allocator.free(result.clippings);
    defer allocator.free(result.books);
    for (result.clippings) |c| {
        allocator.free(c.book_id);
        allocator.free(c.text);
    }
    for (result.books) |b| {
        allocator.free(b.id);
        allocator.free(b.title);
        allocator.free(b.author);
    }

    try std.testing.expectEqual(@as(usize, 1), result.clippings.len);
    try std.testing.expectEqual(@as(usize, 1), result.books.len);
}
