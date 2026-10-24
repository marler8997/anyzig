# anyzig

A universal zig executable that lets you run any version of zig. Since you can only have one `zig` executable in your `PATH`, anyzig removes the limitation that this can only be one version. The version of zig to invoke is pulled from `build.zig.zon`, found by searching the current or any parent directory. anyzig reads the version from the `.minimum_zig_version` field, but will also read `.zig_version` and use that if present.

> `.zig_version` is [proposed](https://github.com/ziglang/zig/issues/23985) as a new property to build.zig.zon, for now, zig allows custom properties in build.zig.zon so anyzig supports it today.

Anytime a new zig version is needed, anyzig downloads and unpacks it into its own data directory (see [Where Compilers Are Installed](#where-compilers-are-installed)) using zig's own package fetching code (what `zig fetch` uses), modified to skip recompressing the package into a cache since anyzig keeps it unpacked.

In addition, you can also specify the version of zig to invoke by including it as the first argument, i.e.

```sh
$ zig 0.13.0 build-exe myproject.zig
$ zig 0.14.0-dev.3028+cdc9d65b0 build-exe mynewerproject.zig
```

Anyzig also adds a few of its own commands, which can be queried and invoked with `zig any ...`.

Set environment variable `ANYZIG_VERBOSE` to any non-empty value to enable verbose log output to stderr.

# Install

Go to https://marler8997.github.io/anyzig and select your OS/Arch to get a download link and/or instructions to install via the command-line.

Otherwise, you can manually find and download/extract the applicable archive from Releases. It will contain a single static binary named `zig`, unless you're on Windows in which case it's 2 files, `zig.exe` and `zig.pdb`. The `anyzls` archives are the same but contain anyzig's `zls` executable instead, they're separate so installing anyzig never replaces your own zls.

# Where Compilers Are Installed

Each version is installed to `APPDATA/zig/VERSION`, where `APPDATA` is:

| OS | APPDATA |
|---|---|
| Linux (and other POSIX) | `$XDG_DATA_HOME/anyzig`, or `~/.local/share/anyzig` if that isn't set |
| macOS | `~/Library/Application Support/anyzig` |
| Windows | `%LOCALAPPDATA%\anyzig` |

`zig any list-installed` lists the installed versions and where they are. A version only appears once it's fully installed, so it's safe to run multiple instances of anyzig at once. When several need the same new version, the first one installs it and the others wait for it.

Compilers from ziglang.org are downloaded from the [community mirrors](https://ziglang.org/download/community-mirrors/), tried in a random order, and each download's minisign signature is verified against the ZSF's public key, including that it signs the requested file. If no mirror can provide it, anyzig falls back to ziglang.org. anyzig fetches the mirror list from ziglang.org each time it downloads a compiler and saves it to `APPDATA/community-mirrors.txt`, which it uses when ziglang.org is down. Set `ANYZIG_MIRRORS` to a space-separated list of mirror URLs to use them, in order, instead of the community mirrors.

Older versions of anyzig installed compilers into zig's global cache (i.e. `~/.cache/zig/p/HASH`). When anyzig needs a version that one of those older versions installed, it copies it from there instead of downloading it again. It never modifies or deletes the old copy, since it lives in zig's cache.

# Mach Versions and Download Mirror

Mach is a game engine that provides a mirror to download the zig compiler as well as its own "nominated versions" (see https://machengine.org/docs/nominated-zig/). Mach versions use a different format (i.e. `2024.10.0-mach`) and always end with `-mach`, so, if anyzig sees a version that looks like this, it will know it's a mach version and that it needs to resolve it to a URL using mach's download index.  In addition, anyzig will also look for a `.mach_zig_version = "..."` property in your `build.zig.zon` file and use that instead of `.minimum_zig_version`.

> The reason for using `.mach_zig_version` instead of `.minimum_zig_version` is that in the future, zig will likely do some verification of the minimum_zig_version field and using a mach version there is likely to fail.

# anyzls

anyzig also has a `zls` executable ("anyzls") that stands in for the [zls](https://github.com/zigtools/zls) language server. It finds the project's zig version the same way `zig` does and runs a zls that's compatible with it.

Unlike zig, the zls for a zig version can't be determined from the version alone (i.e. zig 0.15.2 uses zls 0.15.1, and zig dev versions use zls dev builds with their own versions). The first time anyzls runs for a zig version it asks zigtools' [select-version](https://github.com/zigtools/release-worker) service which zls to use, downloads it, and saves that choice. After that it always runs the saved zls without any network access, even if a newer compatible zls has been published. Mach versions use the zig version from mach's download index.

Run `zls update` in a project to check for a newer compatible zls. If there is one, it's downloaded and used from then on (the old one is kept). Otherwise it reports that zls is up to date.

All other arguments (i.e. `--version`, `--config-path`) are passed to zls.

Installs are in `APPDATA/zls/ZLS_VERSION` and the zls saved for each zig version is in `APPDATA/zls-version/ZIG_VERSION` (see [Where Compilers Are Installed](#where-compilers-are-installed) for `APPDATA`).

To use it, download the `anyzls` archive for your OS/arch from Releases (or build it with `zig build install-zls`, which installs it to `zig-out/bin/zls`) and either put it in your `PATH` as `zls` or point your editor's zls path setting at it. Editors start zls in the project directory, which is where anyzls looks for `build.zig.zon`. If you use VS Code, the [Zig extension](https://github.com/ziglang/vscode-zig) already manages zls for you.

# TODO

- list the zig versions available to download, and a way to remove installed ones (`zig any list-installed` lists what's installed)
- anyzig should participate in zig build progress reporting especially if it needs to fetch a new compiler version (it passes `ZIG_PROGRESS` through to zig, but its own progress is a no-op because anyzig is single threaded)
