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
    // Added to the exe module ONLY. `addAppArtifacts` builds the test compile
    // from the same root module, so adding the C source to both appends it
    // twice and every stb symbol collides at link time.
    app.exe.root_module.addCSourceFile(.{ .file = b.path("src/stb_impl.c"), .flags = &.{"-O2"} });
    app.exe.root_module.addIncludePath(b.path("src"));
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
