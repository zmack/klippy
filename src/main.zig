const std = @import("std");
const domain = @import("domain.zig");
const server_mod = @import("server.zig");

const Library = domain.Library;
const Server = server_mod.Server;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const clippings_path = "data/clippings.txt";
    const file = std.fs.cwd().openFile(clippings_path, .{}) catch |err| {
        std.debug.print("Failed to open {s}: {}\n", .{ clippings_path, err });
        return err;
    };
    defer file.close();

    const raw_text = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(raw_text);

    var library = try Library.init(allocator, raw_text);
    defer library.deinit();

    std.debug.print("Loaded {d} clippings from {d} books\n", .{ library.clippings.len, library.books.len });

    var srv = try Server.init(allocator, &library, 3000);
    defer srv.deinit();

    try srv.run();
}
