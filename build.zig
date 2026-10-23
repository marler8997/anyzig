const builtin = @import("builtin");
const std = @import("std");
const zig = @import("zig");

const Exe = enum { zig, zls };

pub fn build(b: *std.Build) !void {
    // zig's build script gets the version from git, which the fetched package doesn't have
    const zig_dep = b.dependency("zig", .{ .@"version-string" = "0.17.0" });

    const version_option: ?[11]u8 = if (b.option(
        []const u8,
        "force-version",
        "Force a specific version, bypassing the automatic calendar version.",
    )) |v| verifyForceVersion(v) else null;
    const release_version = if (version_option) |v| v else try makeCalVersion(b.graph.io);
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

    // Fetch lives in zig's build runner (lib/compiler), not a module, so we patch a copy and add a root file
    const patched_compiler = b.dependency("patch", .{
        .source = zig_dep.path("lib/compiler"),
        .patches = &[_]std.Build.LazyPath{b.path("zigroot/fetch.patch")},
    }).namedLazyPath("patched");
    const write = b.addWriteFiles();
    _ = write.addCopyDirectory(patched_compiler, "", .{});
    const root = write.addCopyFile(b.path("zigroot/root.zig"), "root.zig");
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
                    .{
                        .name = "version",
                        .module = if (b.graph.environ_map.get("HEW_BUILD_REVISION")) |r| b.createModule(.{
                            .root_source_file = write_files_version.add("version-release-native", b.fmt("{s}-native", .{r})),
                        }) else dev_version_embed,
                    },
                },
            }),
        });
        setBuildOptions(b, exe, .zig);
        const install = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install.step);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);
        run.addPassthruArgs();
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
        run.addPassthruArgs();
        b.step("zls", "").dependOn(&run.step);
    }

    const atleast_xcode26_4 = b.option(
        bool,
        "atleast-xcode26_4",
        "The selected Xcode is 26.4 or newer, skips the tests that build with old zig versions (0.11 to 0.14 can't link against its SDK)",
    ) orelse false;

    const test_step = b.step("test", "");
    addTests(b, dev_version, anyzig, test_step, .{ .make_build_steps = true, .old_zig_builds = !atleast_xcode26_4 });
    {
        const unit_test_step = b.step("unit-test", "Run the unit tests");
        test_step.dependOn(unit_test_step);
        const unit_tests = b.addRunArtifact(b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/test.zig"),
                .target = b.graph.host,
                .imports = &.{.{ .name = "zig", .module = zig_mod }},
            }),
        }));
        unit_test_step.dependOn(&unit_tests.step);
    }

    const host_zip_exe = b.dependency("zip", .{
        .target = b.graph.host,
        .optimize = .debug,
    }).artifact("zip");

    const release_step = b.step("release", "Build/archive release executables for all targets and test the native one");
    release_step.dependOn(&install_version_release_file.step);

    try addReleaseSteps(b, &release_version, release_version_embed, zig_mod, release_step, host_zip_exe);
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

fn makeCalVersion(io: std.Io) ![11]u8 {
    const now = std.time.epoch.EpochSeconds{ .secs = @intCast(std.Io.Clock.real.now(io).toSeconds()) };
    const day = now.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var buf: [11]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "v{d}_{d:0>2}_{d:0>2}", .{
        year_day.year,
        @backingInt(month_day.month),
        month_day.day_index + 1,
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
    old_zig_builds: bool,
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
        run.expectExitCode(0);
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

    const test_factory: TestFactory = .{
        .b = b,
        .test_step = test_step,
        .anyzig = anyzig,
        .wrap_exe = b.addExecutable(.{
            .name = "wrap",
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/wrap.zig"),
                .target = b.graph.host,
            }),
        }),
        .make_build_steps = opt.make_build_steps,
    };

    // these use an isolated appdata, otherwise an ad-hoc version set on the machine running
    // the tests would be used
    {
        const t = test_factory.add(.{
            .name = "test-init-no-version",
            .input_dir = .no_input,
            .options = .{ .appdata = .{ .default_verbosity = true } },
            .offline = true,
            .args = &.{"init"},
        });
        t.run.expectStdErrEqual("error: anyzig init requires a version, you can:\n" ++
            "  1. run 'zig 0.13.0 init'\n" ++
            "  2. set a version to use outside projects with 'zig any set-ad-hoc-version VERSION'\n");
        t.run.expectExitCode(0xff);
    }
    {
        const t = test_factory.add(.{
            .name = "test-no-build-zig",
            .input_dir = .no_input,
            .options = .{ .appdata = .{ .default_verbosity = true } },
            .offline = true,
            .cwd_root = true,
            .args = &.{"version"},
        });
        t.run.addCheck(.{ .expect_stderr_match = "no build.zig to pull a zig version from, you can:" });
        t.run.addCheck(.{ .expect_stderr_match = "'zig any set-ad-hoc-version VERSION'" });
        t.run.expectExitCode(0xff);
    }

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
        t.run.addCheck(.{ .expect_stderr_match = "ANYZIG_VERBOSE=1" });
        t.run.addCheck(.{ .expect_stderr_match = "zig any set-ad-hoc-version [VERSION]" });
        t.run.expectExitCode(0xff);
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
            .name = "test-any-set-verbosity-removed",
            .input_dir = .no_input,
            .options = .nosetup,
            .args = &.{ "any", "set-verbosity", "debug" },
        });
        t.run.expectStdErrEqual("anyzig: error: 'set-verbosity' was removed, set ANYZIG_VERBOSE=1 to log what anyzig is doing\n");
        t.run.expectExitCode(1);
    }

    // these fail before touching appdata
    inline for (.{
        .{ "too-many", &[_][]const u8{ "0.14.0", "0.14.1" }, "anyzig: error: the 'set-ad-hoc-version' subcommand takes at most one VERSION\n" },
        .{ "master", &[_][]const u8{"master"}, "anyzig: error: invalid VERSION 'master', expected a zig version like 0.15.2 (not master)\n" },
    }) |case| {
        const t = test_factory.add(.{
            .name = "test-set-ad-hoc-version-" ++ case[0],
            .input_dir = .no_input,
            .options = .{ .appdata = .{ .default_verbosity = true } },
            .offline = true,
            .args = &([_][]const u8{ "any", "set-ad-hoc-version" } ++ case[1].*),
        });
        t.run.expectStdErrEqual(case[2]);
        t.run.expectExitCode(1);
    }
    {
        // clearing when nothing is set isn't an error
        const t = test_factory.add(.{
            .name = "test-clear-ad-hoc-version-unset",
            .input_dir = .no_input,
            .options = .{ .appdata = .{ .default_verbosity = true } },
            .offline = true,
            .args = &.{ "any", "set-ad-hoc-version" },
        });
        t.run.expectStdErrEqual("anyzig: no ad-hoc version is set\n");
        t.run.expectExitCode(0);
    }
    {
        const t = test_factory.add(.{
            .name = "test-set-ad-hoc-version-not-a-release",
            .input_dir = .no_input,
            .options = .{ .appdata = .{ .saved_index = "{\"0.14.0\":{}}" } },
            .args = &.{ "any", "set-ad-hoc-version", "12.2.1" },
        });
        t.run.addCheck(.{ .expect_stderr_match = "zig 12.2.1 is not a release" });
        t.run.expectExitCode(1);
    }

    {
        // anyzig must forward zig's exit code (on windows it's a child process)
        const t = test_factory.add(.{
            .name = "test-exit-code",
            .input_dir = .no_input,
            .options = .nosetup,
            .args = &.{ "0.14.0", "build-exe", "does-not-exist.zig" },
        });
        t.run.expectExitCode(1);
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

    inline for (comptime std.meta.tags(ZigRelease)) |zig_release| {
        const zig_version = @tagName(zig_release);

        if (zig_release == .@"2024.11.0-mach") continue; // TODO: re-enable when pkg.hexops.org is back online

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
            .windows => switch (builtin.cpu.arch) {
                .aarch64 => switch (comptime zig_release) {
                    // no windows-aarch64 downloads before 0.9.0
                    .@"0.7.0",
                    .@"0.7.1",
                    .@"0.8.0",
                    .@"0.8.1",
                    => continue,
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
            .windows => switch (b.graph.host.result.cpu.arch) {
                .aarch64 => switch (zig_release) {
                    .@"0.9.0", .@"0.9.1" => false, // zig build crashes with exit code 255
                    else => true,
                },
                else => true,
            },
            else => true,
        };

        // TODO: test more than just 'zig build'
        if (build_enabled and opt.old_zig_builds) {
            _ = test_factory.add(.{
                .name = b.fmt("test-{s}-build", .{zig_version}),
                .input_dir = .{ .path = init_out },
                .options = .nosetup,
                .args = &.{"build"},
            });
        }
    }

    // offline runs can only succeed if the install is found, each test uses the previous one's appdata
    {
        const write_files = b.addWriteFiles();
        _ = write_files.add("build.zig", "");
        _ = write_files.add("build.zig.zon", ".{ .minimum_zig_version = \"0.14.0\" }\n");
        const cold = test_factory.add(.{
            .name = "test-cache-cold",
            .input_dir = .{ .path = write_files.getDirectory() },
            .options = .{ .appdata = .{} },
            .args = &.{"version"},
        });
        cold.run.expectStdOutEqual("0.14.0\n");
        cold.run.addCheck(.{ .expect_stderr_match = "downloaded zig-0.14.0" });
        // from a community mirror
        cold.run.addCheck(.{ .expect_stderr_match = " from https://" });

        const warm = test_factory.add(.{
            .name = "test-cache-warm",
            .input_dir = .{ .path = cold.output_dir },
            .options = .{ .appdata = .{} },
            .offline = true,
            .args = &.{"version"},
        });
        warm.run.expectStdOutEqual("0.14.0\n");
        warm.run.addCheck(.{ .expect_stderr_match = "already exists" });

        // the ad-hoc version is used outside projects
        const ad_hoc_set = test_factory.add(.{
            .name = "test-ad-hoc-version-set",
            .input_dir = .{ .path = warm.output_dir },
            .options = .{ .appdata = .{} },
            .offline = true,
            .args = &.{ "any", "set-ad-hoc-version", "0.14.0" },
        });
        ad_hoc_set.run.addCheck(.{ .expect_stderr_match = "zig 0.14.0 will be used outside projects" });
        const ad_hoc_outside = test_factory.add(.{
            .name = "test-ad-hoc-version-outside-project",
            .input_dir = .{ .path = ad_hoc_set.output_dir },
            .options = .{ .appdata = .{} },
            .offline = true,
            .cwd_root = true,
            .args = &.{"version"},
        });
        ad_hoc_outside.run.expectStdOutEqual("0.14.0\n");
        ad_hoc_outside.run.addCheck(.{ .expect_stderr_match = "ad-hoc version 0.14.0 from '" });
        // once cleared, it isn't used outside projects any more
        const ad_hoc_clear = test_factory.add(.{
            .name = "test-clear-ad-hoc-version",
            .input_dir = .{ .path = ad_hoc_outside.output_dir },
            .options = .{ .appdata = .{} },
            .offline = true,
            .args = &.{ "any", "set-ad-hoc-version" },
        });
        ad_hoc_clear.run.addCheck(.{ .expect_stderr_match = "cleared the ad-hoc version (was '0.14.0')" });
        const ad_hoc_cleared = test_factory.add(.{
            .name = "test-clear-ad-hoc-version-outside-project",
            .input_dir = .{ .path = ad_hoc_clear.output_dir },
            .options = .{ .appdata = .{} },
            .offline = true,
            .cwd_root = true,
            .args = &.{"version"},
        });
        ad_hoc_cleared.run.addCheck(.{ .expect_stderr_match = "no build.zig to pull a zig version from" });
        ad_hoc_cleared.run.expectExitCode(0xff);
        // and a project's version wins over it (0.14.1 isn't installed and we're offline)
        const ad_hoc_set_other = test_factory.add(.{
            .name = "test-ad-hoc-version-set-other",
            .input_dir = .{ .path = warm.output_dir },
            .options = .{ .appdata = .{} },
            .offline = true,
            .args = &.{ "any", "set-ad-hoc-version", "0.14.1" },
        });
        const ad_hoc_in_project = test_factory.add(.{
            .name = "test-ad-hoc-version-in-project",
            .input_dir = .{ .path = ad_hoc_set_other.output_dir },
            .options = .{ .appdata = .{} },
            .offline = true,
            .args = &.{"version"},
        });
        ad_hoc_in_project.run.expectStdOutEqual("0.14.0\n");

        // the default verbosity only shows info, warnings and errors, there are none since it's installed
        const default_verbosity = test_factory.add(.{
            .name = "test-default-verbosity",
            .input_dir = .{ .path = warm.output_dir },
            .options = .{ .appdata = .{ .default_verbosity = true } },
            .offline = true,
            .args = &.{"version"},
        });
        default_verbosity.run.expectStdOutEqual("0.14.0\n");
        default_verbosity.run.expectStdErrEqual("");

        const list_installed = test_factory.add(.{
            .name = "test-list-installed",
            .input_dir = .{ .path = warm.output_dir },
            .options = .{ .appdata = .{} },
            .offline = true,
            .args = &.{ "any", "list-installed" },
        });
        list_installed.run.addCheck(.{
            .expect_stdout_match = "0.14.0\t",
        });
        list_installed.run.addCheck(.{
            .expect_stdout_match = "anyzig" ++ std.fs.path.sep_str ++ "zig" ++ std.fs.path.sep_str ++ "0.14.0\n",
        });
        list_installed.run.expectExitCode(0);

        // Older versions of anyzig installed compilers in zig's global cache, these are
        // copied to the new location when they're first used. Two processes migrate at
        // once, only one of them copies it and the other uses that copy.
        const migrate = test_factory.add(.{
            .name = "test-migrate",
            .input_dir = .{ .path = list_installed.output_dir },
            .options = .{ .appdata = .{ .legacy_install = "0.14.0" } },
            .offline = true,
            .concurrent = .{ .count = 2, .install = "zig-0.14.0" },
            .args = &.{"version"},
        });
        migrate.run.expectStdOutEqual("0.14.0\n0.14.0\n");
        migrate.run.addCheck(.{ .expect_stderr_match = "where an older anyzig installed it" });
        migrate.run.addCheck(.{ .expect_stderr_match = "copied zig-0.14.0" });

        // the copy is used from then on, and the legacy install is left alone
        const migrate_warm = test_factory.add(.{
            .name = "test-migrate-warm",
            .input_dir = .{ .path = migrate.output_dir },
            .options = .{ .appdata = .{ .expect_legacy_install = "0.14.0" } },
            .offline = true,
            .args = &.{"version"},
        });
        migrate_warm.run.expectStdOutEqual("0.14.0\n");
        migrate_warm.run.addCheck(.{ .expect_stderr_match = "already exists" });

        // Installs abandoned by processes that died are deleted, both the one for the
        // version being installed and any others, and install directories without a lock file.
        const abandoned = test_factory.add(.{
            .name = "test-abandoned-install",
            .input_dir = .{ .path = migrate_warm.output_dir },
            .options = .{ .appdata = .{
                .uninstall = "0.14.0",
                .abandoned_installs = &.{ "zig-0.14.0", "zig-0.13.0" },
                .lockless_installs = &.{"zig-0.12.0"},
            } },
            .offline = true,
            .args = &.{"version"},
        });
        abandoned.run.expectStdOutEqual("0.14.0\n");
        inline for (.{ "zig-0.14.0", "zig-0.13.0" }) |name| abandoned.run.addCheck(.{
            .expect_stderr_match = "install" ++ std.fs.path.sep_str ++ name ++ "'",
        });
        abandoned.run.addCheck(.{
            .expect_stderr_match = "install" ++ std.fs.path.sep_str ++ "zig-0.12.0', it has no lock file",
        });
        abandoned.run.addCheck(.{ .expect_stderr_match = "copied zig-0.14.0" });
        const abandoned_warm = test_factory.add(.{
            .name = "test-abandoned-install-warm",
            .input_dir = .{ .path = abandoned.output_dir },
            .options = .{ .appdata = .{ .expect_no_abandoned_installs = true } },
            .offline = true,
            .args = &.{"version"},
        });
        abandoned_warm.run.expectStdOutEqual("0.14.0\n");
        abandoned_warm.run.addCheck(.{ .expect_stderr_match = "already exists" });

        // a version directory without its exe (i.e. quarantined by antivirus) is replaced
        const missing_exe = test_factory.add(.{
            .name = "test-install-missing-exe",
            .input_dir = .{ .path = abandoned_warm.output_dir },
            .options = .{ .appdata = .{ .remove_exe = "0.14.0" } },
            .offline = true,
            .args = &.{"version"},
        });
        missing_exe.run.expectStdOutEqual("0.14.0\n");
        missing_exe.run.addCheck(.{ .expect_stderr_match = "without 'zig" });
        missing_exe.run.addCheck(.{ .expect_stderr_match = "copied zig-0.14.0" });

        // an invalid hashstore entry is ignored (with a warning) even though the legacy
        // install it used to point to is there, so the version is downloaded
        const invalid_entry = test_factory.add(.{
            .name = "test-cache-invalid-entry",
            .input_dir = .{ .path = missing_exe.output_dir },
            .options = .{ .appdata = .{
                .uninstall = "0.14.0",
                .corrupt_entry = .{ .name = "zig-0.14.0", .content = .empty },
            } },
            .args = &.{"version"},
        });
        invalid_entry.run.expectStdOutEqual("0.14.0\n");
        invalid_entry.run.addCheck(.{ .expect_stderr_match = "is invalid (empty)" });
        invalid_entry.run.addCheck(.{ .expect_stderr_match = "downloaded zig-0.14.0" });
    }

    // Concurrent installs of the same compiler wait for each other, only one of them
    // downloads it and the others use that install.
    {
        const write_files = b.addWriteFiles();
        _ = write_files.add("build.zig", "");
        _ = write_files.add("build.zig.zon", ".{ .minimum_zig_version = \"0.14.0\" }\n");
        const t = test_factory.add(.{
            .name = "test-concurrent-fetch",
            .input_dir = .{ .path = write_files.getDirectory() },
            .options = .{ .appdata = .{} },
            .concurrent = .{ .count = 2, .install = "zig-0.14.0" },
            .args = &.{"version"},
        });
        t.run.expectStdOutEqual("0.14.0\n0.14.0\n");
    }

    {
        const t = test_factory.add(.{
            .name = "test-not-a-release",
            .input_dir = .no_input,
            .options = .{ .appdata = .{} },
            .args = &.{ "12.2.1", "version" },
        });
        t.run.addCheck(.{ .expect_stderr_match = "zig 12.2.1 is not a release" });
        t.run.expectExitCode(1);
    }

    // The saved download index is checked before fetching it. These are offline with a version
    // that doesn't exist so they fail once they get past the check.
    {
        // the key is found when it has escapes, after skipping a nested value and a longer key
        const t = test_factory.add(.{
            .name = "test-index-escaped-key",
            .input_dir = .no_input,
            .options = .{ .appdata = .{ .saved_index =
            \\{"master":{"0.99.0":{"a":[1,{"b":"0.99.0"}]}},"0.99.0x":{},"0.\u00399.0":{}}
            } },
            .offline = true,
            .args = &.{ "0.99.0", "version" },
        });
        t.run.addCheck(.{ .expect_stderr_match = "zig 0.99.0 is in the saved download index" });
        t.run.expectExitCode(1);
    }
    {
        // nested, longer, shorter and escaped-longer keys don't match
        const t = test_factory.add(.{
            .name = "test-index-similar-keys",
            .input_dir = .no_input,
            .options = .{ .appdata = .{ .saved_index =
            \\{"master":{"0.99.0":{}},"0.99.0x":{},"0.99.":{},"0.\u00399.0.1":{}}
            } },
            .offline = true,
            .args = &.{ "0.99.0", "version" },
        });
        t.run.addCheck(.{ .expect_stderr_match = "can't check that zig 0.99.0 is a release" });
        t.run.expectExitCode(1);
    }
    {
        const t = test_factory.add(.{
            .name = "test-index-invalid",
            .input_dir = .no_input,
            .options = .{ .appdata = .{ .saved_index = "{\"0.1.0\":[" } },
            .offline = true,
            .args = &.{ "0.99.0", "version" },
        });
        t.run.addCheck(.{ .expect_stderr_match = "download-index.json' is invalid JSON (UnexpectedEndOfInput)" });
        t.run.expectExitCode(1);
    }

    // The mirror tests use a dev build that doesn't exist (ziglang.org deletes old ones) and
    // make ziglang.org unreachable, so they fail once anyzig falls back to it.
    const missing_dev_version = "0.15.0-dev.1+aaaaaaaaa";
    {
        // a 404 means the file likely doesn't exist, so anyzig tries ziglang.org rather than
        // every other mirror. Downloads are logged by default.
        const t = test_factory.add(.{
            .name = "test-mirror-not-found",
            .input_dir = .no_input,
            .options = .{ .appdata = .{ .default_verbosity = true, .mirror = .@"not-found" } },
            .args = &.{ missing_dev_version, "version" },
        });
        t.run.addCheck(.{ .expect_stderr_match = "anyzig: downloading zig-" });
        t.run.addCheck(.{ .expect_stderr_match = " from http://127.0.0.1:" });
        t.run.addCheck(.{ .expect_stderr_match = "trying ziglang.org instead of the other mirrors" });
        t.run.addCheck(.{ .expect_stderr_match = "anyzig: downloading https://ziglang.org/builds/zig-" });
        t.run.addCheck(.{ .expect_stderr_match = "fake mirror served 1 requests" });
        t.run.expectExitCode(1);
    }
    {
        // a mirror can't serve another signed file, i.e. an older version
        const t = test_factory.add(.{
            .name = "test-mirror-wrong-file",
            .input_dir = .no_input,
            .options = .{ .appdata = .{ .mirror = .@"wrong-file" } },
            .args = &.{ missing_dev_version, "version" },
        });
        t.run.addCheck(.{ .expect_stderr_match = "served the signature for 'zig-x86_64-linux-0.14.1.tar.xz' instead of 'zig-" });
        t.run.addCheck(.{ .expect_stderr_match = "no mirror could provide" });
        // both signatures, neither archive
        t.run.addCheck(.{ .expect_stderr_match = "fake mirror served 2 requests" });
        t.run.expectExitCode(1);
    }
    // the fake mirror only has the signature for this platform's archive
    if (b.graph.host.result.os.tag == .linux and b.graph.host.result.cpu.arch == .x86_64) {
        // the archive must match the signature
        const t = test_factory.add(.{
            .name = "test-mirror-bad-content",
            .input_dir = .no_input,
            .options = .{ .appdata = .{ .mirror = .@"bad-content" } },
            .args = &.{ "0.14.1", "version" },
        });
        t.run.addCheck(.{ .expect_stderr_match = "can't check that zig 0.14.1 is a release" });
        t.run.addCheck(.{ .expect_stderr_match = "served 'zig-x86_64-linux-0.14.1.tar.xz' with an invalid signature" });
        t.run.addCheck(.{ .expect_stderr_match = "fake mirror served 4 requests" });
        t.run.expectExitCode(1);
    }
    {
        // the saved community mirror list is used when ziglang.org is down, and its mirrors must be https
        const t = test_factory.add(.{
            .name = "test-saved-mirrors",
            .input_dir = .no_input,
            .options = .{ .appdata = .{ .saved_mirrors = &.{ "http://127.0.0.1:1/insecure", "https://127.0.0.1:1/saved" } } },
            .offline = true,
            .args = &.{ missing_dev_version, "version" },
        });
        t.run.addCheck(.{ .expect_stderr_match = "ignoring 'http://127.0.0.1:1/insecure'" });
        t.run.addCheck(.{ .expect_stderr_match = " from https://127.0.0.1:1/saved" });
        t.run.expectExitCode(1);
    }

    // Windows has no execve so anyzig runs zig as a child process, which must die with
    // anyzig (i.e. when an IDE or a CI timeout kills it), see the job in spawnWindows.
    if (b.graph.host.result.os.tag == .windows) {
        const t = test_factory.add(.{
            .name = "test-kill",
            .input_dir = .no_input,
            .options = .{ .appdata = .{} },
            .offline = true,
            .kill = true,
            .args = &.{},
        });
        t.run.expectExitCode(0);
        t.run.addCheck(.{ .expect_stderr_match = "died with anyzig" });
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
            \\.{
            \\    .minimum_zig_version = "0.13.0",
            \\    .zig_version = "0.14.0",
            \\}
            \\
        );
        const t = test_factory.add(.{
            .name = "test-zig-version",
            .input_dir = .{ .path = write_files.getDirectory() },
            .options = .nosetup,
            .args = &.{"version"},
        });
        t.run.expectStdOutEqual("0.14.0\n");
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

    if (opt.old_zig_builds) {
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
            t.run.addFileArg2(build_zig_12, .{ .make_absolute = true });
            t.run.expectStdOutEqual("0.12.0\n");
        }
        {
            const t = test_factory.add(.{
                .name = "test-build-file-0.13.0",
                .input_dir = .{ .path = write_files.getDirectory().path(b, "example-0.12.0") },
                .options = .nosetup,
                .args = &.{ "build", "--build-file" },
            });
            t.run.addFileArg2(build_zig_13, .{ .make_absolute = true });
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
        options: union(enum) {
            nosetup,
            badhash,
            /// Isolates the anyzig appdata directory in the output directory. Since the
            /// input directory is copied to the output directory, appdata state carries
            /// over to tests that use this test's output directory as their input.
            appdata: struct {
                /// don't set ANYZIG_VERBOSE, the tests check anyzig's info logs so it's set by default
                default_verbosity: bool = false,
                /// move this installed version to where older versions of anyzig installed
                /// it (zig's global cache) with a hashstore entry pointing to it
                legacy_install: ?[]const u8 = null,
                /// fail unless the legacy install of this version is still there
                expect_legacy_install: ?[]const u8 = null,
                /// delete this installed version
                uninstall: ?[]const u8 = null,
                /// delete only the exe of this installed version, leaving its directory
                remove_exe: ?[]const u8 = null,
                /// create install directories (i.e. "zig-0.14.0") like ones left behind by
                /// processes that died
                abandoned_installs: []const []const u8 = &.{},
                /// create install directories without a lock file
                lockless_installs: []const []const u8 = &.{},
                /// fail if any install directory is left
                expect_no_abandoned_installs: bool = false,
                /// overwrite a hashstore entry with invalid content before running
                corrupt_entry: ?struct { name: []const u8, content: enum { empty } } = null,
                /// set ANYZIG_MIRRORS to two mirrors served by a fake mirror (see MirrorMode in
                /// wrap.zig) and make ziglang.org unreachable
                mirror: ?enum { @"not-found", @"wrong-file", @"bad-content" } = null,
                /// save these as the community mirror list from a previous download
                saved_mirrors: []const []const u8 = &.{},
                /// save this as the official download index from a previous download
                saved_index: ?[]const u8 = null,
            },
        },
        /// Points the http proxies at a dead port so any attempt to use the network
        /// fails, i.e. to verify anyzig is using its cache.
        offline: bool = false,
        /// Runs this many instances at once, holding the lock of this install (i.e.
        /// "zig-0.14.0") until they're all waiting on it, then verifies exactly one of them
        /// installed it and the others used that install. Requires appdata.
        concurrent: ?struct { count: u8, install: []const u8 } = null,
        /// Runs anyzig from the filesystem root so it's outside any project.
        cwd_root: bool = false,
        /// Installs a fake zig that blocks on stdin, kills anyzig once it has started it and
        /// fails unless it dies too. Takes no args, requires appdata. Windows only.
        kill: bool = false,
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
        // Everything that affects the environment anyzig runs in is passed to wrap as an
        // argument (and wrap sets the environment) rather than set on the run step with
        // setEnvironmentVariable, because the run step's cache key includes its arguments
        // but not its environment variables.
        switch (args.options) {
            .nosetup => {},
            .badhash => run.addArg("--badhash"),
            .appdata => |appdata| {
                run.addArg("--appdata");
                if (appdata.default_verbosity) run.addArg("--default-verbosity");
                if (appdata.corrupt_entry) |entry| run.addArg(b.fmt(
                    "--corrupt-entry={s}:{s}",
                    .{ @tagName(entry.content), entry.name },
                ));
                if (appdata.legacy_install) |v| run.addArg(b.fmt("--legacy-install={s}", .{v}));
                if (appdata.expect_legacy_install) |v| run.addArg(b.fmt("--expect-legacy-install={s}", .{v}));
                if (appdata.uninstall) |v| run.addArg(b.fmt("--uninstall={s}", .{v}));
                if (appdata.remove_exe) |v| run.addArg(b.fmt("--remove-exe={s}", .{v}));
                if (appdata.abandoned_installs.len > 0) run.addArg(b.fmt(
                    "--abandoned-installs={s}",
                    .{std.mem.join(b.allocator, ",", appdata.abandoned_installs) catch @panic("OOM")},
                ));
                if (appdata.lockless_installs.len > 0) run.addArg(b.fmt(
                    "--lockless-installs={s}",
                    .{std.mem.join(b.allocator, ",", appdata.lockless_installs) catch @panic("OOM")},
                ));
                if (appdata.expect_no_abandoned_installs) run.addArg("--expect-no-abandoned-installs");
                if (appdata.mirror) |mode| run.addArg(b.fmt("--mirror={t}", .{mode}));
                if (appdata.saved_index) |content| run.addArg(b.fmt("--saved-index={s}", .{content}));
                if (appdata.saved_mirrors.len > 0) run.addArg(b.fmt(
                    "--saved-mirrors={s}",
                    .{std.mem.join(b.allocator, ",", appdata.saved_mirrors) catch @panic("OOM")},
                ));
            },
        }
        if (args.offline) run.addArg("--offline");
        if (args.concurrent) |c| run.addArg(b.fmt("--concurrent={}:{s}", .{ c.count, c.install }));
        if (args.kill) run.addArg("--kill");
        if (args.cwd_root) run.addArg("--cwd-root");
        run.addArg("--");
        // wrap changes the cwd, so paths are passed absolute
        run.addArtifactArg2(self.anyzig, .{ .make_absolute = true });
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
        return if (@backingInt(self) >= @backingInt(ZigRelease.@"0.12.0")) .simple else .exe_and_lib;
    }
    pub fn getVersionOutput(self: ZigRelease) []const u8 {
        return switch (self) {
            .@"2024.11.0-mach" => "0.14.0-dev.2577+271452d22",
            else => |release| @tagName(release),
        };
    }
};

fn addReleaseSteps(
    b: *std.Build,
    release_version: []const u8,
    release_version_embed: *std.Build.Module,
    zig_mod: *std.Build.Module,
    release_step: *std.Build.Step,
    host_zip_exe: *std.Build.Step.Compile,
) !void {
    const release_targets = [_][]const u8{
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

    const make_archive_step = b.step("archive", "Create release archives");
    const host_supported = builtin.os.tag == .linux and builtin.cpu.arch == .x86_64;
    if (host_supported) {
        release_step.dependOn(make_archive_step);
    } else {
        const fail = b.addFail(b.fmt(
            "releases can only be made on x86_64-linux but this host is {s}-{s}",
            .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) },
        ));
        release_step.dependOn(&fail.step);
        make_archive_step.dependOn(&fail.step);
    }

    for (release_targets) |release_target_str| {
        const target = b.resolveTargetQuery(try std.Target.Query.parse(
            .{ .arch_os_abi = release_target_str },
        ));
        const optimize: std.lang.Optimize = .safe;

        const target_dest_dir: std.Build.InstallDir = .{ .custom = release_target_str };

        const install_exes = b.step(b.fmt("install-{s}", .{release_target_str}), "");
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

        const target_test_step = b.step(b.fmt("test-{s}", .{release_target_str}), "");
        addTests(b, release_version, zig_exe, target_test_step, .{
            .make_build_steps = false,
            .old_zig_builds = true,
        });

        if (host_supported) {
            release_step.dependOn(install_exes);
            // only the native target's tests can be run
            const os_compatible = (builtin.os.tag == target.result.os.tag);
            const arch_compatible = (builtin.cpu.arch == target.result.cpu.arch);
            if (os_compatible and arch_compatible) {
                release_step.dependOn(target_test_step);
            }
            make_archive_step.dependOn(makeReleaseArchiveStep(b, "anyzig", release_target_str, target.result, zig_exe, host_zip_exe));
            make_archive_step.dependOn(makeReleaseArchiveStep(b, "anyzls", release_target_str, target.result, zls_exe, host_zip_exe));
        }
    }
}

/// Archives one exe (and its pdb on windows). zls is in its own anyzls archive so extracting
/// the anyzig archive never replaces a zls that isn't anyzig's.
fn makeReleaseArchiveStep(
    b: *std.Build,
    archive_prefix: []const u8,
    release_target_str: []const u8,
    target: std.Target,
    exe: *std.Build.Step.Compile,
    host_zip_exe: *std.Build.Step.Compile,
) *std.Build.Step {
    const stage = b.addWriteFiles();
    _ = stage.addCopyFile(exe.getEmittedBin(), exe.out_filename);

    if (target.os.tag == .windows) {
        const pdb = b.fmt("{s}.pdb", .{exe.name});
        _ = stage.addCopyFile(exe.getEmittedPdb(), pdb);
        const basename = b.fmt("{s}-{s}.zip", .{ archive_prefix, release_target_str });
        const zip = b.addRunArtifact(host_zip_exe);
        const out_zip_file = zip.addOutputFileArg2(basename, .{});
        zip.addArgs(&.{ exe.out_filename, pdb });
        zip.setCwd(stage.getDirectory());
        return &b.addInstallFile(out_zip_file, basename).step;
    }

    const basename = b.fmt("{s}-{s}.tar.gz", .{ archive_prefix, release_target_str });
    const tar = b.addSystemCommand(&.{ "tar", "-czf" });
    const targz = tar.addOutputFileArg2(basename, .{});
    tar.addArg(exe.out_filename);
    tar.setCwd(stage.getDirectory());
    return &b.addInstallFile(targz, basename).step;
}
