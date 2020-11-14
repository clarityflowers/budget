const std = @import("std");
const StringHashMap = std.StringHashMap;
const Allocator = std.mem.Allocator;

/// Copies a string into a hash map to make its memory reuseable
pub const StringLibrary = struct {
    const Map = StringHashMap(void);
    map: Map,

    pub fn init(allocator: *Allocator) @This() {
        return @This(){ .map = Map.init(allocator) };
    }

    /// `key` and `value` are copied into the BufMap.
    pub fn save(self: *@This(), string: []const u8) ![]const u8 {
        const get_or_put = try self.map.getOrPut(string);
        if (!get_or_put.found_existing) {
            get_or_put.entry.key = self.copy(string) catch |err| {
                _ = self.map.remove(string);
                return err;
            };
        }
        return get_or_put.entry.key;
    }

    fn copy(self: @This(), value: []const u8) ![]u8 {
        return self.map.allocator.dupe(u8, value);
    }
};
