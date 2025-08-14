const builtin = @import("builtin");
const std = @import("std");
const zig = @import("zig");

const Exe = enum { zig, zls };

pub fn build(b: *std.Build) !void {
    const zig_dep = b.dependency("zig", .{});

    const version_option: ?[11]u8 = if (b.option(
        []const u8,
        "force-version",
        "Force a specific version, bypassing the automatic calendar version.",
    )) |v| verifyForceVersion(v) else null;
    const release_version = if (version_option) |v| v else try makeCalVersion();
    const dev_version = b.fmt("{s}-dev", .{if (version_option) |v| v else release_version});
    const write_files_version = b.addWriteFiles();
    const release_version_file = write_files_version.add("version-release", &release_version);
    const release_version_embed = b.createModule(.{
        .root_source_file = release_version_file,
    });
    const dev_version_embed = b.createModule(.{
        .root_source_file = write_files_version.add("version-dev", dev_version),
    });
    const install_version_release_file = b.addInstallFile(release_version_file, "version-release");

    const write = b.addWriteFiles();
    _ = write.addCopyDirectory(zig_dep.path("."), "", .{});
    const root = write.addCopyFile(b.path("zigroot/root.zig"), "src/root.zig");
    const zig_mod = b.createModule(.{
        .root_source_file = root,
    });

    const options = b.addOptions();
    zig_mod.addOptions("build_options", options);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const anyzig = blk: {
        const exe = b.addExecutable(.{
            .name = "zig",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .single_threaded = true,
                .imports = &.{
                    .{ .name = "zig", .module = zig_mod },
                    .{ .name = "version", .module = dev_version_embed },
                },
            }),
        });
        setBuildOptions(b, exe, .zig);
        const install = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install.step);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);
        if (b.args) |args| {
            run.addArgs(args);
        }
        b.step("run", "").dependOn(&run.step);
        break :blk exe;
    };

    {
        const exe = b.addExecutable(.{
            .name = "zls",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .single_threaded = true,
                .imports = &.{
                    .{ .name = "zig", .module = zig_mod },
                    .{ .name = "version", .module = dev_version_embed },
                },
            }),
        });
        setBuildOptions(b, exe, .zls);
        const install = b.addInstallArtifact(exe, .{});

        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);
        if (b.args) |args| {
            run.addArgs(args);
        }
        b.step("zls", "").dependOn(&run.step);
    }

    const test_step = b.step("test", "");
    addTests(b, dev_version, anyzig, test_step, .{ .make_build_steps = true });

    const zip_dep = b.dependency("zip", .{});

    const host_zip_exe = b.addExecutable(.{
        .name = "zip",
        .root_source_file = zip_dep.path("src/zip.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });

    const ci_step = b.step("ci", "The build/test step to run on the CI");
    ci_step.dependOn(b.getInstallStep());
    ci_step.dependOn(test_step);
    ci_step.dependOn(&install_version_release_file.step);

    try ci(b, &release_version, release_version_embed, zig_mod, ci_step, host_zip_exe);
}

fn verifyForceVersion(v: []const u8) [11]u8 {
    if (v.len != 11) std.debug.panic(
        "bad force-version '{s}': must be 11 characters, but got {d}",
        .{ v, v.len },
    );
    if (v[0] != 'v' or v[5] != '_' or v[8] != '_') std.debug.panic(
        "bad force-version '{s}': must be of the form 'vYYYY_MM_DD'",
        .{v},
    );
    const month = std.fmt.parseInt(u8, v[6..8], 10) catch std.debug.panic(
        "bad force-version '{s}': invalid month '{s}'",
        .{ v, v[6..8] },
    );
    if (month < 1 or month > 12) std.debug.panic(
        "base force-version '{s}': invalid month '{s}'",
        .{ v, v[6..8] },
    );
    const day = std.fmt.parseInt(u8, v[9..11], 10) catch std.debug.panic(
        "bad force-version '{s}': invalid day '{s}'",
        .{ v, v[9..11] },
    );
    if (day < 1 or day > 31) std.debug.panic(
        "bad force-version '{s}': invalid day '{s}'",
        .{ v, v[9..11] },
    );
    var result: [11]u8 = undefined;
    @memcpy(&result, v);
    return result;
}

fn makeCalVersion() ![11]u8 {
    const now = std.time.epoch.EpochSeconds{ .secs = @intCast(std.time.timestamp()) };
    const day = now.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var buf: [11]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "v{d}_{d:0>2}_{d:0>2}", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index,
    });
    std.debug.assert(formatted.len == buf.len);
    return buf;
}

fn setBuildOptions(b: *std.Build, exe: *std.Build.Step.Compile, exe_kind: Exe) void {
    const o = b.addOptions();
    o.addOption(Exe, "exe", exe_kind);
    exe.root_module.addOptions("build_options", o);
}

const SharedTestOptions = struct {
    make_build_steps: bool,
    failing_to_execute_foreign_is_an_error: bool = true,
};
fn addTests(
    b: *std.Build,
    version: []const u8,
    anyzig: *std.Build.Step.Compile,
    test_step: *std.Build.Step,
    opt: SharedTestOptions,
) void {
    inline for (&.{ "-h", "--help" }) |flag| {
        const run = b.addRunArtifact(anyzig);
        run.setName(b.fmt("anyzig {s}", .{flag}));
        run.addArg(flag);
        run.addCheck(.{ .expect_stdout_match = "Usage: zig [command] [options]" });
        if (opt.make_build_steps) {
            b.step(b.fmt("test{s}", .{flag}), "").dependOn(&run.step);
        }
        test_step.dependOn(&run.step);
    }

    {
        const run = b.addRunArtifact(anyzig);
        run.setName("anyzig -no-command");
        run.addArg("-no-command");
        run.expectStdErrEqual("error: expected a command but got '-no-command'\n");
        test_step.dependOn(&run.step);
    }

    {
        const run = b.addRunArtifact(anyzig);
        run.setName("anyzig init (no version)");
        run.addArg("init");
        run.expectStdErrEqual("error: anyzig init requires a version, i.e. 'zig 0.13.0 init'\n");
        test_step.dependOn(&run.step);
    }

    {
        const run = b.addRunArtifact(anyzig);
        run.setName("anyzig with no build.zig file");
        run.addArg("version");
        // the most full-proof directory to avoid finding a build.zig...if
        // this doesn't work, then no directory would work anyway
        run.setCwd(.{ .cwd_relative = switch (builtin.os.tag) {
            .windows => "C:/",
            else => "/",
        } });
        run.addCheck(.{
            .expect_stderr_match = "no build.zig to pull a zig version from, you can:",
        });
        test_step.dependOn(&run.step);
    }

    const test_factory: TestFactory = .{
        .b = b,
        .test_step = test_step,
        .anyzig = anyzig,
        .wrap_exe = b.addExecutable(.{
            .name = "wrap",
            .root_source_file = b.path("test/wrap.zig"),
            .target = b.graph.host,
        }),
        .make_build_steps = opt.make_build_steps,
    };

    {
        const t = test_factory.add(.{
            .name = "test-any",
            .input_dir = .no_input,
            .options = .nosetup,
            .args = &.{"any"},
        });
        t.run.addCheck(.{ .expect_stderr_match = b.fmt(
            "anyzig {s} from https://github.com/marler8997/anyzig\n",
            .{version},
        ) });
        t.run.addCheck(.{ .expect_stderr_match = "zig any version" });
        t.run.addCheck(.{ .expect_stderr_match = "zig any set-verbosity" });
    }

    {
        const t = test_factory.add(.{
            .name = "test-any-version",
            .input_dir = .no_input,
            .options = .nosetup,
            .args = &.{ "any", "version" },
        });
        t.run.expectStdOutEqual(b.fmt("{s}\n", .{version}));
    }

    {
        const t = test_factory.add(.{
            .name = "test-any-set-verbosity-none",
            .input_dir = .no_input,
            .options = .nosetup,
            .args = &.{ "any", "set-verbosity" },
        });
        t.run.expectStdErrEqual("anyzig: error: missing VERBOSITY (either 'warn' or 'debug')\n");
    }

    {
        const t = test_factory.add(.{
            .name = "test-any-set-verbosity-too-many",
            .input_dir = .no_input,
            .options = .nosetup,
            .args = &.{ "any", "set-verbosity", "warn", "debug" },
        });
        t.run.expectStdErrEqual("anyzig: error: too many cmdline args\n");
    }

    {
        const t = test_factory.add(.{
            .name = "test-any-set-verbosity-bad",
            .input_dir = .no_input,
            .options = .nosetup,
            .args = &.{ "any", "set-verbosity", "whattheheck" },
        });
        t.run.expectStdErrEqual("anyzig: error: unknown VERBOSITY 'whattheheck', expected 'warn' or 'debug'\n");
    }

    {
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // TODO: override the appdata directory to run this test
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        _ = test_factory.add(.{
            .name = "test-any-set-verbosity-warn",
            .input_dir = .no_input,
            .options = .nosetup,
            .args = &.{ "any", "set-verbosity", "warn" },
        });
    }

    _ = test_factory.add(.{
        .name = "test-master-version",
        .input_dir = .no_input,
        .options = .nosetup,
        .args = &.{ "master", "version" },
    });
    _ = test_factory.add(.{
        .name = "test-master-init",
        .input_dir = .no_input,
        .options = .nosetup,
        .args = &.{ "master", "init" },
    });

    inline for (std.meta.fields(ZigRelease)) |field| {
        const zig_version = field.name;
        const zig_release: ZigRelease = @enumFromInt(field.value);

        switch (builtin.os.tag) {
            .linux => switch (builtin.cpu.arch) {
                .x86_64 => switch (comptime zig_release) {
                    // fails to get dynamic linker on NixOS
                    .@"0.7.0",
                    .@"0.7.1",
                    .@"0.8.0",
                    .@"0.8.1",
                    .@"0.9.0",
                    .@"0.9.1",
                    => continue,
                    else => {},
                },
                else => {},
            },
            .macos => switch (builtin.cpu.arch) {
                .aarch64 => switch (comptime zig_release) {
                    .@"0.7.1" => continue, // HTTP download fails with "404 Not Found"
                    else => {},
                },
                else => {},
            },
            else => {},
        }

        const init_out = test_factory.add(.{
            .name = b.fmt("test-{s}-init", .{zig_version}),
            .input_dir = .no_input,
            .options = .nosetup,
            .args = &.{
                zig_version,
                switch (zig_release.getInitKind()) {
                    .simple => "init",
                    .exe_and_lib => "init-exe",
                },
            },
        }).output_dir;

        {
            const t = test_factory.add(.{
                .name = b.fmt("test-{s}-version", .{zig_version}),
                .input_dir = .{ .path = init_out },
                .options = .nosetup,
                .args = &.{"version"},
            });
            t.run.expectStdOutEqual(comptime zig_release.getVersionOutput() ++ "\n");
        }

        for ([_][]const u8{ "-h", "--help" }) |help_flag| {
            if (zig_release == .@"0.7.0" and std.mem.eql(u8, help_flag, "-h"))
                continue;
            const t = test_factory.add(.{
                .name = b.fmt("test-{s}-init{s}", .{ zig_version, help_flag }),
                .input_dir = .no_input,
                .options = .nosetup,
                .args = &.{ zig_version, switch (zig_release.getInitKind()) {
                    .simple => "init",
                    .exe_and_lib => "init-exe",
                }, help_flag },
            });
            t.run.addCheck(.{ .expect_stdout_match = "Usage: zig init" });
        }

        const build_enabled = switch (b.graph.host.result.os.tag) {
            .macos => switch (b.graph.host.result.cpu.arch) {
                .aarch64 => switch (zig_release) {
                    .@"0.7.0" => false, // crashes for some reason?
                    .@"0.9.0", .@"0.9.1" => false, // panics
                    .@"0.10.0", .@"0.10.1" => false, // error(link): undefined reference to symbol 'dyld_stub_binder'
                    else => true,
                },
                else => true,
            },
            else => true,
        };

        // TODO: test more than just 'zig build'
        if (build_enabled) {
            _ = test_factory.add(.{
                .name = b.fmt("test-{s}-build", .{zig_version}),
                .input_dir = .{ .path = init_out },
                .options = .nosetup,
                .args = &.{"build"},
            });
        }
    }

    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: finish this test
    if (false) {
        const t = test_factory.add(.{
            .name = "test-bad-hash",
            .input_dir = .no_input,
            .options = .badhash,
            .args = &.{"version"},
        });
        t.run.expectStdOutEqual("0.13.0\n");
    }

    {
        const write_files = b.addWriteFiles();
        _ = write_files.add("build.zig", "");
        _ = write_files.add("build.zig.zon",
            \\// example comment
            \\.{
            \\    .minimum_zig_version = "0.13.0",
            \\}
            \\
        );
        {
            const t = test_factory.add(.{
                .name = "test-zon-with-comment",
                .input_dir = .{ .path = write_files.getDirectory() },
                .options = .nosetup,
                .args = &.{"version"},
            });
            t.run.expectStdOutEqual("0.13.0\n");
        }
    }

    {
        const write_files = b.addWriteFiles();
        const build_zig_12 = write_files.add(
            "example-0.12.0/build.zig",
            @embedFile("test/build.version.zig"),
        );
        _ = write_files.add("example-0.12.0/build.zig.zon",
            \\.{
            \\    .name = "Test",
            \\    .version = "0.0.0",
            \\    .minimum_zig_version = "0.12.0",
            \\    .paths = .{"."},
            \\}
            \\
        );
        const build_zig_13 = write_files.add(
            "example-0.13.0/build.zig",
            @embedFile("test/build.version.zig"),
        );
        _ = write_files.add("example-0.13.0/build.zig.zon",
            \\.{
            \\    .name = "Test",
            \\    .version = "0.0.0",
            \\    .minimum_zig_version = "0.13.0",
            \\    .paths = .{"."},
            \\}
            \\
        );
        {
            const t = test_factory.add(.{
                .name = "test-build-file-control-0.12.0",
                .input_dir = .{ .path = write_files.getDirectory().path(b, "example-0.12.0") },
                .options = .nosetup,
                .args = &.{"build"},
            });
            t.run.expectStdOutEqual("0.12.0\n");
        }
        {
            const t = test_factory.add(.{
                .name = "test-build-file-control-0.13.0",
                .input_dir = .{ .path = write_files.getDirectory().path(b, "example-0.13.0") },
                .options = .nosetup,
                .args = &.{"build"},
            });
            t.run.expectStdOutEqual("0.13.0\n");
        }
        {
            const t = test_factory.add(.{
                .name = "test-build-file-0.12.0",
                .input_dir = .{ .path = write_files.getDirectory().path(b, "example-0.13.0") },
                .options = .nosetup,
                .args = &.{ "build", "--build-file" },
            });
            t.run.addFileArg(build_zig_12);
            t.run.expectStdOutEqual("0.12.0\n");
        }
        {
            const t = test_factory.add(.{
                .name = "test-build-file-0.13.0",
                .input_dir = .{ .path = write_files.getDirectory().path(b, "example-0.12.0") },
                .options = .nosetup,
                .args = &.{ "build", "--build-file" },
            });
            t.run.addFileArg(build_zig_13);
            t.run.expectStdOutEqual("0.13.0\n");
        }
    }
}

const TestAnyzig = struct {
    output_dir: std.Build.LazyPath,
    run: *std.Build.Step.Run,
};

const TestFactory = struct {
    b: *std.Build,
    test_step: *std.Build.Step,
    anyzig: *std.Build.Step.Compile,
    wrap_exe: *std.Build.Step.Compile,
    make_build_steps: bool,

    pub fn add(self: *const TestFactory, args: struct {
        name: []const u8,
        input_dir: union(enum) {
            no_input,
            path: std.Build.LazyPath,
        },
        options: enum { nosetup, badhash },
        args: []const []const u8,
    }) TestAnyzig {
        const b = self.b;
        const run = b.addRunArtifact(self.wrap_exe);
        run.setName(args.name);
        switch (args.input_dir) {
            .no_input => run.addArg("--no-input"),
            .path => |p| run.addDirectoryArg(p),
        }
        const output_dir = run.addOutputDirectoryArg("out");
        run.addArg(@tagName(args.options));
        run.addArtifactArg(self.anyzig);
        for (args.args) |a| {
            run.addArg(a);
        }
        if (self.make_build_steps) {
            b.step(args.name, "").dependOn(&run.step);
        }
        self.test_step.dependOn(&run.step);
        return .{ .run = run, .output_dir = output_dir };
    }
};

const ZigRelease = enum {
    @"0.7.0",
    @"0.7.1",
    @"0.8.0",
    @"0.8.1",
    @"0.9.0",
    @"0.9.1",
    @"0.10.0",
    @"0.10.1",
    @"0.11.0",
    @"0.12.0",
    @"0.12.1",
    @"0.13.0",
    @"0.14.0",
    @"0.14.1",
    @"2024.11.0-mach",

    pub fn getInitKind(self: ZigRelease) enum { simple, exe_and_lib } {
        return if (@intFromEnum(self) >= @intFromEnum(ZigRelease.@"0.12.0")) .simple else .exe_and_lib;
    }
    pub fn getVersionOutput(self: ZigRelease) []const u8 {
        return switch (self) {
            .@"2024.11.0-mach" => "0.14.0-dev.2577+271452d22",
            else => |release| @tagName(release),
        };
    }
};

fn ci(
    b: *std.Build,
    release_version: []const u8,
    release_version_embed: *std.Build.Module,
    zig_mod: *std.Build.Module,
    ci_step: *std.Build.Step,
    host_zip_exe: *std.Build.Step.Compile,
) !void {
    const ci_targets = [_][]const u8{
        "aarch64-linux",
        "aarch64-macos",
        "aarch64-windows",
        "arm-linux",
        "powerpc64le-linux",
        "riscv64-linux",
        "s390x-linux",
        "x86-linux",
        "x86-windows",
        "x86_64-linux",
        "x86_64-macos",
        "x86_64-windows",
    };

    const make_archive_step = b.step("archive", "Create CI archives");
    ci_step.dependOn(make_archive_step);

    for (ci_targets) |ci_target_str| {
        const target = b.resolveTargetQuery(try std.Target.Query.parse(
            .{ .arch_os_abi = ci_target_str },
        ));
        const optimize: std.builtin.OptimizeMode = .ReleaseSafe;

        const target_dest_dir: std.Build.InstallDir = .{ .custom = ci_target_str };

        const install_exes = b.step(b.fmt("install-{s}", .{ci_target_str}), "");
        ci_step.dependOn(install_exes);
        const zig_exe = b.addExecutable(.{
            .name = "zig",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .single_threaded = true,
                .imports = &.{
                    .{ .name = "zig", .module = zig_mod },
                    .{ .name = "version", .module = release_version_embed },
                },
            }),
        });
        setBuildOptions(b, zig_exe, .zig);
        install_exes.dependOn(
            &b.addInstallArtifact(zig_exe, .{ .dest_dir = .{ .override = target_dest_dir } }).step,
        );
        const zls_exe = b.addExecutable(.{
            .name = "zls",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .single_threaded = true,
                .imports = &.{
                    .{ .name = "zig", .module = zig_mod },
                    .{ .name = "version", .module = release_version_embed },
                },
            }),
        });
        setBuildOptions(b, zls_exe, .zls);
        install_exes.dependOn(
            &b.addInstallArtifact(zls_exe, .{ .dest_dir = .{ .override = target_dest_dir } }).step,
        );

        const target_test_step = b.step(b.fmt("test-{s}", .{ci_target_str}), "");
        addTests(b, release_version, zig_exe, target_test_step, .{
            .make_build_steps = false,
            // This doesn't seem to be working, so we're only adding these tests
            // as a dependency if we see the arch is compatible beforehand
            .failing_to_execute_foreign_is_an_error = false,
        });
        const os_compatible = (builtin.os.tag == target.result.os.tag);
        const arch_compatible = (builtin.cpu.arch == target.result.cpu.arch);
        if (os_compatible and arch_compatible) {
            ci_step.dependOn(target_test_step);
        }

        if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
            make_archive_step.dependOn(makeCiArchiveStep(
                b,
                ci_target_str,
                target.result,
                target_dest_dir,
                install_exes,
                host_zip_exe,
            ));
        }
    }
}

fn makeCiArchiveStep(
    b: *std.Build,
    ci_target_str: []const u8,
    target: std.Target,
    target_install_dir: std.Build.InstallDir,
    install_exes: *std.Build.Step,
    host_zip_exe: *std.Build.Step.Compile,
) *std.Build.Step {
    const install_path = b.getInstallPath(.prefix, ".");

    // not sure yet if we want to include zls.exe in our archives?
    const include_zls = false;

    if (target.os.tag == .windows) {
        const out_zip_file = b.pathJoin(&.{
            install_path,
            b.fmt("anyzig-{s}.zip", .{ci_target_str}),
        });
        const zip = b.addRunArtifact(host_zip_exe);
        zip.addArg(out_zip_file);
        zip.addArg("zig.exe");
        zip.addArg("zig.pdb");
        if (include_zls) {
            zip.addArg("zls.exe");
            zip.addArg("zls.pdb");
        }
        zip.cwd = .{ .cwd_relative = b.getInstallPath(
            target_install_dir,
            ".",
        ) };
        zip.step.dependOn(install_exes);
        return &zip.step;
    }

    const targz = b.pathJoin(&.{
        install_path,
        b.fmt("anyzig-{s}.tar.gz", .{ci_target_str}),
    });
    const tar = b.addSystemCommand(&.{
        "tar",
        "-czf",
        targz,
        "zig",
    });
    if (include_zls) {
        tar.addArg("zls");
    }
    tar.cwd = .{ .cwd_relative = b.getInstallPath(
        target_install_dir,
        ".",
    ) };
    tar.step.dependOn(install_exes);
    return &tar.step;
}
