const std = @import("std");
const Config = @import("config.zig");
const coreModule = @import("../build.zig").coreModule;

pub fn add(b: *std.Build, compiler: *std.Build.Step.Compile, library: *std.Build.Step.Compile, cfg: Config, headers: std.Build.LazyPath, target: std.Build.ResolvedTarget, runtime: bool) void {
    const filter = b.option([]const u8, "test-filter", "Run tests whose name contains this string") orelse "";
    const runner = b.addExecutable(.{ .name = "test-runner", .root_module = b.createModule(.{ .root_source_file = b.path("build/test_runner.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }) });
    for ([_][]const u8{ "test", "tests2", "test-pp" }) |suite| {
        const step = b.step(suite, if (std.mem.eql(u8, suite, "test")) "Run regression, preprocessor, API and bootstrap tests" else if (std.mem.eql(u8, suite, "tests2")) "Run the tests2 regression suite" else "Run preprocessor tests");
        const native = cfg.target.cpu.arch == b.graph.host.result.cpu.arch and cfg.target.os.tag == b.graph.host.result.os.tag and target.result.cpu.arch == b.graph.host.result.cpu.arch and target.result.os.tag == b.graph.host.result.os.tag;
        if (!runtime or !native) {
            const fail = b.addFail("Tests require -Druntime=true and a native compiler/code-generation target");
            step.dependOn(&fail.step);
            continue;
        }
        const run = b.addRunArtifact(runner);
        run.step.dependOn(b.getInstallStep());
        run.addArg(suite);
        run.addArtifactArg(compiler);
        run.addDirectoryArg(b.path("."));
        run.addDirectoryArg(headers);
        run.addArg(b.getInstallPath(.lib, "tcc"));
        run.addArgs(&.{ @tagName(cfg.target.cpu.arch), @tagName(cfg.target.os.tag), if (cfg.backtrace) "1" else "0", if (cfg.bcheck) "1" else "0", filter, b.graph.zig_exe });
        const temp = b.addTempFiles();
        run.setCwd(temp.getDirectory());
        run.has_side_effects = true;
        run.addPathDir(b.getInstallPath(.bin, ""));
        if (std.mem.eql(u8, suite, "test")) {
            for ([_][]const u8{ "libtcc_test", "libtcc_test_mt", "tcctest", "abitest" }) |name| {
                const exe = b.addExecutable(.{ .name = name, .root_module = coreModule(b, target, .Debug, headers, b.fmt("tests/{s}.c", .{name})) });
                if (!std.mem.eql(u8, name, "tcctest")) {
                    exe.root_module.linkLibrary(library);
                    exe.root_module.addRPath(.{ .cwd_relative = b.getInstallPath(.lib, "") });
                }
                run.addArtifactArg(exe);
            }
            const memory = b.addExecutable(.{ .name = "memtest-tcc", .root_module = coreModule(b, target, .Debug, headers, "tcc.c") });
            memory.root_module.addCMacro("MEM_DEBUG", "2");
            run.addArtifactArg(memory);
        }
        step.dependOn(&run.step);
    }
}
