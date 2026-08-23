//! Plaza's build. `native eject` wrote the baseline, which drives the standard
//! app build through the framework's `addApp`. We extend it to link `nostr`
//! directly into the app process: `nostr` vendors secp256k1 + LMDB, so this is
//! what makes the one-process architecture, the local store opening in the
//! render process, real, rather than a second daemon reached over IPC.
//!
//! `addAppArtifacts` returns the app executable and the test compile. The exe
//! builds ReleaseFast and the tests build Debug, so each gets its own `nostr`
//! instance resolved for its own target and optimize mode.

const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("native_sdk", .{});
    const app = native_sdk.addAppArtifacts(b, dep, .{ .name = "plaza" });

    linkNostr(b, app.exe.root_module);
    linkNostr(b, app.tests.root_module);

    // The window's minimum width, handed to the tests from the manifest that
    // actually enforces it.
    //
    // The floor is a create-time property, so it can only live in app.zon; the
    // layout it has to accommodate only exists in Zig. Nothing connected the
    // two, and they drifted: the floor was set at 680 before the feed became a
    // virtualList, the list then reserved an 11px scrollbar gutter, and the
    // narrowest window the app allowed had been seven pixels too small to hold
    // its own content ever since. Passing the real number through means the
    // sweep in tests.zig measures against the constraint a person actually hits
    // when they drag the window in, rather than against a number typed twice.
    const floor = b.addOptions();
    floor.addOption(f32, "manifest_min_width", manifestWindowNumber(b, "min_width"));
    // The startup size too, for the same reason. These were typed again in Zig
    // as 760x760 beside a manifest that happened to say 760x760, and the app
    // needs the declared number at runtime to notice when it has been handed
    // something else (#100).
    floor.addOption(f32, "manifest_width", manifestWindowNumber(b, "width"));
    // And the version, for the same reason and with worse consequences: the one
    // in Zig said 0.1.0 while the app shipped as 0.2.2, so Settings told people
    // they were running something two releases old.
    floor.addOption([]const u8, "manifest_version", manifestVersion(b));
    floor.addOption(f32, "manifest_height", manifestWindowNumber(b, "height"));
    // BOTH modules, so app.zon is the one place the number lives. The scene
    // declares the same floor it does, and the sweep measures against it.
    app.exe.root_module.addOptions("window_floor", floor);
    app.tests.root_module.addOptions("window_floor", floor);

    // The vendored stb codecs: the canvas image registry decodes at most
    // 512x512 and has no downscaler, so Plaza decodes and resizes oversized
    // images itself before registering the pixels.
    //
    // Built once as a static library and linked into each artifact, so the exe
    // and the test binary both get the symbols exactly once. (Adding the C
    // source file to both root modules duplicated the object within one link.)
    const stb = b.addLibrary(.{
        .name = "stb",
        .root_module = b.createModule(.{ .target = app.exe.root_module.resolved_target.?, .optimize = .ReleaseFast, .link_libc = true }),
    });
    stb.root_module.addCSourceFile(.{ .file = b.path("src/stb_impl.c"), .flags = &.{"-O2"} });
    stb.root_module.addIncludePath(b.path("src"));
    app.exe.root_module.linkLibrary(stb);
    app.tests.root_module.linkLibrary(stb);

    // Receiving a `plaza://` link. The SDK registers the scheme (app.zon's
    // `.url_schemes` becomes CFBundleURLTypes) but delivers nothing: the macOS
    // host implements no inbound URL path at all, so Plaza installs its own
    // Apple Event handler. macOS-only, like the Keychain shim, and for the same
    // reason: there is no AppKit anywhere else.
    //
    // The EXE only. The test binary never receives an Apple Event and linking
    // AppKit into it would make the suite depend on a window server.
    if (app.exe.root_module.resolved_target.?.result.os.tag == .macos) {
        app.exe.root_module.addCSourceFile(.{ .file = b.path("src/urlscheme.m"), .flags = &.{ "-O2", "-fobjc-arc" } });
        // AppKit reaches Security.framework's headers, and those include
        // `libDER/DERItem.h`, which lives in the SDK's usr/include rather than
        // inside any framework. The signer build hit this first; same fix.
        const sdk_path = std.mem.trim(u8, b.run(&.{ "xcrun", "--show-sdk-path" }), " \r\n");
        app.exe.root_module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr/include" }) });
        app.exe.root_module.linkFramework("AppKit", .{});
    }

    // plaza-signer: the isolated keyholder daemon. A SEPARATE binary from the
    // SDK app, built from the nostr library ALONE (no SDK), so the process that
    // holds the key links none of the UI's image or JSON parsers. Plaza spawns
    // it at launch and talks to it over loopback.
    addSigner(b, app.exe.root_module.resolved_target.?, app.exe.root_module.optimize.?);
    addSeedFeed(b, app.exe.root_module.resolved_target.?);
}

/// Builds `seed-feed`, which fills a store with a fixed corpus so the frame
/// budget measures the same app twice. Library-only, like the signer: it wants
/// a store and nothing else.
fn addSeedFeed(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/seed_feed/main.zig"),
        .target = target,
        // Debug: it runs once before a measurement and is not measured itself.
        .optimize = .Debug,
        .link_libc = true,
    });
    linkNostr(b, mod);

    const exe = b.addExecutable(.{ .name = "seed-feed", .root_module = mod });
    // Deliberately NOT `b.installArtifact`.
    //
    // `scripts/package-macos.sh` puts whatever build.zig installs into the app
    // bundle, and derives that list rather than naming binaries, because naming
    // them by hand once shipped a release with no signer daemon in it. The same
    // rule read the other way: anything installed here is handed to everybody
    // who downloads Plaza. This one fabricates a feed to measure against, and
    // it went out in v0.3.0 and v0.4.0 doing nothing but taking up space in a
    // signed bundle.
    //
    // So it is built on request. `zig build seed-feed` puts it in zig-out/bin
    // for the harness; a plain `zig build` does not.
    const install = b.addInstallArtifact(exe, .{});
    b.step("seed-feed", "Build the fixed-corpus seeder that scripts/frame-budget.sh measures against")
        .dependOn(&install.step);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test-seed-feed", "Run the seed-feed tests").dependOn(&run_tests.step);
}

/// Builds the plaza-signer daemon and its test step. Library-only: it imports
/// nostr (secp256k1 + LMDB, hence libc) and nothing else.
fn addSigner(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/signer/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkNostr(b, mod);

    // The Keychain shim, and the frameworks behind it. Only the daemon links
    // this: it is the process that holds the key, and the render process has no
    // business being able to read it.
    // The SDK's framework directory, asked for rather than assumed. This module
    // is built plainly, without the `--sysroot` the app build passes, so Zig has
    // nowhere to look for Security.framework and says so ("searched paths:
    // none"). `xcrun` is how every other tool on this machine answers the same
    // question, and hardcoding a versioned SDK path would break on the next
    // Xcode update.
    if (target.result.os.tag == .macos) {
        // The whole shim is macOS-only, C file included. There is no Keychain
        // elsewhere, and the Zig side compiles its calls out on other targets
        // and falls back to the key file, which is what those platforms had
        // anyway. Adding the C unconditionally is what broke the Linux build:
        // `Security/Security.h` is not a header that exists there.
        mod.addCSourceFile(.{ .file = b.path("src/keychain.c"), .flags = &.{"-O2"} });
        mod.addIncludePath(b.path("src"));
        const sdk = std.mem.trim(u8, b.run(&.{ "xcrun", "--show-sdk-path" }), " \r\n");
        mod.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
        // And the SDK's headers: Security.framework's own headers include
        // `libDER/DERItem.h`, which lives in usr/include rather than inside the
        // framework. The app build gets this from `-isysroot`.
        mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
        mod.linkFramework("Security", .{});
        mod.linkFramework("CoreFoundation", .{});
    }

    const exe = b.addExecutable(.{ .name = "plaza-signer", .root_module = mod });
    b.installArtifact(exe);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const step = b.step("test-signer", "Run the plaza-signer daemon tests");
    step.dependOn(&run_tests.step);
}

/// Adds the `nostr` import to `mod`, compiling the library (and its bundled
/// secp256k1 + LMDB static libs) for the module's own target and optimize mode.
fn linkNostr(b: *std.Build, mod: *std.Build.Module) void {
    const nostr = b.dependency("nostr", .{
        .target = mod.resolved_target.?,
        .optimize = libraryOptimize(mod.optimize.?),
    });
    mod.addImport("nostr", nostr.module("nostr"));
}

/// The library is built one notch safer than the app that links it.
///
/// Zig's bounds, overflow and cast checks are compiled OUT of ReleaseFast, and
/// ReleaseFast is what ships. That is the right trade for the render thread and
/// the wrong one for `nostr`, because everything the library parses is bytes a
/// stranger chose: a relay's frames, an event's JSON, a tag, a bech32 string
/// pasted out of somebody's note. An index derived from a length field in that
/// input is exactly what a safety check is for.
///
/// So ReleaseFast gets a ReleaseSafe library, and Debug and ReleaseSafe are left
/// alone. Measured on this app, that costs nothing anybody can see: the frame
/// budget does not move, because parsing happens on the relay threads and the
/// render thread's own work is Plaza's code, not the library's. Building the
/// WHOLE app ReleaseSafe was measured too, and it is not free at all: rebuild
/// 290us to 852us, layout 1377us to 2650us, three budgets blown.
fn libraryOptimize(app: std.builtin.OptimizeMode) std.builtin.OptimizeMode {
    return switch (app) {
        .ReleaseFast, .ReleaseSmall => .ReleaseSafe,
        .Debug, .ReleaseSafe => app,
    };
}

/// The `.min_width` the manifest declares for the startup window.
///
/// Read rather than duplicated. A second copy of this number in Zig would be
/// one more thing to keep true, and keeping it true by hand is exactly what
/// failed here the first time. A malformed or missing declaration is a hard
/// error: silently defaulting would make the sweep that depends on it pass by
/// measuring against nothing.
/// Reads a numeric field off the startup window in `app.zon`.
///
/// The manifest is the one place these numbers live. Repeating any of them in
/// Zig is how the floor drifted seven pixels below what the layout needed and
/// stayed there: two numbers that must agree, with nothing connecting them.
/// The version string from `app.zon`, which is the one the packaged app carries.
fn manifestVersion(b: *std.Build) []const u8 {
    const text = b.build_root.handle.readFileAlloc(b.graph.io, "app.zon", b.allocator, .limited(1 << 20)) catch
        @panic("cannot read app.zon to find the app version");
    const key = ".version = \"";
    const at = std.mem.indexOf(u8, text, key) orelse @panic("app.zon declares no .version");
    const rest = text[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse @panic("app.zon's .version is not a string");
    if (end == 0) @panic("app.zon's .version is empty");
    return b.allocator.dupe(u8, rest[0..end]) catch @panic("OOM");
}

fn manifestWindowNumber(b: *std.Build, comptime field: []const u8) f32 {
    const text = b.build_root.handle.readFileAlloc(b.graph.io, "app.zon", b.allocator, .limited(1 << 20)) catch
        @panic("cannot read app.zon to size the startup window");
    const key = "." ++ field ++ " = ";
    const at = std.mem.indexOf(u8, text, key) orelse
        @panic("app.zon declares no ." ++ field ++ " for the startup window");
    var end = at + key.len;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    const digits = text[at + key.len .. end];
    if (digits.len == 0) @panic("app.zon's ." ++ field ++ " is not a number");
    const n = std.fmt.parseInt(u32, digits, 10) catch
        @panic("app.zon's ." ++ field ++ " is not a number");
    return @floatFromInt(n);
}
