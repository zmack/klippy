const std = @import("std");
const domain = @import("domain.zig");
const Library = domain.Library;
const Clipping = domain.Clipping;
const Book = domain.Book;

const Allocator = std.mem.Allocator;

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
        const path = parts.next() orelse return;

        if (!std.mem.eql(u8, method, "GET")) {
            try self.sendMethodNotAllowed(conn.stream);
            return;
        }

        if (std.mem.eql(u8, path, "/clippings")) {
            try self.handleGetClippings(conn.stream);
        } else if (std.mem.eql(u8, path, "/books")) {
            try self.handleGetBooks(conn.stream);
        } else if (std.mem.startsWith(u8, path, "/books/")) {
            const book_id = path[7..];
            try self.handleGetBook(conn.stream, book_id);
        } else {
            try self.sendNotFound(conn.stream);
        }
    }

    fn handleGetClippings(self: *Server, stream: std.net.Stream) !void {
        const clippings = self.library.getAllClippings();
        const json = try self.clippingsToJson(clippings);
        defer self.allocator.free(json);
        try self.sendJson(stream, json);
    }

    fn handleGetBooks(self: *Server, stream: std.net.Stream) !void {
        const books = self.library.getBooks();
        const json = try self.booksToJson(books);
        defer self.allocator.free(json);
        try self.sendJson(stream, json);
    }

    fn handleGetBook(self: *Server, stream: std.net.Stream, book_id: []const u8) !void {
        const book = self.library.getBookById(book_id) orelse {
            try self.sendNotFound(stream);
            return;
        };

        const clippings = self.library.getClippingsForBook(book_id);
        defer if (clippings) |c| self.allocator.free(c);

        const json = try self.bookWithClippingsToJson(book, clippings orelse &[_]Clipping{});
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

    fn clippingsToJson(self: *Server, clippings: []const Clipping) ![]u8 {
        var json: std.ArrayListUnmanaged(u8) = .empty;
        var writer = json.writer(self.allocator);

        try writer.writeByte('[');
        for (clippings, 0..) |clipping, i| {
            if (i > 0) try writer.writeByte(',');
            try self.writeClippingJson(writer, clipping);
        }
        try writer.writeByte(']');

        return json.toOwnedSlice(self.allocator);
    }

    fn booksToJson(self: *Server, books: []const Book) ![]u8 {
        var json: std.ArrayListUnmanaged(u8) = .empty;
        var writer = json.writer(self.allocator);

        try writer.writeByte('[');
        for (books, 0..) |book, i| {
            if (i > 0) try writer.writeByte(',');
            try self.writeBookJson(writer, book);
        }
        try writer.writeByte(']');

        return json.toOwnedSlice(self.allocator);
    }

    fn bookWithClippingsToJson(self: *Server, book: Book, clippings: []const Clipping) ![]u8 {
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

        try writer.writeAll("]}");

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
        try writer.writeAll(",\"added_at\":");
        try writer.print("{d}", .{clipping.added_at});
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
