const std = @import("std");
const builtin = @import("builtin");

/// PKCE code verifier and challenge pair
pub const PKCEPair = struct {
    verifier: []const u8,
    challenge: []const u8,

    pub fn deinit(self: *const PKCEPair, allocator: std.mem.Allocator) void {
        allocator.free(self.verifier);
        allocator.free(self.challenge);
    }
};

/// Generate PKCE code verifier and challenge using S256 method
pub fn generatePKCE(allocator: std.mem.Allocator) !PKCEPair {
    // Generate random verifier (32 bytes = 43 chars base64url)
    var verifier_bytes: [32]u8 = undefined;
    try fillSecureRandom(&verifier_bytes);

    const verifier = try base64urlEncode(allocator, &verifier_bytes);
    errdefer allocator.free(verifier);

    // Compute SHA-256 challenge
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &hash, .{});

    const challenge = try base64urlEncode(allocator, &hash);
    errdefer allocator.free(challenge);

    return PKCEPair{
        .verifier = verifier,
        .challenge = challenge,
    };
}

fn fillSecureRandom(bytes: []u8) !void {
    if (bytes.len == 0) return;

    if (builtin.os.tag == .windows) {
        return fillWindowsSecureRandom(bytes);
    }

    if (builtin.link_libc and @TypeOf(std.c.arc4random_buf) != void) {
        std.c.arc4random_buf(bytes.ptr, bytes.len);
        return;
    }

    if (builtin.os.tag == .linux) {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const rc = std.os.linux.getrandom(bytes[offset..].ptr, bytes.len - offset, 0);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.EntropyUnavailable;
                    offset += rc;
                },
                .INTR, .AGAIN => continue,
                else => return error.EntropyUnavailable,
            }
        }
        return;
    }

    return error.EntropyUnavailable;
}

fn fillWindowsSecureRandom(bytes: []u8) !void {
    const windows = std.os.windows;

    var cng_device: windows.HANDLE = undefined;
    var io_status_block: windows.IO_STATUS_BLOCK = undefined;
    switch (windows.ntdll.NtOpenFile(
        &cng_device,
        .{
            .STANDARD = .{ .SYNCHRONIZE = true },
            .SPECIFIC = .{ .FILE = .{ .READ_DATA = true } },
        },
        &.{ .ObjectName = @constCast(&windows.UNICODE_STRING.init(
            &.{ '\\', 'D', 'e', 'v', 'i', 'c', 'e', '\\', 'C', 'N', 'G' },
        )) },
        &io_status_block,
        .VALID_FLAGS,
        .{ .IO = .SYNCHRONOUS_NONALERT },
    )) {
        .SUCCESS => {},
        else => return error.EntropyUnavailable,
    }
    defer windows.CloseHandle(cng_device);

    var offset: usize = 0;
    while (offset < bytes.len) {
        const chunk_len: u32 = @intCast(@min(bytes.len - offset, std.math.maxInt(u32)));
        switch (windows.ntdll.NtDeviceIoControlFile(
            cng_device,
            null,
            null,
            null,
            &io_status_block,
            windows.IOCTL.KSEC.GEN_RANDOM,
            null,
            0,
            bytes[offset..].ptr,
            chunk_len,
        )) {
            .SUCCESS => offset += chunk_len,
            else => return error.EntropyUnavailable,
        }
    }
}

/// Base64url encode bytes (no padding)
fn base64urlEncode(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const base64_len = std.base64.standard.Encoder.calcSize(bytes.len);
    // base64url uses same length but without padding
    const result = try allocator.alloc(u8, base64_len);
    errdefer allocator.free(result);

    const encoded = std.base64.url_safe_no_pad.Encoder.encode(result, bytes);
    // The encoder may have written fewer bytes than allocated if no padding
    // We need to trim to actual length
    const actual_len = encoded.len;
    if (actual_len < base64_len) {
        const trimmed = try allocator.alloc(u8, actual_len);
        @memcpy(trimmed, encoded);
        allocator.free(result);
        return trimmed;
    }

    return result;
}

test "PKCE generation" {
    const allocator = std.testing.allocator;

    const pkce = try generatePKCE(allocator);
    defer pkce.deinit(allocator);

    // Verifier should be 43 characters (32 bytes base64url encoded)
    try std.testing.expectEqual(@as(usize, 43), pkce.verifier.len);

    // Challenge should also be 43 characters (32 bytes SHA-256 base64url encoded)
    try std.testing.expectEqual(@as(usize, 43), pkce.challenge.len);

    // Verifier and challenge should be different
    try std.testing.expect(!std.mem.eql(u8, pkce.verifier, pkce.challenge));
}

test "PKCE deterministic challenge" {
    const allocator = std.testing.allocator;

    // Generate two different PKCE pairs
    const pkce1 = try generatePKCE(allocator);
    defer pkce1.deinit(allocator);

    const pkce2 = try generatePKCE(allocator);
    defer pkce2.deinit(allocator);

    // They should be different (random)
    try std.testing.expect(!std.mem.eql(u8, pkce1.verifier, pkce2.verifier));
    try std.testing.expect(!std.mem.eql(u8, pkce1.challenge, pkce2.challenge));
}
