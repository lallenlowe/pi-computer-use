import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";

export interface ComputerUseConfig {
	browser_use: boolean;
	/**
	 * When true, focus-changing tools (surface_window,
	 * launch_app({activate:true})) skip the user-approval prompt and
	 * activate immediately. When false (default), the tool calls
	 * ctx.ui.confirm and proceeds only if the user accepts.
	 */
	focus_auto_approve: boolean;
	apple_script: AppleScriptConfig;
	overlay: OverlayConfig;
}

export interface AppleScriptConfig {
	enabled: boolean;
	restore_frontmost_on_drift: boolean;
	timeout_ms: number;
}

export interface OverlayConfig {
	enabled: boolean;
	size: number;
	animation_style: "arc" | "linear" | "off";
	animation_duration_ms: number;
	occlusion_aware: boolean;
}

export interface ComputerUseConfigSource {
	path: string;
	exists: boolean;
	values?: Partial<ComputerUseConfig>;
	error?: string;
}

export interface LoadedComputerUseConfig {
	config: ComputerUseConfig;
	sources: ComputerUseConfigSource[];
	env: Partial<ComputerUseConfig>;
}

const DEFAULT_APPLE_SCRIPT_CONFIG: AppleScriptConfig = {
	enabled: true,
	restore_frontmost_on_drift: true,
	timeout_ms: 5000,
};

const DEFAULT_OVERLAY_CONFIG: OverlayConfig = {
	enabled: false,
	size: 28,
	animation_style: "arc",
	animation_duration_ms: 180,
	occlusion_aware: true,
};

const DEFAULT_CONFIG: ComputerUseConfig = {
	browser_use: true,
	focus_auto_approve: false,
	apple_script: { ...DEFAULT_APPLE_SCRIPT_CONFIG },
	overlay: { ...DEFAULT_OVERLAY_CONFIG },
};

let warnedAboutLegacyStealth = false;
function warnLegacyStealthOnce(source: string): void {
	if (warnedAboutLegacyStealth) return;
	warnedAboutLegacyStealth = true;
	console.warn(
		`[pi-computer-use] '${source}' is set but stealth_mode no longer exists - all input ops use the per-PID stealth path unconditionally. ` +
		`Focus-changing tools (surface_window, launch_app({activate:true})) are now gated by focus_auto_approve (default off => prompts the user via ctx.ui.confirm). ` +
		`You can remove stealth_mode from your config; this warning is informational and the value is ignored.`,
	);
}

let activeConfig: ComputerUseConfig = { ...DEFAULT_CONFIG };
let activeLoadedConfig: LoadedComputerUseConfig = { config: activeConfig, sources: [], env: {} };

function parseBoolean(value: unknown): boolean | undefined {
	if (typeof value === "boolean") return value;
	if (typeof value === "number") return value === 1 ? true : value === 0 ? false : undefined;
	if (typeof value !== "string") return undefined;
	const normalized = value.trim().toLowerCase();
	if (["1", "true", "yes", "on", "enabled"].includes(normalized)) return true;
	if (["0", "false", "no", "off", "disabled"].includes(normalized)) return false;
	return undefined;
}

function normalizeOverlay(raw: unknown): Partial<OverlayConfig> | undefined {
	if (!raw || typeof raw !== "object") return undefined;
	const src = raw as any;
	const out: Partial<OverlayConfig> = {};
	const enabled = parseBoolean(src.enabled);
	if (enabled !== undefined) out.enabled = enabled;
	const size = src.size;
	if (typeof size === "number" && Number.isFinite(size) && size > 0) {
		out.size = Math.trunc(size);
	}
	const rawStyle = (src.animation_style ?? src.animationStyle);
	if (typeof rawStyle === "string") {
		const lowered = rawStyle.toLowerCase();
		if (lowered === "arc" || lowered === "linear" || lowered === "off") {
			out.animation_style = lowered;
		}
	}
	const durationMs = src.animation_duration_ms ?? src.animationDurationMs;
	if (typeof durationMs === "number" && Number.isFinite(durationMs) && durationMs >= 0) {
		out.animation_duration_ms = Math.trunc(durationMs);
	}
	const occlusion = parseBoolean(src.occlusion_aware ?? src.occlusionAware);
	if (occlusion !== undefined) out.occlusion_aware = occlusion;
	return Object.keys(out).length > 0 ? out : undefined;
}

function normalizeAppleScript(raw: unknown): Partial<AppleScriptConfig> | undefined {
	if (!raw || typeof raw !== "object") return undefined;
	const src = raw as any;
	const out: Partial<AppleScriptConfig> = {};
	const enabled = parseBoolean(src.enabled);
	const restoreFrontmost = parseBoolean(src.restore_frontmost_on_drift ?? src.restoreFrontmostOnDrift);
	const timeoutMs = src.timeout_ms ?? src.timeoutMs;
	if (enabled !== undefined) out.enabled = enabled;
	if (restoreFrontmost !== undefined) out.restore_frontmost_on_drift = restoreFrontmost;
	if (typeof timeoutMs === "number" && Number.isFinite(timeoutMs) && timeoutMs > 0) {
		out.timeout_ms = Math.trunc(timeoutMs);
	}
	return Object.keys(out).length > 0 ? out : undefined;
}

function normalizePartial(raw: unknown): Partial<ComputerUseConfig> {
	if (!raw || typeof raw !== "object") return {};
	const source = (raw as any).computer_use && typeof (raw as any).computer_use === "object" ? (raw as any).computer_use : raw;
	const out: Partial<ComputerUseConfig> = {};
	const browserUse = parseBoolean((source as any).browser_use ?? (source as any).browserUse);
	const legacyStealth = parseBoolean((source as any).stealth_mode ?? (source as any).stealthMode);
	const focusAutoApprove = parseBoolean((source as any).focus_auto_approve ?? (source as any).focusAutoApprove);
	if (browserUse !== undefined) out.browser_use = browserUse;
	if (legacyStealth !== undefined) warnLegacyStealthOnce("stealth_mode");
	if (focusAutoApprove !== undefined) out.focus_auto_approve = focusAutoApprove;
	const appleScript = normalizeAppleScript((source as any).apple_script ?? (source as any).appleScript);
	if (appleScript) {
		out.apple_script = { ...DEFAULT_APPLE_SCRIPT_CONFIG, ...appleScript };
	}
	const overlay = normalizeOverlay((source as any).overlay);
	if (overlay) {
		out.overlay = { ...DEFAULT_OVERLAY_CONFIG, ...overlay };
	}
	return out;
}

function readConfigFile(filePath: string): ComputerUseConfigSource {
	if (!existsSync(filePath)) return { path: filePath, exists: false };
	try {
		const parsed = JSON.parse(readFileSync(filePath, "utf-8"));
		return { path: filePath, exists: true, values: normalizePartial(parsed) };
	} catch (error) {
		return { path: filePath, exists: true, error: error instanceof Error ? error.message : String(error) };
	}
}

function readEnv(): Partial<ComputerUseConfig> {
	const out: Partial<ComputerUseConfig> = {};
	const browserUse = parseBoolean(process.env.PI_COMPUTER_USE_BROWSER_USE);
	const focusAutoApprove = parseBoolean(process.env.PI_COMPUTER_USE_FOCUS_AUTO_APPROVE);
	if (browserUse !== undefined) out.browser_use = browserUse;
	if (focusAutoApprove !== undefined) out.focus_auto_approve = focusAutoApprove;
	if (parseBoolean(process.env.PI_COMPUTER_USE_STEALTH_MODE) !== undefined) warnLegacyStealthOnce("PI_COMPUTER_USE_STEALTH_MODE");
	if (parseBoolean(process.env.PI_COMPUTER_USE_STEALTH) === true) warnLegacyStealthOnce("PI_COMPUTER_USE_STEALTH");
	if (parseBoolean(process.env.PI_COMPUTER_USE_STRICT_AX) === true) warnLegacyStealthOnce("PI_COMPUTER_USE_STRICT_AX");
	const appleScriptEnabled = parseBoolean(process.env.PI_COMPUTER_USE_APPLE_SCRIPT);
	if (appleScriptEnabled !== undefined) {
		out.apple_script = { ...DEFAULT_APPLE_SCRIPT_CONFIG, enabled: appleScriptEnabled };
	}
	const overlayEnabled = parseBoolean(process.env.PI_COMPUTER_USE_OVERLAY);
	if (overlayEnabled !== undefined) {
		out.overlay = { ...DEFAULT_OVERLAY_CONFIG, enabled: overlayEnabled };
	}
	return out;
}

export function loadComputerUseConfig(cwd: string): LoadedComputerUseConfig {
	const sources = [
		readConfigFile(path.join(getAgentDir(), "extensions", "pi-computer-use.json")),
		readConfigFile(path.join(cwd, ".pi", "computer-use.json")),
	];
	const env = readEnv();
	const config: ComputerUseConfig = {
		...DEFAULT_CONFIG,
		apple_script: { ...DEFAULT_CONFIG.apple_script },
		overlay: { ...DEFAULT_CONFIG.overlay },
	};
	for (const source of sources) {
		if (source.values) Object.assign(config, source.values);
	}
	Object.assign(config, env);
	activeConfig = config;
	activeLoadedConfig = { config, sources, env };
	return activeLoadedConfig;
}

export function getComputerUseConfig(): ComputerUseConfig {
	return activeConfig;
}

export function getLoadedComputerUseConfig(): LoadedComputerUseConfig {
	return activeLoadedConfig;
}

export function isFocusAutoApprove(): boolean {
	return activeConfig.focus_auto_approve;
}

export function isBrowserUseEnabled(): boolean {
	return activeConfig.browser_use;
}

export function getAppleScriptConfig(): AppleScriptConfig {
	return activeConfig.apple_script;
}

export function getOverlayConfig(): OverlayConfig {
	return activeConfig.overlay;
}

/**
 * Path to the user-scoped config file. The interactive `/computer-use`
 * command writes here; project-scoped overrides at `<cwd>/.pi/computer-use.json`
 * are intentionally left for hand-editing.
 */
export function getUserConfigPath(): string {
	return path.join(getAgentDir(), "extensions", "pi-computer-use.json");
}

/**
 * Persist a partial config update to the user-scoped JSON file. Merges with
 * any existing values in the file rather than overwriting unrelated keys.
 * Returns the path that was written.
 */
export function saveUserComputerUseConfig(update: Partial<ComputerUseConfig>): string {
	const targetPath = getUserConfigPath();
	mkdirSync(path.dirname(targetPath), { recursive: true });
	let existing: any = {};
	if (existsSync(targetPath)) {
		try {
			existing = JSON.parse(readFileSync(targetPath, "utf-8"));
			if (typeof existing !== "object" || existing === null) existing = {};
		} catch {
			existing = {};
		}
	}
	// Honour the same nested-namespace convention loadComputerUseConfig accepts:
	// allow either a top-level `computer_use: {...}` wrapper or flat keys. We
	// always write the flat shape so the file is easy to hand-edit.
	const flatExisting = existing.computer_use && typeof existing.computer_use === "object" ? existing.computer_use : existing;
	const merged: any = { ...flatExisting };
	if (update.browser_use !== undefined) merged.browser_use = update.browser_use;
	if (update.focus_auto_approve !== undefined) merged.focus_auto_approve = update.focus_auto_approve;
	if (update.apple_script !== undefined) {
		merged.apple_script = {
			...(typeof flatExisting.apple_script === "object" && flatExisting.apple_script !== null ? flatExisting.apple_script : {}),
			...update.apple_script,
		};
	}
	if (update.overlay !== undefined) {
		merged.overlay = {
			...(typeof flatExisting.overlay === "object" && flatExisting.overlay !== null ? flatExisting.overlay : {}),
			...update.overlay,
		};
	}
	writeFileSync(targetPath, JSON.stringify(merged, null, 2) + "\n", "utf-8");
	return targetPath;
}
