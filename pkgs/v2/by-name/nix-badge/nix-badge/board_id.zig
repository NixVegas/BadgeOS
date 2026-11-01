//! Board-identity fuse decoder. Reads the SG2000 eFuse USER area (40 B, 320 bits) and
//! DEVICE_ID area (8 B) that provision a badge's PCB store path and serial, and rebuilds the
//! USB descriptor strings from them.
//!
//! This must stay byte-for-byte in step with pkgs/badge/board-id/board_id.py (the reference
//! encoder used to generate the burn) and the sg2000-efuse-map memory.
//! Layout (MSB-first); see that Python for the authoritative table:
//!   epoch 3b | nix32 hash 32x5b | drv name 15x7b(ASCII,NUL-term) |
//!   version 7b | tapeout 17b (YYYYMMDD-20250000) | git 28b (7 nibbles)
//! Omission: a component that is 0 (or an empty name) is dropped from the rebuilt strings,
//! never emitting a stray separator.

const std = @import("std");

pub const NIX32 = "0123456789abcdfghijklmnpqrsvwxyz"; // nix base32 (no e,o,u,t)
pub const USER_BYTES = 40;
pub const NAME_CHARS = 15;
pub const EPOCH: u3 = 1;
pub const TAPEOUT_BASE: u32 = 20250000;

/// Physical byte offsets of the ten 4-byte USER words in the raw 256-byte eFuse
/// image (cvi_efuse_user[] in the vendor cmd/efuse.c). The odd half-words are
/// skipped because each logical word maps to two physical rows.
pub const USER_WORDS = [_]usize{ 0x40, 0x48, 0x50, 0x58, 0x60, 0x68, 0x70, 0x78, 0x80, 0x88 };
pub const DEVICE_ID_OFF = 0x8C;
pub const DEVICE_ID_LEN = 8;
pub const EFUSE_BYTES = 256;

/// MSB-first bit reader over a byte slice (mirrors board_id.py's BitReader).
const BitReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn get(self: *BitReader, n: u6) u32 {
        var val: u32 = 0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const byte = self.data[self.pos >> 3];
            const shift: u3 = @intCast(7 - (self.pos & 7));
            val = (val << 1) | ((byte >> shift) & 1);
            self.pos += 1;
        }
        return val;
    }
};

pub const Record = struct {
    valid: bool = false, // epoch matched EPOCH
    epoch: u3 = 0,
    hash: [32]u8 = [_]u8{0} ** 32, // nix32 chars
    name: [NAME_CHARS]u8 = [_]u8{0} ** NAME_CHARS,
    name_len: usize = 0,
    version: u7 = 0,
    tapeout: u17 = 0,
    git: u28 = 0,
};

/// Reassemble the contiguous 40-byte logical USER blob from the scattered raw
/// eFuse image. Returns false if `raw` is too small.
pub fn gatherUser(raw: []const u8, out: *[USER_BYTES]u8) bool {
    var oi: usize = 0;
    for (USER_WORDS) |off| {
        if (off + 4 > raw.len) return false;
        @memcpy(out[oi .. oi + 4], raw[off .. off + 4]);
        oi += 4;
    }
    return true;
}

pub fn decodeUser(user: []const u8) Record {
    var r = BitReader{ .data = user };
    var rec = Record{};
    const epoch = r.get(3);
    rec.epoch = @intCast(epoch);
    rec.valid = (epoch == EPOCH);
    var i: usize = 0;
    while (i < 32) : (i += 1) rec.hash[i] = NIX32[@as(usize, @intCast(r.get(5)))];
    i = 0;
    while (i < NAME_CHARS) : (i += 1) rec.name[i] = @intCast(r.get(7));
    // NUL-terminated name (a leading NUL means empty).
    var nl: usize = 0;
    while (nl < NAME_CHARS and rec.name[nl] != 0) nl += 1;
    rec.name_len = nl;
    rec.version = @intCast(r.get(7));
    rec.tapeout = @intCast(r.get(17));
    rec.git = @intCast(r.get(28));
    return rec;
}

/// The DEVICE_ID serial, if provisioned: trailing-NUL-trimmed, non-empty, and
/// all printable ASCII. Copies into `buf` and returns the slice, else null.
pub fn extractSerial(raw: []const u8, buf: *[DEVICE_ID_LEN]u8) ?[]const u8 {
    if (raw.len < DEVICE_ID_OFF + DEVICE_ID_LEN) return null;
    const did = raw[DEVICE_ID_OFF .. DEVICE_ID_OFF + DEVICE_ID_LEN];
    var n: usize = DEVICE_ID_LEN;
    while (n > 0 and did[n - 1] == 0) n -= 1;
    if (n == 0) return null;
    for (did[0..n]) |ch| if (ch < 0x20 or ch > 0x7e) return null;
    @memcpy(buf[0..n], did[0..n]);
    return buf[0..n];
}

/// Whether any byte of the identity words is set: the ten USER words or
/// DEVICE_ID. eFuse bits only go 0 -> 1, so this is what decides that the
/// identity can no longer be written (U-Boot's nixbadge_fuse uses the same rule).
/// Null for an image shorter than the 256-byte eFuse: that is a read error.
pub fn identityWritten(raw: []const u8) ?bool {
    if (raw.len < EFUSE_BYTES) return null;
    for (USER_WORDS) |off| {
        for (raw[off .. off + 4]) |b| if (b != 0) return true;
    }
    for (raw[DEVICE_ID_OFF .. DEVICE_ID_OFF + DEVICE_ID_LEN]) |b| if (b != 0) return true;
    return false;
}

pub const DEVICE_EK_OFF = 0xE8;
pub const DEVICE_EK_LEN = 16;
pub const LOCK_OFF = 0xF8;
/// DEVICE_EK's read-lock (bits 15:14) and write-lock (bits 7:6) in the LOCK word.
pub const DEVICE_EK_RLOCK: u32 = 0x3 << 14;
pub const DEVICE_EK_LOCK: u32 = (0x3 << 6) | DEVICE_EK_RLOCK;

pub const DeviceKey = enum { locked, @"set-unlocked", blank };

/// The device key's state, by the rule U-Boot's devek uses: locked only with
/// both read-lock bits; set-unlocked with key bits or any partial lock; else
/// blank. Null for a short image.
pub fn deviceKey(raw: []const u8) ?DeviceKey {
    if (raw.len < EFUSE_BYTES) return null;
    const lock = std.mem.readInt(u32, raw[LOCK_OFF..][0..4], .little);
    if (lock & DEVICE_EK_RLOCK == DEVICE_EK_RLOCK) return .locked;
    if (lock & DEVICE_EK_LOCK != 0) return .@"set-unlocked";
    for (raw[DEVICE_EK_OFF .. DEVICE_EK_OFF + DEVICE_EK_LEN]) |b| if (b != 0) return .@"set-unlocked";
    return .blank;
}

// A minimal bounded string appender, so formatting needs no allocator or writer.
const Cursor = struct {
    buf: []u8,
    len: usize = 0,
    fn str(self: *Cursor, s: []const u8) void {
        const n = @min(s.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len .. self.len + n], s[0..n]);
        self.len += n;
    }
    fn byte(self: *Cursor, b: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = b;
            self.len += 1;
        }
    }
};

fn appendGit(c: *Cursor, git: u28) void {
    var g = git;
    var d: [7]u8 = undefined;
    var k: usize = 7;
    while (k > 0) {
        k -= 1;
        d[k] = "0123456789abcdef"[@intCast(g & 0xf)];
        g >>= 4;
    }
    c.str(&d);
}

/// iProduct: `<name> <maj.min> (<date>, <git>)`, omitting any unset component.
pub fn formatProduct(rec: Record, buf: []u8) []const u8 {
    var c = Cursor{ .buf = buf };
    var wrote = false;
    if (rec.name_len > 0) {
        c.str(rec.name[0..rec.name_len]);
        wrote = true;
    }
    if (rec.version != 0) {
        if (wrote) c.byte(' ');
        var nb: [8]u8 = undefined;
        c.str(std.fmt.bufPrint(&nb, "{d}.{d}", .{ rec.version / 10, rec.version % 10 }) catch "");
        wrote = true;
    }
    const has_date = rec.tapeout != 0;
    const has_git = rec.git != 0;
    if (has_date or has_git) {
        if (wrote) c.byte(' ');
        c.byte('(');
        if (has_date) {
            var db: [8]u8 = undefined;
            c.str(std.fmt.bufPrint(&db, "{d}", .{@as(u32, rec.tapeout) + TAPEOUT_BASE}) catch "");
        }
        if (has_date and has_git) c.str(", ");
        if (has_git) appendGit(&c, rec.git);
        c.byte(')');
    }
    return c.buf[0..c.len];
}

/// The full store path: `/nix/store/<hash>[-name][-ver][-date][-git]`.
pub fn formatStorePath(rec: Record, buf: []u8) []const u8 {
    var c = Cursor{ .buf = buf };
    c.str("/nix/store/");
    c.str(&rec.hash);
    if (rec.name_len > 0) {
        c.byte('-');
        c.str(rec.name[0..rec.name_len]);
    }
    if (rec.version != 0) {
        c.byte('-');
        var nb: [8]u8 = undefined;
        c.str(std.fmt.bufPrint(&nb, "{d}.{d}", .{ rec.version / 10, rec.version % 10 }) catch "");
    }
    if (rec.tapeout != 0) {
        c.byte('-');
        var db: [8]u8 = undefined;
        c.str(std.fmt.bufPrint(&db, "{d}", .{@as(u32, rec.tapeout) + TAPEOUT_BASE}) catch "");
    }
    if (rec.git != 0) {
        c.byte('-');
        appendGit(&c, rec.git);
    }
    return c.buf[0..c.len];
}

// Tests (host-native; verify byte-for-byte agreement with board_id.py output).
const testing = std.testing;

const THIS_USER_HEX = "2d6415b2598a43bff3d18c4fd4d9764ccef49102fbb4f85b8b0e4cf956e2df879642829d207f6efc";
const THIS_PATH = "/nix/store/dchav4nca8fzz7lcc9zadjxjcrvs920p-nix-badge-board-2.0-20260706-07f6efc";
const THIS_PRODUCT = "nix-badge-board 2.0 (20260706, 07f6efc)";

test "decode this badge's USER matches board_id.py" {
    var user: [USER_BYTES]u8 = undefined;
    _ = try std.fmt.hexToBytes(&user, THIS_USER_HEX);
    const rec = decodeUser(&user);
    try testing.expect(rec.valid);
    try testing.expectEqual(@as(u7, 20), rec.version);
    try testing.expectEqual(@as(u17, 10706), rec.tapeout);
    try testing.expectEqual(@as(u28, 0x07f6efc), rec.git);
    try testing.expectEqualStrings("nix-badge-board", rec.name[0..rec.name_len]);
    try testing.expectEqualStrings("dchav4nca8fzz7lcc9zadjxjcrvs920p", &rec.hash);

    var pbuf: [128]u8 = undefined;
    try testing.expectEqualStrings(THIS_PRODUCT, formatProduct(rec, &pbuf));
    var sbuf: [128]u8 = undefined;
    try testing.expectEqualStrings(THIS_PATH, formatStorePath(rec, &sbuf));
}

test "gather scattered USER + DEVICE_ID serial from a full eFuse image" {
    var user: [USER_BYTES]u8 = undefined;
    _ = try std.fmt.hexToBytes(&user, THIS_USER_HEX);
    // Scatter the 40 logical bytes into a 256-byte image at the word offsets.
    var raw = [_]u8{0} ** EFUSE_BYTES;
    var oi: usize = 0;
    for (USER_WORDS) |off| {
        @memcpy(raw[off .. off + 4], user[oi .. oi + 4]);
        oi += 4;
    }
    @memcpy(raw[DEVICE_ID_OFF .. DEVICE_ID_OFF + 8], "SG1-0001");

    var gathered: [USER_BYTES]u8 = undefined;
    try testing.expect(gatherUser(&raw, &gathered));
    try testing.expectEqualSlices(u8, &user, &gathered);

    const rec = decodeUser(&gathered);
    var pbuf: [128]u8 = undefined;
    try testing.expectEqualStrings(THIS_PRODUCT, formatProduct(rec, &pbuf));

    var sbuf: [DEVICE_ID_LEN]u8 = undefined;
    try testing.expectEqualStrings("SG1-0001", extractSerial(&raw, &sbuf).?);
}

test "unprovisioned (all-zero) fuses are invalid / no serial" {
    const raw = [_]u8{0} ** EFUSE_BYTES;
    var gathered: [USER_BYTES]u8 = undefined;
    _ = gatherUser(&raw, &gathered);
    try testing.expect(!decodeUser(&gathered).valid);
    var sbuf: [DEVICE_ID_LEN]u8 = undefined;
    try testing.expect(extractSerial(&raw, &sbuf) == null);
}

test "omission rule matches board_id.py" {
    // Derive the fully-populated base record, then drop components.
    var user: [USER_BYTES]u8 = undefined;
    _ = try std.fmt.hexToBytes(&user, THIS_USER_HEX);
    const base = decodeUser(&user);
    var b: [128]u8 = undefined;

    var r = base;
    r.git = 0;
    try testing.expectEqualStrings("nix-badge-board 2.0 (20260706)", formatProduct(r, &b));

    r = base;
    r.tapeout = 0;
    r.git = 0;
    try testing.expectEqualStrings("nix-badge-board 2.0", formatProduct(r, &b));

    r = base;
    r.name = [_]u8{0} ** NAME_CHARS;
    r.name_len = 0;
    try testing.expectEqualStrings("2.0 (20260706, 07f6efc)", formatProduct(r, &b));

    r = base;
    r.version = 0;
    try testing.expectEqualStrings("nix-badge-board (20260706, 07f6efc)", formatProduct(r, &b));
}

test "identityWritten: blank, gap words, USER only, DEVICE_ID only" {
    var raw = [_]u8{0} ** EFUSE_BYTES;
    try testing.expect(!identityWritten(&raw).?);
    // factory words below USER, the stride-8 gaps and the secure region do not count
    raw[0x0C] = 0xff;
    raw[0x44] = 0xff;
    raw[0x94] = 0xff;
    raw[0xA8] = 0xff;
    try testing.expect(!identityWritten(&raw).?);
    raw[0x88 + 3] = 1;
    try testing.expect(identityWritten(&raw).?);
    raw[0x88 + 3] = 0;
    raw[0x90 + 3] = 1;
    try testing.expect(identityWritten(&raw).?);
    // a short read is an error, not "not written"
    try testing.expect(identityWritten(raw[0..0x90]) == null);
}

test "deviceKey: blank, set, partial locks, locked, short read" {
    var raw = [_]u8{0} ** EFUSE_BYTES;
    try testing.expectEqual(DeviceKey.blank, deviceKey(&raw).?);
    raw[0xF0] = 1;
    try testing.expectEqual(DeviceKey.@"set-unlocked", deviceKey(&raw).?);
    raw[0xF0] = 0;
    // write-lock only, or one read-lock bit: not locked
    std.mem.writeInt(u32, raw[LOCK_OFF..][0..4], 0x3 << 6, .little);
    try testing.expectEqual(DeviceKey.@"set-unlocked", deviceKey(&raw).?);
    std.mem.writeInt(u32, raw[LOCK_OFF..][0..4], 0x1 << 14, .little);
    try testing.expectEqual(DeviceKey.@"set-unlocked", deviceKey(&raw).?);
    // both read-lock bits: locked, whatever DEVICE_EK reads (zeros once locked)
    std.mem.writeInt(u32, raw[LOCK_OFF..][0..4], 0x3 << 14, .little);
    try testing.expectEqual(DeviceKey.locked, deviceKey(&raw).?);
    // other areas' lock bits do not count
    std.mem.writeInt(u32, raw[LOCK_OFF..][0..4], 0x3033, .little);
    try testing.expectEqual(DeviceKey.blank, deviceKey(&raw).?);
    try testing.expect(deviceKey(raw[0..0xF8]) == null);
}
