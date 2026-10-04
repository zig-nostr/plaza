//! Tests of uploads.zig. Picture uploads: picking a file, preparing it, and sending it to a media server.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const nostr = @import("nostr");
const main = @import("../main.zig");
const painted = @import("../painted.zig");
const long_form = @import("../article.zig");
const theme = @import("../theme.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;

const harness = @import("../tests.zig");

// ---- from tests.zig
const findByText = harness.findByText;
const awaitUpload = harness.awaitUpload;
const blossom = harness.blossom;
const buildTree = harness.buildTree;
const countByLabel = harness.countByLabel;
const countTags = harness.countTags;
const findAnyText = harness.findAnyText;
const findAnyTextContaining = harness.findAnyTextContaining;
const findByLabel = harness.findByLabel;
const tagNamed = harness.tagNamed;
const writeTestPicture = harness.writeTestPicture;

test "a picture this app uploaded carries everything the uploader knew in its imeta" {
    // A reader fetching a picture learns its type from the server. Only an
    // uploader has the hash, the size, the dimensions and the blurhash before
    // anyone has fetched the file, and a note that leaves them out makes every
    // client that opens it lay the picture out blind.
    main.forgetUploadedForTest();
    defer main.forgetUploadedForTest();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const gpa = a.allocator();
    const sha = "ab" ** 32;
    main.rememberUploadedForTest("https://cdn.example/" ++ sha ++ ".png", "image/png", sha, 48211, 800, 600, "LEHV6nWB2yk8pyo0adR*.7kCMdnj", "A red door");

    const tags = main.contentTagsForTest(gpa, "look at this\nhttps://cdn.example/" ++ sha ++ ".png\n");
    const im = tagNamed(tags, "imeta") orelse return error.NoImetaTag;
    try testing.expectEqual(@as(usize, 8), im.len);
    try testing.expectEqualStrings("url https://cdn.example/" ++ sha ++ ".png", im[1]);
    try testing.expectEqualStrings("m image/png", im[2]);
    try testing.expectEqualStrings("x " ++ sha, im[3]);
    try testing.expectEqualStrings("size 48211", im[4]);
    try testing.expectEqualStrings("dim 800x600", im[5]);
    try testing.expectEqualStrings("blurhash LEHV6nWB2yk8pyo0adR*.7kCMdnj", im[6]);
    try testing.expectEqualStrings("alt A red door", im[7]);
    // And the reader of that note can use it: Plaza's own parser reads it back.
    const meta = main.imetaFor(tags, "https://cdn.example/" ++ sha ++ ".png");
    try testing.expectEqual(@as(u16, 800), meta.width);
    try testing.expectEqual(@as(u16, 600), meta.height);
    try testing.expectEqualStrings("A red door", meta.alt);
    try testing.expectEqual(@as(u32, 48211), meta.size);

    // An address with no extension is a picture here, because this app sent it;
    // anywhere else it is a link, and gets no tag.
    main.rememberUploadedForTest("https://cdn.example/" ++ sha, "image/webp", sha, 10, 0, 0, "", "");
    const bare = main.contentTagsForTest(gpa, "https://cdn.example/" ++ sha ++ " and https://other.example/page");
    try testing.expectEqual(@as(usize, 1), countTags(bare, "imeta"));
    const bare_im = tagNamed(bare, "imeta").?;
    try testing.expectEqualStrings("m image/webp", bare_im[2]);
    // Nothing unknown is written empty.
    try testing.expectEqual(@as(usize, 5), bare_im.len);
}

test "a picture goes from a chosen file to an address in the note, through the signer and over HTTP" {
    // The whole path on one thread of events: the file dialog (stood in for), the
    // worker that reads and cleans the file, the kind:24242 token signed by the
    // same stand-in keyholder every other test signs with, the send to a server
    // on loopback, and the address landing in the draft with its imeta.
    main.forgetBlossomForTest();
    main.forgetUploadedForTest();
    main.clearLastPublishedForTest();
    main.setIdentityForTest([_]u8{0x4a} ** 32);
    defer main.clearIdentityForTest();
    defer main.forgetBlossomForTest();
    defer main.forgetUploadedForTest();
    defer main.setPickPathForTest(null);
    defer main.dropUploadForTest();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();

    var extra = std.ArrayList(u8).empty;
    defer extra.deinit(testing.allocator);
    try blossomPngText(testing.allocator, &extra, "taken at 12.34N 56.78E");
    const path = try writeTestPicture("upload-test-note.png", 40, 30, extra.items);
    defer testing.allocator.free(path);

    const srv = try blossom.TestServer.start(testing.io, .accept, 2);
    defer srv.stop(testing.io);
    var url_buf: [64]u8 = undefined;
    const server_url = srv.url(&url_buf);
    main.setBlossomServersForTest(&.{server_url});

    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    model.draft_buffer.set("a good one");
    var fx: main.EffectsForTest = undefined;

    // Choosing the file reads it and stops. Nothing has been signed or sent.
    main.setPickPathForTest(path);
    main.update(&model, .{ .upload_pick = 0 }, &fx);
    try awaitUpload("ready");
    try testing.expectEqual(@as(usize, 0), srv.heads.load(.acquire));
    try testing.expectEqual(@as(usize, 0), srv.puts.load(.acquire));
    try testing.expect(!main.helperSignPendingForTest());

    // The card names the server before the press.
    const ready_tree = try buildTree(a.allocator(), &model);
    try testing.expect(findAnyTextContaining(ready_tree.root, "from your server list"));
    try testing.expect(findAnyTextContaining(ready_tree.root, "127.0.0.1"));
    try testing.expect(findAnyTextContaining(ready_tree.root, "upload-test-note.png"));
    try testing.expect(findAnyText(ready_tree.root, "Upload") != null);
    try testing.expect(findAnyTextContaining(ready_tree.root, "Location and camera details"));

    model.upload_alt_buffer.set("A square of nothing");
    main.update(&model, .upload_go, &fx);
    // The stand-in keyholder answers at once, so the token is already back.
    try testing.expectEqualStrings("signed", main.uploadStateForTest());
    main.driveUploadForTest(&model);
    try awaitUpload("sent");
    main.driveUploadForTest(&model);

    try testing.expectEqualStrings("none", main.uploadStateForTest());
    try testing.expectEqual(@as(usize, 1), srv.puts.load(.acquire));
    try testing.expect(srv.body_matches_header.load(.acquire));
    try testing.expect(srv.auth_ok.load(.acquire));
    // The file that was sent is the cleaned one: the text chunk with where it was
    // taken is not in it.
    try testing.expect(srv.body_len.load(.acquire) > 0);
    try testing.expect(!srv.body_has_text.load(.acquire));

    // The address is in the draft, after what was already there, and the whole
    // note's tags carry the picture's imeta.
    const draft = model.draft();
    try testing.expect(std.mem.startsWith(u8, draft, "a good one\nhttp://127.0.0.1:"));
    const tags = main.contentTagsForTest(a.allocator(), draft);
    const im = tagNamed(tags, "imeta") orelse return error.NoImetaTag;
    try testing.expect(std.mem.startsWith(u8, im[1], "url http://127.0.0.1:"));
    try testing.expectEqualStrings("m image/png", im[2]);
    try testing.expect(std.mem.startsWith(u8, im[3], "x "));
    try testing.expectEqual(@as(usize, 64 + 2), im[3].len);
    try testing.expectEqualStrings("dim 40x30", im[5]);
    try testing.expectEqualStrings("blurhash L00000fQfQfQfQfQfQfQfQfQfQfQ", im[6]);
    try testing.expectEqualStrings("alt A square of nothing", im[7]);
    // Nothing was published: the token is a credential, not a record.
    try testing.expect(main.lastPublishedForTest() == null);
}

fn blossomPngText(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    // A tEXt chunk, built by hand so the test does not depend on blossom.zig's
    // private helper.
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast("Comment\x00".len + text.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, "tEXt");
    try out.appendSlice(gpa, "Comment\x00");
    try out.appendSlice(gpa, text);
    var crc = std.hash.Crc32.init();
    crc.update("tEXt");
    crc.update("Comment\x00");
    crc.update(text);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    try out.appendSlice(gpa, &sum);
}

test "Post waits for the composer's picture, and a second pick never drops the first" {
    main.forgetBlossomForTest();
    main.setIdentityForTest([_]u8{0x4e} ** 32);
    defer main.clearIdentityForTest();
    defer main.forgetBlossomForTest();
    defer main.setPickPathForTest(null);
    defer main.dropUploadForTest();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const path = try writeTestPicture("upload-test-wait.png", 8, 8, "");
    defer testing.allocator.free(path);
    const srv = try blossom.TestServer.start(testing.io, .accept, 2);
    defer srv.stop(testing.io);
    var url_buf: [64]u8 = undefined;
    main.setBlossomServersForTest(&.{srv.url(&url_buf)});

    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    model.draft_buffer.set("look at this");
    var fx: main.EffectsForTest = undefined;

    // A picture chosen and not sent yet. Post is off, and Cmd+Enter, which
    // reaches the same message, is refused on the card.
    main.setPickPathForTest(path);
    main.update(&model, .{ .upload_pick = 0 }, &fx);
    try awaitUpload("ready");
    {
        const tree = try buildTree(a.allocator(), &model);
        const post = findByText(tree.root, .button, "Post") orelse return error.NoPost;
        try testing.expect(!canvas.semanticActions(post).press);
    }
    main.update(&model, .post, &fx);
    try testing.expect(model.composing);
    try testing.expectEqualStrings("look at this", model.draft());
    try testing.expect(main.postWaitsForTest());
    try testing.expect(findAnyTextContaining((try buildTree(a.allocator(), &model)).root, "Post waits for this picture."));

    // An avatar picked meanwhile, from the Edit profile sheet. The note's
    // picture stays, and the sheet says why nothing happened.
    var sheet = main.initialModel();
    sheet.stage = .settings;
    sheet.editing_profile = true;
    sheet.profile_stage = .have;
    main.update(&sheet, .{ .upload_pick = 1 }, &fx);
    try testing.expectEqualStrings("ready", main.uploadStateForTest());
    try testing.expect(main.postWaitsForTest());
    try testing.expect(main.pickRefusedForTest(1) != null);
    {
        const sheet_tree = try buildTree(a.allocator(), &sheet);
        try testing.expect(findAnyTextContaining(sheet_tree.root, "waiting in the composer"));
        // The introduction gives the note its room, or Save leaves the card at
        // the window's minimum height.
        try testing.expect(!findAnyTextContaining(sheet_tree.root, "Everything this app can read from a profile"));
    }

    // Uploading: still refused, and the card says until when.
    main.silenceTestSignerForTest(true);
    defer main.silenceTestSignerForTest(false);
    defer main.releaseHelperSignForTest();
    main.update(&model, .upload_go, &fx);
    try testing.expectEqualStrings("signing", main.uploadStateForTest());
    main.update(&model, .post, &fx);
    try testing.expect(model.composing);
    try testing.expectEqualStrings("look at this", model.draft());
    try testing.expect(findAnyTextContaining((try buildTree(a.allocator(), &model)).root, "Post waits until this picture is in your note."));
    // A pick while it uploads says so beside the control, not in a toast the
    // sheet covers.
    main.update(&sheet, .{ .upload_pick = 2 }, &fx);
    try testing.expect(findAnyTextContaining((try buildTree(a.allocator(), &sheet)).root, "still uploading"));

    // Put away, and Post is live again.
    main.update(&model, .upload_cancel, &fx);
    try testing.expect(main.pickRefusedForTest(1) == null);
    const tree = try buildTree(a.allocator(), &model);
    const post = findByText(tree.root, .button, "Post") orelse return error.NoPost;
    try testing.expect(canvas.semanticActions(post).press);
}

test "a refused pick is said only while its reason holds" {
    // The reason outlived the job that caused it: a send that ended failed left
    // "still uploading" beside a control that would now work, and closing and
    // reopening the sheet brought it back.
    main.forgetBlossomForTest();
    main.setIdentityForTest([_]u8{0x4f} ** 32);
    defer main.clearIdentityForTest();
    defer main.forgetBlossomForTest();
    defer main.setPickPathForTest(null);
    defer main.dropUploadForTest();
    const path = try writeTestPicture("upload-test-refused-pick.png", 8, 8, "");
    defer testing.allocator.free(path);
    const srv = try blossom.TestServer.start(testing.io, .refuse_put, 2);
    defer srv.stop(testing.io);
    var url_buf: [64]u8 = undefined;
    main.setBlossomServersForTest(&.{srv.url(&url_buf)});

    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    var sheet = main.initialModel();
    sheet.stage = .settings;
    sheet.editing_profile = true;
    sheet.profile_stage = .have;
    var fx: main.EffectsForTest = undefined;

    // The note's picture is on its way, so an avatar pick is refused.
    main.setPickPathForTest(path);
    main.update(&model, .{ .upload_pick = 0 }, &fx);
    try awaitUpload("ready");
    main.update(&model, .upload_go, &fx);
    main.update(&sheet, .{ .upload_pick = 1 }, &fx);
    try testing.expect(main.pickRefusedForTest(1) != null);

    // The send fails. Nothing is in the way any more.
    main.driveUploadForTest(&model);
    try awaitUpload("failed");
    try testing.expect(main.pickRefusedForTest(1) == null);

    // A picture waiting in the composer refuses the pick again, and the sheet
    // closing puts the reason away with it.
    main.update(&model, .upload_cancel, &fx);
    main.update(&model, .{ .upload_pick = 0 }, &fx);
    try awaitUpload("ready");
    main.update(&sheet, .{ .upload_pick = 1 }, &fx);
    try testing.expect(main.pickRefusedForTest(1) != null);
    main.update(&sheet, .close_profile_edit, &fx);
    try testing.expect(main.pickRefusedForTest(1) == null);

    // And opening it does too: the next sheet has not been refused anything.
    sheet.stage = .settings;
    sheet.editing_profile = true;
    main.update(&sheet, .{ .upload_pick = 1 }, &fx);
    try testing.expect(main.pickRefusedForTest(1) != null);
    main.update(&sheet, .open_profile_edit, &fx);
    try testing.expect(main.pickRefusedForTest(1) == null);
}

test "a failed upload keeps the draft, says why in plain words, and can be tried again" {
    main.forgetBlossomForTest();
    main.setIdentityForTest([_]u8{0x4b} ** 32);
    defer main.clearIdentityForTest();
    defer main.forgetBlossomForTest();
    defer main.setPickPathForTest(null);
    defer main.dropUploadForTest();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const path = try writeTestPicture("upload-test-fail.png", 8, 8, "");
    defer testing.allocator.free(path);

    const srv = try blossom.TestServer.start(testing.io, .refuse_put, 4);
    defer srv.stop(testing.io);
    var url_buf: [64]u8 = undefined;
    main.setBlossomServersForTest(&.{srv.url(&url_buf)});

    var model = main.initialModel();
    model.stage = .ready;
    model.composing = true;
    model.draft_buffer.set("words I must not lose");
    var fx: main.EffectsForTest = undefined;

    main.setPickPathForTest(path);
    main.update(&model, .{ .upload_pick = 0 }, &fx);
    try awaitUpload("ready");
    main.update(&model, .upload_go, &fx);
    main.driveUploadForTest(&model);
    try awaitUpload("failed");

    try testing.expectEqualStrings("words I must not lose", model.draft());
    try testing.expect(std.mem.indexOf(u8, main.uploadMessageForTest(), "payment required") != null);
    const tree = try buildTree(a.allocator(), &model);
    try testing.expect(findAnyTextContaining(tree.root, "payment required"));
    try testing.expect(findAnyText(tree.root, "Try again") != null);
    try testing.expect(findAnyText(tree.root, "Dismiss") != null);

    // Try again sends the same file with the same token: the signer is not
    // asked a second time for something it already approved.
    main.update(&model, .upload_retry, &fx);
    try testing.expectEqualStrings("signed", main.uploadStateForTest());
    main.driveUploadForTest(&model);
    try awaitUpload("failed");
    try testing.expectEqual(@as(usize, 2), srv.puts.load(.acquire));

    // A token is good for an hour. Once that is nearly over, Try again asks the
    // signer for a new one instead of sending one every server will refuse.
    main.ageUploadTokenForTest(blossom.auth_lifetime_s);
    main.silenceTestSignerForTest(true);
    defer main.silenceTestSignerForTest(false);
    defer main.releaseHelperSignForTest();
    main.update(&model, .upload_retry, &fx);
    try testing.expectEqualStrings("signing", main.uploadStateForTest());
    try testing.expect(main.helperSignPendingForTest());

    // Dismissing puts the card away and leaves the words.
    main.update(&model, .upload_cancel, &fx);
    try testing.expectEqualStrings("none", main.uploadStateForTest());
    try testing.expectEqualStrings("words I must not lose", model.draft());
}

test "choosing a file uploads nothing, and what is not a picture is refused by its bytes" {
    main.forgetBlossomForTest();
    main.setIdentityForTest([_]u8{0x4c} ** 32);
    defer main.clearIdentityForTest();
    defer main.setPickPathForTest(null);
    defer main.dropUploadForTest();
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = ".zig-cache/upload-test-notes.png", .data = "%PDF-1.7 a document that has been named like a picture" });

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.setPickPathForTest(".zig-cache/upload-test-notes.png");
    main.update(&model, .{ .upload_pick = 0 }, &fx);
    try awaitUpload("failed");
    try testing.expect(std.mem.indexOf(u8, main.uploadMessageForTest(), "not a picture") != null);
    try testing.expect(!main.helperSignPendingForTest());

    // A file that is not there.
    main.dropUploadForTest();
    main.setPickPathForTest(".zig-cache/upload-test-missing.png");
    main.update(&model, .{ .upload_pick = 0 }, &fx);
    try awaitUpload("failed");
    try testing.expect(std.mem.indexOf(u8, main.uploadMessageForTest(), "no longer there") != null);

    // A guest is not offered any of it.
    main.dropUploadForTest();
    main.clearIdentityForTest();
    var guest = main.initialModel();
    main.setPickPathForTest(".zig-cache/upload-test-notes.png");
    main.update(&guest, .{ .upload_pick = 0 }, &fx);
    try testing.expectEqualStrings("none", main.uploadStateForTest());
}

test "a token for some other file, or for more than this upload, is not accepted from a signer" {
    const sha = "cd" ** 32;
    const now: i64 = 1_700_000_000;
    const good = [_]nostr.event.Tag{ &.{ "t", "upload" }, &.{ "expiration", "1700003600" }, &.{ "x", sha } };
    try testing.expect(main.tokenNamesFileForTest(&good, sha, now));
    try testing.expect(!main.tokenNamesFileForTest(&good, "ef" ** 32, now));
    const wrong_purpose = [_]nostr.event.Tag{ &.{ "t", "delete" }, &.{ "expiration", "1700003600" }, &.{ "x", sha } };
    try testing.expect(!main.tokenNamesFileForTest(&wrong_purpose, sha, now));
    const no_file = [_]nostr.event.Tag{ &.{ "t", "upload" }, &.{ "expiration", "1700003600" } };
    try testing.expect(!main.tokenNamesFileForTest(&no_file, sha, now));
    // Wider than what was asked: a delete as well, or a second file.
    const also_delete = [_]nostr.event.Tag{ &.{ "t", "upload" }, &.{ "t", "delete" }, &.{ "expiration", "1700003600" }, &.{ "x", sha } };
    try testing.expect(!main.tokenNamesFileForTest(&also_delete, sha, now));
    const two_files = [_]nostr.event.Tag{ &.{ "t", "upload" }, &.{ "expiration", "1700003600" }, &.{ "x", sha }, &.{ "x", "ef" ** 32 } };
    try testing.expect(!main.tokenNamesFileForTest(&two_files, sha, now));
    // Good forever, already over, or good for a year.
    const no_expiry = [_]nostr.event.Tag{ &.{ "t", "upload" }, &.{ "x", sha } };
    try testing.expect(!main.tokenNamesFileForTest(&no_expiry, sha, now));
    const expired = [_]nostr.event.Tag{ &.{ "t", "upload" }, &.{ "expiration", "1699999999" }, &.{ "x", sha } };
    try testing.expect(!main.tokenNamesFileForTest(&expired, sha, now));
    const a_year = [_]nostr.event.Tag{ &.{ "t", "upload" }, &.{ "expiration", "1731536000" }, &.{ "x", sha } };
    try testing.expect(!main.tokenNamesFileForTest(&a_year, sha, now));
}

test "a new upload waits while a bunker still holds the token of one that was put away" {
    // A bunker takes several requests at once. A picture put away while its
    // token was out leaves that request live, and whatever comes back for it
    // would land on the next upload to start signing: a refusal would fail it,
    // and an approval would be for a different file.
    main.forgetBlossomForTest();
    main.setIdentityForTest([_]u8{0x57} ** 32);
    defer main.clearIdentityForTest();
    defer main.setPickPathForTest(null);
    defer main.dropUploadForTest();
    defer main.clearPendingForTest();
    defer main.setSignerKindLocalForTest();
    const path = try writeTestPicture("upload-test-outstanding.png", 8, 8, "");
    defer testing.allocator.free(path);

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.setPickPathForTest(path);
    main.update(&model, .{ .upload_pick = 0 }, &fx);
    try awaitUpload("ready");
    main.setRemotePubkeyForTest([_]u8{0x58} ** 32);
    main.setSignerKindForTest("remote");

    try testing.expect(main.registerPendingForTest("an-earlier-token", .sign_upload_auth, null));
    main.update(&model, .upload_go, &fx);
    try testing.expectEqualStrings("ready", main.uploadStateForTest());
    try testing.expect(std.mem.indexOf(u8, main.uploadMessageForTest(), "busy") != null);

    // Once that one has come back, the press goes through.
    _ = main.takePendingContentForTest("an-earlier-token");
    main.update(&model, .upload_go, &fx);
    try testing.expectEqualStrings("signing", main.uploadStateForTest());
}

test "a token from a remote signer reaches the upload and is never published" {
    // The bunker's answer arrives on the listener thread and is parked for the
    // tick; the same signed event is what the built-in keyholder returns.
    main.forgetBlossomForTest();
    main.setIdentityForTest([_]u8{0x4e} ** 32);
    defer main.clearIdentityForTest();
    defer main.setPickPathForTest(null);
    defer main.dropUploadForTest();
    defer main.silenceTestSignerForTest(false);
    defer main.releaseHelperSignForTest();
    main.forgetLastPublishedForTest();
    const path = try writeTestPicture("upload-test-remote.png", 8, 8, "");
    defer testing.allocator.free(path);

    var model = main.initialModel();
    model.stage = .ready;
    var fx: main.EffectsForTest = undefined;
    main.setPickPathForTest(path);
    main.update(&model, .{ .upload_pick = 0 }, &fx);
    try awaitUpload("ready");
    main.silenceTestSignerForTest(true);
    main.update(&model, .upload_go, &fx);
    try testing.expectEqualStrings("signing", main.uploadStateForTest());

    // What the bunker would return: this account's token, for this file.
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    var signer = nostr.keys.Signer.init();
    defer signer.deinit();
    const kp = try signer.keyPairFromSecretKey([_]u8{0x4e} ** 32);
    const sha = try uploadedFileSha(a.allocator(), path);
    const now = main.nowSecondsForTest();
    const tags = try blossom.authTags(a.allocator(), &sha, 0, now + blossom.auth_lifetime_s);
    const ev = try nostr.event.create(a.allocator(), signer, kp, now, blossom.auth_kind, tags, blossom.auth_content, null);
    main.parkUploadSignForTest(try nostr.event.toJson(a.allocator(), ev));
    main.driveUploadForTest(&model);
    try testing.expectEqualStrings("sending", main.uploadStateForTest());
    try testing.expect(main.lastPublishedForTest() == null);

    // And a bunker that answers with nothing usable ends the attempt.
    main.dropUploadForTest();
    main.releaseHelperSignForTest();
    main.setPickPathForTest(path);
    main.update(&model, .{ .upload_pick = 0 }, &fx);
    try awaitUpload("ready");
    main.update(&model, .upload_go, &fx);
    main.parkUploadSignForTest(null);
    main.driveUploadForTest(&model);
    try testing.expectEqualStrings("failed", main.uploadStateForTest());
}

/// The sha256 the app will compute for a test picture on disk (it has no
/// metadata to strip, so it is the file's own).
fn uploadedFileSha(gpa: std.mem.Allocator, path: []const u8) ![64]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(1 << 20));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "the avatar and the banner take the address into their own fields, and only those" {
    main.forgetBlossomForTest();
    main.setIdentityForTest([_]u8{0x50} ** 32);
    defer main.clearIdentityForTest();
    defer main.forgetBlossomForTest();
    defer main.setPickPathForTest(null);
    defer main.dropUploadForTest();
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const path = try writeTestPicture("upload-test-avatar.png", 16, 16, "");
    defer testing.allocator.free(path);
    const srv = try blossom.TestServer.start(testing.io, .accept, 4);
    defer srv.stop(testing.io);
    var url_buf: [64]u8 = undefined;
    main.setBlossomServersForTest(&.{srv.url(&url_buf)});

    var model = main.initialModel();
    model.stage = .settings;
    model.editing_profile = true;
    model.profile_stage = .have;
    model.profile_banner_buffer.set("https://old.example/banner.png");
    model.draft_buffer.set("untouched");
    var fx: main.EffectsForTest = undefined;

    // The sheet offers both, and the card stands where the field was.
    const before = try buildTree(a.allocator(), &model);
    try testing.expectEqual(@as(usize, 2), countByLabel(before.root, "Upload..."));
    main.setPickPathForTest(path);
    main.update(&model, .{ .upload_pick = 1 }, &fx);
    try awaitUpload("ready");
    const during = try buildTree(a.allocator(), &model);
    try testing.expectEqual(@as(usize, 1), countByLabel(during.root, "Upload..."));
    try testing.expect(findAnyTextContaining(during.root, "127.0.0.1"));
    // No description box for a profile picture: it has no imeta to put one in.
    try testing.expect(findByLabel(during.root, "Picture description") == null);

    main.update(&model, .upload_go, &fx);
    main.driveUploadForTest(&model);
    try awaitUpload("sent");
    main.driveUploadForTest(&model);
    try testing.expect(std.mem.startsWith(u8, model.profile_picture(), "http://127.0.0.1:"));
    try testing.expectEqualStrings("https://old.example/banner.png", model.profile_banner());
    try testing.expectEqualStrings("untouched", model.draft());
    // Not saved: that is its own press, and the sheet says so, because a field
    // with an address in it does not tell anyone the picture is not out yet.
    try testing.expect(main.lastPublishedForTest() == null);
    const filled = try buildTree(a.allocator(), &model);
    try testing.expect(findAnyTextContaining(filled.root, "not published until you press Save"));

    // Closing the sheet puts a picture still on its way away with it.
    main.update(&model, .{ .upload_pick = 2 }, &fx);
    try awaitUpload("ready");
    main.update(&model, .close_profile_edit, &fx);
    try testing.expectEqualStrings("none", main.uploadStateForTest());
    // Settings' own shortcut, pressed inside Settings, is not a way out of the
    // sheet: the picture on its way stays, and so does the sheet.
    model.editing_profile = true;
    main.update(&model, .{ .upload_pick = 1 }, &fx);
    try awaitUpload("ready");
    main.update(&model, .open_settings, &fx);
    try testing.expect(model.editing_profile);
    try testing.expectEqualStrings("ready", main.uploadStateForTest());
    main.update(&model, .close_profile_edit, &fx);
    try testing.expectEqualStrings("none", main.uploadStateForTest());
    // And reopening starts clean.
    main.update(&model, .open_profile_edit, &fx);
    try testing.expect(model.editing_profile);
    const reopened = try buildTree(a.allocator(), &model);
    try testing.expect(!findAnyTextContaining(reopened.root, "not published until you press Save"));
}

test "an upload's Cancel sits on the card's edge when it is the only button" {
    // The row used to hold a zero-width spacer where Upload goes, and a row
    // charges its gap for every child, so while a picture was on its way Cancel
    // stood 8pt in from where it stands beside Upload.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = main.Model{};

    const Build = struct {
        fn alone(ui: *main.AppUi) main.AppUi.Node {
            return main.uploadButtonsForTest(ui, false);
        }
        fn paired(ui: *main.AppUi) main.AppUi.Node {
            return main.uploadButtonsForTest(ui, true);
        }
    };
    const alone = try painted.Painted.renderPiece(arena, &model, Build.alone, 400, 100);
    const paired = try painted.Painted.renderPiece(arena, &model, Build.paired, 400, 100);
    const first_alone = firstButtonX(alone) orelse return error.NoButton;
    const first_paired = firstButtonX(paired) orelse return error.NoButton;
    try testing.expectApproxEqAbs(first_paired, first_alone, 0.01);
}

fn firstButtonX(p: painted.Painted) ?f32 {
    for (p.layout.nodes) |node| {
        if (node.widget.kind == .button) return node.widget.frame.x;
    }
    return null;
}
