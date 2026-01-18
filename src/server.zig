const std = @import("std");
const domain = @import("domain.zig");
const Library = domain.Library;
const Clipping = domain.Clipping;
const Book = domain.Book;
const SearchFields = domain.SearchFields;

const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;

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

const SearchType = enum {
    all,
    books,
    clippings,
};

const SearchParams = struct {
    query: ?[]const u8,
    search_type: SearchType,
    fields: SearchFields,
    pagination: Pagination,
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
        var write_buffer: [8192]u8 = undefined;

        var stream_reader = conn.stream.reader(&read_buffer);
        var stream_writer = conn.stream.writer(&write_buffer);
        var http_server = std.http.Server.init(stream_reader.interface(), &stream_writer.interface);
        var request = try http_server.receiveHead();

        if (request.head.method != .GET) {
            try self.sendMethodNotAllowed(&request);
            return;
        }

        const full_path = request.head.target;
        const path = parsePath(full_path);
        const pagination = parseQueryParams(path);

        if (std.mem.eql(u8, path, "/clippings")) {
            try self.handleGetClippings(&request, pagination);
        } else if (std.mem.eql(u8, path, "/books")) {
            try self.handleGetBooks(&request, pagination);
        } else if (std.mem.startsWith(u8, path, "/books/")) {
            const book_id = path[7..];
            try self.handleGetBook(&request, book_id, pagination);
        } else if (std.mem.eql(u8, path, "/search")) {
            const search_params = parseSearchParams(full_path);
            try self.handleSearch(&request, search_params);
        } else if (std.mem.startsWith(u8, path, "/assets/")) {
            const filename = path[8..];
            try self.handleGetAsset(&request, filename);
        } else {
            try self.sendNotFound(&request);
        }
    }

    fn handleGetClippings(self: *Server, request: *Request, pagination: Pagination) !void {
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
        try self.sendJson(request, json);
    }

    fn handleGetBooks(self: *Server, request: *Request, pagination: Pagination) !void {
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
        try self.sendJson(request, json);
    }

    fn handleGetBook(self: *Server, request: *Request, book_id: []const u8, pagination: Pagination) !void {
        const book = self.library.getBookById(book_id) orelse {
            try self.sendNotFound(request);
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
        try self.sendJson(request, json);
    }

    fn handleGetAsset(self: *Server, request: *Request, filename: []const u8) !void {
        _ = self;

        // Validate path to prevent directory traversal
        if (!isValidAssetPath(filename)) {
            try request.respond("", .{ .status = .not_found, .keep_alive = false });
            return;
        }

        // Build path: public/{filename}
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "public/{s}", .{filename}) catch {
            try request.respond("", .{ .status = .not_found, .keep_alive = false });
            return;
        };

        // Open file
        const file = std.fs.cwd().openFile(path, .{}) catch {
            try request.respond("", .{ .status = .not_found, .keep_alive = false });
            return;
        };
        defer file.close();

        // Get file size for Content-Length
        const stat = file.stat() catch {
            try request.respond("", .{ .status = .not_found, .keep_alive = false });
            return;
        };

        // Start streaming response with content-length
        const mime_type = getMimeType(filename);
        var response_buf: [8192]u8 = undefined;
        var response = request.respondStreaming(&response_buf, .{
            .content_length = stat.size,
            .respond_options = .{
                .status = .ok,
                .keep_alive = false,
                .extra_headers = &[_]std.http.Header{
                    .{ .name = "content-type", .value = mime_type },
                },
            },
        }) catch {
            return;
        };

        // Stream file content in chunks
        var buf: [8192]u8 = undefined;
        while (true) {
            const bytes_read = file.read(&buf) catch {
                return;
            };
            if (bytes_read == 0) break;
            response.writer.writeAll(buf[0..bytes_read]) catch {
                return;
            };
        }
        response.end() catch {};
    }

    fn handleSearch(self: *Server, request: *Request, params: SearchParams) !void {
        const query = params.query orelse {
            try self.sendBadRequest(request, "Missing required parameter: q");
            return;
        };

        switch (params.search_type) {
            .clippings => {
                const all_results = self.library.searchClippings(query, params.fields);
                defer self.allocator.free(all_results);
                const page = paginate(Clipping, all_results, params.pagination);
                const meta = PageMeta{
                    .total = all_results.len,
                    .limit = params.pagination.limit,
                    .offset = params.pagination.offset,
                    .has_more = params.pagination.offset + page.len < all_results.len,
                };
                const json = try self.clippingsToJsonPaged(page, meta);
                defer self.allocator.free(json);
                try self.sendJson(request, json);
            },
            .books => {
                const all_results = self.library.searchBooks(query, params.fields);
                defer self.allocator.free(all_results);
                const page = paginate(Book, all_results, params.pagination);
                const meta = PageMeta{
                    .total = all_results.len,
                    .limit = params.pagination.limit,
                    .offset = params.pagination.offset,
                    .has_more = params.pagination.offset + page.len < all_results.len,
                };
                const json = try self.booksToJsonPaged(page, meta);
                defer self.allocator.free(json);
                try self.sendJson(request, json);
            },
            .all => {
                const all_clippings = self.library.searchClippings(query, params.fields);
                defer self.allocator.free(all_clippings);
                const all_books = self.library.searchBooks(query, params.fields);
                defer self.allocator.free(all_books);

                // Clippings first, books fill remainder
                const clippings_limit = @min(params.pagination.limit, all_clippings.len);
                const books_limit = params.pagination.limit -| clippings_limit;

                const clippings_page = paginate(Clipping, all_clippings, .{
                    .limit = clippings_limit,
                    .offset = params.pagination.offset,
                });
                const clippings_meta = PageMeta{
                    .total = all_clippings.len,
                    .limit = clippings_limit,
                    .offset = params.pagination.offset,
                    .has_more = params.pagination.offset + clippings_page.len < all_clippings.len,
                };

                const books_page = paginate(Book, all_books, .{
                    .limit = books_limit,
                    .offset = 0,
                });
                const books_meta = PageMeta{
                    .total = all_books.len,
                    .limit = books_limit,
                    .offset = 0,
                    .has_more = books_page.len < all_books.len,
                };

                const json = try self.searchAllToJson(clippings_page, clippings_meta, books_page, books_meta);
                defer self.allocator.free(json);
                try self.sendJson(request, json);
            },
        }
    }

    fn sendJson(self: *Server, request: *Request, json: []const u8) !void {
        _ = self;
        try request.respond(json, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
    }

    fn sendNotFound(self: *Server, request: *Request) !void {
        _ = self;
        try request.respond("", .{ .status = .not_found, .keep_alive = false });
    }

    fn sendMethodNotAllowed(self: *Server, request: *Request) !void {
        _ = self;
        try request.respond("", .{ .status = .method_not_allowed, .keep_alive = false });
    }

    fn sendBadRequest(self: *Server, request: *Request, message: []const u8) !void {
        _ = self;
        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{{\"error\":\"{s}\"}}", .{message}) catch message;
        try request.respond(body, .{
            .status = .bad_request,
            .keep_alive = false,
            .extra_headers = &[_]std.http.Header{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
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

    fn searchAllToJson(self: *Server, clippings: []const Clipping, clippings_meta: PageMeta, books: []const Book, books_meta: PageMeta) ![]u8 {
        var json: std.ArrayListUnmanaged(u8) = .empty;
        var writer = json.writer(self.allocator);

        try writer.writeAll("{\"clippings\":{\"data\":[");
        for (clippings, 0..) |clipping, i| {
            if (i > 0) try writer.writeByte(',');
            try self.writeClippingJson(writer, clipping);
        }
        try writer.writeAll("],\"meta\":");
        try writePageMeta(writer, clippings_meta);
        try writer.writeAll("},\"books\":{\"data\":[");
        for (books, 0..) |book, i| {
            if (i > 0) try writer.writeByte(',');
            try self.writeBookJson(writer, book);
        }
        try writer.writeAll("],\"meta\":");
        try writePageMeta(writer, books_meta);
        try writer.writeAll("}}");

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

fn getMimeType(filename: []const u8) []const u8 {
    const ext = std.fs.path.extension(filename);
    if (std.mem.eql(u8, ext, ".html")) return "text/html";
    if (std.mem.eql(u8, ext, ".css")) return "text/css";
    if (std.mem.eql(u8, ext, ".js")) return "application/javascript";
    if (std.mem.eql(u8, ext, ".json")) return "application/json";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".gif")) return "image/gif";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    if (std.mem.eql(u8, ext, ".woff")) return "font/woff";
    if (std.mem.eql(u8, ext, ".woff2")) return "font/woff2";
    if (std.mem.eql(u8, ext, ".txt")) return "text/plain";
    return "application/octet-stream";
}

fn isValidAssetPath(filename: []const u8) bool {
    if (filename.len == 0) return false;
    if (filename[0] == '/') return false;
    if (std.mem.indexOf(u8, filename, "..") != null) return false;
    return true;
}

fn parsePath(full_path: []const u8) []const u8 {
    if (std.mem.indexOf(u8, full_path, "?")) |idx| {
        return full_path[0..idx];
    }
    return full_path;
}

fn parseSearchParams(full_path: []const u8) SearchParams {
    var result = SearchParams{
        .query = null,
        .search_type = .all,
        .fields = SearchFields.all(),
        .pagination = .{ .limit = DEFAULT_LIMIT, .offset = 0 },
    };

    const query_start = std.mem.indexOf(u8, full_path, "?") orelse return result;
    const query_string = full_path[query_start + 1 ..];

    var params = std.mem.splitScalar(u8, query_string, '&');
    while (params.next()) |param| {
        if (std.mem.indexOf(u8, param, "=")) |eq_idx| {
            const key = param[0..eq_idx];
            const value = param[eq_idx + 1 ..];

            if (std.mem.eql(u8, key, "q")) {
                result.query = value;
            } else if (std.mem.eql(u8, key, "type")) {
                if (std.mem.eql(u8, value, "books")) {
                    result.search_type = .books;
                } else if (std.mem.eql(u8, value, "clippings")) {
                    result.search_type = .clippings;
                } else {
                    result.search_type = .all;
                }
            } else if (std.mem.eql(u8, key, "fields")) {
                result.fields = parseFieldsParam(value);
            } else if (std.mem.eql(u8, key, "limit")) {
                var limit = std.fmt.parseInt(usize, value, 10) catch DEFAULT_LIMIT;
                if (limit > MAX_LIMIT) limit = MAX_LIMIT;
                if (limit == 0) limit = DEFAULT_LIMIT;
                result.pagination.limit = limit;
            } else if (std.mem.eql(u8, key, "offset")) {
                result.pagination.offset = std.fmt.parseInt(usize, value, 10) catch 0;
            }
        }
    }

    return result;
}

fn parseFieldsParam(value: []const u8) SearchFields {
    var fields = SearchFields{};
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "title")) {
            fields.title = true;
        } else if (std.mem.eql(u8, part, "author")) {
            fields.author = true;
        } else if (std.mem.eql(u8, part, "text")) {
            fields.text = true;
        }
    }
    // If no valid fields specified, default to all
    if (!fields.title and !fields.author and !fields.text) {
        return SearchFields.all();
    }
    return fields;
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
