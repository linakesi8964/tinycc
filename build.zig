const std = @import("std");
const Config = @import("build/config.zig");
const Runtime = @import("build/runtime.zig");
const Tests = @import("build/tests.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shared = b.option(bool, "shared", "Build a shared libtcc instead of a static archive") orelse false;
    const runtime = b.option(bool, "runtime", "Build and install the TinyCC runtime") orelse true;
    const cfg = Config.init(b, target);

    const converter = b.addExecutable(.{
        .name = "c2str",
        .root_module = b.createModule(.{ .target = b.graph.host, .optimize = .ReleaseFast, .link_libc = true }),
    });
    converter.root_module.addCSourceFile(.{ .file = b.path("build/c2str.c") });
    const convert = b.addRunArtifact(converter);
    convert.addFileArg(b.path("include/tccdefs.h"));
    const predefs = convert.addOutputFileArg("tccdefs_.h");
    const headers = b.addWriteFiles();
    _ = headers.add("config.h", cfg.header);
    _ = headers.addCopyFile(predefs, "tccdefs_.h");

    const library = b.addLibrary(.{
        .name = "tcc",
        .linkage = if (shared) .dynamic else .static,
        .root_module = coreModule(b, target, optimize, headers.getDirectory(), "libtcc.c"),
    });
    if (shared and target.result.os.tag == .windows)
        library.root_module.addCMacro("LIBTCC_AS_DLL", "1");
    const compiler = b.addExecutable(.{
        .name = "tcc",
        .root_module = coreModule(b, target, optimize, headers.getDirectory(), "tcc.c"),
    });
    compiler.root_module.addCMacro("ONE_SOURCE", "0");
    compiler.root_module.linkLibrary(library);
    if (shared) compiler.root_module.addRPathSpecial(if (target.result.os.tag == .macos) "@executable_path/../lib" else "$ORIGIN/../lib");
    b.installArtifact(compiler);
    b.installArtifact(library);
    b.installFile("libtcc.h", "include/libtcc.h");

    // A host executable builds the runtime even when the installed compiler is foreign.
    const native = target.result.cpu.arch == b.graph.host.result.cpu.arch and target.result.os.tag == b.graph.host.result.os.tag;
    const bootstrap = if (native) compiler else b.addExecutable(.{
        .name = "tcc-bootstrap",
        .root_module = coreModule(b, b.graph.host, .ReleaseFast, headers.getDirectory(), "tcc.c"),
    });
    if (shared and target.result.os.tag == .windows and cfg.target.os.tag == .windows) {
        const impdef = b.addRunArtifact(bootstrap);
        impdef.addArg("-impdef");
        impdef.addFileArg(library.getEmittedBin());
        impdef.addArg("-o");
        const definition = impdef.addOutputFileArg("tcc.def");
        b.getInstallStep().dependOn(&b.addInstallLibFile(definition, "tcc.def").step);
    }
    if (runtime) Runtime.add(b, bootstrap, cfg, headers.getDirectory());
    const run = b.addRunArtifact(compiler);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the built compiler (arguments after --)").dependOn(&run.step);
    Tests.add(b, compiler, library, cfg, headers.getDirectory(), target, runtime);
    const doc_config = b.addWriteFiles();
    const texi = doc_config.add("config.texi", b.fmt("@set VERSION {s}\n", .{std.mem.trim(u8, @embedFile("VERSION"), "\r\n ")}));
    b.getInstallStep().dependOn(&b.addInstallFile(texi, "share/doc/tcc/config.texi").step);
    b.installFile("tcc-doc.texi", "share/doc/tcc/tcc-doc.texi");
    b.installFile("COPYING", "share/doc/tcc/COPYING");
}

pub fn coreModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, headers: std.Build.LazyPath, source: []const u8) *std.Build.Module {
    // Match the original C build: Debug keeps symbols, without implicit UBSan.
    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .pic = true, .sanitize_c = .off });
    module.addIncludePath(headers);
    module.addIncludePath(b.path("."));
    module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=gnu99", "-fno-strict-aliasing", "-fno-omit-frame-pointer", "-Wno-unused-result", "-Wno-deprecated-declarations" } });
    if (target.result.os.tag != .windows) {
        module.linkSystemLibrary("m", .{});
        module.linkSystemLibrary("pthread", .{});
        if (target.result.os.tag == .linux) module.linkSystemLibrary("dl", .{});
    }
    return module;
}
