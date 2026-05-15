/**
 * Compact rendering for pi-computer-use tool calls.
 *
 * Each tool's call line shows `<tool> <app>` (or just `<tool>` for
 * window-less tools) and each result line shows a one-line summary. The
 * full payload — AX targets, app instructions, screenshot metadata, etc.
 * — is shown only when the user expands the row with `app.tools.expand`
 * (default `ctrl+o`).
 *
 * Lives in src/ rather than extensions/ because pi auto-loads every .ts
 * file in extensions/ as an extension factory; this module is a helper,
 * not an extension.
 */

import { keyHint } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";

// Result shape isn't exported as a public type by pi-coding-agent; use a
// minimal structural alias so we don't depend on internal symbols.
interface ToolResultLike {
	content?: Array<{ type: string; text?: string } | { type: "image"; [key: string]: any }>;
	details?: unknown;
	isError?: boolean;
}

import type {
	AppleScriptDetails,
	ComputerUseDetails,
	LaunchAppDetails,
	ListAppsDetails,
	ListWindowsDetails,
	SurfaceWindowDetails,
	WakeWindowDetails,
} from "../src/bridge.ts";

type AnyDetails = ComputerUseDetails | ListAppsDetails | ListWindowsDetails | WakeWindowDetails | SurfaceWindowDetails | LaunchAppDetails | AppleScriptDetails | undefined;

interface ThemeLike {
	bold: (s: string) => string;
	fg: (slot: string, s: string) => string;
}

interface RenderResultOptions {
	expanded: boolean;
	isPartial: boolean;
}

/** Format the tool-call header line (pre-execution). Looks like
 * `screenshot @w2` or `apple_script` (no app yet, since args are
 * pre-execution and we don't know the resolved target).
 */
export function renderCallHeader(
	toolName: string,
	args: any,
	theme: ThemeLike,
): Text {
	let text = theme.fg("toolTitle", theme.bold(toolName));
	const fragments: string[] = [];

	// app/window selector hints — purely for visual context while the call streams
	if (args && typeof args === "object") {
		if (typeof args.app === "string" && args.app) fragments.push(args.app);
		if (typeof args.windowTitle === "string" && args.windowTitle) fragments.push(args.windowTitle);
		const windowSel = args.window;
		if (typeof windowSel === "string" && windowSel) fragments.push(windowSel);
		else if (typeof windowSel === "number") fragments.push(`@w${windowSel}`);

		// tool-specific arg hints
		if (toolName === "click" || toolName === "double_click" || toolName === "set_text" || toolName === "scroll" || toolName === "drag") {
			if (typeof args.ref === "string" && args.ref) fragments.push(args.ref);
		}
		if (toolName === "keypress" && Array.isArray(args.keys) && args.keys.length > 0) {
			fragments.push(args.keys.slice(0, 2).join(" "));
		}
		if (toolName === "set_text" && typeof args.text === "string") {
			fragments.push(`"${truncate(args.text, 24)}"`);
		}
		if (toolName === "type_text" && typeof args.text === "string") {
			fragments.push(`"${truncate(args.text, 24)}"`);
		}
		if (toolName === "navigate_browser" && typeof args.url === "string") {
			fragments.push(truncate(args.url, 48));
		}
		if (toolName === "arrange_window" && typeof args.preset === "string") {
			fragments.push(args.preset);
		}
		if (toolName === "wait" && typeof args.ms === "number") {
			fragments.push(`${args.ms}ms`);
		}
		if (toolName === "computer_actions" && Array.isArray(args.actions)) {
			fragments.push(`${args.actions.length} actions`);
		}
		if (toolName === "apple_script" && typeof args.app === "string") {
			fragments.push(args.app);
		}
	}

	if (fragments.length > 0) {
		text += " " + theme.fg("accent", fragments.join(" "));
	}
	return new Text(text, 0, 0);
}

/** Format the tool-result line (post-execution). The compact form is
 * `<status> <app>` (or `<status>` for window-less tools); expanded mode
 * renders the original textual content.
 */
export function renderResultLine(
	toolName: string,
	result: ToolResultLike,
	options: RenderResultOptions,
	theme: ThemeLike,
): Text {
	if (options.isPartial) {
		return new Text(theme.fg("warning", `${toolName}\u2026`), 0, 0);
	}
	const details = result.details as AnyDetails;
	const isError = isErrorContent(result);

	const compact = compactStatusLine(toolName, details, result, isError, theme);

	if (!options.expanded) {
		const expandHint = theme.fg("muted", ` (${keyHint("app.tools.expand", "to expand")})`);
		return new Text(compact + expandHint, 0, 0);
	}

	// Expanded: include the original textual content below the compact line
	// so the full information the model received is visible. We still keep
	// the compact summary at the top so the user can scan the row.
	const body = extractTextBody(result);
	const lines = [compact];
	if (body.length > 0) {
		lines.push("");
		for (const line of body.split("\n")) {
			lines.push(theme.fg("dim", line));
		}
	}
	return new Text(lines.join("\n"), 0, 0);
}

function compactStatusLine(
	toolName: string,
	details: AnyDetails,
	result: ToolResultLike,
	isError: boolean,
	theme: ThemeLike,
): string {
	if (isError) {
		const body = extractTextBody(result);
		const firstLine = body.split("\n", 1)[0] ?? "error";
		return theme.fg("error", `\u2717 ${truncate(firstLine, 90)}`);
	}

	// Prefix: tool name in bold + the app/target context
	const head = theme.fg("toolTitle", theme.bold(toolName));
	const appTag = appOrTargetTag(toolName, details);
	const headWithApp = appTag ? `${head} ${theme.fg("accent", appTag)}` : head;

	// Suffix: tool-specific one-line summary
	const summary = toolSummary(toolName, details, result, theme);
	if (summary) {
		return `${headWithApp} ${theme.fg("dim", summary)}`;
	}
	return headWithApp;
}

function appOrTargetTag(toolName: string, details: AnyDetails): string | undefined {
	if (!details) return undefined;
	switch (details.tool) {
		case "list_apps":
			return undefined;
		case "list_windows":
			return undefined;
		case "wake_window": {
			const d = details as WakeWindowDetails;
			return d.window?.appName;
		}
		case "surface_window": {
			const d = details as SurfaceWindowDetails;
			return d.window?.appName;
		}
		case "launch_app": {
			const d = details as LaunchAppDetails;
			return d.appName;
		}
		case "apple_script": {
			const d = details as AppleScriptDetails;
			return d.app;
		}
		default: {
			const d = details as ComputerUseDetails;
			return d.target?.app;
		}
	}
}

function toolSummary(
	toolName: string,
	details: AnyDetails,
	result: ToolResultLike,
	theme: ThemeLike,
): string {
	if (!details) {
		// Fall back to first non-empty line of textual content if any.
		const body = extractTextBody(result).split("\n")[0]?.trim() ?? "";
		return truncate(body, 80);
	}
	switch (details.tool) {
		case "list_apps": {
			const d = details as ListAppsDetails;
			return `${d.apps.length} apps`;
		}
		case "list_windows": {
			const d = details as ListWindowsDetails;
			const offSpace = d.windows.filter((w) => !w.isOnActiveSpace && !w.isMinimized).length;
			const offSpaceTag = offSpace > 0 ? `, ${offSpace} off-Space` : "";
			return `${d.windows.length} windows${offSpaceTag}`;
		}
		case "wake_window": {
			const d = details as WakeWindowDetails;
			const bits: string[] = [];
			if (d.unminimized) bits.push("unminimized");
			else if (d.isOffActiveSpace) bits.push("off-Space \u2014 see alternatives");
			else bits.push("on Space");
			return bits.join(" \u00b7 ");
		}
		case "surface_window": {
			const d = details as SurfaceWindowDetails;
			const bits: string[] = [];
			if (d.appActivated) bits.push("app activated");
			if (d.windowRaised) bits.push("window raised");
			if (!bits.length) bits.push("no-op");
			return bits.join(" \u00b7 ");
		}
		case "launch_app": {
			const d = details as LaunchAppDetails;
			const bits: string[] = [];
			bits.push(d.alreadyRunning ? "already running" : "launched");
			bits.push(d.activated ? "foreground" : "background");
			bits.push(`pid ${d.pid}`);
			return bits.join(" \u00b7 ");
		}
		case "apple_script": {
			const d = details as AppleScriptDetails;
			const parts: string[] = [];
			if (d.timedOut) parts.push("timed out");
			else if (d.exitCode === 0) parts.push("ok");
			else parts.push(`exit ${d.exitCode}`);
			parts.push(`${d.durationMs}ms`);
			if (d.frontmostDrifted) {
				parts.push(d.restoreSucceeded ? "drift restored" : "DRIFT");
			}
			return parts.join(" \u00b7 ");
		}
		default: {
			const d = details as ComputerUseDetails;
			const parts: string[] = [];
			if (d.execution?.strategy) parts.push(d.execution.strategy);
			if (d.execution?.variant && d.execution.variant !== "default") {
				parts.push(d.execution.variant);
			}
			if (toolName === "screenshot" && Array.isArray(d.axTargets)) {
				parts.push(`${d.axTargets.length} targets`);
			}
			if (toolName === "set_text" && typeof (d as any).execution?.fallbackUsed === "boolean" && (d as any).execution.fallbackUsed) {
				parts.push("fallback");
			}
			return parts.join(" \u00b7 ");
		}
	}
}

function extractTextBody(result: ToolResultLike): string {
	const out: string[] = [];
	for (const block of result.content ?? []) {
		if (block.type === "text" && typeof (block as any).text === "string") {
			out.push((block as any).text);
		}
	}
	return out.join("\n");
}

function isErrorContent(result: ToolResultLike): boolean {
	if (result.isError === true) return true;
	const first = result.content?.[0];
	if (first?.type === "text" && typeof (first as any).text === "string") {
		const head = ((first as any).text as string).slice(0, 80).toLowerCase();
		if (head.startsWith("error") || head.includes("stealth/strict ax mode")) {
			return true;
		}
	}
	return false;
}

function truncate(text: string, max: number): string {
	if (text.length <= max) return text;
	return text.slice(0, Math.max(0, max - 1)) + "\u2026";
}
