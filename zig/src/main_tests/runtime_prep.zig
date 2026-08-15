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

test "prepareCliRuntime loads defaults resources context and prompt templates" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/skills/reviewer");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/prompts");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/themes");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "faux",
        \\  "defaultModel": "faux-1",
        \\  "defaultThinkingLevel": "minimal",
        \\  "sessionDir": "~/sessions"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/settings.json",
        .data =
        \\{
        \\  "theme": "night"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/AGENTS.md",
        .data = "Project instructions from AGENTS.md",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/skills/reviewer/SKILL.md",
        .data =
        \\---
        \\description: Review code changes
        \\---
        \\Use the review checklist.
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/prompts/fix.md",
        .data = "Fix $ARGUMENTS please.",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/themes/night.json",
        .data =
        \\{
        \\  "name": "night",
        \\  "tokens": {
        \\    "assistant": { "fg": "cyan" }
        \\  }
        \\}
        ,
    });

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var args = try cli.parseArgs(allocator, &.{
        "--tools",
        "read,ls",
        "/fix parser bug",
    });
    defer args.deinit(allocator);

    const selected_tools = effectiveToolSelection(&args);
    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, selected_tools, false);
    defer prepared.deinit(allocator);

    try std.testing.expectEqualStrings("faux", prepared.provider_name);
    try std.testing.expectEqualStrings("faux-1", prepared.model_name.?);
    try std.testing.expectEqual(agent.ThinkingLevel.minimal, prepared.thinking_level);
    try std.testing.expectEqualStrings("night", prepared.resource_bundle.selectedTheme().name);
    try std.testing.expectEqual(@as(usize, 1), prepared.expanded_messages.len);
    try std.testing.expectEqualStrings("Fix parser bug please.", prepared.expanded_messages[0]);
    try std.testing.expect(prepared.context_files.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "Project instructions from AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "<available_skills>") != null);

    const expected_session_dir = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, "sessions" });
    defer allocator.free(expected_session_dir);
    try std.testing.expectEqualStrings(expected_session_dir, prepared.session_dir);
}

test "prepareCliRuntime appends repeatable CLI system prompts in order" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "faux",
        \\  "defaultModel": "faux-1"
        \\}
        ,
    });

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var args = try cli.parseArgs(allocator, &.{
        "--append-system-prompt",
        "First appended chunk.",
        "--append-system-prompt",
        "Second appended chunk.",
    });
    defer args.deinit(allocator);

    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, .{}, false);
    defer prepared.deinit(allocator);

    const first_index_opt = std.mem.indexOf(u8, prepared.system_prompt, "First appended chunk.");
    const second_index_opt = std.mem.indexOf(u8, prepared.system_prompt, "Second appended chunk.");
    try std.testing.expect(first_index_opt != null);
    try std.testing.expect(second_index_opt != null);
    try std.testing.expect(first_index_opt.? < second_index_opt.?);
}

test "prepareCliRuntime wires CLI resource overrides and discovery toggles" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/extensions");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/skills/default-reviewer");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/prompts");
    try tmp.dir.createDirPath(std.testing.io, "repo/.pi/themes");
    try tmp.dir.createDirPath(std.testing.io, "repo/cli-skills/reviewer");
    try tmp.dir.createDirPath(std.testing.io, "repo/cli-prompts");

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "faux",
        \\  "defaultModel": "faux-1",
        \\  "sessionDir": "~/sessions"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/settings.json",
        .data =
        \\{
        \\  "theme": "night"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/extensions/default-extension.ts",
        .data = "export default {};",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/skills/default-reviewer/SKILL.md",
        .data =
        \\---
        \\description: Default review skill
        \\---
        \\Use the default review checklist.
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/prompts/fix.md",
        .data = "Default fix $ARGUMENTS.",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.pi/themes/night.json",
        .data =
        \\{
        \\  "name": "night",
        \\  "tokens": {
        \\    "assistant": { "fg": "cyan" }
        \\  }
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/cli-extension.ts",
        .data = "export default {};",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/cli-skills/reviewer/SKILL.md",
        .data =
        \\---
        \\description: CLI review skill
        \\---
        \\Use the CLI review checklist.
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/cli-prompts/fix.md",
        .data = "CLI fix $ARGUMENTS.",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/cli-night.json",
        .data =
        \\{
        \\  "name": "night",
        \\  "tokens": {
        \\    "assistant": { "fg": "magenta" }
        \\  }
        \\}
        ,
    });

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var args = try cli.parseArgs(allocator, &.{
        "--no-extensions",
        "--extension",
        "cli-extension.ts",
        "--no-skills",
        "--skill",
        "cli-skills",
        "--no-prompt-templates",
        "--prompt-template",
        "cli-prompts",
        "--no-themes",
        "--theme",
        "cli-night.json",
        "/fix parser bug",
    });
    defer args.deinit(allocator);

    const selected_tools = effectiveToolSelection(&args);
    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, selected_tools, false);
    defer prepared.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), prepared.resource_bundle.extensions.len);
    try std.testing.expect(std.mem.indexOf(u8, prepared.resource_bundle.extensions[0].path, "cli-extension.ts") != null);
    try std.testing.expectEqual(@as(usize, 1), prepared.resource_bundle.skills.len);
    try std.testing.expectEqualStrings("reviewer", prepared.resource_bundle.skills[0].name);
    try std.testing.expectEqual(@as(usize, 1), prepared.resource_bundle.prompt_templates.len);
    try std.testing.expectEqualStrings("fix", prepared.resource_bundle.prompt_templates[0].name);
    try std.testing.expectEqual(@as(usize, 1), prepared.expanded_messages.len);
    try std.testing.expectEqualStrings("CLI fix parser bug.", prepared.expanded_messages[0]);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "CLI review skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "Default review skill") == null);
    try std.testing.expectEqualStrings("night", prepared.resource_bundle.selectedTheme().name);

    const styled = try prepared.resource_bundle.selectedTheme().applyAlloc(allocator, .assistant, "Pi:");
    defer allocator.free(styled);
    try std.testing.expectEqualStrings("Pi:", styled);
}

test "prepareCliRuntime skips context file discovery when requested" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.git");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{
        \\  "defaultProvider": "faux",
        \\  "defaultModel": "faux-1"
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/AGENTS.md",
        .data = "Project instructions from AGENTS.md",
    });

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var args = try cli.parseArgs(allocator, &.{
        "--no-context-files",
        "--verbose",
        "hello",
    });
    defer args.deinit(allocator);

    try std.testing.expect(args.verbose);

    const selected_tools = effectiveToolSelection(&args);
    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, selected_tools, false);
    defer prepared.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), prepared.context_files.len);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "Project instructions from AGENTS.md") == null);
}

test "prepareCliRuntime selects default model from configured api key" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/auth.json",
        .data =
        \\{
        \\  "kimi": { "type": "api_key", "key": "stored-kimi-key" }
        \\}
        ,
    });

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var args = try cli.parseArgs(allocator, &.{});
    defer args.deinit(allocator);

    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, .{}, false);
    defer prepared.deinit(allocator);

    try std.testing.expectEqualStrings("kimi", prepared.provider_name);
    try std.testing.expectEqualStrings("kimi-k2.6", prepared.model_name.?);
}

test "prepareCliRuntime selects kimi-coding from KIMI_API_KEY" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("KIMI_API_KEY", "kimi-key");

    var args = try cli.parseArgs(allocator, &.{});
    defer args.deinit(allocator);

    var prepared = try prepareCliRuntime(allocator, std.testing.io, &env_map, repo_dir, &args, .{}, false);
    defer prepared.deinit(allocator);

    try std.testing.expectEqualStrings("kimi-coding", prepared.provider_name);
    try std.testing.expectEqualStrings("kimi-for-coding", prepared.model_name.?);
}

test "resolvePreflightSessionDir prefers --session-dir over env and settings" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "explicit");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{ "sessionDir": "/tmp/should-be-ignored-by-cli-flag" }
        ,
    });

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);
    const explicit_dir = try cli_test.makeTmpPath(allocator, tmp, "explicit");
    defer allocator.free(explicit_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_SESSION_DIR", "/tmp/should-be-ignored-by-cli-flag-too");

    var args = try cli.parseArgs(allocator, &.{ "--session-dir", explicit_dir });
    defer args.deinit(allocator);

    const resolved = try runtime_prep.resolvePreflightSessionDir(allocator, std.testing.io, &env_map, repo_dir, &args);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(explicit_dir, resolved);
}

test "resolvePreflightSessionDir uses PI_CODING_AGENT_SESSION_DIR when no flag" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "envvar-sessions");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);
    const env_dir = try cli_test.makeTmpPath(allocator, tmp, "envvar-sessions");
    defer allocator.free(env_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_SESSION_DIR", env_dir);

    var args = try cli.parseArgs(allocator, &.{});
    defer args.deinit(allocator);

    const resolved = try runtime_prep.resolvePreflightSessionDir(allocator, std.testing.io, &env_map, repo_dir, &args);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(env_dir, resolved);
}

test "resolvePreflightSessionDir falls back to default cwd/.pi/sessions" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "repo");

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);

    var args = try cli.parseArgs(allocator, &.{});
    defer args.deinit(allocator);

    const resolved = try runtime_prep.resolvePreflightSessionDir(allocator, std.testing.io, &env_map, repo_dir, &args);
    defer allocator.free(resolved);
    const expected = try std.fs.path.join(allocator, &[_][]const u8{ repo_dir, ".pi", "sessions" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, resolved);
}

test "resolvePreflightSessionDir and effectiveSessionDir agree when env and settings both present" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "envvar-sessions");
    try tmp.dir.createDirPath(std.testing.io, "repo");
    // Settings sessionDir must NOT win when env is also present; both
    // resolvers must pick the env-derived directory.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home/.pi/agent/settings.json",
        .data =
        \\{ "sessionDir": "/tmp/should-be-ignored-by-env-var" }
        ,
    });

    const home_dir = try cli_test.makeTmpPath(allocator, tmp, "home");
    defer allocator.free(home_dir);
    const repo_dir = try cli_test.makeTmpPath(allocator, tmp, "repo");
    defer allocator.free(repo_dir);
    const env_dir = try cli_test.makeTmpPath(allocator, tmp, "envvar-sessions");
    defer allocator.free(env_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_SESSION_DIR", env_dir);

    var args = try cli.parseArgs(allocator, &.{});
    defer args.deinit(allocator);

    const preflight_resolved = try runtime_prep.resolvePreflightSessionDir(
        allocator,
        std.testing.io,
        &env_map,
        repo_dir,
        &args,
    );
    defer allocator.free(preflight_resolved);

    var runtime = try config_mod.loadRuntimeConfig(allocator, std.testing.io, &env_map, repo_dir);
    defer runtime.deinit();
    defer ai.model_registry.resetForTesting();

    const runtime_resolved = try runtime.effectiveSessionDir(allocator, &env_map, repo_dir);
    defer allocator.free(runtime_resolved);

    try std.testing.expectEqualStrings(env_dir, preflight_resolved);
    try std.testing.expectEqualStrings(env_dir, runtime_resolved);
    try std.testing.expectEqualStrings(preflight_resolved, runtime_resolved);
}
