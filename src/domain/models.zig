const std = @import("std");

pub const Clipping = struct {
    book_id: []const u8,
    page: ?u32,
    location_start: u32,
    location_end: ?u32,
    added_at: i64,
    text: []const u8,
};

pub const Book = struct {
    id: []const u8,
    title: []const u8,
    author: []const u8,
    latest_clipping_at: i64,
};
