const builtin = @import("builtin");
const std = @import("std");
const zig = @import("zig");

const Exe = enum { zig, zls };

pub fn build(b: *std.Build) !void {
    const zig_dep = b.dependency("zig", .{});

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
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
        });
        exe.root_module.addImport("zig", zig_mod);
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

    const test_step = b.step("test", "");
    addZigTests(b, anyzig, test_step, .{ .make_build_steps = true });

    const anyzls = blk: {
        const exe = b.addExecutable(.{
            .name = "zls",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
        });
        exe.root_module.addImport("zig", zig_mod);
        setBuildOptions(b, exe, .zls);
        const install = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install.step);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);
        if (b.args) |args| {
            run.addArgs(args);
        }
        b.step("zls", "").dependOn(&run.step);
        break :blk exe;
    };

    addZlsTests(b, anyzls, anyzig, test_step, .{ .make_build_steps = true });

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
    try ci(b, zig_mod, ci_step, host_zip_exe);
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
fn addZigTests(
    b: *std.Build,
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
            b.step(b.fmt("test-zig{s}", .{flag}), "").dependOn(&run.step);
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

    const wrap_exe = b.addExecutable(.{
        .name = "wrap",
        .root_source_file = b.path("test/wrap.zig"),
        .target = b.graph.host,
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

        const init_out = blk: {
            const init = b.addRunArtifact(wrap_exe);
            init.setName(b.fmt("zig {s} build init", .{zig_version}));
            init.addArg("--no-input");
            const out = init.addOutputDirectoryArg("out");
            init.addArg("nosetup");
            init.addArtifactArg(anyzig);
            init.addArg(zig_version);
            init.addArg(switch (zig_release.getInitKind()) {
                .simple => "init",
                .exe_and_lib => "init-exe",
            });
            break :blk out;
        };

        {
            const run = b.addRunArtifact(wrap_exe);
            run.setName(b.fmt("zig {s} version", .{zig_version}));
            run.addDirectoryArg(init_out);
            _ = run.addOutputDirectoryArg("out");
            run.addArg("nosetup");
            run.addArtifactArg(anyzig);
            run.addArg("version");
            run.expectStdOutEqual(comptime zig_release.getVersionOutput() ++ "\n");
            test_step.dependOn(&run.step);
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
            const run = b.addRunArtifact(wrap_exe);
            run.setName(b.fmt("zig {s} build", .{zig_version}));
            run.addDirectoryArg(init_out);
            _ = run.addOutputDirectoryArg("out");
            run.addArg("nosetup");
            run.addArtifactArg(anyzig);
            run.addArg("build");
            if (opt.make_build_steps) {
                b.step(b.fmt("test-zig-{s}-build", .{zig_version}), "").dependOn(&run.step);
            }
            test_step.dependOn(&run.step);
        }
    }

    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: finish this test
    if (false) {
        const run = b.addRunArtifact(wrap_exe);
        run.setName(b.fmt("bad hash", .{}));
        run.addArg("--no-input");
        _ = run.addOutputDirectoryArg("out");
        run.addArg("badhash");
        run.addArtifactArg(anyzig);
        run.addArg("version");
        //run.expectStdOutEqual("0.13.0\n");
        if (opt.make_build_steps) {
            b.step("test-zig-bad-hash", "").dependOn(&run.step);
        }
        test_step.dependOn(&run.step);
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
            const run = b.addRunArtifact(wrap_exe);
            run.setName(b.fmt("zon with comment", .{}));
            run.addDirectoryArg(write_files.getDirectory());
            _ = run.addOutputDirectoryArg("out");
            run.addArg("nosetup");
            run.addArtifactArg(anyzig);
            run.addArg("version");
            run.expectStdOutEqual("0.13.0\n");
            if (opt.make_build_steps) {
                b.step("test-zig-zon-with-comment", "").dependOn(&run.step);
            }
            test_step.dependOn(&run.step);
        }
    }
}

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

fn addZlsTests(
    b: *std.Build,
    anyzls: *std.Build.Step.Compile,
    /// anyzig required to generate build configs.
    anyzig: *std.Build.Step.Compile,
    test_step: *std.Build.Step,
    opt: SharedTestOptions,
) void {
    inline for (&.{ "-h", "--help" }) |flag| {
        const run = b.addRunArtifact(anyzls);
        run.setName(b.fmt("anyzls {s}", .{flag}));
        run.addArg(flag);
        run.addCheck(.{ .expect_stderr_match = "ZLS - A non-official language server for Zig" });
        if (opt.make_build_steps) {
            b.step(b.fmt("test-zls{s}", .{flag}), "").dependOn(&run.step);
        }
        test_step.dependOn(&run.step);
    }

    {
        const run = b.addRunArtifact(anyzls);
        run.setName("anyzls -no-command");
        run.addArg("-no-command");
        run.expectStdErrEqual("error: expected a command but got '-no-command'\n");
        test_step.dependOn(&run.step);
    }

    {
        const run = b.addRunArtifact(anyzls);
        run.setName("anyzls with no build.zig file");
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

    const wrap_exe = b.addExecutable(.{
        .name = "wrap",
        .root_source_file = b.path("test/wrap.zig"),
        .target = b.graph.host,
    });

    inline for (std.meta.fields(ZlsSupportedZigRelease)) |field| {
        var splits = std.mem.splitScalar(u8, field.name, '.');
        const major = splits.next().?;
        const minor = splits.next().?;
        const zls_version = b.fmt("{s}.{s}.0", .{ major, minor });
        const zig_release: ZigRelease = @field(ZigRelease, field.name);

        switch (builtin.os.tag) {
            .linux => switch (builtin.cpu.arch) {
                .x86_64 => switch (comptime zig_release) {
                    // fails to get dynamic linker on NixOS
                    .@"0.9.0",
                    .@"0.9.1",
                    => continue,
                    else => {},
                },
                else => {},
            },
            else => {},
        }

        const init_out = blk: {
            const init = b.addRunArtifact(wrap_exe);
            init.setName(b.fmt("zig {s} build init", .{zls_version}));
            init.addArg("--no-input");
            const out = init.addOutputDirectoryArg("out");
            init.addArg("nosetup");
            init.addArtifactArg(anyzig);
            init.addArg(zls_version);
            init.addArg(switch (zig_release.getInitKind()) {
                .simple => "init",
                .exe_and_lib => "init-exe",
            });
            break :blk out;
        };

        {
            const run = b.addRunArtifact(wrap_exe);
            run.setName(b.fmt("zls {s} --version", .{zls_version}));
            run.addDirectoryArg(init_out);
            _ = run.addOutputDirectoryArg("out");
            run.addArg("nosetup");
            run.addArtifactArg(anyzls);
            run.addArg("--version");
            run.addCheck(.{ .expect_stdout_match = zls_version });
            test_step.dependOn(&run.step);
        }
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
            const run = b.addRunArtifact(wrap_exe);
            run.setName(b.fmt("zls zon with comment", .{}));
            run.addDirectoryArg(write_files.getDirectory());
            _ = run.addOutputDirectoryArg("out");
            run.addArg("nosetup");
            run.addArtifactArg(anyzls);
            run.addArg("--version");
            run.expectStdOutEqual("0.13.0\n");
            if (opt.make_build_steps) {
                b.step("test-zls-zon-with-comment", "").dependOn(&run.step);
            }
            test_step.dependOn(&run.step);
        }
    }
}

const ZlsSupportedZigRelease = enum {
    @"0.9.0",
    @"0.9.1",
    @"0.10.0",
    @"0.10.1",
    @"0.11.0",
    @"0.12.0",
    @"0.12.1",
    @"0.13.0",
    @"0.14.0",
};

fn ci(
    b: *std.Build,
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
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
        });
        zig_exe.root_module.addImport("zig", zig_mod);
        setBuildOptions(b, zig_exe, .zig);
        install_exes.dependOn(
            &b.addInstallArtifact(zig_exe, .{ .dest_dir = .{ .override = target_dest_dir } }).step,
        );
        const zls_exe = b.addExecutable(.{
            .name = "zls",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
        });
        zls_exe.root_module.addImport("zig", zig_mod);
        setBuildOptions(b, zls_exe, .zls);
        install_exes.dependOn(
            &b.addInstallArtifact(zls_exe, .{ .dest_dir = .{ .override = target_dest_dir } }).step,
        );

        const target_test_step = b.step(b.fmt("test-{s}", .{ci_target_str}), "");
        const options = SharedTestOptions{
            .make_build_steps = false,
            // This doesn't seem to be working, so we're only adding these tests
            // as a dependency if we see the arch is compatible beforehand
            .failing_to_execute_foreign_is_an_error = false,
        };
        addZigTests(b, zig_exe, target_test_step, options);
        addZlsTests(b, zls_exe, zig_exe, target_test_step, options);
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
