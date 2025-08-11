# anyzig



A universal zig executable that lets you run any version of zig. Since you can only have one `zig` executable in your `PATH`, anyzig removes the limitation that this can only be one version. The version of zig to invoke is pulled from the `minimum_zig_version` field of `build.zig.zon`. `build.zig.zon` is found by searching the current or any parent directory.

Anytime a new zig version is needed, anyzig will invoke the equivalent of `zig fetch ZIG_DOWNLOAD_URL` to download it into the global cache.

In addition, you can also specify the version of zig to invoke by including it as the first argument, i.e.

```sh
$ zig 0.13.0 build-exe myproject.zig
$ zig 0.14.0-dev.3028+cdc9d65b0 build-exe mynewerproject.zig
```

Anyzig also adds a few of its own commands, which can be queried and invoked with `zig any ...`.

# Install

Go to https://marler8997.github.io/anyzig and select your OS/Arch to get a download link and/or instructions to install via the command-line.

You can also install anyzig using Homebrew:
```bash
brew tap matrixfurry.com/zig https://tangled.sh/@matrixfurry.com/homebrew-zig
brew install anyzig
```

Otherwise, you can manually find and download/extract the applicable archive from Releases. It will contain a single static binary named `zig`, unless you're on Windows in which case it's 2 files, `zig.exe` and `zig.pdb`.

# Mach Versions and Download Mirror

Mach is a game engine that provides a mirror to download the zig compiler as well as its own "nominated versions" (see https://machengine.org/docs/nominated-zig/). Mach versions use a different format (i.e. `2024.10.0-mach`) and always end with `-mach`, so, if anyzig sees a version that looks like this, it will know it's a mach version and that it needs to resolve it to a URL using mach's download index.  In addition, anyzig will also look for a `.mach_zig_version = "..."` property in your `build.zig.zon` file and use that instead of `.minimum_zig_version`.

> The reason for using `.mach_zig_version` instead of `.minimum_zig_version` is that in the future, zig will likely do some verification of the minimum_zig_version field and using a mach version there is likely to fail.

# TODO

- provide a mechanism to list all available zig versions, maybe a way to clean them?
- anyzig should participate in zig build progress reporting especially if it needs to fetch a new compiler version
- make it easy to configure anyzig and share that configuration accross machines
- add a "hook" concept that allows the user to run a command for every new version of zig. anyzig should also track anytime it has run a hook for a new version of zig so that if a hook is added, it will re-run that hook for all existing zig versions.  Maybe also just add a "symlinks" directory option that anyzig will create symlinks for each compiler version.
- add a configuration option to configure whether anyzig should try mach's download mirror or the official download links first

# Notes

> NOTE: is there any reason to support an alternative mechanism to declare which version of zig to use?

> NOTE: should we have a command to override the minimum_zig_version in the zon file?

> NOTE: If there is no `build.zig.zon`, anyzig could try to use a set of heuristics to determine which version of zig should be used.  Once it's determined, it could create a `build.zig.zon` file (or alternative) and save the version there.

> NOTE: It might be worth trying to detect if anyzig is being run by a user interactively and query the user to enter a version or choose a setting when the version is ambiguous and/or there's some decision to be made.  For example, if a user just runs `zig init` without a version, it *could* be interesting to query them for the version instead of exiting with an error.
