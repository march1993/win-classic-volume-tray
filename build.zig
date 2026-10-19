const std = @import("std");

pub fn build(b: *std.Build) void {
    // This is a Windows-only program; default to a Windows target so `zig build`
    // works from Linux as well.
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .windows,
            .abi = .gnu,
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "win-classic-volume-tray",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .debug,
        }),
    });

    // GUI subsystem: no console window.
    exe.subsystem = .windows;

    exe.root_module.linkSystemLibrary("user32", .{});
    exe.root_module.linkSystemLibrary("shell32", .{});
    exe.root_module.linkSystemLibrary("ole32", .{});
    exe.root_module.linkSystemLibrary("comctl32", .{});

    // Embeds the Common Controls v6 manifest and the tray icon.
    exe.root_module.addWin32ResourceFile(.{
        .file = b.path("app.rc"),
        .include_paths = &.{b.path(".")},
    });

    b.installArtifact(exe);
}
