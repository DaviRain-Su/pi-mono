import { describe, expect, test } from "vitest";
import { parseCommand } from "../src/cli/experimental/command.ts";

describe("parseCommand", () => {
	test("selects combined mode and preserves existing CLI arguments", () => {
		expect(
			parseCommand([
				"--cwd",
				"/workspace",
				"--provider=anthropic",
				"--model",
				"claude-sonnet",
				"--thinking=high",
				"inspect",
				"the project",
			]),
		).toEqual({
			ok: true,
			command: {
				command: "combined",
				remainingArgs: [
					"--cwd",
					"/workspace",
					"--provider=anthropic",
					"--model",
					"claude-sonnet",
					"--thinking=high",
					"inspect",
					"the project",
				],
			},
		});
	});

	test("parses repeatable server listeners and preserves other arguments", () => {
		expect(
			parseCommand([
				"server",
				"--listen",
				"unix:///tmp/pi.sock",
				"--listen=unix:///tmp/pi-admin.sock",
				"--model",
				"claude-sonnet",
			]),
		).toEqual({
			ok: true,
			command: {
				command: "server",
				listen: [
					{ transport: "unix", path: "/tmp/pi.sock" },
					{ transport: "unix", path: "/tmp/pi-admin.sock" },
				],
				remainingArgs: ["--model", "claude-sonnet"],
			},
		});
	});

	test("preserves existing option values that look like experimental options", () => {
		expect(parseCommand(["--system-prompt", "--listen", "unix:///tmp/pi.sock"])).toEqual({
			ok: true,
			command: {
				command: "combined",
				remainingArgs: ["--system-prompt", "--listen", "unix:///tmp/pi.sock"],
			},
		});
	});

	test("preserves experimental-looking arguments after the existing option prefix begins", () => {
		expect(
			parseCommand([
				"server",
				"--listen",
				"unix:///tmp/pi.sock",
				"--model",
				"claude-sonnet",
				"--listen=unix:///tmp/second.sock",
			]),
		).toEqual({
			ok: true,
			command: {
				command: "server",
				listen: [{ transport: "unix", path: "/tmp/pi.sock" }],
				remainingArgs: ["--model", "claude-sonnet", "--listen=unix:///tmp/second.sock"],
			},
		});
	});

	test("parses a client transport address", () => {
		expect(parseCommand(["client", "--connect", "unix:///tmp/pi.sock", "hello"])).toEqual({
			ok: true,
			command: {
				command: "client",
				connect: { transport: "unix", path: "/tmp/pi.sock" },
				remainingArgs: ["hello"],
			},
		});
	});

	test.each([
		[["--auth-token", "secret"], { type: "token", token: "secret" }],
		[["--auth-token-file", "/tmp/token"], { type: "file", path: "/tmp/token" }],
	] as const)("parses authentication source %j", (argv, auth) => {
		expect(parseCommand(argv)).toEqual({
			ok: true,
			command: { command: "combined", auth, remainingArgs: [] },
		});
	});

	test.each([[[]], [["server"]], [["client"]]] as const)(
		"permits omitted authentication for later environment/default resolution",
		(argv) => {
			expect(parseCommand(argv)).toEqual({
				ok: true,
				command: { command: argv[0] ?? "combined", remainingArgs: [] },
			});
		},
	);

	test("preserves unknown options, @file arguments, and the positional separator", () => {
		expect(parseCommand(["--unknown", "@prompt.md", "--", "--listen", "unix:///tmp/pi.sock"])).toEqual({
			ok: true,
			command: {
				command: "combined",
				remainingArgs: ["--unknown", "@prompt.md", "--", "--listen", "unix:///tmp/pi.sock"],
			},
		});
	});

	test.each([
		[
			["--auth-token", "secret", "--auth-token-file", "/tmp/token"],
			"--auth-token and --auth-token-file are mutually exclusive",
		],
		[["--auth-token", "first", "--auth-token", "second"], "--auth-token may only be specified once"],
		[
			["--auth-token-file", "/tmp/first", "--auth-token-file=/tmp/second"],
			"--auth-token-file may only be specified once",
		],
		[["--listen", "/tmp/pi.sock"], 'Invalid --listen address "/tmp/pi.sock"'],
		[["--listen", "ws://localhost:8080"], 'Unsupported --listen transport "ws:"'],
		[["--listen", "unix://relative.sock"], "Unix transport address must not include an authority"],
		[["--listen", "unix:///tmp/pi.sock?wrong=value"], 'Invalid --listen address "unix:///tmp/pi.sock?wrong=value"'],
		[["--listen", "unix:///tmp/pi.sock#fragment"], 'Invalid --listen address "unix:///tmp/pi.sock#fragment"'],
		[["--listen", "unix:/tmp/pi.sock"], 'Invalid --listen address "unix:/tmp/pi.sock"'],
		[["--listen", "unix:///tmp/%00pi.sock"], 'Invalid --listen address "unix:///tmp/%00pi.sock"'],
		[["client", "--listen", "unix:///tmp/pi.sock"], "--listen is only valid for combined or server mode"],
		[["server", "--connect", "unix:///tmp/pi.sock"], "--connect is only valid for client mode"],
		[["client", "--connect", "ws://localhost:8080"], 'Unsupported --connect transport "ws:"'],
		[["--listen"], "--listen requires a value"],
		[["--connect="], "--connect requires a value"],
	] as const)("rejects invalid experimental input %j", (argv, error) => {
		const result = parseCommand(argv);
		expect(result).toMatchObject({ ok: false });
		if (!result.ok) expect(result.errors).toContainEqual(expect.stringContaining(error));
	});

	test("reports independent experimental errors together", () => {
		expect(
			parseCommand([
				"client",
				"--listen",
				"ws://localhost:8080",
				"--auth-token",
				"secret",
				"--auth-token-file",
				"/tmp/token",
			]),
		).toEqual({
			ok: false,
			errors: [
				'Unsupported --listen transport "ws:"',
				"--auth-token and --auth-token-file are mutually exclusive",
				"--listen is only valid for combined or server mode",
			],
		});
	});

	test("treats command names after the first argument as existing CLI arguments", () => {
		expect(parseCommand(["--cwd", "/workspace", "server"])).toEqual({
			ok: true,
			command: { command: "combined", remainingArgs: ["--cwd", "/workspace", "server"] },
		});
	});
});
