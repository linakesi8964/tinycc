//! Portable regression runner: no shell, make, sed, diff or Python required.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Args = std.array_list.Managed([]const u8);

const Runner = struct {
    gpa: Allocator,
    io: std.Io,
    compiler: []const u8,
    root: []const u8,
    headers: []const u8,
    support: []const u8,
    arch: []const u8,
    os: []const u8,
    backtrace: bool,
    bcheck: bool,
    filter: []const u8,
    zig: []const u8,
    passed: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,

    fn fmt(r: *Runner, comptime format: []const u8, values: anytype) []const u8 {
        return std.fmt.allocPrint(r.gpa, format, values) catch @panic("OOM");
    }
    fn is(r: *Runner, os: []const u8) bool {
        return std.mem.eql(u8, r.os, os);
    }
    fn cpu(r: *Runner, arch: []const u8) bool {
        return std.mem.eql(u8, r.arch, arch);
    }
    fn path(r: *Runner, relative: []const u8) []const u8 {
        return std.fs.path.join(r.gpa, &.{ r.root, relative }) catch @panic("OOM");
    }
    fn read(r: *Runner, file: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(r.io, file, r.gpa, .limited(16 * 1024 * 1024));
    }
    fn flags(r: *Runner) []const []const u8 {
        return r.gpa.dupe([]const u8, &.{ r.fmt("-B{s}", .{r.support}), r.fmt("-I{s}", .{r.root}), r.fmt("-I{s}", .{r.headers}) }) catch @panic("OOM");
    }
    fn command(r: *Runner, extra: []const []const u8) Args {
        var args = Args.init(r.gpa);
        args.append(r.compiler) catch @panic("OOM");
        args.appendSlice(r.flags()) catch @panic("OOM");
        args.appendSlice(extra) catch @panic("OOM");
        return args;
    }
    const Output = struct { text: []const u8, term: std.process.Child.Term };
    fn exec(r: *Runner, args: []const []const u8) !Output {
        // One shared file preserves the ordering of stdout and stderr for -dt tests.
        const output = try std.Io.Dir.cwd().createFile(r.io, "command.output", .{});
        defer output.close(r.io);
        var child = try std.process.spawn(r.io, .{ .argv = args, .stdin = .ignore, .stdout = .{ .file = output }, .stderr = .{ .file = output } });
        const term = try child.wait(r.io);
        return .{ .text = try r.read("command.output"), .term = term };
    }
    fn checked(r: *Runner, args: []const []const u8) ![]const u8 {
        const out = try r.exec(args);
        if (out.term != .exited or out.term.exited != 0) {
            std.debug.print("Command failed: {s}\n{s}\n", .{ try std.mem.join(r.gpa, " ", args), out.text });
            return error.CommandFailed;
        }
        return out.text;
    }
    fn tcc(r: *Runner, args: []const []const u8) ![]const u8 {
        return r.checked(r.command(args).items);
    }
    fn selected(r: *Runner, name: []const u8) bool {
        return r.filter.len == 0 or std.mem.indexOf(u8, name, r.filter) != null;
    }
    fn report(r: *Runner, name: []const u8, ok: bool) void {
        if (ok) {
            r.passed += 1;
        } else {
            r.failed += 1;
            std.debug.print("FAIL {s}\n", .{name});
        }
    }
    fn compare(r: *Runner, name: []const u8, expected: []const u8, actual: []const u8, whitespace: bool, blank: bool, addresses: bool) void {
        const e = r.normalize(expected, whitespace, blank, addresses);
        const a = r.normalize(actual, whitespace, blank, addresses);
        const ok = std.mem.eql(u8, e, a);
        r.report(name, ok);
        if (!ok) std.debug.print("--- expected ({s}) ---\n{s}\n--- actual ---\n{s}\n", .{ name, expected, actual });
    }
    fn normalize(r: *Runner, input: []const u8, all_space: bool, blank: bool, addresses: bool) []const u8 {
        var out = std.array_list.Managed(u8).init(r.gpa);
        var lines = std.mem.splitScalar(u8, if (std.mem.endsWith(u8, input, "\n")) input[0 .. input.len - 1] else input, '\n');
        while (lines.next()) |raw| {
            var line = std.mem.trimEnd(u8, raw, " \t\r");
            if (blank and std.mem.trim(u8, line, " \t").len == 0) continue;
            var pending_space = false;
            while (line.len > 0) {
                // Strip absolute source directories from compiler diagnostics.
                const dirs = [_][]const u8{ r.path("tests/tests2/"), r.path("tests/pp/") };
                var stripped = false;
                for (dirs) |dir| {
                    if (std.mem.startsWith(u8, line, dir)) {
                        line = line[dir.len..];
                        stripped = true;
                        break;
                    }
                }
                if (stripped) continue;
                const c = line[0];
                if (c == ' ' or c == '\t' or c == '\r') {
                    pending_space = !all_space;
                    line = line[1..];
                    continue;
                }
                if (pending_space) {
                    out.append(' ') catch @panic("OOM");
                    pending_space = false;
                }
                if (addresses and (std.ascii.isHex(c) or c == 'x')) {
                    var n: usize = 0;
                    while (n < line.len and (std.ascii.isHex(line[n]) or line[n] == 'x')) : (n += 1) {}
                    if (n >= 5) {
                        out.appendSlice("........") catch @panic("OOM");
                        line = line[n..];
                        continue;
                    }
                    if (n > 2 and std.mem.startsWith(u8, line, "0x")) {
                        out.appendSlice("0x?") catch @panic("OOM");
                        line = line[n..];
                        continue;
                    }
                }
                out.append(c) catch @panic("OOM");
                line = line[1..];
            }
            out.append('\n') catch @panic("OOM");
        }
        return out.toOwnedSlice() catch @panic("OOM");
    }
    fn skip(r: *Runner, id: u16) bool {
        if (id == 34) return true; // Non-standard array assignment, as in the original suite.
        if ((id == 98 or id == 99) and !r.cpu("x86")) return true;
        if ((id == 85 or id == 127) and !r.cpu("x86") and !r.cpu("x86_64")) return true;
        if (id == 113 and !r.backtrace) return true;
        if (!r.bcheck) switch (id) {
            112, 114, 115, 116, 117, 126, 132 => return true,
            else => {},
        };
        if (id == 95 and !r.is("windows") and (r.cpu("x86") or r.cpu("arm") or r.cpu("thumb"))) return true;
        if (r.is("windows")) switch (id) {
            106, 114, 117, 148 => return true,
            else => {},
        };
        if (r.is("macos")) switch (id) {
            144, 146, 148 => return true,
            else => {},
        };
        if (r.is("freebsd") or r.is("openbsd") or r.is("netbsd")) switch (id) {
            106, 114, 116, 144, 146 => return true,
            else => {},
        };
        if ((r.cpu("arm") or r.cpu("thumb")) and (id == 144 or id == 146)) return true;
        if (id >= 138 and id <= 140 and !r.cpu("aarch64")) return true;
        if (id == 141 and !r.cpu("riscv64")) return true;
        if (id == 145 and !(r.cpu("aarch64") and r.is("windows"))) return true;
        return false;
    }
    fn suite(r: *Runner, pp: bool) !void {
        const dir_path = r.path(if (pp) "tests/pp" else "tests/tests2");
        var dir = try std.Io.Dir.cwd().openDir(r.io, dir_path, .{ .iterate = true });
        defer dir.close(r.io);
        var files = Args.init(r.gpa);
        var it = dir.iterate();
        while (try it.next(r.io)) |entry| {
            if (entry.kind != .file or !(std.mem.endsWith(u8, entry.name, ".c") or (pp and std.mem.endsWith(u8, entry.name, ".S")))) continue;
            const stem = std.fs.path.stem(entry.name);
            if (!r.selected(stem)) continue;
            const end = std.mem.indexOfScalar(u8, stem, '_') orelse stem.len;
            _ = std.fmt.parseInt(u16, stem[0..end], 10) catch continue;
            try files.append(try r.gpa.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, files.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        for (files.items) |name| {
            const stem = std.fs.path.stem(name);
            const id = try std.fmt.parseInt(u16, stem[0 .. std.mem.indexOfScalar(u8, stem, '_') orelse stem.len], 10);
            if (!pp and r.skip(id)) {
                r.skipped += 1;
                continue;
            }
            const source = try std.fs.path.join(r.gpa, &.{ dir_path, name });
            const expected = try r.read(r.fmt("{s}/{s}.expect", .{ dir_path, stem }));
            const result = if (pp) try r.exec(r.command(&.{ "-E", "-P", source }).items) else r.regression(id, source) catch {
                r.report(stem, false);
                continue;
            };
            if (result.term != .exited) {
                r.report(stem, false);
                std.debug.print("Abnormal termination: {any}\n{s}\n", .{ result.term, result.text });
                continue;
            }
            r.compare(stem, expected, result.text, pp and id == 2, pp and id == 16, !pp and (id == 112 or id == 113 or id == 126));
        }
    }
    fn regression(r: *Runner, id: u16, source: []const u8) !Output {
        var args = r.command(&.{});
        var run_args = Args.init(r.gpa);
        switch (id) {
            31 => try run_args.appendSlice(&.{ "arg1", "arg2", "arg3", "arg4", "arg5" }),
            46 => try run_args.appendSlice(&.{ "[^* ]*[:a:d: ]+\\:\\*-/: $", source }),
            76 => try args.append("-fdollars-in-identifiers"),
            22, 24 => if (!r.is("windows")) {
                try args.append("-lm");
            },
            60, 96, 125, 128, 139 => try args.append("-dt"),
            104, 120 => {
                const basename = std.fs.path.basename(source);
                try args.append(r.path(r.fmt("tests/tests2/{s}+{s}", .{ basename[0..3], basename[3..] })));
            },
            106, 124, 144 => try args.append("-pthread"),
            112 => try args.appendSlice(&.{ "-dt", "-b" }),
            114, 115, 116, 126, 132 => try args.append("-b"),
            121, 122 => if (r.bcheck) {
                try args.append("-b");
            },
            113 => return r.dllRegression(source),
            117 => {
                const a = try r.tcc(&.{ "-run", source });
                const b = try r.tcc(&.{ "-b", "-run", source });
                return .{ .text = r.fmt("{s}{s}", .{ a, b }), .term = .{ .exited = 0 } };
            },
            146 => {
                _ = try r.tcc(&.{ "-c", source, "-o", "tls-main.o" });
                _ = try r.tcc(&.{ "-c", source, "-DDEFS", "-o", "tls-defs.o" });
                _ = try r.checked(&.{ r.zig, "cc", "-no-pie", "-Wl,-z,noexecstack", "tls-main.o", "tls-defs.o", "-o", "tls.exe" });
                return r.exec(&.{"./tls.exe"});
            },
            148 => return r.linkerRegression(source),
            else => {},
        }
        const executable = switch (id) {
            42, 106, 108, 114, 120, 126, 144 => true,
            else => false,
        };
        if (executable) {
            try args.appendSlice(&.{ source, "-o", "regression.exe" });
            _ = try r.checked(args.items);
            args = Args.init(r.gpa);
            try args.append("./regression.exe");
        } else try args.appendSlice(&.{ "-run", source });
        try args.appendSlice(run_args.items);
        return r.exec(args.items);
    }
    fn dllRegression(r: *Runner, source: []const u8) !Output {
        const suffix = if (r.is("windows")) ".dll" else if (r.is("macos")) ".dylib" else ".so";
        const a = r.fmt("a1{s}", .{suffix});
        const b = r.fmt("a2{s}", .{suffix});
        _ = try r.tcc(&.{ "-bt", source, "-shared", "-DDLL=1", "-o", a });
        _ = try r.tcc(&.{ "-bt", source, "-shared", "-DDLL=2", "-o", b });
        _ = try r.tcc(&.{ "-bt", source, a, b, "-Wl,-rpath=.", "-o", "btdll.exe" });
        return r.exec(&.{"./btdll.exe"});
    }
    fn linkerRegression(r: *Runner, source: []const u8) !Output {
        var result = std.array_list.Managed(u8).init(r.gpa);
        for (1..7) |i| {
            try result.appendSlice(r.fmt("\n--- TEST {d} ---\n", .{i}));
            _ = try r.tcc(&.{ source, r.fmt("-DTEST={d}", .{i + 100}), "-c", "-fcommon", "-o", "linker.o" });
            _ = try r.tcc(&.{ source, r.fmt("-DTEST={d}", .{i + 200}), "-shared", "-fPIC", "-o", "linker.so" });
            _ = try r.tcc(&.{ source, r.fmt("-DTEST={d}", .{i}), "-Wl,-rpath=.", "-no-pie", "linker.o", "linker.so", "-o", "linker.exe" });
            try result.appendSlice(try r.checked(&.{"./linker.exe"}));
        }
        return .{ .text = try result.toOwnedSlice(), .term = .{ .exited = 0 } };
    }
    fn systemLibs(r: *Runner) []const []const u8 {
        return if (r.is("windows")) &.{} else if (r.is("linux")) &.{ "-lm", "-ldl", "-lpthread" } else &.{ "-lm", "-lpthread" };
    }
    fn integration(r: *Runner, artifacts: []const []const u8) !void {
        if (r.selected("hello")) {
            const source = r.path("examples/ex1.c");
            const memory = try r.tcc(&.{ "-run", source });
            _ = try r.tcc(&.{ source, "-o", "hello.exe" });
            const exe = try r.checked(&.{"./hello.exe"});
            r.compare("hello-exe/run", memory, exe, false, false, false);
        }
        for (artifacts[0..2], [_][]const u8{ "libtcc_test", "libtcc_test_mt" }) |artifact, name| {
            if (!r.selected(name) or (!r.backtrace and std.mem.endsWith(u8, name, "_mt"))) continue;
            var args = Args.init(r.gpa);
            try args.append(artifact);
            try args.append(r.path("tcc.c"));
            try args.appendSlice(r.flags());
            _ = r.checked(args.items) catch {
                r.report(name, false);
                continue;
            };
            r.report(name, true);
        }
        if (r.selected("bootstrap")) {
            const reference = try r.checked(&.{artifacts[2]});
            var args = r.command(&.{});
            for (0..3) |_| {
                try args.appendSlice(&.{ "-run", r.path("tcc.c") });
                try args.appendSlice(r.flags());
            }
            try args.appendSlice(&.{ "-w", "-run", r.path("tests/tcctest.c") });
            const output = try r.checked(args.items);
            r.compare("bootstrap (three generations)", reference, output, false, false, false);
        }
        if (r.selected("abi")) {
            var args = Args.init(r.gpa);
            try args.append(artifacts[3]);
            try args.appendSlice(r.flags());
            _ = try r.checked(args.items);
            var compile = r.command(&.{ r.path("tests/abitest.c"), r.path("libtcc.c"), "-o", "abi.exe" });
            try compile.appendSlice(r.systemLibs());
            _ = try r.checked(compile.items);
            args = Args.init(r.gpa);
            try args.append("./abi.exe");
            try args.appendSlice(r.flags());
            _ = try r.checked(args.items);
            r.report("abi (Zig C and TinyCC)", true);
        }
        if (r.selected("vla")) {
            _ = try r.tcc(&.{ r.path("tests/vla_test.c"), "-o", "vla.exe" });
            _ = try r.checked(&.{"./vla.exe"});
            r.report("vla", true);
        }
        if (r.selected("dll")) {
            const lib = if (r.is("windows")) "libtcc2.dll" else if (r.is("macos")) "libtcc2.dylib" else "libtcc2.so";
            var compile = r.command(&.{ "-DLIBTCC_AS_DLL", r.path("libtcc.c"), "-shared", "-o", lib });
            try compile.appendSlice(r.systemLibs());
            _ = try r.checked(compile.items);
            compile = r.command(&.{ "-DONE_SOURCE=0", r.path("tcc.c"), lib, "-Wl,-rpath=.", "-o", "tcc2.exe" });
            try compile.appendSlice(r.systemLibs());
            _ = try r.checked(compile.items);
            var args = Args.init(r.gpa);
            try args.append("./tcc2.exe");
            try args.appendSlice(r.flags());
            try args.appendSlice(&.{ "-run", r.path("tcc.c") });
            try args.appendSlice(r.flags());
            try args.appendSlice(&.{ "-run", r.path("examples/ex1.c") });
            _ = try r.checked(args.items);
            r.report("dll bootstrap", true);
        }
        if ((r.cpu("x86") or r.cpu("x86_64")) and r.selected("asm-c-connect")) {
            const a = r.path("tests/asm-c-connect-1.c");
            const b = r.path("tests/asm-c-connect-2.c");
            _ = try r.tcc(&.{ a, b, "-o", "asm.exe" });
            const expected = try r.checked(&.{"./asm.exe"});
            _ = try r.tcc(&.{ "-c", a, "-o", "asm1.o" });
            _ = try r.tcc(&.{ "-c", b, "-o", "asm2.o" });
            _ = try r.tcc(&.{ "asm1.o", "asm2.o", "-o", "asm-separate.exe" });
            r.compare("asm-c-connect", expected, try r.checked(&.{"./asm-separate.exe"}), false, false, false);
        }
        if (r.selected("memory")) {
            var args = Args.init(r.gpa);
            try args.append(artifacts[4]);
            try args.appendSlice(r.flags());
            try args.appendSlice(&.{ r.path("tcc.c"), "-o", "mem-tcc.exe" });
            try args.appendSlice(r.systemLibs());
            _ = try r.checked(args.items);
            args = Args.init(r.gpa);
            try args.append(artifacts[4]);
            try args.appendSlice(r.flags());
            try args.appendSlice(&.{ "-run", r.path("tcc.c") });
            try args.appendSlice(r.flags());
            try args.appendSlice(&.{ "-w", r.path("tests/tcctest.c"), "-o", "mem-test.exe" });
            _ = try r.checked(args.items);
            r.report("memory", true);
        }
        if (r.bcheck and r.selected("bound-bootstrap")) {
            const reference = try r.checked(&.{artifacts[2]});
            var args = r.command(&.{ "-b", "-bt1", "-run", r.path("tcc.c") });
            try args.appendSlice(r.flags());
            try args.appendSlice(&.{ "-b", "-bt1", "-w", "-run", r.path("tests/tcctest.c") });
            r.compare("bound-bootstrap", reference, try r.checked(args.items), false, false, false);
            args = r.command(&.{ "-b", r.path("tcc.c"), "-o", "tccb1.exe" });
            try args.appendSlice(r.systemLibs());
            _ = try r.checked(args.items);
            try std.Io.Dir.cwd().rename("tccb1.exe", std.Io.Dir.cwd(), "tccb2.exe", r.io);
            args = Args.init(r.gpa);
            try args.append("./tccb2.exe");
            try args.appendSlice(r.flags());
            try args.appendSlice(&.{ "-b", r.path("tcc.c"), "-o", "tccb1.exe" });
            try args.appendSlice(r.systemLibs());
            _ = try r.checked(args.items);
            r.report("bound self-hosting binaries", std.mem.eql(u8, try r.read("tccb1.exe"), try r.read("tccb2.exe")));
        }
        if (r.bcheck and r.selected("bounds")) {
            for ([_]usize{ 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 }) |i| {
                const out = try r.exec(r.command(&.{ "-b", "-bt1", "-run", r.path("tests/boundtest.c"), r.fmt("{d}", .{i}) }).items);
                const expected = switch (i) {
                    1, 4, 8, 10, 14, 16 => true,
                    else => false,
                };
                r.report(r.fmt("bounds-{d}", .{i}), (out.term == .exited and out.term.exited == 0) == expected);
            }
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var r = Runner{ .gpa = init.arena.allocator(), .io = init.io, .compiler = args[2], .root = try std.fs.path.resolve(init.arena.allocator(), &.{args[3]}), .headers = args[4], .support = args[5], .arch = args[6], .os = args[7], .backtrace = std.mem.eql(u8, args[8], "1"), .bcheck = std.mem.eql(u8, args[9], "1"), .filter = args[10], .zig = args[11] };
    const all = std.mem.eql(u8, args[1], "test");
    if (all or std.mem.eql(u8, args[1], "test-pp")) try r.suite(true);
    if (all or std.mem.eql(u8, args[1], "tests2")) try r.suite(false);
    if (all) r.integration(args[12..]) catch {
        r.report("integration", false);
    };
    std.debug.print("TinyCC tests: {d} passed, {d} skipped, {d} failed\n", .{ r.passed, r.skipped, r.failed });
    if (r.failed != 0 or r.passed == 0) return error.TestsFailed;
}
