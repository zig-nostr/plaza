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
    floor.addOption(f32, "manifest_min_width", manifestMinWidth(b));
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

/// The `.min_width` the manifest declares for the startup window.
///
/// Read rather than duplicated. A second copy of this number in Zig would be
/// one more thing to keep true, and keeping it true by hand is exactly what
/// failed here the first time. A malformed or missing declaration is a hard
/// error: silently defaulting would make the sweep that depends on it pass by
/// measuring against nothing.
fn manifestMinWidth(b: *std.Build) f32 {
    const text = b.build_root.handle.readFileAlloc(b.graph.io, "app.zon", b.allocator, .limited(1 << 20)) catch
        @panic("cannot read app.zon to find the window's minimum width");
    const key = ".min_width = ";
    const at = std.mem.indexOf(u8, text, key) orelse
        @panic("app.zon declares no .min_width for the startup window");
    var end = at + key.len;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    const digits = text[at + key.len .. end];
    if (digits.len == 0) @panic("app.zon's .min_width is not a number");
    const n = std.fmt.parseInt(u32, digits, 10) catch
        @panic("app.zon's .min_width is not a number");
    return @floatFromInt(n);
}
