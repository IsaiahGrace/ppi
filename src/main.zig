const std = @import("std");

const filePath = "/sys/firmware/acpi/platform_profile";

const libnotify = @cImport(@cInclude("/usr/include/libnotify/notify.h"));

const FD = struct {
    inotify: i32,
    watch: i32,
    epoll: i32,
};

pub fn main() anyerror!void {
    std.log.info("PPI starting...", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    _ = libnotify.notify_init("PPI");
    defer libnotify.notify_uninit();

    const fd = try initInotify();
    defer std.os.close(fd.inotify);

    var inotifyEventBuffer: [1024]u8 = undefined;

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const startTime = std.time.milliTimestamp();
        var initialFileContents = try std.fs.cwd().readFileAlloc(allocator, filePath, 100);
        defer allocator.free(initialFileContents);

        // Wait until the file has changed, and then read from the inotify fd to clear the event.
        // We don't care what happened, because we monitor it here anyway
        try wait(fd.epoll);
        _ = try std.os.read(fd.inotify, &inotifyEventBuffer);

        const wakeTime = std.time.milliTimestamp();
        if (wakeTime - startTime < 1000) {
            const sleep_ms = @intCast(u64, 1000 - (wakeTime - startTime));
            std.log.warn("Throttling PPI notifications, sleeping for {d}ms", .{sleep_ms});
            std.time.sleep(sleep_ms * std.time.ns_per_ms);
        }

        var newFileContents = try std.fs.cwd().readFileAlloc(allocator, filePath, 100);
        defer allocator.free(newFileContents);

        if (std.mem.eql(u8, initialFileContents, newFileContents)) {
            std.log.err("Woke up, but file not changed.", .{});
            continue;
        }

        // replace the trailing newline with a null byte;
        std.mem.replaceScalar(u8, newFileContents, '\n', 0);
        std.log.info("New platform profile: {s}", .{newFileContents});
        sendNotification(newFileContents);
    }
}

fn sendNotification(newProfile: []const u8) void {
    if (newProfile[newProfile.len - 1] != 0) {
        std.log.err("newProfile doesnt end with a null byte! {s}", .{newProfile});
        return;
    }

    const icon = switch (newProfile[0]) {
        'l' => "power-profile-power-saver-symbolic",
        'b' => "power-profile-balanced-symbolic",
        'p' => "power-profile-performance-symbolic",
        else => "",
    };

    const notification = libnotify.notify_notification_new(newProfile.ptr, "", icon);
    defer libnotify.g_object_unref(notification);

    const transient_hint = libnotify.g_variant_new_boolean(1);

    libnotify.notify_notification_set_timeout(notification, 2);
    libnotify.notify_notification_set_hint(notification, "transient", transient_hint);
    _ = libnotify.notify_notification_show(notification, null);
}

fn wait(epoll: i32) !void {
    var events: [1]std.os.linux.epoll_event = undefined;
    const epoll_wait_ret = std.os.epoll_wait(epoll, &events, -1);
    if (epoll_wait_ret == -1) {
        return error.epoll_wait_failed;
    }
}

fn initInotify() !FD {
    var fd: FD = undefined;
    fd.inotify = try std.os.inotify_init1(0);

    fd.watch = try std.os.inotify_add_watch(fd.inotify, filePath, std.os.linux.IN.MODIFY);

    fd.epoll = @intCast(i32, std.os.linux.epoll_create());

    var event: std.os.linux.epoll_event = undefined;
    event.events = std.os.linux.EPOLL.IN;

    const epoll_ctl_ret = std.os.linux.epoll_ctl(fd.epoll, std.os.linux.EPOLL.CTL_ADD, fd.inotify, &event);
    if (epoll_ctl_ret != 0) {
        return error.epoll_ctl_failed;
    }

    return fd;
}
