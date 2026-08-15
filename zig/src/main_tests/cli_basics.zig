const common = @import("common.zig");

const std = common.std;
const ai = common.ai;
const agent = common.agent;
const cli = common.cli;
const bootstrap = common.bootstrap;
const input_prep = common.input_prep;
const runtime_prep = common.runtime_prep;
const cli_test = common.cli_test;
const main = common.main;
const coding_agent = common.coding_agent;
const config_mod = common.config_mod;
const resources_mod = common.resources_mod;
const tools_common = common.tools_common;
const extension_runtime = common.extension_runtime;
const tool_adapters = common.tool_adapters;
const json_event_wire = common.json_event_wire;
const json_format = common.json_format;

const writeJsonStringValue = common.writeJsonStringValue;
const CliStdin = common.CliStdin;
const VERSION = common.VERSION;
const effectiveToolSelection = common.effectiveToolSelection;
const prepareCliRuntime = common.prepareCliRuntime;
const prepareEffectiveEnvMap = common.prepareEffectiveEnvMap;
const runCli = common.runCli;
const runCliWithInput = common.runCliWithInput;
const startupNetworkOperationsEnabled = common.startupNetworkOperationsEnabled;
const LifecyclePackageFixture = common.LifecyclePackageFixture;
const readSettingsPackageSources = common.readSettingsPackageSources;
const freeOwnedStringSlice = common.freeOwnedStringSlice;
const expectInstalledPackageSources = common.expectInstalledPackageSources;
const settingsWithInstalledPackagePolicies = common.settingsWithInstalledPackagePolicies;
const temporaryTypeScriptPolicyKey = common.temporaryTypeScriptPolicyKey;
const settingsWithTemporaryExtensionPolicies = common.settingsWithTemporaryExtensionPolicies;
const expectPackageConfigSources = common.expectPackageConfigSources;
const expectLoadedExtensionsMatchInstalledPackages = common.expectLoadedExtensionsMatchInstalledPackages;
const loadedExtensionForSource = common.loadedExtensionForSource;
const expectLoadedExtensionManifestMetadata = common.expectLoadedExtensionManifestMetadata;
const expectRegistrySnapshotsMatchLoadedPackages = common.expectRegistrySnapshotsMatchLoadedPackages;
const expectInstallLockSettingsMetadataMatchesLoadedRegistry = common.expectInstallLockSettingsMetadataMatchesLoadedRegistry;
const settingsPackageEntry = common.settingsPackageEntry;
const lockEntryForKey = common.lockEntryForKey;
const packageSnapshotForId = common.packageSnapshotForId;
const compositionNodeForPackageId = common.compositionNodeForPackageId;
const jsonArrayField = common.jsonArrayField;
const jsonObjectField = common.jsonObjectField;
const expectJsonStringFieldValue = common.expectJsonStringFieldValue;
const expectJsonFieldEqual = common.expectJsonFieldEqual;
const expectFileContains = common.expectFileContains;
const writeAbsoluteTestFile = common.writeAbsoluteTestFile;
const packagePolicyKey = common.packagePolicyKey;
const packageHostScript = common.packageHostScript;
const makeManifestSources = common.makeManifestSources;
const freeManifestSources = common.freeManifestSources;
const jsonObjectWithString = common.jsonObjectWithString;
const expectToolResultContainsMain = common.expectToolResultContainsMain;
const findToolByName = common.findToolByName;

test "main help text includes expected CLI options" {
    const allocator = std.testing.allocator;
    const help = try cli.helpText(allocator, VERSION);
    defer allocator.free(help);

    try std.testing.expect(std.mem.indexOf(u8, help, "--model <model>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--provider <provider>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--api-key <key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--thinking <level>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--continue, -c") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--resume, -r") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--session <id|path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--fork <id|path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--session-dir <dir>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-session") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--models <patterns>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--list-models [search]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--print, -p") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--mode, -mode <mode>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "rpc, json-rpc") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--tools, -t <names>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-tools, -nt") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-builtin-tools, -nbt") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--no-context-files, -nc") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--export <file>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--verbose") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--offline") != null);
}

test "effectiveToolSelection disables built-in tools when requested" {
    const allocator = std.testing.allocator;

    var no_builtin_args = try cli.parseArgs(allocator, &.{"--no-builtin-tools"});
    defer no_builtin_args.deinit(allocator);
    const no_builtin_selection = effectiveToolSelection(&no_builtin_args);
    try std.testing.expect(!no_builtin_selection.allowsBuiltin("read"));
    try std.testing.expect(no_builtin_selection.allowsExtension("ext-echo"));

    var explicit_args = try cli.parseArgs(allocator, &.{
        "--no-builtin-tools",
        "--tools",
        "read,ls",
    });
    defer explicit_args.deinit(allocator);
    const explicit_selection = effectiveToolSelection(&explicit_args);
    try std.testing.expect(!explicit_selection.allowsBuiltin("read"));
    try std.testing.expect(!explicit_selection.allowsBuiltin("ls"));
    try std.testing.expect(!explicit_selection.allowsExtension("ext-echo"));
    try std.testing.expect(explicit_selection.allowsExtension("read"));

    var app_context = coding_agent.interactive_mode.AppContext.init("/tmp", std.testing.io);
    var built_tools = try coding_agent.interactive_mode.buildAgentToolsWithSelection(allocator, &app_context, no_builtin_selection);
    defer built_tools.deinit();
    try std.testing.expectEqual(@as(usize, 0), built_tools.items.len);
}

test "startup network operations respect CLI offline flag and environment" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var default_args = try cli.parseArgs(allocator, &.{});
    defer default_args.deinit(allocator);
    try std.testing.expect(startupNetworkOperationsEnabled(&default_args, &env_map));

    var offline_args = try cli.parseArgs(allocator, &.{"--offline"});
    defer offline_args.deinit(allocator);
    try std.testing.expect(!startupNetworkOperationsEnabled(&offline_args, &env_map));

    try env_map.put("PI_OFFLINE", "true");
    try std.testing.expect(!startupNetworkOperationsEnabled(&default_args, &env_map));
}

test "prepareEffectiveEnvMap sets offline environment overrides" {
    const allocator = std.testing.allocator;

    var base_env_map = std.process.Environ.Map.init(allocator);
    defer base_env_map.deinit();
    try base_env_map.put("HOME", "/tmp/home");

    var offline_args = try cli.parseArgs(allocator, &.{"--offline"});
    defer offline_args.deinit(allocator);

    var effective_env_map = try prepareEffectiveEnvMap(allocator, &base_env_map, &offline_args);
    defer effective_env_map.deinit();

    try std.testing.expectEqualStrings("/tmp/home", effective_env_map.get("HOME").?);
    try std.testing.expectEqualStrings("1", effective_env_map.get("PI_OFFLINE").?);
    try std.testing.expectEqualStrings("1", effective_env_map.get("PI_SKIP_VERSION_CHECK").?);
    try std.testing.expect(base_env_map.get("PI_OFFLINE") == null);
    try std.testing.expect(base_env_map.get("PI_SKIP_VERSION_CHECK") == null);
}

test "prepareEffectiveEnvMap promotes PI_OFFLINE into PI_SKIP_VERSION_CHECK" {
    const allocator = std.testing.allocator;

    var base_env_map = std.process.Environ.Map.init(allocator);
    defer base_env_map.deinit();
    try base_env_map.put("PI_OFFLINE", "true");

    var default_args = try cli.parseArgs(allocator, &.{});
    defer default_args.deinit(allocator);

    var effective_env_map = try prepareEffectiveEnvMap(allocator, &base_env_map, &default_args);
    defer effective_env_map.deinit();

    try std.testing.expectEqualStrings("1", effective_env_map.get("PI_OFFLINE").?);
    try std.testing.expectEqualStrings("1", effective_env_map.get("PI_SKIP_VERSION_CHECK").?);
}

test "runCli lists models and applies optional search" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("ANTHROPIC_API_KEY", "anthropic-key");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--list-models", "sonnet" },
        "/tmp/project",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "provider") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "claude-sonnet-4-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout_capture.writer.buffered(), "gpt-5.4") == null);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "runCli prints faux response end to end" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "hello from cli");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--print", "hello" },
        "/tmp/project",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("hello from cli\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "runCli resolves provider-prefixed model without explicit provider" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "provider inferred");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--model", "faux/faux-1", "--print", "hello" },
        "/tmp/project",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("provider inferred\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "CLI positional messages remain separate through initial input prep" {
    const allocator = std.testing.allocator;

    var args = try cli.parseArgs(allocator, &.{ "first prompt", "second prompt", "third prompt" });
    defer args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), args.messages.?.len);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    var prepared_input = try input_prep.prepareInitialInput(
        allocator,
        std.testing.io,
        &env_map,
        "/tmp/project",
        null,
        args.messages.?,
        null,
        &stderr_capture.writer,
        .{},
    );
    defer prepared_input.deinit(allocator);

    try std.testing.expectEqualStrings("first prompt", prepared_input.prompt.?);
    try std.testing.expectEqual(@as(usize, 2), prepared_input.messages.len);
    try std.testing.expectEqualStrings("second prompt", prepared_input.messages[0]);
    try std.testing.expectEqualStrings("third prompt", prepared_input.messages[1]);
}

test "prepareCliRuntime resolves model thinking suffix" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var args = try cli.parseArgs(allocator, &.{ "--model", "faux/faux-1:high" });
    defer args.deinit(allocator);

    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, "/tmp/project", &args, .{}, false);
    defer prepared.deinit(allocator);

    try std.testing.expectEqualStrings("faux", prepared.provider_name);
    try std.testing.expectEqualStrings("faux-1", prepared.model_name.?);
    try std.testing.expectEqual(agent.ThinkingLevel.high, prepared.thinking_level);
    try std.testing.expect(prepared.model_error == null);
}

test "runCli auto-switches to print mode for piped stdin" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "hello from stdin");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var stdin_input = CliStdin{
        .is_tty = false,
        .content = "prompt from pipe",
    };

    const exit_code = try runCliWithInput(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux" },
        "/tmp/project",
        &stdin_input,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("hello from stdin\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
}

test "runCli exports session files to html and jsonl" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try cli_test.makeTmpPath(allocator, tmp, "cli-export");
    defer allocator.free(cwd);
    try std.Io.Dir.createDirAbsolute(std.testing.io, cwd, .default_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "export reply");

    var create_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer create_stdout.deinit();
    var create_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer create_stderr.deinit();

    const create_exit = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--print", "export prompt" },
        cwd,
        &create_stdout.writer,
        &create_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), create_exit);

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);

    const html_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "exported.html" });
    defer allocator.free(html_path);
    const jsonl_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "exported.jsonl" });
    defer allocator.free(jsonl_path);

    var html_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer html_stdout.deinit();
    var html_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer html_stderr.deinit();
    const html_exit = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--export", session_file, html_path },
        cwd,
        &html_stdout.writer,
        &html_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), html_exit);
    try std.testing.expect(std.mem.indexOf(u8, html_stdout.writer.buffered(), "Exported to:") != null);
    try std.testing.expectEqualStrings("", html_stderr.writer.buffered());

    const html_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, html_path, allocator, .limited(1024 * 1024));
    defer allocator.free(html_bytes);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "export prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "export reply") != null);

    var jsonl_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer jsonl_stdout.deinit();
    var jsonl_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer jsonl_stderr.deinit();
    const jsonl_exit = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--export", session_file, jsonl_path },
        cwd,
        &jsonl_stdout.writer,
        &jsonl_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), jsonl_exit);
    try std.testing.expectEqualStrings("", jsonl_stderr.writer.buffered());

    const exported_jsonl = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, jsonl_path, allocator, .limited(1024 * 1024));
    defer allocator.free(exported_jsonl);
    try std.testing.expect(std.mem.indexOf(u8, exported_jsonl, "\"export prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, exported_jsonl, "\"export reply\"") != null);
}

test "runCli injects @file text into the initial prompt" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try cli_test.makeTmpPath(allocator, tmp, "cli-file-text");
    defer allocator.free(cwd);
    try std.Io.Dir.createDirAbsolute(std.testing.io, cwd, .default_dir);
    const note_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "note.txt" });
    defer allocator.free(note_path);
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = note_path,
        .data = "alpha beta",
    });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "text file injected");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var stdin_input = CliStdin{};

    const exit_code = try runCliWithInput(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--print", "@note.txt", "Question?" },
        cwd,
        &stdin_input,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("text file injected\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);

    var manager = try coding_agent.SessionManager.open(allocator, std.testing.io, session_file, cwd);
    defer manager.deinit();

    var context = try manager.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    const user_text = context.messages[0].user.content[0].text.text;
    try std.testing.expect(std.mem.startsWith(u8, user_text, "<file name=\""));
    try std.testing.expect(std.mem.indexOf(u8, user_text, "alpha beta") != null);
    try std.testing.expect(std.mem.endsWith(u8, user_text, "</file>\nQuestion?"));
    try std.testing.expectEqualStrings("text file injected", context.messages[1].assistant.content[0].text.text);
}

test "runCli injects image file arguments into the initial prompt" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try cli_test.makeTmpPath(allocator, tmp, "cli-file-image");
    defer allocator.free(cwd);
    try std.Io.Dir.createDirAbsolute(std.testing.io, cwd, .default_dir);
    const image_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "screenshot.png" });
    defer allocator.free(image_path);
    // Minimal valid PNG (8-byte signature + IHDR for a 2x2 image). The M14
    // file_image processor reads dimensions from IHDR before attaching the
    // image; an unparseable header would trigger the deterministic omission
    // path instead.
    const minimal_png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d,
        0x24,
    };
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = image_path,
        .data = &minimal_png,
    });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "image file injected");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var stdin_input = CliStdin{};

    const exit_code = try runCliWithInput(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--print", "@screenshot.png", "Describe it" },
        cwd,
        &stdin_input,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("image file injected\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);

    var manager = try coding_agent.SessionManager.open(allocator, std.testing.io, session_file, cwd);
    defer manager.deinit();

    var context = try manager.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectEqual(@as(usize, 2), context.messages[0].user.content.len);
    const user_text = context.messages[0].user.content[0].text.text;
    try std.testing.expect(std.mem.startsWith(u8, user_text, "<file name=\""));
    try std.testing.expect(std.mem.endsWith(u8, user_text, "\"></file>\nDescribe it"));
    try std.testing.expectEqualStrings("image/png", context.messages[0].user.content[1].image.mime_type);
    try std.testing.expect(context.messages[0].user.content[1].image.data.len > 0);
    try std.testing.expectEqualStrings("image file injected", context.messages[1].assistant.content[0].text.text);
}

// VAL-M14-IMAGE-008: when the file_image processor cannot resize an image
// below the inline byte limit, the CLI must omit the attachment and inject
// the deterministic omission text into the user message instead. Regression
// for the M14 file image normalization parity surface.
test "runCli omits oversized image with deterministic message when processor returns null" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try cli_test.makeTmpPath(allocator, tmp, "cli-file-image-omit");
    defer allocator.free(cwd);
    try std.Io.Dir.createDirAbsolute(std.testing.io, cwd, .default_dir);
    const image_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "huge.png" });
    defer allocator.free(image_path);
    // Valid PNG header reporting 8000x8000 dimensions; well above the
    // default 2000x2000 max so the default processor returns null.
    const huge_png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x1f, 0x40, 0x00, 0x00, 0x1f, 0x40,
        0x08, 0x06, 0x00, 0x00, 0x00,
    };
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = image_path,
        .data = &huge_png,
    });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "ack");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var stdin_input = CliStdin{};

    const exit_code = try runCliWithInput(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--print", "@huge.png", "what is this" },
        cwd,
        &stdin_input,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);

    var manager = try coding_agent.SessionManager.open(allocator, std.testing.io, session_file, cwd);
    defer manager.deinit();
    var context = try manager.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectEqual(@as(usize, 1), context.messages[0].user.content.len);
    const user_text = context.messages[0].user.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, user_text, "[Image omitted: could not be resized below the inline image size limit.]") != null);
    try std.testing.expect(std.mem.endsWith(u8, user_text, "what is this"));
}

// VAL-M14-IMAGE-010: when `images.autoResize` is set to `false` in
// settings.json the file image is attached without dimension/byte gating,
// even when the default processor would otherwise omit it. Mirrors TS
// `processFileArguments({ autoResizeImages: false })`.
test "runCli respects images.autoResize=false and attaches oversized image bytes" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try cli_test.makeTmpPath(allocator, tmp, "cli-file-image-no-resize");
    defer allocator.free(cwd);
    try std.Io.Dir.createDirAbsolute(std.testing.io, cwd, .default_dir);
    const project_pi = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi" });
    defer allocator.free(project_pi);
    try std.Io.Dir.createDirAbsolute(std.testing.io, project_pi, .default_dir);
    const project_settings = try std.fs.path.join(allocator, &[_][]const u8{ project_pi, "settings.json" });
    defer allocator.free(project_settings);
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = project_settings,
        .data = "{\"images\":{\"autoResize\":false}}",
    });

    const image_path = try std.fs.path.join(allocator, &[_][]const u8{ cwd, "huge.png" });
    defer allocator.free(image_path);
    const huge_png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x1f, 0x40, 0x00, 0x00, 0x1f, 0x40,
        0x08, 0x06, 0x00, 0x00, 0x00,
    };
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = image_path,
        .data = &huge_png,
    });

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_FAUX_RESPONSE", "noresize");

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    var stdin_input = CliStdin{};

    const exit_code = try runCliWithInput(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--provider", "faux", "--print", "@huge.png", "describe" },
        cwd,
        &stdin_input,
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);

    const session_dir = try std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "sessions" });
    defer allocator.free(session_dir);
    const session_file = (try coding_agent.session_manager.findMostRecentSession(allocator, std.testing.io, session_dir)).?;
    defer allocator.free(session_file);

    var manager = try coding_agent.SessionManager.open(allocator, std.testing.io, session_file, cwd);
    defer manager.deinit();
    var context = try manager.buildSessionContext(allocator);
    defer context.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), context.messages[0].user.content.len);
    try std.testing.expectEqualStrings("image/png", context.messages[0].user.content[1].image.mime_type);
    const user_text = context.messages[0].user.content[0].text.text;
    try std.testing.expect(std.mem.indexOf(u8, user_text, "[Image omitted") == null);
    try std.testing.expect(std.mem.endsWith(u8, user_text, "describe"));
}

test "cli executable print mode writes assistant text to stdout without interactive escape codes" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var result = try cli_test.runCliExecutable(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--print", "hello" },
        &.{.{ "PI_FAUX_RESPONSE", "hello from cli binary" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("hello from cli binary\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(!cli_test.hasAnsiEscape(result.stdout));
    try std.testing.expect(!cli_test.hasAnsiEscape(result.stderr));
}

test "cli executable print mode json writes valid JSON lines to stdout" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var result = try cli_test.runCliExecutable(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--mode", "json", "--print", "hello" },
        &.{.{ "PI_FAUX_RESPONSE", "json from cli binary" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(!cli_test.hasAnsiEscape(result.stdout));

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var line_count: usize = 0;
    var saw_agent_start = false;
    var saw_agent_end = false;
    var saw_response_text = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();

        try json_event_wire.validateAgentEventJson(allocator, parsed.value);

        const event_type = parsed.value.object.get("type").?.string;
        if (std.mem.eql(u8, event_type, "agent_start")) saw_agent_start = true;
        if (std.mem.eql(u8, event_type, "agent_end")) saw_agent_end = true;
        if (std.mem.indexOf(u8, line, "json from cli binary") != null) saw_response_text = true;
    }

    try std.testing.expect(line_count >= 3);
    try std.testing.expect(saw_agent_start);
    try std.testing.expect(saw_agent_end);
    try std.testing.expect(saw_response_text);
}

test "cli executable --mode rpc uses TS-compatible JSONL get_state" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var result = try cli_test.runCliExecutableWithInput(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--no-session", "--mode", "rpc" },
        "{\"id\":\"state\",\"type\":\"get_state\"}\n",
        &.{},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(!cli_test.hasAnsiEscape(result.stdout));
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"id\":\"state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"type\":\"response\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"command\":\"get_state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"jsonrpc\"") == null);
}

test "cli executable -mode rpc uses TS-compatible JSONL get_state" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var result = try cli_test.runCliExecutableWithInput(
        allocator,
        tmp,
        &.{ "--provider", "faux", "--no-session", "-mode", "rpc" },
        "{\"id\":\"state_short\",\"type\":\"get_state\"}\n",
        &.{},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expect(!cli_test.hasAnsiEscape(result.stdout));
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"id\":\"state_short\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"type\":\"response\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"command\":\"get_state\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"jsonrpc\"") == null);
}

test "runCli rejects conflicting fork flags" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--fork", "session-123", "--resume", "--print", "hello" },
        "/tmp/project",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings("", stdout_capture.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), "--fork cannot be combined") != null);
}

test "runCli rejects prompt arguments in RPC modes before runtime routing" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const cases = [_][]const u8{ "rpc", "ts-rpc" };
    for (cases) |mode| {
        var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
        defer stdout_capture.deinit();
        var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
        defer stderr_capture.deinit();

        const exit_code = try runCli(
            allocator,
            std.testing.io,
            &env_map,
            &.{ "--mode", mode, "hello" },
            "/tmp/project",
            &stdout_capture.writer,
            &stderr_capture.writer,
        );

        try std.testing.expectEqual(@as(u8, 1), exit_code);
        try std.testing.expectEqualStrings("", stdout_capture.writer.buffered());
        try std.testing.expectEqualStrings("Error: Prompt arguments are not supported in RPC mode\n", stderr_capture.writer.buffered());
    }
}

test "runCli rejects file arguments in RPC modes before runtime routing" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    const cases = [_][]const u8{ "rpc", "ts-rpc" };
    for (cases) |mode| {
        var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
        defer stdout_capture.deinit();
        var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
        defer stderr_capture.deinit();

        const exit_code = try runCli(
            allocator,
            std.testing.io,
            &env_map,
            &.{ "--mode", mode, "@missing.txt" },
            "/tmp/project",
            &stdout_capture.writer,
            &stderr_capture.writer,
        );

        try std.testing.expectEqual(@as(u8, 1), exit_code);
        try std.testing.expectEqualStrings("", stdout_capture.writer.buffered());
        try std.testing.expectEqualStrings("Error: @file arguments are not supported in RPC mode\n", stderr_capture.writer.buffered());
    }
}

test "runCli rejects unregistered unknown long flag with sanitized diagnostic" {
    const allocator = std.testing.allocator;

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try runCli(
        allocator,
        std.testing.io,
        &env_map,
        &.{ "--bogus-flag", "--print", "hello" },
        "/tmp/project",
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings("", stdout_capture.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.writer.buffered(), "Unknown option: --bogus-flag") != null);
}
