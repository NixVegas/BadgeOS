//! An optional monochrome I2C OLED with runtime dimensions (SSD1306 class).
//!
//! The panel is `height/8` pages of `width` columns. A page is 8 vertically
//! stacked pixels in one byte, with the LSB on top. Pixel (x,y) therefore lives
//! in page y/8, column x, at bit y%8 of the framebuffer, and the buffer streams
//! straight to GDDRAM with no reshuffle once horizontal addressing spans the
//! whole panel.
//!
//! The display is optional hardware and its size is configurable. `Panel.open`
//! takes a width and height and allocates a framebuffer of `width*height/8`
//! bytes from the injected allocator, so there is no hidden allocation and no
//! static framebuffer. Only 32-row and 64-row heights are supported, because
//! those are the two SSD1306 COM-pin layouts.
//!
//! I2C framing: every message starts with a control byte. 0x00 means the bytes
//! that follow are commands, and 0x40 means they are display data. Init and
//! config go out as command frames and the framebuffer flush goes out as one
//! data frame. The 0x40 control byte is therefore kept as the first byte of the
//! buffer, so control and data stream in one write.
//!
//! Screen content is pure Nix. This module only moves bytes to the panel; it
//! draws nothing itself.

const std = @import("std");

pub const i2c_bus = "/dev/i2c-1";
pub const i2c_addr: u16 = 0x3c;

/// Default geometry: the SSD1306 128x32 fitted today.
pub const default_width: u16 = 128;
pub const default_height: u16 = 32;

/// A panel height must be one of the two SSD1306 COM-pin layouts.
pub fn heightSupported(height: u16) bool {
    return height == 32 or height == 64;
}

/// The `linux/i2c-dev.h` subset this module drives. Only the combined-transaction
/// path needs it; a plain command or data frame is an ordinary write.
const I2c = struct {
    const slave: u32 = 0x0703; // I2C_SLAVE
    const rdwr: u32 = 0x0707; // I2C_RDWR
    const m_rd: u16 = 0x0001; // I2C_M_RD

    /// `linux/i2c.h` struct i2c_msg: one segment of a combined transaction.
    const Msg = extern struct {
        addr: u16,
        flags: u16,
        len: u16,
        buf: [*]u8,
    };

    /// `linux/i2c-dev.h` struct i2c_rdwr_ioctl_data.
    const RdwrData = extern struct {
        msgs: [*]Msg,
        nmsgs: u32,
    };
};

/// SSD1306 command bytes from the datasheet. Only the ones init and flush use.
const Cmd = struct {
    const set_contrast = 0x81;
    const display_all_on_resume = 0xa4;
    const normal_display = 0xa6;
    const display_off = 0xae;
    const display_on = 0xaf;
    const set_display_offset = 0xd3;
    const set_com_pins = 0xda;
    const set_vcom_detect = 0xdb;
    const set_display_clock_div = 0xd5;
    const set_precharge = 0xd9;
    const set_multiplex = 0xa8;
    const set_start_line = 0x40;
    const memory_mode = 0x20;
    const column_addr = 0x21;
    const page_addr = 0x22;
    const com_scan_dec = 0xc8;
    const seg_remap = 0xa1;
    const charge_pump = 0x8d;
    /// A no-operation both controllers accept. Used as a presence probe.
    const nop = 0xe3;
};

/// A bus fault. The panel is optional hardware, so every caller either recovers
/// or reports the panel as absent.
pub const Error = error{Io};

/// Which controller drives the panel. This matters because the two common 0.96"
/// and 1.3" module controllers address memory in incompatible ways.
///
///  * ssd1306: 128-column GDDRAM with a horizontal addressing mode (0x20, 0x21,
///    0x22), so one bulk data stream walks the whole window. This is the default.
///  * sh1106: 132-column RAM with the 128 visible columns at offset +2, and no
///    horizontal addressing mode, so it is page mode only (0xB0|page plus the
///    column low and high nibbles) and takes one data stream per page.
///
/// An SSD1306 bulk flush sent to an SH1106 wraps the RAM pointer into the
/// invisible columns and shows as a scrambled or offset image. SH1106 is common
/// on 1.3" 128x64 modules.
pub const Controller = enum { ssd1306, sh1106 };

/// The CLI-facing choice: name a controller, or probe for one at open.
pub const ControllerChoice = enum { auto, ssd1306, sh1106 };

/// The SH1106's 128 visible columns sit at RAM columns 2 through 129.
const sh1106_col_offset: u8 = 2;

/// Write one buffer to the panel as a single I2C transaction.
///
/// This must stay one write. A split write puts a stop condition in the middle of
/// a frame, which the controller reads as the end of the transfer.
/// Goes through the raw write(2), not `std.Io.File.writeStreaming`, for the same
/// reason `ioctl` below does: on a failing i2c transfer the std path reaches
/// `std.c.errno`, whose `@enumFromInt(_errno().*)` panics ("integer overflow")
/// instead of returning an error. A panic is not catchable, so every `catch` on
/// this function was dead code whenever the bus did not answer; the process
/// aborted instead, and `Restart=on-failure` span it forever (bench: 259
/// restarts of nix-badge-oled on a badge with no panel fitted). `std.os.linux.errno`
/// reads the signed syscall return directly and never touches libc's errno.
fn writeOnce(io: std.Io, file: std.Io.File, bytes: []const u8) Error!void {
    _ = io;
    const rc = std.os.linux.write(file.handle, bytes.ptr, bytes.len);
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        else => return error.Io,
    }
    if (rc != bytes.len) return error.Io;
}

/// How many times a command frame is re-sent after the panel does not ACK it,
/// and how long to settle between tries.
///
/// This exists so the bus can run at 1 MHz. At 400 kHz the panel ACKs every
/// frame, but faster the multi-byte power-on sequence NAKs now and then, and a
/// NAK during init is not a small problem: `open` reads it as "nothing answers
/// at 0x3c", reports no display, and the badge runs blind until the next boot
/// (see the no-panel guard). That intermittency is why the bus was pinned
/// to 400 kHz before.
///
/// Re-sending is safe for commands specifically. A NAK means the controller
/// never latched the frame, and every byte the init sequence and the addressing
/// path send is an idempotent register write: set multiplex, set contrast,
/// pick a page, not a step in a state machine, so applying one twice lands on
/// the same state. data frames deliberately do not retry: they follow an
/// addressing command that has already moved the RAM pointer, so a re-send would
/// write at the wrong place.
const cmd_retries: u8 = 4;
const cmd_retry_delay_ns: u64 = 2 * std.time.ns_per_ms;

/// `writeOnce` for command frames, re-sending a frame the panel did not ACK.
/// Costs nothing on the normal path: the retry loop is only entered on error.
fn writeCmdFrame(io: std.Io, file: std.Io.File, bytes: []const u8) Error!void {
    var attempt: u8 = 0;
    while (true) {
        if (writeOnce(io, file, bytes)) |_| {
            if (attempt > 0)
                std.log.debug("oled: command frame ACKed after {d} retr{s}", .{
                    attempt, if (attempt == 1) "y" else "ies",
                });
            return;
        } else |err| {
            attempt += 1;
            if (attempt > cmd_retries) {
                std.log.warn("oled: command frame not ACKed after {d} tries: {t}", .{ attempt, err });
                return err;
            }
            io.sleep(.{ .nanoseconds = cmd_retry_delay_ns }, .awake) catch {};
        }
    }
}

/// Probe which controller answers at the panel address, or null when the bus
/// itself faults.
///
/// The discriminator is that an SH1106 can read display RAM back over I2C (a
/// dummy byte, then the data), and an SSD1306 in serial mode cannot: its read
/// returns constants or garbage, or the transfer is not acknowledged. So write
/// two magic bytes at page 0 / RAM column 2 and read them back through a combined
/// write-then-read transaction. A match means SH1106.
///
/// The probe never corrupts controller state: the page-select (0xB0) and
/// column-nibble (0x00, 0x10) commands are valid on both parts, because the
/// SSD1306 resets into page mode. The caller re-inits and clears right after.
/// `file` must already be bound to the panel address.
/// `error.Io` means nothing answered: the probe writes are commands both parts
/// accept, so if they do not even get an ACK there is no panel on the bus. `null`
/// means a panel is there but the read-back was inconclusive, which is the
/// SSD1306 case the caller falls back on. Keeping those two apart is what lets
/// `Panel.open` report "no display" instead of pretending an absent panel is an
/// SSD1306 and then failing on every subsequent write.
fn detectController(io: std.Io, file: std.Io.File) Error!?Controller {
    const magic = [_]u8{ 0xa5, 0x5a };
    const setcol = [_]u8{ 0x00, 0xb0, 0x02, 0x10 }; // command control, page 0, RAM column 2
    try writeCmdFrame(io, file, &setcol);
    // The magic write is a data frame, and it retries anyway. A NAK here would
    // otherwise propagate as "nothing answers at 0x3c" and cost the display for
    // the whole session, which is far worse than this retry's failure mode: if a
    // NAK ever lands mid-frame the read-back simply mismatches, the probe reports
    // the SSD1306 fallback, and `redetect` can still correct it later.
    try writeCmdFrame(io, file, &[_]u8{ 0x40, magic[0], magic[1] });
    // Point back at column 2 and read: the 0x40 data control byte, then a dummy
    // byte followed by the two data bytes.
    try writeCmdFrame(io, file, &setcol);

    var ctrl = [_]u8{0x40};
    var back: [3]u8 = @splat(0);
    var msgs = [_]I2c.Msg{
        .{ .addr = i2c_addr, .flags = 0, .len = 1, .buf = &ctrl },
        .{ .addr = i2c_addr, .flags = I2c.m_rd, .len = back.len, .buf = &back },
    };
    var xfer: I2c.RdwrData = .{ .msgs = &msgs, .nmsgs = msgs.len };
    ioctl(file.handle, I2c.rdwr, @intFromPtr(&xfer)) catch return null;
    // back[0] is the SH1106 dummy read and the data follows it.
    if (back[1] == magic[0] and back[2] == magic[1]) return .sh1106;
    return .ssd1306;
}

/// An ioctl on an open file. The i2c-dev calls report only success or failure, so
/// the return value carries nothing worth keeping.
fn ioctl(handle: std.Io.File.Handle, request: u32, arg: usize) Error!void {
    return switch (std.os.linux.errno(std.os.linux.ioctl(handle, request, arg))) {
        .SUCCESS => {},
        else => error.Io,
    };
}

/// A runtime-sized panel: an open i2c file plus a framebuffer it owns. There is
/// one instance per panel and it is passed by pointer, so there is no static
/// state. `buf` is `1 + width*pages` bytes: byte 0 is the fixed 0x40 data control
/// byte, and `buf[1..]` is the framebuffer that streams to GDDRAM behind it.
pub const Panel = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    width: u16,
    height: u16,
    controller: Controller,
    /// The 0x40 control byte followed by the framebuffer. Owned, and freed in
    /// `close`.
    buf: []u8,

    pub fn pages(self: *const Panel) u16 {
        return self.height / 8;
    }

    /// The framebuffer in page-major order: a view into `buf` after the control
    /// byte.
    pub fn fb(self: *Panel) []u8 {
        return self.buf[1..];
    }

    fn fbLen(width: u16, height: u16) usize {
        return @as(usize, width) * (height / 8);
    }

    /// Open the i2c bus, bind the panel address, and allocate the framebuffer.
    /// Returns null with a logged reason on any failure. The panel is optional
    /// hardware, so a missing bus, a bad height, and an allocation failure all
    /// mean "no panel" and the caller simply runs without one.
    pub fn open(
        io: std.Io,
        alloc: std.mem.Allocator,
        width: u16,
        height: u16,
        choice: ControllerChoice,
    ) ?Panel {
        if (!heightSupported(height)) {
            std.log.warn("oled: unsupported height {d} (must be 32 or 64)", .{height});
            return null;
        }
        const buf = alloc.alloc(u8, 1 + fbLen(width, height)) catch {
            std.log.warn("oled: cannot allocate a {d}x{d} framebuffer", .{ width, height });
            return null;
        };
        @memset(buf, 0);
        buf[0] = 0x40; // the data control byte, fixed for the panel's whole life

        const file = std.Io.Dir.cwd().openFile(io, i2c_bus, .{ .mode = .read_write }) catch |err| {
            std.log.warn("oled: cannot open {s}: {t}", .{ i2c_bus, err });
            alloc.free(buf);
            return null;
        };
        ioctl(file.handle, I2c.slave, i2c_addr) catch {
            std.log.warn("oled: cannot select i2c addr 0x{x:0>2}", .{i2c_addr});
            file.close(io);
            alloc.free(buf);
            return null;
        };
        const controller: Controller = switch (choice) {
            .ssd1306 => .ssd1306,
            .sh1106 => .sh1106,
            .auto => blk: {
                const det = detectController(io, file) catch {
                    // Nothing ACKed the probe commands, so no panel is fitted.
                    // Report it as "no display" rather than guessing ssd1306 and
                    // then failing on every write for the life of the process.
                    std.log.info("oled: no panel answers at 0x{x:0>2}; running without a display", .{i2c_addr});
                    file.close(io);
                    alloc.free(buf);
                    return null;
                };
                if (det) |c| {
                    std.log.info("oled: controller autodetect found {s}", .{@tagName(c)});
                    break :blk c;
                }
                std.log.warn("oled: controller probe failed; assuming ssd1306", .{});
                break :blk .ssd1306;
            },
        };
        return .{
            .alloc = alloc,
            .io = io,
            .file = file,
            .width = width,
            .height = height,
            .controller = controller,
            .buf = buf,
        };
    }

    /// Probe the controller again, which the flush-recovery path does before it
    /// re-inits.
    ///
    /// A hot-swapped panel always drops the bus mid-transaction first, so the
    /// recovery that follows is exactly the moment the other controller might now
    /// be seated. Only a successful probe updates the choice: a dead bus keeps the
    /// last known controller instead of overwriting it with the fallback default.
    /// Returns true when the controller changed. The caller re-inits and redraws
    /// either way, so this is only for the log.
    pub fn redetect(self: *Panel) bool {
        // A dead bus (error) and an inconclusive read-back (null) both mean "keep
        // the last known controller", which is what this path already wanted.
        const det = (detectController(self.io, self.file) catch return false) orelse return false;
        if (det == self.controller) return false;
        std.log.info("oled: controller changed from {s} to {s} (panel swapped?)", .{
            @tagName(self.controller), @tagName(det),
        });
        self.controller = det;
        return true;
    }

    pub fn close(self: *Panel) void {
        self.file.close(self.io);
        self.alloc.free(self.buf);
    }

    /// Send a run of command bytes as one 0x00-control frame. The SSD1306 accepts
    /// a whole command list after a single control byte.
    fn sendCommands(self: *Panel, cmds: []const u8) Error!void {
        var out: [64]u8 = undefined;
        std.debug.assert(cmds.len + 1 <= out.len);
        out[0] = 0x00;
        @memcpy(out[1 .. 1 + cmds.len], cmds);
        return writeCmdFrame(self.io, self.file, out[0 .. cmds.len + 1]);
    }

    fn sendCommand(self: *Panel, c: u8) Error!void {
        return self.sendCommands(&.{c});
    }

    /// A presence check that changes nothing: one NOP behind the command control
    /// byte. An absent panel does not acknowledge its address and the write fails;
    /// a present one acknowledges and changes no display state.
    ///
    /// This is the memory guard without the clear that `init` performs, so the
    /// caller can compile its screen set while a predecessor, the initrd boot
    /// splash, is still painting, and run the real `init` only after taking over.
    pub fn probe(self: *Panel) Error!void {
        return self.sendCommand(Cmd.nop);
    }

    /// Push the whole framebuffer to GDDRAM. On an SSD1306 this points the column
    /// and page windows at the full panel and then streams `1 + width*pages` bytes
    /// behind the 0x40 control byte already at buf[0]. An SH1106 has no windowed
    /// addressing, so its full flush is one page-mode span per page.
    pub fn flush(self: *Panel) Error!void {
        switch (self.controller) {
            .ssd1306 => {
                try self.sendCommands(&.{
                    Cmd.column_addr, 0, @intCast(self.width - 1),
                    Cmd.page_addr,   0, @intCast(self.pages() - 1),
                });
                try writeOnce(self.io, self.file, self.buf);
            },
            .sh1106 => {
                var page: u16 = 0;
                while (page < self.pages()) : (page += 1)
                    try self.flushPageSpan(page, 0, self.width - 1);
            },
        }
    }

    /// Flush one page's inclusive column span [c0, c1] to GDDRAM.
    ///
    /// A page's bytes `fb[page*width + c0 ..]` are contiguous, so this points the
    /// column and page window at just that span and streams it behind one 0x40
    /// control byte, with no gather step. The delta render path calls this once
    /// per dirty page and pushes only the changed columns, a few dozen bytes,
    /// instead of the whole ~1 KiB panel. That is what lets 60 fps Bad Apple fit
    /// the 400 kHz bus.
    ///
    /// In horizontal addressing a single-page window wraps back to (page, c0)
    /// after c1, but exactly `span` bytes go out, so it fills (page, c0..c1) and
    /// stops.
    pub fn flushPageSpan(self: *Panel, page: u16, c0: u16, c1: u16) Error!void {
        std.debug.assert(page < self.pages());
        std.debug.assert(c0 <= c1 and c1 < self.width);
        switch (self.controller) {
            .ssd1306 => try self.sendCommands(&.{
                Cmd.column_addr, @intCast(c0),   @intCast(c1),
                Cmd.page_addr,   @intCast(page), @intCast(page),
            }),
            // SH1106 page mode: select the page, then the start column through its
            // low and high nibbles, with the +2 RAM offset. The column
            // auto-increments across the data write and there is no end column, so
            // exactly `span` bytes go out and the write stops.
            .sh1106 => {
                const col: u8 = @as(u8, @intCast(c0)) + sh1106_col_offset;
                try self.sendCommands(&.{
                    0xb0 | @as(u8, @intCast(page)),
                    0x00 | (col & 0x0f),
                    0x10 | (col >> 4),
                });
            },
        }
        const span: usize = @as(usize, c1 - c0) + 1;
        // The 0x40 data control byte plus up to a full 128-column SSD1306 row.
        var tmp: [1 + 128]u8 = undefined;
        std.debug.assert(1 + span <= tmp.len);
        tmp[0] = 0x40;
        const start = @as(usize, page) * self.width + c0;
        @memcpy(tmp[1 .. 1 + span], self.fb()[start .. start + span]);
        return writeOnce(self.io, self.file, tmp[0 .. 1 + span]);
    }

    /// The Adafruit power-on sequence, generalised to the runtime height:
    /// multiplex = height-1, COM pins = 0x02 for 32 rows and 0x12 for 64, page
    /// window = pages-1, charge pump on, horizontal addressing, and segment remap
    /// plus reversed COM scan so that (0,0) is top left. The sequence goes out in
    /// chunks of 8 bytes or fewer, because some panels reject one large burst.
    pub fn init(self: *Panel) Error!void {
        std.debug.assert(heightSupported(self.height));
        const mux: u8 = @intCast(self.height - 1);
        const com_pins: u8 = if (self.height == 32) 0x02 else 0x12;
        // The SH1106 has no memory-mode or window commands, and its charge pump is
        // the 0xAD/0x8B pair rather than the SSD1306's 0x8D/0x14. It starts in page
        // mode, which is the only mode flushPageSpan uses for it.
        const seq: []const u8 = if (self.controller == .sh1106) &.{
            Cmd.display_off,
            Cmd.set_display_clock_div,
            0x80,
            Cmd.set_multiplex,
            mux,
            Cmd.set_display_offset,
            0x00,
            Cmd.set_start_line | 0x00,
            0xad,
            0x8b, // DC-DC pump on
            Cmd.seg_remap,
            Cmd.com_scan_dec,
            Cmd.set_com_pins,
            com_pins,
            Cmd.set_contrast,
            0x8f,
            Cmd.set_precharge,
            0x22,
            Cmd.set_vcom_detect,
            0x35,
            Cmd.display_all_on_resume,
            Cmd.normal_display,
            Cmd.display_on,
        } else &.{
            Cmd.display_off,
            Cmd.set_display_clock_div,
            0x80,
            Cmd.set_multiplex,
            mux,
            Cmd.set_display_offset,
            0x00,
            Cmd.set_start_line | 0x00,
            Cmd.charge_pump,
            0x14,
            Cmd.memory_mode,
            0x00,
            Cmd.seg_remap,
            Cmd.com_scan_dec,
            Cmd.set_com_pins,
            com_pins,
            Cmd.set_contrast,
            0x8f,
            Cmd.set_precharge,
            0xf1,
            Cmd.set_vcom_detect,
            0x40,
            Cmd.display_all_on_resume,
            Cmd.normal_display,
            Cmd.display_on,
        };
        var i: usize = 0;
        while (i < seq.len) : (i += 8) {
            try self.sendCommands(seq[i..@min(i + 8, seq.len)]);
        }
    }

    /// Blank the framebuffer, flush it, and turn the panel off, so a stopped
    /// service leaves a dark panel instead of a frozen frame.
    pub fn blankOff(self: *Panel) Error!void {
        self.clear();
        try self.flush();
        try self.sendCommand(Cmd.display_off);
    }

    pub fn clear(self: *Panel) void {
        @memset(self.fb(), 0);
    }

    /// Copy a full page-major frame into the framebuffer. `frame.len` must equal
    /// this panel's framebuffer length. The caller validates a rendered frame's
    /// size against the panel before it plays it.
    pub fn blit(self: *Panel, frame: []const u8) void {
        std.debug.assert(frame.len == self.fb().len);
        @memcpy(self.fb(), frame);
    }
};

// Tests.

// A test panel backed by a fixed stack buffer instead of a real allocator and
// i2c file, so the framebuffer bookkeeping is exercised without a device.
fn testPanel(store: []u8, width: u16, height: u16) Panel {
    @memset(store, 0);
    store[0] = 0x40;
    return .{
        .alloc = std.testing.failing_allocator,
        .io = std.testing.io,
        .file = .{ .handle = -1, .flags = .{ .nonblocking = false } },
        .width = width,
        .height = height,
        .controller = .ssd1306,
        .buf = store,
    };
}

test "fb is the buffer after the control byte and pages is height/8" {
    var store: [1 + 128 * 4]u8 = undefined;
    var p = testPanel(&store, 128, 32);
    try std.testing.expectEqual(@as(u16, 4), p.pages());
    try std.testing.expectEqual(@as(usize, 128 * 4), p.fb().len);
    try std.testing.expectEqual(@as(u8, 0x40), p.buf[0]);
    // Writing through fb() must not disturb the control byte.
    p.fb()[0] = 0xff;
    try std.testing.expectEqual(@as(u8, 0x40), p.buf[0]);
}

test "pages tracks a 64-row panel" {
    var store: [1 + 64 * 8]u8 = undefined;
    var p = testPanel(&store, 64, 64);
    try std.testing.expectEqual(@as(u16, 8), p.pages());
    try std.testing.expectEqual(@as(usize, 64 * 8), p.fb().len);
}

test "blit copies a whole frame and clear zeroes it" {
    var store: [1 + 8 * 4]u8 = undefined;
    var p = testPanel(&store, 8, 32);
    const frame: [8 * 4]u8 = @splat(0xa5);
    p.blit(&frame);
    try std.testing.expectEqualSlices(u8, &frame, p.fb());
    // The control byte survives a blit of the full framebuffer.
    try std.testing.expectEqual(@as(u8, 0x40), p.buf[0]);
    p.clear();
    for (p.fb()) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "heightSupported accepts 32 and 64 only" {
    try std.testing.expect(heightSupported(32));
    try std.testing.expect(heightSupported(64));
    try std.testing.expect(!heightSupported(48));
    try std.testing.expect(!heightSupported(16));
    try std.testing.expect(!heightSupported(0));
}
