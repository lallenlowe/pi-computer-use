/**
 * apple_script tool — runs an AppleScript via osascript and returns
 * structured stdout/stderr along with frontmost-app drift detection.
 *
 * Why this exists: many Mac apps (Messages, Mail, Notes, Music, Safari,
 * Finder, …) expose AppleScript dictionaries that drive operations cleanly
 * via Apple Events. Apple Events are delivered to the target process
 * directly and do not raise the target window or change frontmost — same
 * mechanical guarantee as event.postToPid for keypresses. That makes
 * AppleScript a stealth-safe fallback for things AX can't do (e.g.
 * Messages.app's composer accepts AX setValue but its Send button is
 * gated on UITextInput change notifications that AX setValue does not
 * fire — AppleScript `send X to chat Y` is the canonical workaround).
 *
 * Stealth contract: we read frontmost before/after the script and report
 * any drift. If config.apple_script.restore_frontmost_on_drift is true
 * (default) and drift is detected, we attempt to re-activate the original
 * frontmost via NSWorkspace's URL-launch path (osascript `activate`).
 * Drift is still reported in the result so the model knows.
 */

import { execFile } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import type {
	AgentToolResult,
	AgentToolUpdateCallback,
	ExtensionContext,
} from "@earendil-works/pi-coding-agent";

import { getAppleScriptConfig, getComputerUseConfig } from "./config.ts";

const execFileAsync = promisify(execFile);

export interface AppleScriptParams {
	script: string;
	app?: string;
	timeoutMs?: number;
}

export interface AppleScriptDetails {
	tool: "apple_script";
	app?: string;
	exitCode: number;
	stdout: string;
	stderr: string;
	durationMs: number;
	timedOut: boolean;
	frontmostBefore?: string;
	frontmostAfter?: string;
	frontmostDrifted: boolean;
	restoreAttempted: boolean;
	restoreSucceeded?: boolean;
	stealthMode: boolean;
	config: {
		browser_use: boolean;
		stealth_mode: boolean;
	};
}

const READ_FRONTMOST_SCRIPT =
	'tell application "System Events" to get name of first application process whose frontmost is true';

async function readFrontmost(timeoutMs: number, signal?: AbortSignal): Promise<string | undefined> {
	try {
		const { stdout } = await execFileAsync("osascript", ["-e", READ_FRONTMOST_SCRIPT], {
			timeout: timeoutMs,
			signal,
			encoding: "utf8",
		});
		const value = stdout.trim();
		return value.length > 0 ? value : undefined;
	} catch {
		return undefined;
	}
}

async function activateApp(appName: string, timeoutMs: number, signal?: AbortSignal): Promise<boolean> {
	if (!appName) return false;
	// Re-activate the original frontmost app. This is intentionally NOT
	// stealth-clean — we are restoring user state after a script that drifted.
	const escaped = appName.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
	const script = `tell application "${escaped}" to activate`;
	try {
		await execFileAsync("osascript", ["-e", script], {
			timeout: timeoutMs,
			signal,
			encoding: "utf8",
		});
		return true;
	} catch {
		return false;
	}
}

interface ExecResult {
	exitCode: number;
	stdout: string;
	stderr: string;
	timedOut: boolean;
}

async function runAppleScript(scriptBody: string, timeoutMs: number, signal?: AbortSignal): Promise<ExecResult> {
	// Write to a temp file rather than passing -e, so multi-line scripts and
	// embedded quotes work without shell-escaping. osascript reads the file
	// path argument as a script when no -e flag is present.
	const dir = await mkdtemp(path.join(tmpdir(), "pi-apple-script-"));
	const scriptPath = path.join(dir, "script.applescript");
	await writeFile(scriptPath, scriptBody, "utf8");
	try {
		const { stdout, stderr } = await execFileAsync("osascript", [scriptPath], {
			timeout: timeoutMs,
			signal,
			encoding: "utf8",
			maxBuffer: 4 * 1024 * 1024,
		});
		return { exitCode: 0, stdout: stdout ?? "", stderr: stderr ?? "", timedOut: false };
	} catch (error: any) {
		const stdout = typeof error?.stdout === "string" ? error.stdout : "";
		const stderr = typeof error?.stderr === "string" ? error.stderr : "";
		const timedOut = error?.killed === true && error?.signal === "SIGTERM";
		const exitCode = typeof error?.code === "number" ? error.code : 1;
		if (typeof error?.code !== "number" && !timedOut) {
			// True spawn failure (osascript missing, signal, etc.). Surface it.
			throw new Error(`apple_script: failed to execute osascript: ${error?.message ?? error}`);
		}
		return { exitCode, stdout, stderr, timedOut };
	} finally {
		// Best-effort cleanup; a leftover temp file is harmless.
		await rm(dir, { recursive: true, force: true }).catch(() => {});
	}
}

function summarizeForText(details: AppleScriptDetails): string {
	const lines: string[] = [];
	if (details.exitCode === 0) {
		lines.push(`apple_script ok${details.app ? ` (${details.app})` : ""} in ${details.durationMs}ms`);
	} else if (details.timedOut) {
		lines.push(`apple_script TIMED OUT${details.app ? ` (${details.app})` : ""} after ${details.durationMs}ms`);
	} else {
		lines.push(`apple_script exit=${details.exitCode}${details.app ? ` (${details.app})` : ""}`);
	}
	if (details.stdout.trim().length > 0) {
		lines.push("stdout:");
		lines.push(truncate(details.stdout, 2000));
	}
	if (details.stderr.trim().length > 0) {
		lines.push("stderr:");
		lines.push(truncate(details.stderr, 2000));
	}
	if (details.frontmostBefore || details.frontmostAfter) {
		const before = details.frontmostBefore ?? "(unknown)";
		const after = details.frontmostAfter ?? "(unknown)";
		if (details.frontmostDrifted) {
			const restore = details.restoreAttempted
				? details.restoreSucceeded
					? " (restored)"
					: " (restore attempted, status unknown)"
				: "";
			lines.push(`frontmost DRIFTED: ${before} → ${after}${restore}`);
		} else {
			lines.push(`frontmost unchanged: ${before}`);
		}
	}
	return lines.join("\n");
}

function truncate(text: string, max: number): string {
	if (text.length <= max) return text;
	return `${text.slice(0, max)}\n…[truncated ${text.length - max} chars]`;
}

export async function performAppleScript(
	params: AppleScriptParams,
	signal?: AbortSignal,
): Promise<AgentToolResult<AppleScriptDetails>> {
	const config = getComputerUseConfig();
	const appleScriptConfig = getAppleScriptConfig();
	if (!appleScriptConfig.enabled) {
		throw new Error(
			"apple_script is disabled in config. Set computer_use.apple_script.enabled = true (or PI_COMPUTER_USE_APPLE_SCRIPT=1) to enable.",
		);
	}
	const script = typeof params.script === "string" ? params.script : "";
	if (script.trim().length === 0) {
		throw new Error("apple_script: 'script' is required and must be a non-empty string.");
	}
	const requestedTimeout =
		typeof params.timeoutMs === "number" && Number.isFinite(params.timeoutMs) && params.timeoutMs > 0
			? Math.trunc(params.timeoutMs)
			: appleScriptConfig.timeout_ms;
	// Cap timeout at a sane upper bound so a runaway script can't hang the agent.
	const timeoutMs = Math.min(requestedTimeout, 60_000);

	const frontmostBefore = await readFrontmost(2000, signal);
	const start = Date.now();
	const result = await runAppleScript(script, timeoutMs, signal);
	const durationMs = Date.now() - start;
	const frontmostAfter = await readFrontmost(2000, signal);

	const drifted = Boolean(
		frontmostBefore && frontmostAfter && frontmostBefore !== frontmostAfter,
	);

	let restoreAttempted = false;
	let restoreSucceeded: boolean | undefined;
	if (drifted && appleScriptConfig.restore_frontmost_on_drift && frontmostBefore) {
		restoreAttempted = true;
		restoreSucceeded = await activateApp(frontmostBefore, 2000, signal);
	}

	const details: AppleScriptDetails = {
		tool: "apple_script",
		app: typeof params.app === "string" && params.app.trim().length > 0 ? params.app.trim() : undefined,
		exitCode: result.exitCode,
		stdout: result.stdout,
		stderr: result.stderr,
		durationMs,
		timedOut: result.timedOut,
		frontmostBefore,
		frontmostAfter,
		frontmostDrifted: drifted,
		restoreAttempted,
		restoreSucceeded,
		stealthMode: config.stealth_mode,
		config,
	};

	return {
		content: [{ type: "text", text: summarizeForText(details) }],
		details,
	};
}
