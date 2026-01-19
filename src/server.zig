const std = @import("std");
const domain = @import("domain.zig");
const Library = domain.Library;
const Clipping = domain.Clipping;
const ClippingJson = domain.ClippingJson;
const Book = domain.Book;
const BookJson = domain.BookJson;
const Iso8601 = domain.Iso8601;
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

fn PagedJson(comptime T: type) type {
    return struct {
        data: []const T,
        meta: PageMeta,
    };
}

const BookDetailJson = struct {
    id: []const u8,
    title: []const u8,
    author: []const u8,
    clippings: []const ClippingJson,
    meta: PageMeta,
};

const SearchAllJson = struct {
    clippings: PagedJson(ClippingJson),
    books: PagedJson(BookJson),
};

fn mapEntities(allocator: Allocator, items: anytype, args: anytype) ![]@typeInfo(@TypeOf(items)).pointer.child.Json {
    const T = @typeInfo(@TypeOf(items)).pointer.child;
    const TargetType = T.Json;
    const result = try allocator.alloc(TargetType, items.len);

    for (items, 0..) |item, i| {
        const full_args = .{item} ++ args;
        result[i] = @call(.auto, TargetType.from, full_args);
    }
    return result;
}

fn mapClippings(allocator: Allocator, clippings: []const Clipping) ![]const ClippingJson {
    return mapEntities(allocator, clippings, .{});
}

fn mapBooks(allocator: Allocator, books: []const Book, library: *const Library) ![]const BookJson {
    return mapEntities(allocator, books, .{library});
}

fn toJson(allocator: Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

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

const RequestContext = struct {
    request: *Request,
    full_path: []const u8,
    path: []const u8,

    pub fn pathSuffix(self: RequestContext, prefix: []const u8) []const u8 {
        return self.path[prefix.len..];
    }

    pub fn getPagination(self: RequestContext) Pagination {
        return parseQueryParams(self.full_path);
    }

    pub fn getSearchParams(self: RequestContext) SearchParams {
        return parseSearchParams(self.full_path);
    }
};

pub const Server = struct {
    allocator: Allocator,
    library: *const Library,
    tcp_server: std.net.Server,

    const Route = struct {
        path: []const u8,
        match: MatchType,
        handler: *const fn (*Server, RequestContext) anyerror!void,

        const MatchType = enum { exact, prefix };
    };

    const routes = [_]Route{
        .{ .path = "/clippings", .match = .exact, .handler = handleGetClippings },
        .{ .path = "/books/", .match = .prefix, .handler = handleGetBook },
        .{ .path = "/books", .match = .exact, .handler = handleGetBooks },
        .{ .path = "/search", .match = .exact, .handler = handleSearch },
        .{ .path = "/assets/", .match = .prefix, .handler = handleGetAsset },
        .{ .path = "/", .match = .exact, .handler = handleIndex },
        .{ .path = "/index.html", .match = .exact, .handler = handleIndex },
        .{ .path = "/index.htm", .match = .exact, .handler = handleIndex },
    };

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

        const ctx = RequestContext{
            .request = &request,
            .full_path = request.head.target,
            .path = parsePath(request.head.target),
        };

        try self.route(ctx);
    }

    fn route(self: *Server, ctx: RequestContext) !void {
        for (routes) |r| {
            const matched = switch (r.match) {
                .exact => std.mem.eql(u8, ctx.path, r.path),
                .prefix => std.mem.startsWith(u8, ctx.path, r.path),
            };
            if (matched) {
                try r.handler(self, ctx);
                return;
            }
        }
        try self.sendNotFound(ctx.request);
    }

    fn handleGetClippings(self: *Server, ctx: RequestContext) !void {
        const all_clippings = self.library.getAllClippings();
        const result = paginateWithMeta(all_clippings, ctx.getPagination());

        const data = try mapClippings(self.allocator, result.page);
        defer self.allocator.free(data);

        const json = try toJson(self.allocator, PagedJson(ClippingJson){ .data = data, .meta = result.meta });
        defer self.allocator.free(json);
        try self.sendJson(ctx.request, json);
    }

    fn handleGetBooks(self: *Server, ctx: RequestContext) !void {
        const all_books = self.library.getBooks();
        const result = paginateWithMeta(all_books, ctx.getPagination());

        const data = try mapBooks(self.allocator, result.page, self.library);
        defer self.allocator.free(data);

        const json = try toJson(self.allocator, PagedJson(BookJson){ .data = data, .meta = result.meta });
        defer self.allocator.free(json);
        try self.sendJson(ctx.request, json);
    }

    fn handleGetBook(self: *Server, ctx: RequestContext) !void {
        const book_id = ctx.pathSuffix("/books/");

        const book = self.library.getBookById(book_id) orelse {
            try self.sendNotFound(ctx.request);
            return;
        };

        const all_clippings = self.library.getClippingsForBook(book_id);
        defer if (all_clippings) |c| self.allocator.free(c);

        const clippings = all_clippings orelse &[_]Clipping{};
        const result = paginateWithMeta(clippings, ctx.getPagination());

        const clippings_json = try mapClippings(self.allocator, result.page);
        defer self.allocator.free(clippings_json);

        const json = try toJson(self.allocator, BookDetailJson{
            .id = book.id,
            .title = book.title,
            .author = book.author,
            .clippings = clippings_json,
            .meta = result.meta,
        });
        defer self.allocator.free(json);
        try self.sendJson(ctx.request, json);
    }

    fn handleGetAsset(self: *Server, ctx: RequestContext) !void {
        _ = self;
        const filename = ctx.pathSuffix("/assets/");

        // Validate path to prevent directory traversal
        if (!isValidAssetPath(filename)) {
            try ctx.request.respond("", .{ .status = .not_found, .keep_alive = false });
            return;
        }

        // Build path: public/{filename}
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "public/{s}", .{filename}) catch {
            try ctx.request.respond("", .{ .status = .not_found, .keep_alive = false });
            return;
        };

        // Open file
        const file = std.fs.cwd().openFile(path, .{}) catch {
            try ctx.request.respond("", .{ .status = .not_found, .keep_alive = false });
            return;
        };
        defer file.close();

        // Get file size for Content-Length
        const stat = file.stat() catch {
            try ctx.request.respond("", .{ .status = .not_found, .keep_alive = false });
            return;
        };

        // Start streaming response with content-length
        const mime_type = getMimeType(filename);
        var response_buf: [8192]u8 = undefined;
        var response = ctx.request.respondStreaming(&response_buf, .{
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

    fn handleSearch(self: *Server, ctx: RequestContext) !void {
        const params = ctx.getSearchParams();
        const query = params.query orelse {
            try self.sendBadRequest(ctx.request, "Missing required parameter: q");
            return;
        };

        switch (params.search_type) {
            .clippings => {
                const all_results = self.library.searchClippings(query, params.fields);
                defer self.allocator.free(all_results);
                const result = paginateWithMeta(all_results, params.pagination);

                const data = try mapClippings(self.allocator, result.page);
                defer self.allocator.free(data);

                const json = try toJson(self.allocator, PagedJson(ClippingJson){ .data = data, .meta = result.meta });
                defer self.allocator.free(json);
                try self.sendJson(ctx.request, json);
            },
            .books => {
                const all_results = self.library.searchBooks(query, params.fields);
                defer self.allocator.free(all_results);
                const result = paginateWithMeta(all_results, params.pagination);

                const data = try mapBooks(self.allocator, result.page, self.library);
                defer self.allocator.free(data);

                const json = try toJson(self.allocator, PagedJson(BookJson){ .data = data, .meta = result.meta });
                defer self.allocator.free(json);
                try self.sendJson(ctx.request, json);
            },
            .all => {
                const all_clippings = self.library.searchClippings(query, params.fields);
                defer self.allocator.free(all_clippings);
                const all_books = self.library.searchBooks(query, params.fields);
                defer self.allocator.free(all_books);

                // Clippings first, books fill remainder
                const clippings_limit = @min(params.pagination.limit, all_clippings.len);
                const books_limit = params.pagination.limit -| clippings_limit;

                const clippings_result = paginateWithMeta(all_clippings, .{
                    .limit = clippings_limit,
                    .offset = params.pagination.offset,
                });
                const books_result = paginateWithMeta(all_books, .{
                    .limit = books_limit,
                    .offset = 0,
                });

                const clippings_data = try mapClippings(self.allocator, clippings_result.page);
                defer self.allocator.free(clippings_data);
                const books_data = try mapBooks(self.allocator, books_result.page, self.library);
                defer self.allocator.free(books_data);

                const json = try toJson(self.allocator, SearchAllJson{
                    .clippings = .{ .data = clippings_data, .meta = clippings_result.meta },
                    .books = .{ .data = books_data, .meta = books_result.meta },
                });
                defer self.allocator.free(json);
                try self.sendJson(ctx.request, json);
            },
        }
    }

    fn handleIndex(self: *Server, ctx: RequestContext) !void {
        _ = self;

        const file = std.fs.cwd().openFile("public/index.html", .{}) catch {
            try ctx.request.respond("", .{ .status = .not_found, .keep_alive = false });
            return;
        };
        defer file.close();

        const stat = file.stat() catch {
            try ctx.request.respond("", .{ .status = .not_found, .keep_alive = false });
            return;
        };

        var response_buf: [8192]u8 = undefined;
        var response = ctx.request.respondStreaming(&response_buf, .{
            .content_length = stat.size,
            .respond_options = .{
                .status = .ok,
                .keep_alive = false,
                .extra_headers = &[_]std.http.Header{
                    .{ .name = "content-type", .value = "text/html" },
                },
            },
        }) catch {
            return;
        };

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

fn paginate(items: anytype, pagination: Pagination) @TypeOf(items) {
    if (pagination.offset >= items.len) {
        return items[0..0];
    }
    const start = pagination.offset;
    const end = @min(pagination.offset + pagination.limit, items.len);
    return items[start..end];
}

fn paginateWithMeta(items: anytype, pagination: Pagination) struct { page: @TypeOf(items), meta: PageMeta } {
    const page = paginate(items, pagination);
    return .{
        .page = page,
        .meta = PageMeta{
            .total = items.len,
            .limit = pagination.limit,
            .offset = pagination.offset,
            .has_more = pagination.offset + page.len < items.len,
        },
    };
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
    const page1 = paginate(&items, .{ .limit = 2, .offset = 0 });
    try std.testing.expectEqual(@as(usize, 2), page1.len);

    const page2 = paginate(&items, .{ .limit = 2, .offset = 2 });
    try std.testing.expectEqual(@as(usize, 2), page2.len);

    const page3 = paginate(&items, .{ .limit = 2, .offset = 10 });
    try std.testing.expectEqual(@as(usize, 0), page3.len);
}

test "iso8601 json serialization" {
    const ts = Iso8601{ .epoch = 1655163452 };
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, ts, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("\"2022-06-13T23:37:32Z\"", json);
}
