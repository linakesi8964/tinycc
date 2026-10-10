const std = @import("std");
const Config = @import("config.zig");

pub fn add(b: *std.Build, compiler: *std.Build.Step.Compile, cfg: Config, headers: std.Build.LazyPath) void {
    const windows = cfg.target.os.tag == .windows;
    const arch = cfg.target.cpu.arch;
    const support = b.addWriteFiles();
    _ = support.addCopyDirectory(b.path("include"), "include", .{});
    _ = support.addCopyFile(b.path("tcclib.h"), "include/tcclib.h");
    if (windows) {
        _ = support.addCopyDirectory(b.path("win32/include"), "include", .{});
        _ = support.addCopyDirectory(b.path("win32/lib"), "lib", .{ .include_extensions = &.{".def"} });
    }
    const install_headers = b.addInstallDirectory(.{ .source_dir = support.getDirectory(), .install_dir = .lib, .install_subdir = "tcc" });
    b.getInstallStep().dependOn(&install_headers.step);

    var sources: std.array_list.Managed([]const u8) = .init(b.allocator);
    sources.appendSlice(&.{ "lib/stdatomic.c", "lib/atomic.S", "lib/builtin.c", "lib/alloca.S", "lib/alloca-bt.S", "lib/tcov.c" }) catch @panic("OOM");
    sources.append(if (arch == .aarch64 or arch == .riscv64) "lib/lib-arm64.c" else "lib/libtcc1.c") catch @panic("OOM");
    if (arch == .arm or arch == .thumb) sources.append("lib/armeabi.c") catch @panic("OOM");
    if (arch == .arm or arch == .thumb or ((arch == .aarch64 or arch == .riscv64) and !windows and cfg.target.os.tag != .macos)) sources.append("lib/armflush.c") catch @panic("OOM");
    if (windows) {
        sources.appendSlice(&.{ "win32/lib/crt1.c", "win32/lib/crt1w.c", "win32/lib/wincrt1.c", "win32/lib/wincrt1w.c", "win32/lib/dllcrt1.c", "win32/lib/dllmain.c", "win32/lib/winex.c", "win32/lib/chkstk.S" }) catch @panic("OOM");
    } else {
        if (cfg.target.os.tag != .macos) sources.append("lib/dsohandle.c") catch @panic("OOM");
        if (arch == .x86) sources.append("lib/pic86.S") catch @panic("OOM");
        if (arch == .x86_64) sources.append("lib/va_list.c") catch @panic("OOM");
    }
    const archive = b.addRunArtifact(compiler);
    archive.addArgs(&.{ "-ar", "rcs" });
    const archive_file = archive.addOutputFileArg("libtcc1.a");
    for (sources.items) |source| {
        const stem = std.fs.path.stem(source);
        archive.addFileArg(object(b, compiler, support.getDirectory(), headers, source, b.fmt("{s}.o", .{stem}), &.{}));
    }
    b.getInstallStep().dependOn(&b.addInstallLibFile(archive_file, if (windows) "tcc/lib/libtcc1.a" else "tcc/libtcc1.a").step);
    var extras: std.array_list.Managed([]const u8) = .init(b.allocator);
    extras.append("runmain") catch @panic("OOM");
    if (cfg.backtrace) extras.appendSlice(&.{ "bt-exe", "bt-log" }) catch @panic("OOM");
    if (cfg.backtrace and windows) extras.append("bt-dll") catch @panic("OOM");
    if (cfg.bcheck) extras.appendSlice(&.{ "bcheck", "bcheck_run" }) catch @panic("OOM");
    for (extras.items) |name| {
        const bound = std.mem.startsWith(u8, name, "bcheck");
        const flags: []const []const u8 = if (std.mem.eql(u8, name, "bcheck_run")) &.{ "-bt", "-DBCHECK_RUN" } else if (bound) &.{"-bt"} else &.{};
        const out = object(b, compiler, support.getDirectory(), headers, b.fmt("lib/{s}.c", .{if (bound) "bcheck" else name}), b.fmt("{s}.o", .{name}), flags);
        b.getInstallStep().dependOn(&b.addInstallLibFile(out, b.fmt("tcc/{s}{s}.o", .{ if (windows) "lib/" else "", name })).step);
    }
}

fn object(b: *std.Build, compiler: *std.Build.Step.Compile, support: std.Build.LazyPath, headers: std.Build.LazyPath, source: []const u8, name: []const u8, flags: []const []const u8) std.Build.LazyPath {
    const run = b.addRunArtifact(compiler);
    run.addPrefixedDirectoryArg("-B", support);
    run.addPrefixedDirectoryArg("-I", headers);
    run.addPrefixedDirectoryArg("-I", b.path("."));
    // TinyCC's dependency files make included C/header edits invalidate cached objects.
    run.addArgs(&.{ "-MD", "-MF" });
    _ = run.addDepFileOutputArg(b.fmt("{s}.d", .{name}));
    run.addArgs(flags);
    run.addArg("-c");
    run.addFileArg(b.path(source));
    run.addArg("-o");
    return run.addOutputFileArg(name);
}
