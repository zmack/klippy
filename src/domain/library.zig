const std = @import("std");
const parser = @import("parser.zig");
const models = @import("models.zig");

pub const Clipping = models.Clipping;
pub const Book = models.Book;

const Allocator = std.mem.Allocator;
pub const Library = struct {
    allocator: Allocator,
    clippings: []Clipping,
    books: []Book,
    book_clippings: std.StringHashMapUnmanaged([]usize),

    pub fn init(allocator: Allocator, raw_text: []const u8) !Library {
        const result = try parser.parse(allocator, raw_text);

        // Sort clippings by added_at desc
        std.mem.sort(Clipping, result.clippings, {}, struct {
            fn cmp(_: void, a: Clipping, b: Clipping) bool {
                return a.added_at > b.added_at;
            }
        }.cmp);

        // Sort books by latest_clipping_at desc, then by id
        std.mem.sort(Book, result.books, {}, struct {
            fn cmp(_: void, a: Book, b: Book) bool {
                if (a.latest_clipping_at != b.latest_clipping_at) {
                    return a.latest_clipping_at > b.latest_clipping_at;
                }
                return std.mem.order(u8, a.id, b.id) == .lt;
            }
        }.cmp);

        var book_clippings: std.StringHashMapUnmanaged([]usize) = .empty;

        for (result.books) |book| {
            var indices: std.ArrayListUnmanaged(usize) = .empty;
            for (result.clippings, 0..) |clipping, i| {
                if (std.mem.eql(u8, clipping.book_id, book.id)) {
                    try indices.append(allocator, i);
                }
            }
            try book_clippings.put(allocator, book.id, try indices.toOwnedSlice(allocator));
        }

        return Library{
            .allocator = allocator,
            .clippings = result.clippings,
            .books = result.books,
            .book_clippings = book_clippings,
        };
    }

    pub fn deinit(self: *Library) void {
        for (self.clippings) |clipping| {
            self.allocator.free(clipping.book_id);
            self.allocator.free(clipping.text);
        }
        self.allocator.free(self.clippings);

        for (self.books) |book| {
            self.allocator.free(book.id);
            self.allocator.free(book.title);
            self.allocator.free(book.author);
        }
        self.allocator.free(self.books);

        var iter = self.book_clippings.valueIterator();
        while (iter.next()) |indices| {
            self.allocator.free(indices.*);
        }
        self.book_clippings.deinit(self.allocator);
    }

    pub fn getAllClippings(self: *const Library) []const Clipping {
        return self.clippings;
    }

    pub fn getBooks(self: *const Library) []const Book {
        return self.books;
    }

    pub fn getBookById(self: *const Library, id: []const u8) ?Book {
        for (self.books) |book| {
            if (std.mem.eql(u8, book.id, id)) {
                return book;
            }
        }
        return null;
    }

    pub fn getClippingsForBook(self: *const Library, book_id: []const u8) ?[]const Clipping {
        const indices = self.book_clippings.get(book_id) orelse return null;

        var result = self.allocator.alloc(Clipping, indices.len) catch return null;
        for (indices, 0..) |idx, i| {
            result[i] = self.clippings[idx];
        }
        return result;
    }

    pub fn getClippingCountForBook(self: *const Library, book_id: []const u8) usize {
        const indices = self.book_clippings.get(book_id) orelse return 0;
        return indices.len;
    }

    pub const SearchFields = struct {
        title: bool = false,
        author: bool = false,
        text: bool = false,

        pub fn all() SearchFields {
            return .{ .title = true, .author = true, .text = true };
        }
    };

    pub fn searchBooks(self: *const Library, query: []const u8, fields: SearchFields) []const Book {
        var results: std.ArrayListUnmanaged(Book) = .empty;

        for (self.books) |book| {
            if (fields.title and containsIgnoreCase(book.title, query)) {
                results.append(self.allocator, book) catch continue;
                continue;
            }
            if (fields.author and containsIgnoreCase(book.author, query)) {
                results.append(self.allocator, book) catch continue;
            }
        }

        return results.toOwnedSlice(self.allocator) catch &[_]Book{};
    }

    pub fn searchClippings(self: *const Library, query: []const u8, fields: SearchFields) []const Clipping {
        var results: std.ArrayListUnmanaged(Clipping) = .empty;

        for (self.clippings) |clipping| {
            if (fields.text and containsIgnoreCase(clipping.text, query)) {
                results.append(self.allocator, clipping) catch continue;
                continue;
            }
            if (fields.title or fields.author) {
                if (self.getBookById(clipping.book_id)) |book| {
                    if (fields.title and containsIgnoreCase(book.title, query)) {
                        results.append(self.allocator, clipping) catch continue;
                        continue;
                    }
                    if (fields.author and containsIgnoreCase(book.author, query)) {
                        results.append(self.allocator, clipping) catch continue;
                    }
                }
            }
        }

        return results.toOwnedSlice(self.allocator) catch &[_]Clipping{};
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            const hc = haystack[i + j];
            if (std.ascii.toLower(hc) != std.ascii.toLower(nc)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

test "contains ignore case" {
    try std.testing.expect(containsIgnoreCase("Hello World", "world"));
    try std.testing.expect(containsIgnoreCase("Hello World", "HELLO"));
    try std.testing.expect(containsIgnoreCase("Hello World", "lo Wo"));
    try std.testing.expect(!containsIgnoreCase("Hello World", "xyz"));
    try std.testing.expect(containsIgnoreCase("Test", ""));
}

test "library init and query" {
    const allocator = std.testing.allocator;
    const raw =
        \\Test Book (Test Author)
        \\- Your Highlight on page 10 | Location 100-105 | Added on Monday, June 13, 2022 11:37:32 PM
        \\
        \\First highlight text
        \\==========
        \\Test Book (Test Author)
        \\- Your Highlight on page 20 | Location 200 | Added on Monday, June 13, 2022 11:40:00 PM
        \\
        \\Second highlight text
        \\==========
        \\Another Book (Different Author)
        \\- Your Highlight on page 5 | Location 50 | Added on Monday, June 13, 2022 12:00:00 PM
        \\
        \\Third highlight text
        \\==========
    ;

    var library = try Library.init(allocator, raw);
    defer library.deinit();

    try std.testing.expectEqual(@as(usize, 3), library.clippings.len);
    try std.testing.expectEqual(@as(usize, 2), library.books.len);

    const all_clippings = library.getAllClippings();
    try std.testing.expectEqual(@as(usize, 3), all_clippings.len);

    const books = library.getBooks();
    try std.testing.expectEqual(@as(usize, 2), books.len);
}

test "library get book by id" {
    const allocator = std.testing.allocator;
    const raw =
        \\Test Book (Test Author)
        \\- Your Highlight on page 10 | Location 100 | Added on Monday, June 13, 2022 11:37:32 PM
        \\
        \\Some text
        \\==========
    ;

    var library = try Library.init(allocator, raw);
    defer library.deinit();

    const book = library.getBookById(library.books[0].id);
    try std.testing.expect(book != null);
    try std.testing.expectEqualStrings("Test Book", book.?.title);
    try std.testing.expectEqualStrings("Test Author", book.?.author);

    const not_found = library.getBookById("nonexistent");
    try std.testing.expect(not_found == null);
}

test "library get clippings for book" {
    const allocator = std.testing.allocator;
    const raw =
        \\Book A (Author A)
        \\- Your Highlight on page 1 | Location 10 | Added on Monday, June 13, 2022 11:00:00 AM
        \\
        \\Text one
        \\==========
        \\Book A (Author A)
        \\- Your Highlight on page 2 | Location 20 | Added on Monday, June 13, 2022 11:00:00 AM
        \\
        \\Text two
        \\==========
        \\Book B (Author B)
        \\- Your Highlight on page 1 | Location 10 | Added on Monday, June 13, 2022 11:00:00 AM
        \\
        \\Text three
        \\==========
    ;

    var library = try Library.init(allocator, raw);
    defer library.deinit();

    var book_a_id: ?[]const u8 = null;
    for (library.books) |book| {
        if (std.mem.eql(u8, book.title, "Book A")) {
            book_a_id = book.id;
            break;
        }
    }

    try std.testing.expect(book_a_id != null);
    const clippings = library.getClippingsForBook(book_a_id.?);
    defer if (clippings) |c| allocator.free(c);

    try std.testing.expect(clippings != null);
    try std.testing.expectEqual(@as(usize, 2), clippings.?.len);
}

test "library clipping count for book" {
    const allocator = std.testing.allocator;
    const raw =
        \\Book A (Author A)
        \\- Your Highlight on page 1 | Location 10 | Added on Monday, June 13, 2022 11:00:00 AM
        \\
        \\Text
        \\==========
    ;

    var library = try Library.init(allocator, raw);
    defer library.deinit();

    const count = library.getClippingCountForBook(library.books[0].id);
    try std.testing.expectEqual(@as(usize, 1), count);

    const zero_count = library.getClippingCountForBook("nonexistent");
    try std.testing.expectEqual(@as(usize, 0), zero_count);
}
