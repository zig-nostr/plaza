//! The Signet ceremony window: a small, separate SDK app Plaza spawns for key
//! ceremonies (import, backup). Its own process, so a pasted key never enters
//! Plaza's UI process. Links nostr for validation and the signer_ipc wire
//! types; talks to plaza-signer over loopback.

const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("native_sdk", .{});
    const app = native_sdk.addAppArtifacts(b, dep, .{ .name = "signet-window" });
    linkNostr(b, app.exe.root_module);
    linkNostr(b, app.tests.root_module);
}

fn linkNostr(b: *std.Build, mod: *std.Build.Module) void {
    const nostr = b.dependency("nostr", .{
        .target = mod.resolved_target.?,
        .optimize = mod.optimize.?,
    });
    mod.addImport("nostr", nostr.module("nostr"));
}
