const std = @import("std");
const domain = @import("domain.zig");
const Library = domain.Library;
const Clipping = domain.Clipping;
const Book = domain.Book;

const Allocator = std.mem.Allocator;

const DEFAULT_LIMIT: usize = 20;
const MAX_LIMIT: usize = 100;

const Pagination = struct {
    limit: usize,
    offset: usize,
};

const PageMeta = struct {
    total: usize,
    limit: usize,
    offset: usize,
    has_more: bool,
};

pub const Server = struct {
    allocator: Allocator,
    library: *const Library,
    tcp_server: std.net.Server,

    pub fn init(allocator: Allocator, library: *const Library, port: u16) !Server {
        const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
        const tcp_server = try address.listen(.{
            .reuse_address = true,
        });

        return Server{
            .allocator = allocator,
            .library = library,
            .tcp_server = tcp_server,
        };
    }

    pub fn deinit(self: *Server) void {
        self.tcp_server.deinit();
    }

    pub fn run(self: *Server) !void {
        std.debug.print("Server listening on http://localhost:{d}\n", .{self.tcp_server.listen_address.getPort()});

        while (true) {
            const conn = self.tcp_server.accept() catch |err| {
                std.debug.print("Accept error: {}\n", .{err});
                continue;
            };

            self.handleConnection(conn) catch |err| {
                std.debug.print("Handle error: {}\n", .{err});
            };
            conn.stream.close();
        }
    }

    fn handleConnection(self: *Server, conn: std.net.Server.Connection) !void {
        var read_buffer: [8192]u8 = undefined;
        const bytes_read = try conn.stream.read(&read_buffer);
        if (bytes_read == 0) return;

        const request = read_buffer[0..bytes_read];
        const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse return;
        const first_line = request[0..first_line_end];

        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return;
        const full_path = parts.next() orelse return;

        if (!std.mem.eql(u8, method, "GET")) {
            try self.sendMethodNotAllowed(conn.stream);
            return;
        }

        const path = parsePath(full_path);
        const pagination = parseQueryParams(full_path);

        if (std.mem.eql(u8, path, "/clippings")) {
            try self.handleGetClippings(conn.stream, pagination);
        } else if (std.mem.eql(u8, path, "/books")) {
            try self.handleGetBooks(conn.stream, pagination);
        } else if (std.mem.startsWith(u8, path, "/books/")) {
            const book_id = path[7..];
            try self.handleGetBook(conn.stream, book_id, pagination);
        } else {
            try self.sendNotFound(conn.stream);
        }
    }

    fn handleGetClippings(self: *Server, stream: std.net.Stream, pagination: Pagination) !void {
        const all_clippings = self.library.getAllClippings();
        const page = paginate(Clipping, all_clippings, pagination);
        const meta = PageMeta{
            .total = all_clippings.len,
            .limit = pagination.limit,
            .offset = pagination.offset,
            .has_more = pagination.offset + page.len < all_clippings.len,
        };

        const json = try self.clippingsToJsonPaged(page, meta);
        defer self.allocator.free(json);
        try self.sendJson(stream, json);
    }

    fn handleGetBooks(self: *Server, stream: std.net.Stream, pagination: Pagination) !void {
        const all_books = self.library.getBooks();
        const page = paginate(Book, all_books, pagination);
        const meta = PageMeta{
            .total = all_books.len,
            .limit = pagination.limit,
            .offset = pagination.offset,
            .has_more = pagination.offset + page.len < all_books.len,
        };

        const json = try self.booksToJsonPaged(page, meta);
        defer self.allocator.free(json);
        try self.sendJson(stream, json);
    }

    fn handleGetBook(self: *Server, stream: std.net.Stream, book_id: []const u8, pagination: Pagination) !void {
        const book = self.library.getBookById(book_id) orelse {
            try self.sendNotFound(stream);
            return;
        };

        const all_clippings = self.library.getClippingsForBook(book_id);
        defer if (all_clippings) |c| self.allocator.free(c);

        const clippings = all_clippings orelse &[_]Clipping{};
        const page = paginate(Clipping, clippings, pagination);
        const meta = PageMeta{
            .total = clippings.len,
            .limit = pagination.limit,
            .offset = pagination.offset,
            .has_more = pagination.offset + page.len < clippings.len,
        };

        const json = try self.bookWithClippingsToJsonPaged(book, page, meta);
        defer self.allocator.free(json);
        try self.sendJson(stream, json);
    }

    fn sendJson(self: *Server, stream: std.net.Stream, json: []const u8) !void {
        _ = self;
        var response_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&response_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{json.len}) catch unreachable;
        _ = try stream.write(header);
        _ = try stream.write(json);
    }

    fn sendNotFound(self: *Server, stream: std.net.Stream) !void {
        _ = self;
        const response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        _ = try stream.write(response);
    }

    fn sendMethodNotAllowed(self: *Server, stream: std.net.Stream) !void {
        _ = self;
        const response = "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        _ = try stream.write(response);
    }

    fn clippingsToJsonPaged(self: *Server, clippings: []const Clipping, meta: PageMeta) ![]u8 {
        var json: std.ArrayListUnmanaged(u8) = .empty;
        var writer = json.writer(self.allocator);

        try writer.writeAll("{\"data\":[");
        for (clippings, 0..) |clipping, i| {
            if (i > 0) try writer.writeByte(',');
            try self.writeClippingJson(writer, clipping);
        }
        try writer.writeAll("],\"meta\":");
        try writePageMeta(writer, meta);
        try writer.writeByte('}');

        return json.toOwnedSlice(self.allocator);
    }

    fn booksToJsonPaged(self: *Server, books: []const Book, meta: PageMeta) ![]u8 {
        var json: std.ArrayListUnmanaged(u8) = .empty;
        var writer = json.writer(self.allocator);

        try writer.writeAll("{\"data\":[");
        for (books, 0..) |book, i| {
            if (i > 0) try writer.writeByte(',');
            try self.writeBookJson(writer, book);
        }
        try writer.writeAll("],\"meta\":");
        try writePageMeta(writer, meta);
        try writer.writeByte('}');

        return json.toOwnedSlice(self.allocator);
    }

    fn bookWithClippingsToJsonPaged(self: *Server, book: Book, clippings: []const Clipping, meta: PageMeta) ![]u8 {
        var json: std.ArrayListUnmanaged(u8) = .empty;
        var writer = json.writer(self.allocator);

        try writer.writeAll("{\"id\":\"");
        try writer.writeAll(book.id);
        try writer.writeAll("\",\"title\":");
        try writeJsonString(writer, book.title);
        try writer.writeAll(",\"author\":");
        try writeJsonString(writer, book.author);
        try writer.writeAll(",\"clippings\":[");

        for (clippings, 0..) |clipping, i| {
            if (i > 0) try writer.writeByte(',');
            try self.writeClippingJson(writer, clipping);
        }

        try writer.writeAll("],\"meta\":");
        try writePageMeta(writer, meta);
        try writer.writeByte('}');

        return json.toOwnedSlice(self.allocator);
    }

    fn writeClippingJson(self: *Server, writer: anytype, clipping: Clipping) !void {
        _ = self;
        try writer.writeAll("{\"book_id\":\"");
        try writer.writeAll(clipping.book_id);
        try writer.writeAll("\",\"page\":");
        if (clipping.page) |page| {
            try writer.print("{d}", .{page});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"location_start\":");
        try writer.print("{d}", .{clipping.location_start});
        try writer.writeAll(",\"location_end\":");
        if (clipping.location_end) |end| {
            try writer.print("{d}", .{end});
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"added_at\":\"");
        try writeIso8601(writer, clipping.added_at);
        try writer.writeByte('"');
        try writer.writeAll(",\"text\":");
        try writeJsonString(writer, clipping.text);
        try writer.writeByte('}');
    }

    fn writeBookJson(self: *Server, writer: anytype, book: Book) !void {
        try writer.writeAll("{\"id\":\"");
        try writer.writeAll(book.id);
        try writer.writeAll("\",\"title\":");
        try writeJsonString(writer, book.title);
        try writer.writeAll(",\"author\":");
        try writeJsonString(writer, book.author);
        try writer.writeAll(",\"clipping_count\":");
        try writer.print("{d}", .{self.library.getClippingCountForBook(book.id)});
        try writer.writeByte('}');
    }
};

fn parsePath(full_path: []const u8) []const u8 {
    if (std.mem.indexOf(u8, full_path, "?")) |idx| {
        return full_path[0..idx];
    }
    return full_path;
}

fn parseQueryParams(full_path: []const u8) Pagination {
    var limit: usize = DEFAULT_LIMIT;
    var offset: usize = 0;

    const query_start = std.mem.indexOf(u8, full_path, "?") orelse return .{ .limit = limit, .offset = offset };
    const query = full_path[query_start + 1 ..];

    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |param| {
        if (std.mem.indexOf(u8, param, "=")) |eq_idx| {
            const key = param[0..eq_idx];
            const value = param[eq_idx + 1 ..];

            if (std.mem.eql(u8, key, "limit")) {
                limit = std.fmt.parseInt(usize, value, 10) catch DEFAULT_LIMIT;
                if (limit > MAX_LIMIT) limit = MAX_LIMIT;
                if (limit == 0) limit = DEFAULT_LIMIT;
            } else if (std.mem.eql(u8, key, "offset")) {
                offset = std.fmt.parseInt(usize, value, 10) catch 0;
            }
        }
    }

    return .{ .limit = limit, .offset = offset };
}

fn paginate(comptime T: type, items: []const T, pagination: Pagination) []const T {
    if (pagination.offset >= items.len) {
        return &[_]T{};
    }
    const start = pagination.offset;
    const end = @min(pagination.offset + pagination.limit, items.len);
    return items[start..end];
}

fn writePageMeta(writer: anytype, meta: PageMeta) !void {
    try writer.writeAll("{\"total\":");
    try writer.print("{d}", .{meta.total});
    try writer.writeAll(",\"limit\":");
    try writer.print("{d}", .{meta.limit});
    try writer.writeAll(",\"offset\":");
    try writer.print("{d}", .{meta.offset});
    try writer.writeAll(",\"has_more\":");
    try writer.writeAll(if (meta.has_more) "true" else "false");
    try writer.writeByte('}');
}

fn writeIso8601(writer: anytype, epoch: i64) !void {
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch) };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();

    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}

fn writeJsonString(writer: anytype, str: []const u8) !void {
    try writer.writeByte('"');
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

test "parse query params" {
    const p1 = parseQueryParams("/clippings?limit=10&offset=20");
    try std.testing.expectEqual(@as(usize, 10), p1.limit);
    try std.testing.expectEqual(@as(usize, 20), p1.offset);
}

test "parse query params defaults" {
    const p1 = parseQueryParams("/clippings");
    try std.testing.expectEqual(@as(usize, DEFAULT_LIMIT), p1.limit);
    try std.testing.expectEqual(@as(usize, 0), p1.offset);
}

test "parse query params max limit" {
    const p1 = parseQueryParams("/clippings?limit=999");
    try std.testing.expectEqual(@as(usize, MAX_LIMIT), p1.limit);
}

test "parse path" {
    try std.testing.expectEqualStrings("/clippings", parsePath("/clippings?limit=10"));
    try std.testing.expectEqualStrings("/books", parsePath("/books"));
}

test "paginate" {
    const items = [_]u8{ 1, 2, 3, 4, 5 };
    const page1 = paginate(u8, &items, .{ .limit = 2, .offset = 0 });
    try std.testing.expectEqual(@as(usize, 2), page1.len);

    const page2 = paginate(u8, &items, .{ .limit = 2, .offset = 2 });
    try std.testing.expectEqual(@as(usize, 2), page2.len);

    const page3 = paginate(u8, &items, .{ .limit = 2, .offset = 10 });
    try std.testing.expectEqual(@as(usize, 0), page3.len);
}

test "write iso8601" {
    var buf: [32]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try writeIso8601(writer, 1655163452);
    try std.testing.expectEqualStrings("2022-06-13T23:37:32Z", fbs.getWritten());
}
