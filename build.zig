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

    // plaza-signer: the isolated keyholder daemon. A SEPARATE binary from the
    // SDK app, built from the nostr library ALONE (no SDK), so the process that
    // holds the key links none of the UI's image or JSON parsers. Plaza spawns
    // it at launch and talks to it over loopback.
    addSigner(b, app.exe.root_module.resolved_target.?, app.exe.root_module.optimize.?);
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
        .optimize = mod.optimize.?,
    });
    mod.addImport("nostr", nostr.module("nostr"));
}
