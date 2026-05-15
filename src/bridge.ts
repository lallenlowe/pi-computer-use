import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { access } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { AgentToolResult, AgentToolUpdateCallback, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { getAppleScriptConfig, getComputerUseConfig, getOverlayConfig, isBrowserUseEnabled, isStrictAxMode, loadComputerUseConfig } from "./config.ts";
import { ensurePermissions, type PermissionStatus } from "./permissions.ts";
import { loadAppInstructions, type AppInstructions } from "./app-instructions.ts";
import { performAppleScript, type AppleScriptDetails, type AppleScriptParams } from "./apple-script.ts";

type WindowSelector = string | number;
type ImageMode = "auto" | "always" | "never";

interface StateTargetSnapshot {
	pid: number;
	windowId: number;
	windowRef?: string;
}

export interface ScreenshotParams {
	app?: string;
	windowTitle?: string;
	window?: WindowSelector;
	image?: ImageMode;
}

export interface ListWindowsParams {
	app?: string;
	bundleId?: string;
	pid?: number;
}

export interface WakeWindowParams {
	windowRef?: string;
	windowId?: number;
	pid?: number;
}

export interface WakeWindowAlternatives {
	appleScript: {
		enabled: boolean;
		hint: string;
	};
	appInstructions: {
		found: boolean;
		source: "user" | "bundled" | null;
		matchedKey: string | null;
	};
	surfaceWindow: {
		tool: "surface_window";
		windowRef?: string;
		hint: string;
	};
}

export interface WakeWindowDetails {
	tool: "wake_window";
	query: WakeWindowParams;
	pid: number;
	window: {
		windowRef?: string;
		windowId?: number;
		windowTitle?: string;
		appName?: string;
		bundleId?: string;
	};
	isOffActiveSpace: boolean;
	isMinimized: boolean;
	unminimized: boolean;
	action: "unminimized" | "on_space_status" | "off_space_status";
	alternatives: WakeWindowAlternatives;
}

export interface SurfaceWindowParams {
	windowRef?: string;
	windowId?: number;
	pid?: number;
}

export interface LaunchAppParams {
	bundleId?: string;
	appName?: string;
	activate?: boolean;
}

export interface LaunchAppDetails {
	tool: "launch_app";
	query: LaunchAppParams;
	pid: number;
	appName: string;
	bundleId: string;
	alreadyRunning: boolean;
	activated: boolean;
}

export interface SurfaceWindowDetails {
	tool: "surface_window";
	query: SurfaceWindowParams;
	appActivated: boolean;
	windowRaised: boolean;
	pid: number;
	window: {
		windowRef?: string;
		windowId?: number;
		windowTitle?: string;
		appName?: string;
	};
}

interface WindowTargetParams {
	window?: WindowSelector;
	stateId?: string;
	image?: ImageMode;
}

export interface ClickParams extends WindowTargetParams {
	x?: number;
	y?: number;
	ref?: string;
	button?: MouseButtonName;
	clickCount?: number;
}

export interface TypeTextParams extends WindowTargetParams {
	text: string;
}

export interface SetTextParams extends WindowTargetParams {
	text: string;
	ref?: string;
}

export interface KeypressParams extends WindowTargetParams {
	keys: string[];
}

export interface ScrollParams extends WindowTargetParams {
	x?: number;
	y?: number;
	ref?: string;
	scrollX?: number;
	scrollY?: number;
}

export interface MoveMouseParams extends WindowTargetParams {
	x: number;
	y: number;
}

export interface DragParams extends WindowTargetParams {
	path?: Array<{ x: number; y: number } | [number, number]>;
	ref?: string;
}

export type ComputerAction =
	| ({ type: "click" } & ClickParams)
	| ({ type: "double_click" } & ClickParams)
	| ({ type: "move_mouse" } & MoveMouseParams)
	| ({ type: "drag" } & DragParams)
	| ({ type: "scroll" } & ScrollParams)
	| ({ type: "keypress" } & KeypressParams)
	| ({ type: "type_text" } & TypeTextParams)
	| ({ type: "set_text" } & SetTextParams)
	| ({ type: "wait" } & WaitParams);

export interface ComputerActionsParams extends WindowTargetParams {
	actions: ComputerAction[];
}

export interface ArrangeWindowParams extends WindowTargetParams {
	x?: number;
	y?: number;
	width?: number;
	height?: number;
	preset?: "center_large" | "left_half" | "right_half" | "top_half" | "bottom_half";
}

export interface NavigateBrowserParams extends WindowTargetParams {
	url: string;
}

export interface WaitParams extends WindowTargetParams {
	ms?: number;
}

export interface CurrentTarget {
	appName: string;
	bundleId?: string;
	pid: number;
	windowTitle: string;
	windowId: number;
	windowRef?: string;
	nativeWindowRef?: string;
}

export interface CurrentCapture {
	stateId: string;
	/** Image pixel width (typically window logical width × scaleFactor). */
	width: number;
	/** Image pixel height. */
	height: number;
	scaleFactor: number;
	timestamp: number;
	/**
	 * Window logical-point dimensions. THIS is the coordinate space
	 * for click/move_mouse/drag/scroll - x in [0, windowWidth], y in
	 * [0, windowHeight]. Image pixel dimensions are exposed via
	 * width/height for the model's vision pass; image pixels are NOT
	 * the input contract.
	 */
	windowWidth: number;
	windowHeight: number;
	/** Cached window frame in global screen points; passed to native
	 * helper so it doesn't need to do a fresh SCK lookup per click. */
	framePoints: { x: number; y: number; w: number; h: number };
}

interface ActivationFlags {
	activated: boolean;
	unminimized: boolean;
	raised: boolean;
}

type ExecutionVariant = "stealth" | "default";

interface ExecutionTrace {
	strategy:
		| "screenshot"
		| "wait"
		| "batch"
		| "window_frame"
		| "ax_press"
		| "ax_focus"
		| "coordinate_event_click"
		| "coordinate_event_double_click"
		| "coordinate_event_move"
		| "coordinate_event_drag"
		| "coordinate_event_scroll"
		| "ax_scroll"
		| "ax_action"
		| "browser_open_location"
		| "ax_set_value"
		| "raw_keypress"
		| "per_pid_keypress"
		| "raw_key_text";
	axAttempted?: boolean;
	axSucceeded?: boolean;
	fallbackUsed?: boolean;
	runtimeMode?: ExecutionVariant;
	variant?: ExecutionVariant;
	stealthCompatible?: boolean;
	nonStealthReason?: string;
	actionCount?: number;
	completedActionCount?: number;
	actions?: BatchActionTrace[];
}

interface BatchActionTrace {
	index: number;
	type: string;
	strategy: ExecutionTrace["strategy"];
	durationMs: number;
	axAttempted?: boolean;
	axSucceeded?: boolean;
	fallbackUsed?: boolean;
	runtimeMode?: ExecutionVariant;
	variant?: ExecutionVariant;
	stealthCompatible?: boolean;
	nonStealthReason?: string;
}

export interface ComputerUseDetails {
	tool: string;
	target: {
		app: string;
		bundleId?: string;
		pid: number;
		windowTitle: string;
		windowId: number;
		windowRef?: string;
		nativeWindowRef?: string;
	};
	capture: {
		stateId: string;
		/** Image pixel width (typically `windowWidth × scaleFactor`). */
		width: number;
		/** Image pixel height. */
		height: number;
		/** image / window scale (typically 2.0 on retina). */
		scaleFactor: number;
		timestamp: number;
		/** Window logical-point width - the input space for click/move/drag/scroll. */
		windowWidth: number;
		/** Window logical-point height. */
		windowHeight: number;
		/** Coordinate-units contract version. v3 = window-relative logical points. */
		coordinateSpace: "window-relative-logical-points";
	};
	axTargets?: AxTarget[];
	activation: ActivationFlags;
	execution: ExecutionTrace;
	config?: {
		browser_use: boolean;
		stealth_mode: boolean;
	};
	status?: "ok";
	axDiagnostics?: {
		reason?: string;
		message?: string;
		debug?: unknown;
	};
	imageReason?:
		| "fallback_recovery"
		| "browser_ax_window_unavailable"
		| "no_ax_targets"
		| "sparse_ax_targets"
		| "weak_ax_targets"
		| "unlabeled_ax_targets"
		| "duplicated_ax_labels"
		| "browser_wait_verification";
	/**
	 * Hand-written guidance for this app, when an instructions file matches the
	 * target's bundle id or display name. Additive hint layer; absence is
	 * normal and the model should proceed using AX targets and screenshots.
	 */
	appInstructions?: AppInstructions;
}

export interface ListAppsDetails {
	tool: "list_apps";
	apps: Array<{
		app: string;
		bundleId?: string;
		pid: number;
		isFrontmost: boolean;
		browserUseAllowed: boolean;
	}>;
	config: {
		browser_use: boolean;
		stealth_mode: boolean;
	};
}

export interface ListWindowsDetails {
	tool: "list_windows";
	query: ListWindowsParams;
	windows: Array<{
		app: string;
		bundleId?: string;
		pid: number;
		windowTitle: string;
		windowId?: number;
		windowRef: string;
		nativeWindowRef?: string;
		framePoints: FramePoints;
		scaleFactor: number;
		isMinimized: boolean;
		isOnscreen: boolean;
		isOnActiveSpace: boolean;
		isMain: boolean;
		isFocused: boolean;
		browserUseAllowed: boolean;
		score: number;
	}>;
	config: {
		browser_use: boolean;
		stealth_mode: boolean;
	};
}

interface HelperApp {
	appName: string;
	bundleId?: string;
	pid: number;
	isFrontmost?: boolean;
}

interface FramePoints {
	x: number;
	y: number;
	w: number;
	h: number;
}

interface HelperWindow {
	windowId?: number;
	windowRef?: string;
	title: string;
	framePoints: FramePoints;
	scaleFactor: number;
	isMinimized: boolean;
	isOnscreen: boolean;
	// True when the window is on the user's currently visible Space
	// (or minimized, which is a separate user-resolvable state).
	// False when the window exists and the app is running but the
	// window has been moved to another Space - the window is still
	// AX-addressable but won't render until raised.
	isOnActiveSpace: boolean;
	isMain: boolean;
	isFocused: boolean;
}

interface FrontmostResult {
	appName: string;
	bundleId?: string;
	pid: number;
	windowTitle?: string;
	windowId?: number;
}

interface RestoreUserFocusResult {
	restored: boolean;
	appRestored?: boolean;
	windowRestored?: boolean;
	appName?: string;
	windowTitle?: string;
}

interface ScreenshotPayload {
	pngBase64: string;
	width: number;
	height: number;
	scaleFactor: number;
	windowWidth?: number;
	windowHeight?: number;
}

interface FocusedElementResult {
	exists: boolean;
	elementRef?: string;
	role?: string;
	subrole?: string;
	isTextInput?: boolean;
	isSecure?: boolean;
	canSetValue?: boolean;
}

interface FocusWindowResult {
	focused: boolean;
	alreadyFocused?: boolean;
	reason?: string;
}

interface AxPressAtPointResult {
	pressed: boolean;
	reason?: string;
}

interface AxFocusResult {
	focused: boolean;
	reason?: string;
}

interface HelperAxTarget {
	elementRef?: string;
	role?: string;
	subrole?: string;
	title?: string;
	description?: string;
	value?: string;
	actions?: string[];
	isTextInput?: boolean;
	canSetValue?: boolean;
	canFocus?: boolean;
	canPress?: boolean;
	canScroll?: boolean;
	canIncrement?: boolean;
	canDecrement?: boolean;
	x?: number;
	y?: number;
	score?: number;
}

interface ResolvedTarget extends CurrentTarget {
	framePoints: FramePoints;
	scaleFactor: number;
	isMinimized: boolean;
	isOnscreen: boolean;
	isOnActiveSpace: boolean;
	isMain: boolean;
	isFocused: boolean;
}

interface PendingRequest {
	cmd: string;
	resolve: (value: any) => void;
	reject: (reason?: unknown) => void;
	timer: ReturnType<typeof setTimeout>;
	abortListener?: () => void;
}

interface AxTarget {
	ref: string;
	elementRef: string;
	role: string;
	subrole: string;
	title: string;
	description: string;
	value: string;
	actions: string[];
	isTextInput: boolean;
	canSetValue: boolean;
	canFocus: boolean;
	canPress: boolean;
	canScroll: boolean;
	canIncrement: boolean;
	canDecrement: boolean;
	x: number;
	y: number;
	score?: number;
}

interface PendingBrowserAddress {
	text: string;
	pid: number;
	windowId: number;
}

interface WindowRefRecord {
	ref: string;
	appName: string;
	bundleId?: string;
	pid: number;
	windowTitle: string;
	windowId?: number;
	nativeWindowRef?: string;
	framePoints: FramePoints;
	scaleFactor: number;
	isMinimized: boolean;
	isOnscreen: boolean;
	isOnActiveSpace: boolean;
	isMain: boolean;
	isFocused: boolean;
}

interface RuntimeState {
	currentTarget?: CurrentTarget;
	currentCapture?: CurrentCapture;
	currentStateTarget?: StateTargetSnapshot;
	currentImageMode?: ImageMode;
	currentAxTargets?: AxTarget[];
	windowRefs: Map<string, WindowRefRecord>;
	windowRefByIdentity: Map<string, string>;
	windowWriteQueues: Map<string, Promise<void>>;
	nextWindowRefIndex: number;
	allowNextTypeTextAxReplacement?: boolean;
	pendingBrowserAddress?: PendingBrowserAddress;
	helper?: ChildProcessWithoutNullStreams;
	helperStdoutBuffer: string;
	pending: Map<string, PendingRequest>;
	requestSequence: number;
	queueTail: Promise<void>;
	permissionStatus?: PermissionStatus;
	lastPermissionCheckAt: number;
	helperInstallChecked: boolean;
	// Per-app instructions are emitted at most once per (pi-session, source,
	// matchedKey) tuple. Without this set we'd burn ~500-2000 tokens of static
	// markdown into every screenshot result. The model retains the first ship
	// in conversation history; subsequent screenshots get a short breadcrumb
	// reminding it the instructions were already provided.
	shippedAppInstructions: Set<string>;
	// Last overlay state we successfully synced to the helper. Lets us
	// skip the bridge round-trip on every tool call when the user's
	// config hasn't changed.
	overlayEnabled?: boolean;
	overlayAnimationStyle?: string;
	overlayAnimationDurationMs?: number;
	overlayOcclusionAware?: boolean;
}

type MouseButtonName = "left" | "right" | "middle";

const TOOL_NAMES = new Set([
	"list_apps",
	"list_windows",
	"screenshot",
	"click",
	"double_click",
	"move_mouse",
	"drag",
	"scroll",
	"keypress",
	"type_text",
	"set_text",
	"wait",
	"arrange_window",
	"navigate_browser",
	"computer_actions",
	"apple_script",
]);

const MISSING_TARGET_ERROR = "No current controlled window. Call screenshot first to choose a target window.";
const CURRENT_TARGET_GONE_ERROR =
	"The current controlled window is no longer available. Call screenshot to choose a new target window.";
const CURRENT_TARGET_OFF_SPACE_ERROR =
	"The current controlled window is on another macOS Space. macOS does not allow silent cross-Space window control - AX cannot deliver actions to off-Space windows. Call wake_window({ windowRef }) for a recipe of non-GUI alternatives (apple_script, app instructions, URL schemes); only call surface_window({ windowRef }) after asking the user for permission to disturb their workspace.";
const NON_MACOS_ERROR = "pi-computer-use currently supports macOS 15+ only.";

const COMMAND_TIMEOUT_MS = 15_000;
const SCREENSHOT_TIMEOUT_MS = 25_000;
const HELPER_SETUP_TIMEOUT_MS = 60_000;
const ACTION_SETTLE_MS = 280;
const BATCH_ACTION_GAP_MS = 80;
const BATCH_MAX_ACTIONS = 20;
const DEFAULT_WAIT_MS = 1_000;

const RECOVERABLE_SCREENSHOT_ERROR_CODES = new Set(["screenshot_timeout", "window_not_found"]);
const BROWSER_BUNDLE_IDS = new Set([
	"com.apple.Safari",
	"com.google.Chrome",
	"org.chromium.Chromium",
	"company.thebrowser.Browser",
	"com.brave.Browser",
	"com.microsoft.edgemac",
	"com.vivaldi.Vivaldi",
	"net.imput.helium",
	"org.mozilla.firefox",
]);
const BROWSER_APP_NAMES = new Set([
	"safari",
	"google chrome",
	"chrome",
	"chromium",
	"arc",
	"brave browser",
	"brave",
	"microsoft edge",
	"edge",
	"vivaldi",
	"helium",
	"firefox",
]);
const CHROME_FAMILY_BUNDLE_IDS = new Set([
	"com.google.Chrome",
	"org.chromium.Chromium",
	"company.thebrowser.Browser",
	"com.brave.Browser",
	"com.microsoft.edgemac",
	"com.vivaldi.Vivaldi",
	"net.imput.helium",
]);
const CHROME_FAMILY_APP_NAMES = new Set([
	"google chrome",
	"chrome",
	"chromium",
	"arc",
	"brave browser",
	"brave",
	"microsoft edge",
	"edge",
	"vivaldi",
	"helium",
]);
const BROWSER_WINDOW_OPEN_TIMEOUT_MS = 10_000;
const BROWSER_WINDOW_OPEN_POLL_MS = 200;
const BROWSER_WINDOW_OPEN_ATTEMPTS = 12;

export const HELPER_STABLE_PATH = path.join(os.homedir(), ".pi", "agent", "helpers", "pi-computer-use", "bridge");

const PACKAGE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SETUP_HELPER_SCRIPT = path.join(PACKAGE_ROOT, "scripts", "setup-helper.mjs");

const runtimeState: RuntimeState = {
	helperStdoutBuffer: "",
	pending: new Map(),
	requestSequence: 0,
	queueTail: Promise.resolve(),
	lastPermissionCheckAt: 0,
	helperInstallChecked: false,
	allowNextTypeTextAxReplacement: false,
	windowRefs: new Map(),
	windowRefByIdentity: new Map(),
	windowWriteQueues: new Map(),
	nextWindowRefIndex: 1,
	shippedAppInstructions: new Set(),
};

class HelperTransportError extends Error {
	constructor(message: string) {
		super(message);
		this.name = "HelperTransportError";
	}
}

class HelperCommandError extends Error {
	readonly code?: string;

	constructor(message: string, code?: string) {
		super(message);
		this.name = "HelperCommandError";
		this.code = code;
	}
}

const BROWSER_JAVASCRIPT_APPLE_EVENTS_HINT = [
	"Browser JavaScript Apple Events are disabled for the target browser.",
	"Ask the user to enable \"Allow JavaScript from Apple Events\" in the browser's developer menu, then retry the browser action.",
].join(" ");

function isBrowserJavaScriptAppleEventsErrorMessage(message: string): boolean {
	return /not allowed to send javascript commands/i.test(message)
		|| /executing javascript through applescript is turned off/i.test(message)
		|| /allow javascript from apple events/i.test(message)
		|| /enable javascript from apple events/i.test(message)
		|| (/javascript/i.test(message) && /apple events/i.test(message));
}

function appendBrowserJavaScriptAppleEventsHint(error: Error): Error {
	if (!isBrowserJavaScriptAppleEventsErrorMessage(error.message) || error.message.includes(BROWSER_JAVASCRIPT_APPLE_EVENTS_HINT)) {
		return error;
	}
	const enhanced = new Error(`${error.message}\n\n${BROWSER_JAVASCRIPT_APPLE_EVENTS_HINT}`);
	enhanced.name = error.name;
	return enhanced;
}

function normalizeError(error: unknown): Error {
	return error instanceof Error ? error : new Error(String(error));
}

function isRecoverableScreenshotError(error: unknown): error is HelperCommandError {
	return error instanceof HelperCommandError && !!error.code && RECOVERABLE_SCREENSHOT_ERROR_CODES.has(error.code);
}

function currentRuntimeMode(): ExecutionVariant {
	return isStrictAxMode() ? "stealth" : "default";
}

function executionTrace(
	strategy: ExecutionTrace["strategy"],
	variant: ExecutionVariant,
	metadata: Omit<ExecutionTrace, "strategy" | "runtimeMode" | "variant" | "stealthCompatible"> = {},
): ExecutionTrace {
	return {
		strategy,
		runtimeMode: currentRuntimeMode(),
		variant,
		stealthCompatible: variant === "stealth",
		...metadata,
	};
}

function strictModeBlock(message: string, alternative?: string): never {
	const altClause = alternative ? ` Try instead: ${alternative}` : "";
	throw new Error(
		`${message} Stealth/strict AX mode is enabled, so non-AX, foreground-focus, and cursor fallbacks are blocked.${altClause}`,
	);
}

function settleMsForExecution(execution: ExecutionTrace): number {
	if (execution.strategy === "batch") {
		const actions = execution.actions ?? [];
		return actions.length > 0 && actions.every((action) => action.variant === "stealth") ? 120 : ACTION_SETTLE_MS;
	}
	if (execution.variant === "stealth") {
		switch (execution.strategy) {
			case "ax_focus":
			case "ax_set_value":
				return 80;
			case "ax_action":
			case "browser_open_location":
			case "ax_scroll":
				return 120;
			case "ax_press":
				return 160;
			default:
				return 120;
		}
	}
	return ACTION_SETTLE_MS;
}

function addRefreshHint(error: unknown): Error {
	const message = normalizeError(error).message;
	if (/call screenshot/i.test(message)) {
		return new Error(message);
	}
	return new Error(`${message} Call screenshot again to refresh the current window state.`);
}

function throwIfAborted(signal?: AbortSignal): void {
	if (signal?.aborted) {
		throw new Error("Operation aborted.");
	}
}

async function sleep(ms: number, signal?: AbortSignal): Promise<void> {
	if (ms <= 0) return;
	throwIfAborted(signal);

	await new Promise<void>((resolve, reject) => {
		const timer = setTimeout(() => {
			cleanup();
			resolve();
		}, ms);

		const onAbort = () => {
			cleanup();
			reject(new Error("Operation aborted."));
		};

		const cleanup = () => {
			clearTimeout(timer);
			signal?.removeEventListener("abort", onAbort);
		};

		signal?.addEventListener("abort", onAbort, { once: true });
	});
}

async function withRuntimeLock<T>(work: () => Promise<T>): Promise<T> {
	const previous = runtimeState.queueTail;
	let release!: () => void;
	runtimeState.queueTail = new Promise<void>((resolve) => {
		release = resolve;
	});

	await previous.catch(() => undefined);
	try {
		return await work();
	} finally {
		release();
	}
}

function windowWriteLockKey(target: ResolvedTarget | CurrentTarget): string {
	return target.windowId > 0 ? `pid:${target.pid}:window:${target.windowId}` : `pid:${target.pid}:ref:${target.windowRef ?? target.windowTitle}`;
}

async function withWindowWriteLock<T>(target: ResolvedTarget | CurrentTarget, work: () => Promise<T>): Promise<T> {
	const key = windowWriteLockKey(target);
	const previous = runtimeState.windowWriteQueues.get(key) ?? Promise.resolve();
	let release!: () => void;
	const next = new Promise<void>((resolve) => {
		release = resolve;
	});
	const queued = previous.catch(() => undefined).then(() => next);
	runtimeState.windowWriteQueues.set(key, queued);
	await previous.catch(() => undefined);
	try {
		return await work();
	} finally {
		release();
		if (runtimeState.windowWriteQueues.get(key) === queued) {
			runtimeState.windowWriteQueues.delete(key);
		}
	}
}

function randomStateId(): string {
	try {
		return randomUUID();
	} catch {
		return `cap_${Date.now()}_${Math.random().toString(16).slice(2)}`;
	}
}

function trimOrUndefined(value: string | undefined): string | undefined {
	if (typeof value !== "string") return undefined;
	const trimmed = value.trim();
	return trimmed.length > 0 ? trimmed : undefined;
}

function normalizeText(value: string | undefined): string {
	return (value ?? "").trim().toLowerCase();
}

function toFiniteNumber(value: unknown, fallback = 0): number {
	if (typeof value === "number" && Number.isFinite(value)) return value;
	if (typeof value === "string") {
		const parsed = Number(value);
		if (Number.isFinite(parsed)) return parsed;
	}
	return fallback;
}

function toOptionalString(value: unknown): string | undefined {
	return typeof value === "string" ? value : undefined;
}

function toBoolean(value: unknown): boolean {
	return value === true;
}

function normalizeMouseButton(value: unknown): MouseButtonName {
	if (value === "right" || value === "middle" || value === "left") {
		return value;
	}
	return "left";
}

function normalizeClickCount(value: unknown, fallback = 1): number {
	const count = Math.trunc(toFiniteNumber(value, fallback));
	return Math.max(1, Math.min(3, count));
}

function normalizeScrollDelta(value: unknown): number {
	const delta = Math.round(toFiniteNumber(value, 0));
	return Math.max(-10_000, Math.min(10_000, delta));
}

function normalizeKeyList(value: unknown): string[] {
	return Array.isArray(value) ? value.filter((key): key is string => typeof key === "string" && key.trim().length > 0) : [];
}

/**
 * Validate window-relative LOGICAL POINT coordinates against the latest
 * capture's window frame.
 *
 * Coordinates contract: x in [0, windowWidth], y in [0, windowHeight] -
 * the same units as `framePoints.w`/`framePoints.h` returned by
 * `list_windows`. NOT image pixels. The screenshot image is captured at
 * the display's backing scale (typically 2x on retina), but coordinates
 * are always logical points.
 *
 * Most common bug: the model reads pixel coordinates off the image
 * (e.g. "the close button is at (1700, 50) in this 1920x1080 image")
 * and passes those raw to click() on a 880x440-point window. Image
 * pixels are ~2x larger than logical points; the click lands far past
 * the right edge. The error message below names this trap explicitly
 * so the model can self-correct on the next call.
 */
function ensurePointIsInCapture(
	x: number,
	y: number,
	capture: CurrentCapture,
	errorPrefix = "Coordinates",
): void {
	if (!Number.isFinite(x) || !Number.isFinite(y)) {
		throw new Error(`${errorPrefix} must be finite numbers.`);
	}
	const w = capture.windowWidth;
	const h = capture.windowHeight;
	if (x < 0 || y < 0 || x > w || y > h) {
		const scale = capture.scaleFactor || 1;
		const hint = scale > 1.05
			? ` Image pixels (${capture.width}x${capture.height}) are ~${scale.toFixed(1)}x logical points; if you read this coordinate from the image, divide by ${scale.toFixed(1)} (image pixel \u2192 logical point).`
			: "";
		throw new Error(
			`${errorPrefix} (${Math.round(x)},${Math.round(y)}) are outside the window frame (${Math.round(w)}x${Math.round(h)} logical points). Coordinates are window-relative LOGICAL POINTS, not image pixels.${hint} If the window was resized or moved since the last screenshot, call screenshot again and retry.`,
		);
	}
}

function normalizeDragPath(path: DragParams["path"], capture: CurrentCapture): Array<{ x: number; y: number }> {
	if (!Array.isArray(path) || path.length < 2) {
		throw new Error("drag.path must contain at least two points.");
	}

	return path.map((point, index) => {
		const x = Array.isArray(point) ? toFiniteNumber(point[0], NaN) : toFiniteNumber(point?.x, NaN);
		const y = Array.isArray(point) ? toFiniteNumber(point[1], NaN) : toFiniteNumber(point?.y, NaN);
		ensurePointIsInCapture(x, y, capture, `Drag point ${index + 1}`);
		return { x, y };
	});
}

function validateStateId(stateId?: string): CurrentCapture {
	if (!runtimeState.currentTarget || !runtimeState.currentCapture) {
		throw new Error(MISSING_TARGET_ERROR);
	}
	const supplied = stateId;
	if (supplied && runtimeState.currentCapture.stateId !== supplied) {
		throw new Error(
			`Stale state '${supplied}'. The latest state is '${runtimeState.currentCapture.stateId}' for ${runtimeState.currentTarget.windowRef ?? "the current window"}. Call screenshot${runtimeState.currentTarget.windowRef ? `({ window: "${runtimeState.currentTarget.windowRef}" })` : ""} again and retry.`,
		);
	}
	const stateTarget = runtimeState.currentStateTarget;
	if (stateTarget && (stateTarget.pid !== runtimeState.currentTarget.pid || stateTarget.windowId !== runtimeState.currentTarget.windowId)) {
		throw new Error("The latest state belongs to a different window. Call screenshot for the target window and retry.");
	}
	return runtimeState.currentCapture;
}

function axDiagnosticsFromResult(result: unknown, target: ResolvedTarget): CaptureResult["axDiagnostics"] {
	const raw = result as any;
	const reason = toOptionalString(raw?.reason);
	const debug = raw?.diagnostics;
	if (!reason && debug === undefined) return undefined;
	if (reason === "window_not_found") {
		const windowHint = target.windowRef ? ` Use list_windows and choose an existing content window such as ${target.windowRef}, then call screenshot({ window: "${target.windowRef}" }).` : " Use list_windows and choose an existing content window.";
		return { reason, message: `Accessibility could not resolve the target browser window. Duplicate/empty browser windows can cause this.${windowHint}`, debug };
	}
	return { reason, message: reason ? `Accessibility target listing returned '${reason}'.` : undefined, debug };
}

function parseAxTargets(result: unknown): AxTarget[] {
	const items = Array.isArray(result) ? result : (result as any)?.targets;
	if (!Array.isArray(items)) return [];

	return items
		.map((raw, index) => {
			const target = raw as HelperAxTarget;
			const elementRef = toOptionalString(target?.elementRef);
			if (!elementRef) return undefined;
			const actions = Array.isArray(target?.actions) ? target.actions.filter((value): value is string => typeof value === "string") : [];
			return {
				ref: `@e${index + 1}`,
				elementRef,
				role: toOptionalString(target?.role) ?? "",
				subrole: toOptionalString(target?.subrole) ?? "",
				title: toOptionalString(target?.title) ?? "",
				description: toOptionalString(target?.description) ?? "",
				value: toOptionalString(target?.value) ?? "",
				actions,
				isTextInput: toBoolean(target?.isTextInput),
				canSetValue: toBoolean(target?.canSetValue),
				canFocus: toBoolean(target?.canFocus),
				canPress: toBoolean(target?.canPress),
				canScroll: toBoolean(target?.canScroll),
				canIncrement: toBoolean(target?.canIncrement),
				canDecrement: toBoolean(target?.canDecrement),
				x: toFiniteNumber(target?.x, 0),
				y: toFiniteNumber(target?.y, 0),
				score: Number.isFinite(target?.score) ? Number(target.score) : undefined,
			} as AxTarget;
		})
		.filter((item): item is AxTarget => Boolean(item));
}

function formatAxTargetLabel(target: AxTarget): string {
	const label = target.title || target.description || target.value || "(unlabeled)";
	const capabilities = [
		target.canSetValue ? "setValue" : undefined,
		target.canPress ? "press" : undefined,
		target.canFocus ? "focus" : undefined,
		target.canScroll ? "scroll" : undefined,
		target.canIncrement || target.canDecrement ? "adjust" : undefined,
	].filter((item): item is string => Boolean(item));
	return `${target.ref} ${target.role}${target.subrole ? `/${target.subrole}` : ""} ${JSON.stringify(label)}${capabilities.length ? ` [${capabilities.join(",")}]` : ""}`;
}

function axTargetByRef(ref: string): AxTarget {
	const axTarget = runtimeState.currentAxTargets?.find((candidate) => candidate.ref === ref);
	if (!axTarget) {
		const windowHint = runtimeState.currentTarget?.windowRef ? `({ window: "${runtimeState.currentTarget.windowRef}" })` : "";
		throw new Error(`AX target '${ref}' is stale or not available for the latest state. Call screenshot${windowHint} again and choose a current @e ref.`);
	}
	return axTarget;
}

function axTargetLabelKey(target: AxTarget): string {
	return normalizeText(target.title || target.description || target.value);
}

function isElementRefInvalid(error: unknown): boolean {
	return (error instanceof HelperCommandError && error.code === "element_ref_invalid") || /element reference is no longer valid|element_ref_invalid/i.test(normalizeError(error).message);
}

async function reacquireAxTarget(stale: AxTarget, target: ResolvedTarget, signal?: AbortSignal): Promise<AxTarget | undefined> {
	const refreshed = parseAxTargets(
		await bridgeCommand(
			"axListTargets",
			{ ...nativeWindowRequest(target), limit: 50 },
			{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
		).catch(() => []),
	);
	if (!refreshed.length) return undefined;
	runtimeState.currentAxTargets = refreshed;

	const staleLabel = axTargetLabelKey(stale);
	const candidates = refreshed.filter((candidate) => {
		if (candidate.role !== stale.role) return false;
		if (staleLabel && axTargetLabelKey(candidate) !== staleLabel) return false;
		if (stale.canSetValue && !candidate.canSetValue) return false;
		if (stale.canPress && !candidate.canPress) return false;
		if (stale.canScroll && !candidate.canScroll) return false;
		if (stale.canIncrement && !candidate.canIncrement) return false;
		if (stale.canDecrement && !candidate.canDecrement) return false;
		return true;
	});
	const pool = candidates.length ? candidates : refreshed.filter((candidate) => staleLabel && axTargetLabelKey(candidate) === staleLabel);
	const best = pool.sort((a, b) => Math.hypot(a.x - stale.x, a.y - stale.y) - Math.hypot(b.x - stale.x, b.y - stale.y))[0];
	return best ? { ...best, ref: stale.ref } : undefined;
}

function imageFallbackReason(
	tool: string,
	result: CaptureResult,
	execution: ExecutionTrace,
	imageMode: ImageMode = "auto",
): { reason: NonNullable<ComputerUseDetails["imageReason"]>; message: string } | undefined {
	if (imageMode === "never") return undefined;
	if (imageMode === "always") return { reason: "fallback_recovery", message: "An image was requested explicitly for visual verification." };
	if (execution.fallbackUsed === true) {
		return { reason: "fallback_recovery", message: "The action used a fallback path, so an image is attached for recovery." }
	}
	if (result.axTargets.length === 0) {
		if (isBrowserApp(result.target.appName, result.target.bundleId) && result.axDiagnostics?.reason === "window_not_found") {
			return { reason: "browser_ax_window_unavailable", message: result.axDiagnostics.message ?? "The browser window could not be resolved through Accessibility, so an image is attached for recovery." }
		}
		return { reason: "no_ax_targets", message: "No useful AX targets were found, so an image is attached for vision fallback." }
	}
	const labels = result.axTargets.map((target) => normalizeText(target.title || target.description || target.value)).filter(Boolean)
	const unlabeledCount = result.axTargets.filter((target) => !normalizeText(target.title || target.description || target.value)).length
	const strongTextRoles = new Set(["AXTextField", "AXSearchField", "AXTextArea", "AXTextView", "AXEditableText", "AXComboBox"])
	const strongTargets = result.axTargets.filter((target) => {
		const label = normalizeText(target.title || target.description || target.value)
		return strongTextRoles.has(target.role) || (!!label && (target.actions.includes("AXPress") || target.role === "AXLink" || target.role === "AXButton"))
	})
	if (result.axTargets.length < 3 && strongTargets.length === 0) {
		return { reason: "sparse_ax_targets", message: "Only a few AX targets were found, so an image is attached for extra context." }
	}
	if (strongTargets.length === 0) {
		return { reason: "weak_ax_targets", message: "No strong AX targets were found, so an image is attached for vision fallback." }
	}
	if (result.axTargets.length < 3 && !strongTargets.some((target) => strongTextRoles.has(target.role))) {
		return { reason: "sparse_ax_targets", message: "Only a few AX targets were found, so an image is attached for extra context." }
	}
	if (result.axTargets.length >= 3 && unlabeledCount * 2 > result.axTargets.length) {
		return { reason: "unlabeled_ax_targets", message: "Most AX targets are unlabeled, so an image is attached for vision fallback." }
	}
	if (labels.length > 3 && new Set(labels).size * 2 <= labels.length) {
		return { reason: "duplicated_ax_labels", message: "AX target labels are highly duplicated, so an image is attached for extra context." }
	}
	if (tool === "wait" && isBrowserApp(result.target.appName, result.target.bundleId)) {
		return { reason: "browser_wait_verification", message: "Browser content may have changed visually during wait, so an image is attached for fallback." }
	}
	return undefined
}

function currentTargetOrThrow(): CurrentTarget {
	if (!runtimeState.currentTarget) {
		throw new Error(MISSING_TARGET_ERROR);
	}
	return runtimeState.currentTarget;
}

function emptyActivation(): ActivationFlags {
	return { activated: false, unminimized: false, raised: false };
}

function rejectAllPending(error: Error): void {
	for (const [id, pending] of runtimeState.pending) {
		clearTimeout(pending.timer);
		if (pending.abortListener) {
			pending.abortListener();
		}
		runtimeState.pending.delete(id);
		pending.reject(error);
	}
}

function handleHelperStdoutChunk(chunk: string): void {
	runtimeState.helperStdoutBuffer += chunk;

	while (true) {
		const newlineIndex = runtimeState.helperStdoutBuffer.indexOf("\n");
		if (newlineIndex < 0) break;

		const line = runtimeState.helperStdoutBuffer.slice(0, newlineIndex).trim();
		runtimeState.helperStdoutBuffer = runtimeState.helperStdoutBuffer.slice(newlineIndex + 1);
		if (!line) continue;

		let parsed: any;
		try {
			parsed = JSON.parse(line);
		} catch {
			continue;
		}

		const id = typeof parsed?.id === "string" ? parsed.id : undefined;
		if (!id) continue;

		const pending = runtimeState.pending.get(id);
		if (!pending) continue;
		runtimeState.pending.delete(id);
		clearTimeout(pending.timer);
		if (pending.abortListener) pending.abortListener();

		if (parsed.ok === true) {
			pending.resolve(parsed.result);
		} else {
			const message =
				typeof parsed?.error?.message === "string" ? parsed.error.message : `Helper command '${pending.cmd}' failed.`;
			const code = typeof parsed?.error?.code === "string" ? parsed.error.code : undefined;
			pending.reject(new HelperCommandError(message, code));
		}
	}
}

async function isExecutable(filePath: string): Promise<boolean> {
	try {
		await access(filePath, fsConstants.X_OK);
		return true;
	} catch {
		return false;
	}
}

async function runProcess(
	command: string,
	args: string[],
	timeoutMs: number,
	signal?: AbortSignal,
): Promise<void> {
	throwIfAborted(signal);

	await new Promise<void>((resolve, reject) => {
		const child = spawn(command, args, {
			stdio: ["ignore", "pipe", "pipe"],
		});

		let stderr = "";
		let stdout = "";

		const timer = setTimeout(() => {
			child.kill("SIGTERM");
			cleanup();
			reject(new Error(`Command timed out after ${timeoutMs}ms: ${command} ${args.join(" ")}`));
		}, timeoutMs);

		const onAbort = () => {
			child.kill("SIGTERM");
			cleanup();
			reject(new Error("Operation aborted."));
		};

		const cleanup = () => {
			clearTimeout(timer);
			signal?.removeEventListener("abort", onAbort);
		};

		child.stdout.on("data", (chunk) => {
			stdout += String(chunk);
		});

		child.stderr.on("data", (chunk) => {
			stderr += String(chunk);
		});

		child.on("error", (error) => {
			cleanup();
			reject(error);
		});

		child.on("close", (code) => {
			cleanup();
			if (code === 0) {
				resolve();
				return;
			}
			const output = [stderr.trim(), stdout.trim()].filter(Boolean).join("\n");
			reject(new Error(`Command failed (${code}): ${command} ${args.join(" ")}\n${output}`.trim()));
		});

		signal?.addEventListener("abort", onAbort, { once: true });
	});
}

function appleScriptString(value: string): string {
	return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

async function ensureHelperInstalled(signal?: AbortSignal): Promise<void> {
	const helperAlreadyPresent = await isExecutable(HELPER_STABLE_PATH);
	if (helperAlreadyPresent && runtimeState.helperInstallChecked) {
		return;
	}

	await runProcess(process.execPath, [SETUP_HELPER_SCRIPT, "--runtime"], HELPER_SETUP_TIMEOUT_MS, signal);
	runtimeState.helperInstallChecked = true;

	if (!(await isExecutable(HELPER_STABLE_PATH))) {
		throw new Error(`Failed to install pi-computer-use helper at ${HELPER_STABLE_PATH}.`);
	}
}

function isSshSession(): boolean {
	return Boolean(process.env.SSH_CONNECTION || process.env.SSH_CLIENT || process.env.SSH_TTY);
}

function helperSpawnCommand(): { command: string; args: string[] } {
	const mode = process.env.PI_COMPUTER_USE_GUI_SESSION_LAUNCH ?? "auto";
	const shouldUseGuiSession = mode === "1" || mode === "true" || (mode === "auto" && isSshSession());
	const uid = typeof process.getuid === "function" ? process.getuid() : undefined;
	if (shouldUseGuiSession && process.platform === "darwin" && uid !== undefined) {
		return { command: "launchctl", args: ["asuser", String(uid), HELPER_STABLE_PATH] };
	}
	return { command: HELPER_STABLE_PATH, args: [] };
}

async function startBridgeProcess(): Promise<ChildProcessWithoutNullStreams> {
	if (!(await isExecutable(HELPER_STABLE_PATH))) {
		throw new HelperTransportError(`Computer-use helper is missing at ${HELPER_STABLE_PATH}.`);
	}

	const helperLaunch = helperSpawnCommand();
	const child = spawn(helperLaunch.command, helperLaunch.args, {
		stdio: ["pipe", "pipe", "pipe"],
	});

	child.stdout.setEncoding("utf8");
	child.stderr.setEncoding("utf8");
	child.stdin.setDefaultEncoding("utf8");

	child.stdout.on("data", (chunk: string) => {
		handleHelperStdoutChunk(chunk);
	});

	child.stderr.on("data", (_chunk: string) => {
		// helper diagnostics are intentionally not forwarded to tool output
	});

	child.on("error", (error) => {
		if (runtimeState.helper === child) {
			runtimeState.helper = undefined;
			runtimeState.overlayEnabled = undefined;
			runtimeState.overlayAnimationStyle = undefined;
			runtimeState.overlayAnimationDurationMs = undefined;
			runtimeState.overlayOcclusionAware = undefined;
		}
		rejectAllPending(new HelperTransportError(`Computer-use helper crashed: ${error.message}`));
	});

	child.on("exit", (code, sig) => {
		if (runtimeState.helper === child) {
			runtimeState.helper = undefined;
			runtimeState.overlayEnabled = undefined;
			runtimeState.overlayAnimationStyle = undefined;
			runtimeState.overlayAnimationDurationMs = undefined;
			runtimeState.overlayOcclusionAware = undefined;
		}
		const reason = sig ? `signal ${sig}` : `exit code ${code ?? "unknown"}`;
		rejectAllPending(new HelperTransportError(`Computer-use helper exited (${reason}).`));
	});

	runtimeState.helper = child;
	runtimeState.helperStdoutBuffer = "";
	return child;
}

async function ensureBridgeProcess(): Promise<ChildProcessWithoutNullStreams> {
	if (runtimeState.helper && runtimeState.helper.exitCode === null && !runtimeState.helper.killed) {
		return runtimeState.helper;
	}
	return await startBridgeProcess();
}

async function bridgeCommand<T>(
	cmd: string,
	args: Record<string, unknown> = {},
	options?: { timeoutMs?: number; signal?: AbortSignal },
): Promise<T> {
	const timeoutMs = options?.timeoutMs ?? COMMAND_TIMEOUT_MS;

	for (let attempt = 0; attempt < 2; attempt += 1) {
		throwIfAborted(options?.signal);
		const helper = await ensureBridgeProcess();
		const id = `req_${++runtimeState.requestSequence}`;

		try {
			const result = await new Promise<T>((resolve, reject) => {
				const payload = `${JSON.stringify({ id, cmd, ...args })}\n`;
				const timer = setTimeout(() => {
					runtimeState.pending.delete(id);
					reject(new HelperTransportError(`Helper command '${cmd}' timed out after ${timeoutMs}ms.`));
				}, timeoutMs);

				const pending: PendingRequest = {
					cmd,
					resolve,
					reject,
					timer,
				};

				const abortListener = () => {
					if (runtimeState.pending.delete(id)) {
						clearTimeout(timer);
						reject(new Error("Operation aborted."));
					}
				};

				if (options?.signal) {
					options.signal.addEventListener("abort", abortListener, { once: true });
					pending.abortListener = () => options.signal?.removeEventListener("abort", abortListener);
				}

				runtimeState.pending.set(id, pending);

				helper.stdin.write(payload, (error) => {
					if (!error) return;
					const p = runtimeState.pending.get(id);
					if (!p) return;
					runtimeState.pending.delete(id);
					clearTimeout(p.timer);
					if (p.abortListener) p.abortListener();
					reject(new HelperTransportError(`Failed to send command '${cmd}': ${error.message}`));
				});
			});

			return result;
		} catch (error) {
			if (error instanceof HelperTransportError && attempt === 0) {
				stopBridge();
				continue;
			}
			throw normalizeError(error);
		}
	}

	throw new Error(`Helper command '${cmd}' failed.`);
}

async function checkPermissions(signal?: AbortSignal): Promise<PermissionStatus> {
	const result = await bridgeCommand<any>("checkPermissions", {}, { signal });
	return {
		accessibility: toBoolean(result?.accessibility),
		screenRecording: toBoolean(result?.screenRecording),
	};
}

/**
 * Send overlay enable/disable + animation config to the helper when the
 * user's config has flipped since the last sync. Cheap no-op when state
 * is already correct. Errors are swallowed: the overlay is decorative
 * and must never block a tool call. We reset cached state on error so
 * the next call retries.
 */
async function syncOverlayState(signal?: AbortSignal): Promise<void> {
	const cfg = getOverlayConfig();
	const desiredEnabled = cfg.enabled;
	const desiredStyle = cfg.animation_style;
	const desiredDuration = cfg.animation_duration_ms;
	const desiredOcclusion = cfg.occlusion_aware;

	const enabledChanged = runtimeState.overlayEnabled !== desiredEnabled;
	const styleChanged = runtimeState.overlayAnimationStyle !== desiredStyle;
	const durationChanged = runtimeState.overlayAnimationDurationMs !== desiredDuration;
	const occlusionChanged = runtimeState.overlayOcclusionAware !== desiredOcclusion;
	if (!enabledChanged && !styleChanged && !durationChanged && !occlusionChanged) return;

	try {
		if (enabledChanged) {
			if (desiredEnabled) {
				await bridgeCommand("overlayEnable", {}, { signal });
			} else {
				await bridgeCommand("overlayDisable", {}, { signal });
			}
			runtimeState.overlayEnabled = desiredEnabled;
		}
		if (desiredEnabled && (styleChanged || durationChanged || occlusionChanged)) {
			await bridgeCommand(
				"overlayConfigure",
				{ style: desiredStyle, durationMs: desiredDuration, occlusionAware: desiredOcclusion },
				{ signal },
			);
			runtimeState.overlayAnimationStyle = desiredStyle;
			runtimeState.overlayAnimationDurationMs = desiredDuration;
			runtimeState.overlayOcclusionAware = desiredOcclusion;
		}
	} catch {
		runtimeState.overlayEnabled = undefined;
		runtimeState.overlayAnimationStyle = undefined;
		runtimeState.overlayAnimationDurationMs = undefined;
		runtimeState.overlayOcclusionAware = undefined;
	}
}

async function ensureReady(ctx: ExtensionContext, signal?: AbortSignal): Promise<void> {
	loadComputerUseConfig(ctx.cwd);

	if (process.platform !== "darwin") {
		throw new Error(NON_MACOS_ERROR);
	}

	throwIfAborted(signal);
	await ensureHelperInstalled(signal);
	await ensureBridgeProcess();
	await syncOverlayState(signal);

	const now = Date.now();
	const canUseCachedPermissions =
		runtimeState.permissionStatus &&
		runtimeState.permissionStatus.accessibility &&
		runtimeState.permissionStatus.screenRecording &&
		now - runtimeState.lastPermissionCheckAt < 2_000;
	if (canUseCachedPermissions) {
		return;
	}

	let status = await checkPermissions(signal);
	runtimeState.permissionStatus = status;
	runtimeState.lastPermissionCheckAt = now;

	if (!status.accessibility || !status.screenRecording) {
		status = await ensurePermissions(
			ctx,
			{
				checkPermissions: (permissionSignal) => checkPermissions(permissionSignal ?? signal),
				openPermissionPane: async (kind, permissionSignal) => {
					await bridgeCommand("openPermissionPane", { kind }, { signal: permissionSignal ?? signal });
				},
				copyHelperPathToClipboard: async (permissionSignal) => {
					await runProcess("osascript", ["-e", `set the clipboard to ${appleScriptString(HELPER_STABLE_PATH)}`], COMMAND_TIMEOUT_MS, permissionSignal ?? signal);
				},
			},
			HELPER_STABLE_PATH,
			signal,
		);
	}

	runtimeState.permissionStatus = status;
	runtimeState.lastPermissionCheckAt = Date.now();
}

export async function ensureComputerUseSetup(ctx: ExtensionContext, signal?: AbortSignal): Promise<void> {
	await ensureReady(ctx, signal);
}

function parseApps(result: unknown): HelperApp[] {
	const array = Array.isArray(result) ? result : (result as any)?.apps;
	if (!Array.isArray(array)) return [];

	return array
		.map((raw) => {
			const pid = Math.trunc(toFiniteNumber((raw as any)?.pid, NaN));
			if (!Number.isFinite(pid) || pid <= 0) return undefined;
			const appName = toOptionalString((raw as any)?.appName) ?? "Unknown App";
			return {
				appName,
				bundleId: toOptionalString((raw as any)?.bundleId),
				pid,
				isFrontmost: toBoolean((raw as any)?.isFrontmost),
			} as HelperApp;
		})
		.filter((item): item is HelperApp => Boolean(item));
}

function parseFramePoints(raw: unknown): FramePoints {
	const frame = (raw as any)?.framePoints ?? {};
	return {
		x: toFiniteNumber(frame.x, 0),
		y: toFiniteNumber(frame.y, 0),
		w: Math.max(1, toFiniteNumber(frame.w, 1)),
		h: Math.max(1, toFiniteNumber(frame.h, 1)),
	};
}

function parseWindows(result: unknown): HelperWindow[] {
	const array = Array.isArray(result) ? result : (result as any)?.windows;
	if (!Array.isArray(array)) return [];

	return array.map((raw) => {
		const isMinimized = toBoolean((raw as any)?.isMinimized);
		const isOnscreen = toBoolean((raw as any)?.isOnscreen);
		// Native helper supplies `isOnActiveSpace` directly when it can,
		// but fall back to (minimized OR onscreen) for older binaries.
		const rawOnActive = (raw as any)?.isOnActiveSpace;
		const isOnActiveSpace =
			typeof rawOnActive === "boolean" ? rawOnActive : isMinimized || isOnscreen;
		return {
			windowId: Number.isFinite((raw as any)?.windowId) ? Math.trunc((raw as any).windowId) : undefined,
			windowRef: toOptionalString((raw as any)?.windowRef),
			title: toOptionalString((raw as any)?.title) ?? "",
			framePoints: parseFramePoints(raw),
			scaleFactor: Math.max(1, toFiniteNumber((raw as any)?.scaleFactor, 1)),
			isMinimized,
			isOnscreen,
			isOnActiveSpace,
			isMain: toBoolean((raw as any)?.isMain),
			isFocused: toBoolean((raw as any)?.isFocused),
		};
	});
}

async function listApps(signal?: AbortSignal): Promise<HelperApp[]> {
	const result = await bridgeCommand<unknown>("listApps", {}, { signal });
	return parseApps(result);
}

async function listWindows(pid: number, signal?: AbortSignal): Promise<HelperWindow[]> {
	const result = await bridgeCommand<unknown>("listWindows", { pid }, { signal });
	return parseWindows(result);
}

function appMatchesWindowQuery(app: HelperApp, query: ListWindowsParams): boolean {
	const appQuery = trimOrUndefined(query.app);
	const bundleQuery = trimOrUndefined(query.bundleId);
	const pidQuery = Number.isFinite(query.pid) ? Math.trunc(query.pid!) : undefined;

	if (pidQuery !== undefined && app.pid !== pidQuery) return false;
	if (bundleQuery && normalizeText(app.bundleId ?? "") !== normalizeText(bundleQuery)) return false;
	if (appQuery && !normalizeText(app.appName).includes(normalizeText(appQuery))) return false;
	return true;
}

/**
 * One-line summary of the agent's current operating mode. Surfaced at
 * the top of screenshot / list_apps / list_windows responses so the
 * agent learns its constraints (especially stealth mode) on the very
 * first call instead of by failing into the strict-mode error message.
 *
 * Format is intentionally compact and front-loaded with the most
 * surprising thing ("stealth") so the agent's tool-use planner
 * notices it without us having to teach the agent about a long
 * paragraph in the skill.
 *
 * Always renders even outside stealth so the agent gets a consistent
 * mental model of what's available; on by default in normal mode is
 * cheap and removes the "oh, AppleScript existed all along" surprise.
 */
function formatModeMarker(): string {
	const config = getComputerUseConfig();
	const bits: string[] = [];
	bits.push(`mode: ${config.stealth_mode ? "stealth" : "normal"}`);
	if (config.stealth_mode) {
		// Stealth model v2: stealth blocks SURPRISE FOCUS CHANGES, not
		// input mechanism. Coordinate clicks, keypresses, type_text,
		// scroll, drag all work via per-PID delivery. The only blocked
		// ops are those that would surface a window without explicit
		// user permission: surface_window (gated, asks user), launch_app
		// with activate=true (gated, asks user), navigate_browser AppleScript
		// (gated, agent should use Cmd+L + set_text + Enter instead).
		bits.push("rule: don't change frontmost without user permission; everything else is allowed");
		bits.push("focus-changing tools (need user permission): surface_window, launch_app({activate:true})");
	}
	bits.push(`apple_script: ${config.apple_script.enabled ? "enabled" : "disabled"}`);
	bits.push(`browser_use: ${config.browser_use ? "allowed" : "blocked"}`);
	return bits.join(" \u00b7 ");
}

function formatAppLine(app: ListAppsDetails["apps"][number]): string {
	const flags = [app.isFrontmost ? "frontmost" : undefined, app.browserUseAllowed ? undefined : "browser_use_disabled"]
		.filter(Boolean)
		.join(", ");
	return `- ${app.app}${app.bundleId ? ` (${app.bundleId})` : ""}, pid ${app.pid}${flags ? ` [${flags}]` : ""}`;
}

function formatWindowLine(window: ListWindowsDetails["windows"][number]): string {
	const flags = [
		window.isFocused ? "focused" : undefined,
		window.isMain ? "main" : undefined,
		window.isOnscreen ? "onscreen" : undefined,
		window.isMinimized ? "minimized" : undefined,
		window.isOnActiveSpace ? undefined : "off_active_space",
		window.browserUseAllowed ? undefined : "browser_use_disabled",
	]
		.filter(Boolean)
		.join(", ");
	const frame = `${Math.round(window.framePoints.x)},${Math.round(window.framePoints.y)} ${Math.round(window.framePoints.w)}x${Math.round(window.framePoints.h)}`;
	const id = window.windowId ? `windowId ${window.windowId}` : window.nativeWindowRef ? `nativeWindowRef ${window.nativeWindowRef}` : "unstable window id";
	return `- ${window.windowRef} ${window.app} — ${window.windowTitle || "(untitled)"} (${id}, pid ${window.pid}, frame ${frame}, score ${window.score}${flags ? `, ${flags}` : ""})`;
}

async function getFrontmost(signal?: AbortSignal): Promise<FrontmostResult> {
	const result = await bridgeCommand<any>("getFrontmost", {}, { signal });
	const pid = Math.trunc(toFiniteNumber(result?.pid, NaN));
	if (!Number.isFinite(pid) || pid <= 0) {
		throw new Error("No frontmost app was available for screenshot targeting.");
	}

	return {
		appName: toOptionalString(result?.appName) ?? "Unknown App",
		bundleId: toOptionalString(result?.bundleId),
		pid,
		windowTitle: toOptionalString(result?.windowTitle),
		windowId: Number.isFinite(result?.windowId) ? Math.trunc(result.windowId) : undefined,
	};
}

async function beginInputSuppression(signal?: AbortSignal): Promise<void> {
	await bridgeCommand("beginInputSuppression", {}, { signal, timeoutMs: COMMAND_TIMEOUT_MS });
}

async function endInputSuppression(signal?: AbortSignal): Promise<void> {
	await bridgeCommand("endInputSuppression", {}, { signal, timeoutMs: COMMAND_TIMEOUT_MS }).catch(() => undefined);
}

async function restoreUserFocus(target: FrontmostResult, signal?: AbortSignal): Promise<void> {
	const restoreResult = await bridgeCommand<RestoreUserFocusResult>(
		"restoreUserFocus",
		{ pid: target.pid, windowTitle: target.windowTitle },
		{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
	).catch(() => undefined);

	if (isStrictAxMode() || toBoolean(restoreResult?.windowRestored) || toBoolean(restoreResult?.appRestored)) {
		return;
	}

	const activateTarget = target.bundleId
		? `application id "${escapeAppleScriptString(target.bundleId)}"`
		: `application "${escapeAppleScriptString(target.appName)}"`;
	await runAppleScript([`tell ${activateTarget} to activate`], signal).catch(() => undefined);
}

/**
 * Stealth model v2 surfaces ZERO windows on its own. The only path
 * that should change frontmost is surface_window, which the agent
 * calls explicitly after asking the user for permission. Every other
 * input op goes through CGEventPostToPid (per-PID delivery) which
 * lands in the target app's event queue without raising the window
 * or changing the user's frontmost.
 *
 * focusControlledWindow used to be the "raise the window before posting
 * raw input" helper, gated on stealth. Under v2 it is dead - kept as a
 * stub that throws so any straggler caller fails loudly instead of
 * silently disturbing the user. All known callers have been removed.
 */
async function focusControlledWindow(_target: ResolvedTarget, _signal?: AbortSignal): Promise<void> {
	throw new Error(
		"focusControlledWindow is not part of stealth model v2. Input ops post via CGEventPostToPid; surface_window is the only sanctioned focus-change path.",
	);
}

function isBrowserApp(appName: string, bundleId?: string): boolean {
	return BROWSER_BUNDLE_IDS.has(bundleId ?? "") || BROWSER_APP_NAMES.has(normalizeText(appName));
}

function assertBrowserUseAllowed(target: { appName: string; bundleId?: string }): void {
	if (!isBrowserUseEnabled() && isBrowserApp(target.appName, target.bundleId)) {
		throw new Error(
			`Browser use is disabled by pi-computer-use config, so '${target.appName}' cannot be controlled. Enable browser_use in ~/.pi/agent/extensions/pi-computer-use.json or .pi/computer-use.json to allow browser windows.`,
		);
	}
}

function windowIdentity(window: HelperWindow): string {
	if (window.windowId && window.windowId > 0) {
		return `id:${window.windowId}`;
	}
	if (window.windowRef) {
		return `ref:${window.windowRef}`;
	}
	const { x, y, w, h } = window.framePoints;
	return `title:${normalizeText(window.title)}|frame:${Math.round(x)},${Math.round(y)},${Math.round(w)},${Math.round(h)}`;
}

function windowRecordIdentity(record: Pick<WindowRefRecord, "pid" | "windowId" | "nativeWindowRef" | "windowTitle" | "framePoints">): string {
	if (record.windowId && record.windowId > 0) {
		return `pid:${record.pid}|id:${record.windowId}`;
	}
	if (record.nativeWindowRef) {
		return `pid:${record.pid}|ref:${record.nativeWindowRef}`;
	}
	const { x, y, w, h } = record.framePoints;
	return `pid:${record.pid}|title:${normalizeText(record.windowTitle)}|frame:${Math.round(x)},${Math.round(y)},${Math.round(w)},${Math.round(h)}`;
}

function storeWindowRef(record: Omit<WindowRefRecord, "ref">): WindowRefRecord {
	const identity = windowRecordIdentity(record);
	const existingRef = runtimeState.windowRefByIdentity.get(identity);
	if (existingRef) {
		const existing = runtimeState.windowRefs.get(existingRef);
		if (existing) {
			const updated = { ...record, ref: existingRef };
			runtimeState.windowRefs.set(existingRef, updated);
			return updated;
		}
	}

	const ref = `@w${runtimeState.nextWindowRefIndex++}`;
	const stored = { ...record, ref };
	runtimeState.windowRefByIdentity.set(identity, ref);
	runtimeState.windowRefs.set(ref, stored);
	return stored;
}

function storeWindowRefForTarget(target: ResolvedTarget): string {
	return storeWindowRef({
		appName: target.appName,
		bundleId: target.bundleId,
		pid: target.pid,
		windowTitle: target.windowTitle,
		windowId: target.windowId > 0 ? target.windowId : undefined,
		framePoints: target.framePoints,
		scaleFactor: target.scaleFactor,
		isMinimized: target.isMinimized,
		isOnscreen: target.isOnscreen,
		isOnActiveSpace: target.isOnActiveSpace,
		isMain: target.isMain,
		isFocused: target.isFocused,
	}).ref;
}

function storeWindowRefForAppWindow(app: HelperApp, window: HelperWindow): WindowRefRecord {
	return storeWindowRef({
		appName: app.appName,
		bundleId: app.bundleId,
		pid: app.pid,
		windowTitle: window.title || "(untitled)",
		windowId: window.windowId,
		nativeWindowRef: window.windowRef,
		framePoints: window.framePoints,
		scaleFactor: window.scaleFactor,
		isMinimized: window.isMinimized,
		isOnscreen: window.isOnscreen,
		isOnActiveSpace: window.isOnActiveSpace,
		isMain: window.isMain,
		isFocused: window.isFocused,
	});
}

function escapeAppleScriptString(value: string): string {
	return value.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
}

function buildBrowserNewWindowAppleScript(app: HelperApp): string[] | undefined {
	const normalizedName = normalizeText(app.appName);
	const target = app.bundleId
		? `application id "${escapeAppleScriptString(app.bundleId)}"`
		: `application "${escapeAppleScriptString(app.appName)}"`;

	if (app.bundleId === "com.apple.Safari" || normalizedName === "safari") {
		return [`tell ${target} to make new document`];
	}

	if (CHROME_FAMILY_BUNDLE_IDS.has(app.bundleId ?? "") || CHROME_FAMILY_APP_NAMES.has(normalizedName)) {
		return [`tell ${target} to make new window`];
	}

	if (app.bundleId === "org.mozilla.firefox" || normalizedName === "firefox") {
		return [
			`tell ${target} to activate`,
			'tell application "System Events" to keystroke "n" using command down',
		];
	}

	return undefined;
}

async function runAppleScript(lines: string[], signal?: AbortSignal): Promise<void> {
	const args = lines.flatMap((line) => ["-e", line]);
	try {
		await runProcess("osascript", args, BROWSER_WINDOW_OPEN_TIMEOUT_MS, signal);
	} catch (error) {
		throw appendBrowserJavaScriptAppleEventsHint(normalizeError(error));
	}
}

function browserOpenLocationAppleScript(target: ResolvedTarget, url: string): string[] | undefined {
	if (!isBrowserApp(target.appName, target.bundleId)) return undefined;
	const appTarget = target.bundleId
		? `application id "${escapeAppleScriptString(target.bundleId)}"`
		: `application "${escapeAppleScriptString(target.appName)}"`;
	const escapedUrl = escapeAppleScriptString(url);
	const normalizedName = normalizeText(target.appName);
	if (target.bundleId === "com.apple.Safari" || normalizedName === "safari") {
		return [`tell ${appTarget} to set URL of front document to "${escapedUrl}"`];
	}
	if (CHROME_FAMILY_BUNDLE_IDS.has(target.bundleId ?? "") || CHROME_FAMILY_APP_NAMES.has(normalizedName)) {
		return [`tell ${appTarget} to set URL of active tab of front window to "${escapedUrl}"`];
	}
	return undefined;
}

async function openBrowserLocationFromPendingAddress(keys: string[], target: ResolvedTarget, signal?: AbortSignal): Promise<boolean> {
	const isEnter = keys.length === 1 && ["enter", "return"].includes(keys[0]?.trim().toLowerCase());
	const pending = runtimeState.pendingBrowserAddress;
	if (!pending) return false;
	if (!isEnter) {
		runtimeState.pendingBrowserAddress = undefined;
		return false;
	}
	if (pending.pid !== target.pid || pending.windowId !== target.windowId) {
		runtimeState.pendingBrowserAddress = undefined;
		return false;
	}
	const script = browserOpenLocationAppleScript(target, pending.text);
	if (!script) return false;
	runtimeState.pendingBrowserAddress = undefined;
	await runAppleScript(script, signal);
	return true;
}

function findNewWindow(before: HelperWindow[], after: HelperWindow[]): HelperWindow | undefined {
	const previous = new Set(before.map(windowIdentity));
	const added = after.filter((window) => !previous.has(windowIdentity(window)));
	if (added.length > 0) {
		return choosePreferredWindow(added, "browser");
	}

	const promoted = after.filter((window) => {
		const match = before.find((candidate) => windowIdentity(candidate) === windowIdentity(window));
		if (!match) return false;
		return (window.isFocused && !match.isFocused) || (window.isMain && !match.isMain);
	});
	if (promoted.length > 0) {
		return choosePreferredWindow(promoted, "browser");
	}

	return undefined;
}

async function openIsolatedBrowserWindow(app: HelperApp, signal?: AbortSignal): Promise<HelperWindow | undefined> {
	const script = buildBrowserNewWindowAppleScript(app);
	if (!script) {
		return undefined;
	}
	if (isStrictAxMode()) {
		strictModeBlock(
			`Strict AX mode cannot create an isolated browser window for '${app.appName}' because that bootstrap is not AX-only. Open a dedicated browser window first, then call screenshot again.`,
		);
	}

	const previousFrontmost = await getFrontmost(signal).catch(() => undefined);
	const before = await listWindows(app.pid, signal);
	await runAppleScript(script, signal);

	await beginInputSuppression(signal);
	try {
		for (let attempt = 0; attempt < BROWSER_WINDOW_OPEN_ATTEMPTS; attempt += 1) {
			await sleep(BROWSER_WINDOW_OPEN_POLL_MS, signal);
			const after = await listWindows(app.pid, signal);
			const created = findNewWindow(before, after);
			if (created) {
				return created;
			}
			const focused = after.find((window) => window.isFocused) ?? after.find((window) => window.isMain);
			if (focused && !before.some((window) => windowIdentity(window) === windowIdentity(focused))) {
				return focused;
			}
		}

		return undefined;
	} finally {
		if (previousFrontmost) {
			await restoreUserFocus(previousFrontmost, signal);
		}
		await endInputSuppression(signal);
	}
}

function choosePreferredWindow(windows: HelperWindow[], appName: string): HelperWindow {
	if (!windows.length) {
		throw new Error(`No controllable window was found in app '${appName}'.`);
	}

	const scored = [...windows].sort((a, b) => scoreWindow(b) - scoreWindow(a));
	return scored[0];
}

function scoreWindow(window: HelperWindow): number {
	let score = 0;
	if (window.isFocused) score += 100;
	if (window.isMain) score += 80;
	if (!window.isMinimized) score += 40;
	if (window.isOnscreen) score += 20;
	// Off-Space windows are still controllable but the user can't see
	// them right now. Bias the auto-selection away from them so we
	// only land there when there's nothing else.
	if (!window.isOnActiveSpace) score -= 30;
	if (window.windowId && window.windowId > 0) score += 10;
	if (window.title.trim().length > 0) score += 2;
	return score;
}

function summarizeWindowCandidate(window: HelperWindow): string {
	const flags = [
		window.isFocused ? "focused" : undefined,
		window.isMain ? "main" : undefined,
		window.isOnscreen ? "onscreen" : undefined,
		window.isMinimized ? "minimized" : undefined,
		window.isOnActiveSpace ? undefined : "off_active_space",
	]
		.filter(Boolean)
		.join(",");
	return `${window.title || "(untitled)"} [score=${scoreWindow(window)}${flags ? `, ${flags}` : ""}]`;
}

function summarizeWindowCandidates(windows: HelperWindow[], limit = 6): string {
	return [...windows]
		.sort((a, b) => scoreWindow(b) - scoreWindow(a))
		.slice(0, limit)
		.map(summarizeWindowCandidate)
		.join("; ");
}

function chooseRankedWindowOrUndefined(windows: HelperWindow[]): HelperWindow | undefined {
	if (windows.length === 0) return undefined;
	const ranked = [...windows].sort((a, b) => scoreWindow(b) - scoreWindow(a));
	if (ranked.length === 1) return ranked[0];
	const topScore = scoreWindow(ranked[0]);
	const nextScore = scoreWindow(ranked[1]);
	return topScore >= nextScore + 25 ? ranked[0] : undefined;
}

function chooseAppByQuery(apps: HelperApp[], appQuery: string): HelperApp {
	const query = normalizeText(appQuery);
	const exactMatches = apps.filter((app) => normalizeText(app.appName) === query);
	if (exactMatches.length === 1) return exactMatches[0];
	if (exactMatches.length > 1) {
		return exactMatches.find((app) => app.isFrontmost) ?? exactMatches[0];
	}

	const partialMatches = apps.filter((app) => normalizeText(app.appName).includes(query));
	if (partialMatches.length === 0) {
		const running = apps.slice(0, 12).map((app) => app.appName).join(", ");
		throw new Error(`App '${appQuery}' is not running. Running apps: ${running || "none"}.`);
	}
	if (partialMatches.length === 1) {
		return partialMatches[0];
	}

	const candidates = partialMatches.map((app) => app.appName).join(", ");
	throw new Error(`App name '${appQuery}' is ambiguous (${candidates}). Use a more specific app name.`);
}

function chooseWindowByTitle(windows: HelperWindow[], windowTitle: string, appName: string): HelperWindow {
	const query = normalizeText(windowTitle);
	const exactMatches = windows.filter((window) => normalizeText(window.title) === query);
	if (exactMatches.length === 1) return exactMatches[0];
	if (exactMatches.length > 1) {
		const clearWinner = chooseRankedWindowOrUndefined(exactMatches);
		if (clearWinner) return clearWinner;
		throw new Error(
			`Window title '${windowTitle}' is ambiguous in app '${appName}'. Candidates: ${summarizeWindowCandidates(exactMatches)}.`,
		);
	}

	const partialMatches = windows.filter((window) => normalizeText(window.title).includes(query));
	if (partialMatches.length === 0) {
		throw new Error(
			`Window '${windowTitle}' was not found in app '${appName}'. Available windows: ${summarizeWindowCandidates(windows)}.`,
		);
	}
	if (partialMatches.length === 1) return partialMatches[0];
	const clearWinner = chooseRankedWindowOrUndefined(partialMatches);
	if (clearWinner) return clearWinner;

	throw new Error(
		`Window title '${windowTitle}' is ambiguous in app '${appName}'. Candidates: ${summarizeWindowCandidates(partialMatches)}.`,
	);
}

function toResolvedTarget(app: HelperApp, window: HelperWindow): ResolvedTarget {
	const baseTarget = {
		appName: app.appName,
		bundleId: app.bundleId,
		pid: app.pid,
		windowTitle: window.title || "(untitled)",
		windowId: typeof window.windowId === "number" ? window.windowId : 0,
		nativeWindowRef: window.windowRef,
		framePoints: window.framePoints,
		scaleFactor: window.scaleFactor,
		isMinimized: window.isMinimized,
		isOnscreen: window.isOnscreen,
		isOnActiveSpace: window.isOnActiveSpace,
		isMain: window.isMain,
		isFocused: window.isFocused,
	};
	return { ...baseTarget, windowRef: storeWindowRefForAppWindow(app, window).ref };
}

function nativeWindowRequest(target: Pick<CurrentTarget, "pid" | "windowId" | "nativeWindowRef">): { pid: number; windowId: number; windowRef?: string } {
	return { pid: target.pid, windowId: target.windowId, windowRef: target.nativeWindowRef };
}

/**
 * Build the canonical capture-context payload for any input op that
 * takes coordinates. Includes:
 *   - captureWidth/captureHeight (image-pixel dimensions, kept for
 *     request-shape compat with the helper but ignored under the v3
 *     coordinate contract)
 *   - windowFramePoints {x,y,w,h} (logical points) so the helper can
 *     skip the SCK currentWindowBounds round-trip and use the cached
 *     frame the TS layer already knows about
 */
function captureRequest(capture: CurrentCapture): {
	captureWidth: number;
	captureHeight: number;
	windowFramePoints: { x: number; y: number; w: number; h: number };
} {
	return {
		captureWidth: capture.width,
		captureHeight: capture.height,
		windowFramePoints: { ...capture.framePoints },
	};
}

function setCurrentTarget(target: ResolvedTarget): void {
	assertBrowserUseAllowed(target);
	const windowRef = target.windowRef ?? storeWindowRefForTarget(target);
	runtimeState.currentTarget = {
		appName: target.appName,
		bundleId: target.bundleId,
		pid: target.pid,
		windowTitle: target.windowTitle,
		windowId: target.windowId,
		windowRef,
		nativeWindowRef: target.nativeWindowRef,
	};
}

function normalizeWindowSelector(selector: WindowSelector | undefined): string | undefined {
	if (typeof selector === "number" && Number.isFinite(selector)) return String(Math.trunc(selector));
	if (typeof selector === "string") return trimOrUndefined(selector);
	return undefined;
}

async function resolveTargetByWindowSelector(selector: WindowSelector, signal?: AbortSignal): Promise<ResolvedTarget> {
	const normalized = normalizeWindowSelector(selector);
	if (!normalized) {
		throw new Error("window target must be a non-empty @w ref or numeric windowId.");
	}

	const current = runtimeState.currentTarget;
	if (current?.windowRef === normalized) {
		return await resolveCurrentTarget(signal);
	}

	const fromRef = runtimeState.windowRefs.get(normalized);
	if (fromRef) {
		const app: HelperApp = { appName: fromRef.appName, bundleId: fromRef.bundleId, pid: fromRef.pid };
		const windows = await listWindows(fromRef.pid, signal);
		const match =
			(fromRef.windowId ? windows.find((window) => window.windowId === fromRef.windowId) : undefined) ??
			(fromRef.nativeWindowRef ? windows.find((window) => window.windowRef === fromRef.nativeWindowRef) : undefined) ??
			windows.find((window) => normalizeText(window.title || "(untitled)") === normalizeText(fromRef.windowTitle));
		if (!match) {
			throw new Error(`Window ref '${normalized}' is stale. Call list_windows again and choose a current window.`);
		}
		const resolved = toResolvedTarget(app, match);
		setCurrentTarget(resolved);
		return resolved;
	}

	const numericWindowId = Number(normalized);
	if (Number.isInteger(numericWindowId) && numericWindowId > 0) {
		const apps = await listApps(signal);
		for (const app of apps) {
			const windows = await listWindows(app.pid, signal);
			const match = windows.find((window) => window.windowId === numericWindowId);
			if (match) {
				assertBrowserUseAllowed(app);
				const resolved = toResolvedTarget(app, match);
				setCurrentTarget(resolved);
				return resolved;
			}
		}
		throw new Error(`Window id '${numericWindowId}' was not found. Call list_windows again and choose a current window.`);
	}

	if (normalized.startsWith("@w")) {
		throw new Error(`Window ref '${normalized}' is not available in this session. Call list_windows first.`);
	}
	throw new Error(`Unsupported window target '${normalized}'. Use a @w ref from list_windows or a numeric windowId.`);
}

async function selectWindowIfProvided(selector: WindowSelector | undefined, signal?: AbortSignal): Promise<void> {
	if (!normalizeWindowSelector(selector)) return;
	const previous = runtimeState.currentTarget;
	const selected = await resolveTargetByWindowSelector(selector!, signal);
	const changedWindow =
		!previous ||
		previous.pid !== selected.pid ||
		(previous.windowId > 0 && selected.windowId > 0 ? previous.windowId !== selected.windowId : previous.windowRef !== selected.windowRef);
	if (changedWindow) {
		runtimeState.currentCapture = undefined;
		runtimeState.currentAxTargets = undefined;
	}
}

async function resolveCurrentTarget(signal?: AbortSignal): Promise<ResolvedTarget> {
	const current = currentTargetOrThrow();
	const windows = await listWindows(current.pid, signal);
	if (!windows.length) {
		throw new Error(CURRENT_TARGET_GONE_ERROR);
	}

	const hadStableWindowId = current.windowId > 0;
	const titleQuery = normalizeText(current.windowTitle);
	let match = hadStableWindowId ? windows.find((window) => window.windowId !== undefined && window.windowId === current.windowId) : undefined;
	if (!match) {
		const exactTitleMatches = titleQuery && titleQuery !== "(untitled)" ? windows.filter((window) => normalizeText(window.title) === titleQuery) : [];
		if (exactTitleMatches.length === 1) {
			match = exactTitleMatches[0];
		} else if (exactTitleMatches.length > 1) {
			match = chooseRankedWindowOrUndefined(exactTitleMatches);
			if (!match) {
				throw new Error(
					`${CURRENT_TARGET_GONE_ERROR} Multiple windows now match '${current.windowTitle}': ${summarizeWindowCandidates(exactTitleMatches)}.`,
				);
			}
		}
	}

	if (!match && !hadStableWindowId) {
		match = chooseRankedWindowOrUndefined(windows);
	}

	if (!match) {
		throw new Error(CURRENT_TARGET_GONE_ERROR);
	}

	// If the only match we found is off-Space, the agent should know
	// to either wake it or pick something else. Surface a specific
	// error so the recovery loop is obvious.
	if (!match.isOnActiveSpace && !match.isMinimized) {
		const windowRef = storeWindowRefForAppWindow({ appName: current.appName, bundleId: current.bundleId, pid: current.pid }, match).ref;
		throw new Error(`${CURRENT_TARGET_OFF_SPACE_ERROR} Suggested call: wake_window({ windowRef: "${windowRef}" }).`);
	}

	const app: HelperApp = {
		appName: current.appName,
		bundleId: current.bundleId,
		pid: current.pid,
	};

	const resolved = toResolvedTarget(app, match);
	setCurrentTarget(resolved);
	return resolved;
}

async function resolveFrontmostTarget(signal?: AbortSignal): Promise<ResolvedTarget> {
	const frontmost = await getFrontmost(signal);
	const apps = await listApps(signal);
	const app = apps.find((candidate) => candidate.pid === frontmost.pid) ?? {
		appName: frontmost.appName,
		bundleId: frontmost.bundleId,
		pid: frontmost.pid,
	};

	const windows = await listWindows(frontmost.pid, signal);
	if (!windows.length) {
		throw new Error("No frontmost controllable window was found. Open an app window and call screenshot again.");
	}

	if (isBrowserApp(app.appName, app.bundleId)) {
		assertBrowserUseAllowed(app);
	}

	let selected = windows.find((window) => window.windowId !== undefined && window.windowId === frontmost.windowId);
	if (!selected && frontmost.windowTitle) {
		selected = windows.find((window) => normalizeText(window.title) === normalizeText(frontmost.windowTitle));
	}
	selected ??= choosePreferredWindow(windows, app.appName);

	const resolved = toResolvedTarget(app, selected);
	setCurrentTarget(resolved);
	return resolved;
}

function matchesScreenshotSelection(target: ResolvedTarget, selection: ScreenshotParams): boolean {
	const windowQuery = normalizeWindowSelector(selection.window);
	if (windowQuery) {
		if (target.windowRef === windowQuery) return true;
		const numeric = Number(windowQuery);
		return Number.isInteger(numeric) && numeric > 0 && target.windowId === numeric;
	}
	const appQuery = trimOrUndefined(selection.app);
	const windowTitleQuery = trimOrUndefined(selection.windowTitle);
	if (appQuery && !normalizeText(target.appName).includes(normalizeText(appQuery))) {
		return false;
	}
	if (windowTitleQuery && normalizeText(target.windowTitle) !== normalizeText(windowTitleQuery)) {
		return false;
	}
	return true;
}

async function resolveTargetForScreenshot(selection: ScreenshotParams, signal?: AbortSignal): Promise<ResolvedTarget> {
	const appQuery = trimOrUndefined(selection.app);
	const windowTitleQuery = trimOrUndefined(selection.windowTitle);

	if (!appQuery && !windowTitleQuery) {
		if (runtimeState.currentTarget) {
			return await resolveCurrentTarget(signal);
		}
		return await resolveFrontmostTarget(signal);
	}

	const apps = await listApps(signal);

	if (appQuery) {
		const app = chooseAppByQuery(apps, appQuery);
		assertBrowserUseAllowed(app);
		let windows = await listWindows(app.pid, signal);
		if (!windows.length) {
			throw new Error(`No controllable window was found in app '${app.appName}'.`);
		}

		let window: HelperWindow;
		if (windowTitleQuery) {
			window = chooseWindowByTitle(windows, windowTitleQuery, app.appName);
		} else if (isBrowserApp(app.appName, app.bundleId)) {
			const current = runtimeState.currentTarget;
			const currentBrowserWindow =
				current && current.pid === app.pid ? windows.find((candidate) => candidate.windowId === current.windowId) : undefined;
			window = currentBrowserWindow ?? choosePreferredWindow(windows, app.appName);
		} else {
			window = choosePreferredWindow(windows, app.appName);
		}

		const resolved = toResolvedTarget(app, window);
		setCurrentTarget(resolved);
		return resolved;
	}

	const query = windowTitleQuery!;
	const exactMatches: Array<{ app: HelperApp; window: HelperWindow }> = [];
	const partialMatches: Array<{ app: HelperApp; window: HelperWindow }> = [];

	for (const app of apps) {
		const windows = await listWindows(app.pid, signal);
		for (const window of windows) {
			const title = normalizeText(window.title);
			if (!title) continue;
			if (title === normalizeText(query)) {
				exactMatches.push({ app, window });
			} else if (title.includes(normalizeText(query))) {
				partialMatches.push({ app, window });
			}
		}
	}

	const matches = exactMatches.length > 0 ? exactMatches : partialMatches;
	if (matches.length === 0) {
		throw new Error(`Window '${query}' was not found in any running app.`);
	}
	if (matches.length > 1) {
		const ranked = [...matches].sort((a, b) => scoreWindow(b.window) - scoreWindow(a.window));
		if (ranked.length > 1 && scoreWindow(ranked[0].window) >= scoreWindow(ranked[1].window) + 25) {
			const resolved = toResolvedTarget(ranked[0].app, ranked[0].window);
			setCurrentTarget(resolved);
			return resolved;
		}
		const options = ranked
			.slice(0, 6)
			.map((match) => `${match.app.appName} — ${summarizeWindowCandidate(match.window)}`)
			.join(", ");
		throw new Error(`Window title '${query}' is ambiguous (${options}). Specify app as well.`);
	}

	const resolved = toResolvedTarget(matches[0].app, matches[0].window);
	setCurrentTarget(resolved);
	return resolved;
}

async function ensureTargetWindowId(target: ResolvedTarget, signal?: AbortSignal): Promise<ResolvedTarget> {
	if (target.windowId > 0) {
		return target;
	}

	const refreshed = await resolveCurrentTarget(signal);
	if (refreshed.windowId <= 0) {
		throw new Error(CURRENT_TARGET_GONE_ERROR);
	}
	return refreshed;
}

async function helperScreenshot(windowId: number, signal?: AbortSignal): Promise<ScreenshotPayload> {
	const result = await bridgeCommand<any>(
		"screenshot",
		{ windowId },
		{ timeoutMs: SCREENSHOT_TIMEOUT_MS, signal },
	);

	const base64 = toOptionalString(result?.pngBase64);
	if (!base64) {
		throw new Error("Helper returned an invalid screenshot payload.");
	}

	return {
		pngBase64: base64,
		width: Math.max(1, Math.trunc(toFiniteNumber(result?.width, 1))),
		height: Math.max(1, Math.trunc(toFiniteNumber(result?.height, 1))),
		scaleFactor: Math.max(1, toFiniteNumber(result?.scaleFactor, 1)),
		windowWidth: toOptionalNumber(result?.windowWidth),
		windowHeight: toOptionalNumber(result?.windowHeight),
	};
}

function toOptionalNumber(value: unknown): number | undefined {
	const n = typeof value === "number" ? value : Number(value);
	return Number.isFinite(n) && n > 0 ? n : undefined;
}

function windowsByCaptureRecoveryPriority(
	windows: HelperWindow[],
	target: ResolvedTarget,
	failureCode: string,
): HelperWindow[] {
	const sorted = [...windows].sort((a, b) => scoreWindow(b) - scoreWindow(a));
	if (failureCode !== "screenshot_timeout") {
		return sorted;
	}

	const alternatives = sorted.filter((window) => window.windowId !== target.windowId);
	const original = sorted.filter((window) => window.windowId === target.windowId);
	return [...alternatives, ...original];
}

async function recoverCaptureFromHelperFailure(
	target: ResolvedTarget,
	error: HelperCommandError,
	signal?: AbortSignal,
): Promise<{ target: ResolvedTarget; image: ScreenshotPayload }> {
	const windows = await listWindows(target.pid, signal);
	if (!windows.length) {
		throw new Error(CURRENT_TARGET_GONE_ERROR);
	}

	const app: HelperApp = {
		appName: target.appName,
		bundleId: target.bundleId,
		pid: target.pid,
	};

	const orderedWindows = windowsByCaptureRecoveryPriority(windows, target, error.code ?? "");
	const candidates = orderedWindows.filter((window) => typeof window.windowId === "number" && window.windowId > 0).slice(0, 3);
	if (!candidates.length) {
		throw normalizeError(error);
	}

	let lastError: Error = normalizeError(error);
	for (const candidateWindow of candidates) {
		const candidateTarget = toResolvedTarget(app, candidateWindow);
		try {
			const image = await helperScreenshot(candidateTarget.windowId, signal);
			return { target: candidateTarget, image };
		} catch (candidateError) {
			if (!isRecoverableScreenshotError(candidateError)) {
				throw normalizeError(candidateError);
			}
			lastError = normalizeError(candidateError);
		}
	}

	throw lastError;
}

interface CaptureResult {
	target: ResolvedTarget;
	capture: CurrentCapture;
	image?: ScreenshotPayload;
	axTargets: AxTarget[];
	axDiagnostics?: { reason?: string; message?: string; debug?: unknown };
	activation: ActivationFlags;
}

function captureForTarget(target: ResolvedTarget): CurrentCapture {
	return {
		stateId: randomStateId(),
		width: Math.max(1, Math.round(target.framePoints.w * target.scaleFactor)),
		height: Math.max(1, Math.round(target.framePoints.h * target.scaleFactor)),
		scaleFactor: target.scaleFactor,
		timestamp: Date.now(),
		windowWidth: target.framePoints.w,
		windowHeight: target.framePoints.h,
		framePoints: { ...target.framePoints },
	};
}

async function ensureCaptureImage(result: CaptureResult, signal?: AbortSignal): Promise<void> {
	if (result.image) return;
	try {
		result.image = await helperScreenshot(result.target.windowId, signal);
		result.capture.width = result.image.width;
		result.capture.height = result.image.height;
		result.capture.scaleFactor = result.image.scaleFactor;
		// Helper now derives scale by comparing image to known window
		// bounds. If it returned authoritative window dimensions, prefer
		// those over the AX-cached framePoints (they can drift if the
		// user resized between listWindows and screenshot).
		if (typeof result.image.windowWidth === "number" && result.image.windowWidth > 0) {
			result.capture.windowWidth = result.image.windowWidth;
			result.capture.framePoints.w = result.image.windowWidth;
		}
		if (typeof result.image.windowHeight === "number" && result.image.windowHeight > 0) {
			result.capture.windowHeight = result.image.windowHeight;
			result.capture.framePoints.h = result.image.windowHeight;
		}
	} catch (error) {
		if (!isRecoverableScreenshotError(error)) {
			const normalized = normalizeError(error);
			if (isBrowserApp(result.target.appName, result.target.bundleId)) {
				throw new Error(`${normalized.message} Browser capture failed for ${result.target.appName} window '${result.target.windowTitle}'. Call list_windows and retry screenshot with an explicit existing content window ref, or use navigate_browser for direct URL navigation.`);
			}
			throw normalized;
		}
		const recovered = await recoverCaptureFromHelperFailure(result.target, error, signal);
		result.target = recovered.target;
		result.image = recovered.image;
		result.capture.width = recovered.image.width;
		result.capture.height = recovered.image.height;
		result.capture.scaleFactor = recovered.image.scaleFactor;
		if (typeof recovered.image.windowWidth === "number" && recovered.image.windowWidth > 0) {
			result.capture.windowWidth = recovered.image.windowWidth;
			result.capture.framePoints.w = recovered.image.windowWidth;
		}
		if (typeof recovered.image.windowHeight === "number" && recovered.image.windowHeight > 0) {
			result.capture.windowHeight = recovered.image.windowHeight;
			result.capture.framePoints.h = recovered.image.windowHeight;
		}
		const axResult = await bridgeCommand(
			"axListTargets",
			{ ...nativeWindowRequest(result.target), limit: 12 },
			{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
		).catch((axError) => ({ targets: [], reason: axError instanceof HelperCommandError ? (axError.code ?? "ax_list_failed") : "ax_list_failed" }));
		result.axTargets = parseAxTargets(axResult);
		result.axDiagnostics = axDiagnosticsFromResult(axResult, result.target);
	}
	setCurrentTarget(result.target);
	runtimeState.currentCapture = result.capture;
	runtimeState.currentStateTarget = { pid: result.target.pid, windowId: result.target.windowId, windowRef: result.target.windowRef };
	runtimeState.currentAxTargets = result.axTargets;
}

async function captureCurrentTarget(signal?: AbortSignal, priorActivation = emptyActivation()): Promise<CaptureResult> {
	let target = await resolveCurrentTarget(signal);
	let activation = { ...priorActivation };

	target = await ensureTargetWindowId(target, signal);

	const capture = captureForTarget(target);
	const axResult = await bridgeCommand(
		"axListTargets",
		{ ...nativeWindowRequest(target), limit: 12 },
		{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
	).catch((axError) => ({ targets: [], reason: axError instanceof HelperCommandError ? (axError.code ?? "ax_list_failed") : "ax_list_failed" }));
	const axTargets = parseAxTargets(axResult);
	const axDiagnostics = axDiagnosticsFromResult(axResult, target);

	setCurrentTarget(target);
	runtimeState.currentCapture = capture;
	runtimeState.currentStateTarget = { pid: target.pid, windowId: target.windowId, windowRef: target.windowRef };
	runtimeState.currentAxTargets = axTargets;

	return {
		target,
		capture,
		axTargets,
		axDiagnostics,
		activation,
	};
}

async function buildToolResult(
	tool: string,
	summary: string,
	result: CaptureResult,
	execution: ExecutionTrace,
	signal?: AbortSignal,
	imageMode: ImageMode = runtimeState.currentImageMode ?? "auto",
): Promise<AgentToolResult<ComputerUseDetails>> {
	const fallbackReason = imageFallbackReason(tool, result, execution, imageMode);
	if (fallbackReason) {
		await ensureCaptureImage(result, signal);
	}

	const details: ComputerUseDetails = {
		tool,
		target: {
			app: result.target.appName,
			bundleId: result.target.bundleId,
			pid: result.target.pid,
			windowTitle: result.target.windowTitle,
			windowId: result.target.windowId,
			windowRef: result.target.windowRef ?? runtimeState.currentTarget?.windowRef,
			nativeWindowRef: result.target.nativeWindowRef ?? runtimeState.currentTarget?.nativeWindowRef,
		},
		capture: {
			stateId: result.capture.stateId,
			width: result.capture.width,
			height: result.capture.height,
			scaleFactor: result.capture.scaleFactor,
			timestamp: result.capture.timestamp,
			windowWidth: result.capture.windowWidth,
			windowHeight: result.capture.windowHeight,
			coordinateSpace: "window-relative-logical-points",
		},
		axTargets: result.axTargets,
		activation: result.activation,
		execution,
		axDiagnostics: result.axDiagnostics,
		status: "ok",
		config: getComputerUseConfig(),
		imageReason: fallbackReason?.reason,
	};

	// Per-app instructions. Only inject on screenshot results — that's the
	// "you're now looking at this app" moment. Repeating the full markdown on
	// every screenshot would burn tokens for no new info, so we ship the full
	// body once per (session, source, matchedKey) tuple and a short breadcrumb
	// after that. Absence of a file is normal and silent.
	let appInstructionsText = "";
	if (tool === "screenshot") {
		try {
			const instructions = await loadAppInstructions({
				bundleId: result.target.bundleId,
				appName: result.target.appName,
			});
			if (instructions) {
				details.appInstructions = instructions;
				const shipKey = `${instructions.source}:${instructions.matchedKey}`;
				const headerNote = instructions.source === "user" ? "user override" : "bundled";
				const truncatedNote = instructions.truncated ? ", truncated to ~3KB" : "";
				if (runtimeState.shippedAppInstructions.has(shipKey)) {
					appInstructionsText = `\n\nApp-specific instructions for ${result.target.appName} (${headerNote}) were already provided earlier in this session \u2014 follow them. Restart pi to re-ship.`;
				} else {
					appInstructionsText = `\n\n--- App-specific instructions for ${result.target.appName} (${headerNote}${truncatedNote}) ---\n${instructions.text}\n--- end instructions ---`;
					runtimeState.shippedAppInstructions.add(shipKey);
				}
			}
		} catch {
			// Loader is best-effort. Never block a tool result on instruction lookup.
		}
	}

	const axTargetText = result.axTargets.length
		? `\n\nPrefer these AX targets over coordinate clicks or focus-based text replacement when one matches your intent:\n${result.axTargets.map(formatAxTargetLabel).join("\n")}`
		: "";
	const fallbackText = fallbackReason ? `\n\n${fallbackReason.message}` : "";
	// Prepend a one-line mode marker on screenshot results only. Other
	// tools (click/keypress/etc.) fire often enough that repeating the
	// marker would be noise; screenshot is the natural "start of
	// inspection" moment, mirroring how we ship app instructions there.
	const markerText = tool === "screenshot" ? `[${formatModeMarker()}]\n` : "";
	// Coordinate-units reminder. Bolt this onto every screenshot so the
	// model can't read it once and forget. Names the trap explicitly:
	// the image is captured at retina backing scale (typically 2x), but
	// click/move/drag/scroll coordinates are window-relative LOGICAL
	// POINTS in [0..windowWidth] x [0..windowHeight]. Without this line
	// models routinely read pixel coords off the image and silently
	// miss by ~2x.
	const coordsLine = tool === "screenshot"
		? `\n\nCoords: window ${Math.round(result.capture.windowWidth)}x${Math.round(result.capture.windowHeight)} pts | image ${result.capture.width}x${result.capture.height} px | scale ${(result.capture.scaleFactor || 1).toFixed(2)}. Click/move/drag/scroll x,y are LOGICAL POINTS in [0..${Math.round(result.capture.windowWidth)}, 0..${Math.round(result.capture.windowHeight)}]. If you read a coordinate off the image, divide by scale before passing it.`
		: "";
	const content: AgentToolResult<ComputerUseDetails>["content"] = [{ type: "text", text: `${markerText}${summary}${coordsLine}${axTargetText}${fallbackText}${appInstructionsText}` }];
	if (fallbackReason) {
		content.push({ type: "image", data: result.image!.pngBase64, mimeType: "image/png" });
	}

	return { content, details };
}

async function dispatchClick(
	params: ClickParams,
	capture: CurrentCapture,
	target: ResolvedTarget,
	signal?: AbortSignal,
): Promise<ExecutionTrace> {
	const ref = trimOrUndefined(params.ref);
	const x = toFiniteNumber(params.x, NaN);
	const y = toFiniteNumber(params.y, NaN);
	const button = normalizeMouseButton(params.button);
	const clickCount = normalizeClickCount(params.clickCount);

	if (ref) {
		if (button !== "left") {
			throw new Error(`AX target refs only support left-button clicks. Use coordinates for ${button}-click.`);
		}
		const attemptRefClick = async (axTarget: AxTarget): Promise<{ clickedViaAX: boolean; focusedViaAX: boolean }> => {
			let clickedViaAX = false;
			let focusedViaAX = false;
			for (let index = 0; index < clickCount; index += 1) {
				try {
					const axResult = await bridgeCommand<AxPressAtPointResult>(
						"axPressElement",
						{ elementRef: axTarget.elementRef, pid: target.pid },
						{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
					);
					clickedViaAX = toBoolean(axResult?.pressed);
				} catch {
					clickedViaAX = false;
				}
				if (!clickedViaAX) break;
				if (index + 1 < clickCount) {
					await sleep(60, signal);
				}
			}

			if (!clickedViaAX && clickCount === 1) {
				try {
					const focusResult = await bridgeCommand<AxFocusResult>(
						"axFocusElement",
						{ elementRef: axTarget.elementRef, pid: target.pid },
						{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
					);
					focusedViaAX = toBoolean(focusResult?.focused);
				} catch {
					focusedViaAX = false;
				}
			}
			return { clickedViaAX, focusedViaAX };
		};

		const axTarget = axTargetByRef(ref);
		let { clickedViaAX, focusedViaAX } = await attemptRefClick(axTarget);
		if (!clickedViaAX && !focusedViaAX) {
			const reacquired = await reacquireAxTarget(axTarget, target, signal);
			if (reacquired) {
				({ clickedViaAX, focusedViaAX } = await attemptRefClick(reacquired));
			}
		}

		if (!clickedViaAX && !focusedViaAX) {
			throw new Error(`AX click/focus could not be completed for ${ref}.`);
		}

		return executionTrace(clickedViaAX ? "ax_press" : "ax_focus", "stealth", {
			axAttempted: true,
			axSucceeded: true,
			fallbackUsed: false,
		});
	}

	if (!Number.isFinite(x) || !Number.isFinite(y)) {
		throw new Error("click requires either ref or both x and y.");
	}
	ensurePointIsInCapture(x, y, capture);

	let clickedViaAX = false;
	let focusedViaAX = false;
	const canTryAX = button === "left" && clickCount === 1;
	if (canTryAX) {
		try {
			const axResult = await bridgeCommand<AxPressAtPointResult>(
				"axPressAtPoint",
				{
					...nativeWindowRequest(target),
					x,
					y,
					...captureRequest(capture),
				},
				{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
			);
			clickedViaAX = toBoolean(axResult?.pressed);
		} catch {
			clickedViaAX = false;
		}

		if (!clickedViaAX) {
			try {
				const focusResult = await bridgeCommand<AxFocusResult>(
					"axFocusAtPoint",
					{
						...nativeWindowRequest(target),
						x,
						y,
						...captureRequest(capture),
					},
					{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
				);
				focusedViaAX = toBoolean(focusResult?.focused);
			} catch {
				focusedViaAX = false;
			}
		}
	}

	if (!clickedViaAX && !focusedViaAX) {
		// Stealth no longer blocks coordinate clicks. The native helper
		// posts via CGEventPostToPid (per-PID delivery), so the click
		// lands in the target app's queue without changing the user's
		// frontmost. Webview content (Electron, Catalyst) is the
		// motivating case: AX cannot ground these clicks, but the
		// underlying renderer accepts the synthetic event. The stealth
		// contract is now "no surprise focus changes", not "no
		// synthesized input."
		await bridgeCommand(
			"mouseClick",
			{
				...nativeWindowRequest(target),
				x,
				y,
				button,
				clickCount,
				...captureRequest(capture),
			},
			{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
		);
	}

	const usedAxPath = clickedViaAX || focusedViaAX;
	return executionTrace(
		clickedViaAX ? "ax_press" : focusedViaAX ? "ax_focus" : clickCount > 1 ? "coordinate_event_double_click" : "coordinate_event_click",
		usedAxPath ? "stealth" : "default",
		{
			axAttempted: canTryAX,
			axSucceeded: usedAxPath,
			fallbackUsed: canTryAX && !usedAxPath,
			nonStealthReason: usedAxPath ? undefined : "coordinate_mouse_click_requires_pointer_event",
		},
	);
}

async function dispatchTypeText(text: string, target: ResolvedTarget, signal?: AbortSignal): Promise<ExecutionTrace> {
	if (runtimeState.allowNextTypeTextAxReplacement) {
		runtimeState.allowNextTypeTextAxReplacement = false;
		const focusedElementRef = await focusedTextElementRef(target, signal);
		if (focusedElementRef) {
			await setAxValue(focusedElementRef, text, signal);
			if (isBrowserApp(target.appName, target.bundleId)) {
				runtimeState.pendingBrowserAddress = { text, pid: target.pid, windowId: target.windowId };
			}
			return executionTrace("ax_set_value", "stealth", { axAttempted: true, axSucceeded: true, fallbackUsed: false });
		}
	}
	// Stealth v2: post the keystrokes via per-PID delivery. set_text
	// with an AX ref is still preferred; this raw path is the fallback
	// for fields that don't expose AX values (Electron webview content
	// is the motivating case).
	await bridgeCommand(
		"typeText",
		{ text, pid: target.pid },
		{ signal, timeoutMs: Math.min(90_000, Math.max(COMMAND_TIMEOUT_MS, text.length * 25 + 4_000)) },
	);
	return executionTrace("raw_key_text", "stealth", {
		axAttempted: false,
		axSucceeded: false,
		fallbackUsed: false,
	});
}

async function focusedTextElementRef(target: ResolvedTarget, signal?: AbortSignal): Promise<string | undefined> {
	const focused: FocusedElementResult = await bridgeCommand<FocusedElementResult>(
		"focusedElement",
		nativeWindowRequest(target),
		{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
	).catch(() => ({ exists: false } as FocusedElementResult));

	if (!focused.exists || !focused.isTextInput || !focused.canSetValue || !focused.elementRef) {
		return undefined;
	}
	return focused.elementRef;
}

async function setAxValue(elementRef: string, text: string, signal?: AbortSignal): Promise<void> {
	await bridgeCommand(
		"setValue",
		{
			elementRef,
			value: text,
		},
		{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
	);
}

async function focusAxElement(elementRef: string, target: ResolvedTarget, signal?: AbortSignal): Promise<boolean> {
	const result = await bridgeCommand<AxFocusResult>(
		"axFocusElement",
		{ elementRef, pid: target.pid },
		{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
	).catch(() => undefined);
	return toBoolean(result?.focused);
}

async function dispatchSetText(params: SetTextParams, target: ResolvedTarget, signal?: AbortSignal): Promise<ExecutionTrace> {
	const ref = trimOrUndefined(params.ref);
	if (ref) {
		let axTarget = axTargetByRef(ref);
		if (axTarget.canSetValue !== false) {
			try {
				await setAxValue(axTarget.elementRef, params.text, signal);
				return executionTrace("ax_set_value", "stealth", { axAttempted: true, axSucceeded: true, fallbackUsed: false });
			} catch (error) {
				if (isElementRefInvalid(error)) {
					const reacquired = await reacquireAxTarget(axTarget, target, signal);
					if (reacquired && reacquired.canSetValue !== false) {
						axTarget = reacquired;
						await setAxValue(axTarget.elementRef, params.text, signal);
						return executionTrace("ax_set_value", "stealth", { axAttempted: true, axSucceeded: true, fallbackUsed: false });
					}
				}
				// Stealth v2: fall through to focus + setValue path (which
				// does not raise the window). The original strict-mode
				// rejection is gone because v2 trusts per-PID delivery.
			}
		}

		// Stealth v2: try the focus + setValue path before giving up.
		// focusAxElement focuses an AX element via AXFocusedAttribute,
		// which does NOT raise the parent window.

		let focusedViaRef = await focusAxElement(axTarget.elementRef, target, signal);
		if (!focusedViaRef) {
			const reacquired = await reacquireAxTarget(axTarget, target, signal);
			if (reacquired) {
				axTarget = reacquired;
				focusedViaRef = await focusAxElement(axTarget.elementRef, target, signal);
			}
		}
		if (focusedViaRef) {
			const focusedElementRef = await focusedTextElementRef(target, signal);
			if (focusedElementRef) {
				await setAxValue(focusedElementRef, params.text, signal);
				return executionTrace("ax_set_value", "stealth", {
					axAttempted: true,
					axSucceeded: true,
					fallbackUsed: false,
				});
			}
		}
	}

	const focusedElementRef = await focusedTextElementRef(target, signal);
	if (focusedElementRef) {
		await setAxValue(focusedElementRef, params.text, signal);
		return executionTrace("ax_set_value", "stealth", { axAttempted: true, axSucceeded: true, fallbackUsed: false });
	}

	// Stealth v2: no AX text target found, no currently-focused text
	// control. Rather than raising the window (forbidden under v2), we
	// surface a clear error pointing the agent at click({ x, y }) +
	// type_text({ text }) - both of which now use per-PID delivery and
	// don't disturb the user. This path is for callers that asked
	// set_text without a ref.
	throw new Error(
		"set_text needs a text AX ref or an already-focused text control. Either: (a) call screenshot to refresh AX targets and pass a ref whose role is AXTextField/AXTextArea/AXSearchField/AXComboBox, or (b) click({ x, y }) on the field to focus it (per-PID delivery), then call set_text again.",
	);
}

function isCommandL(keys: string[]): boolean {
	return keys.length === 1 && /^(cmd|command|meta)\+l$/i.test(keys[0].replace(/\s+/g, ""));
}

async function focusBrowserAddressField(keys: string[], target: ResolvedTarget, signal?: AbortSignal): Promise<boolean> {
	if (!isCommandL(keys) || !isBrowserApp(target.appName, target.bundleId)) return false;

	const focusedTextInput = await bridgeCommand<{ focused?: boolean; elementRef?: string }>(
		"axFocusTextInput",
		nativeWindowRequest(target),
		{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
	).catch(() => undefined);
	if (toBoolean(focusedTextInput?.focused)) {
		runtimeState.allowNextTypeTextAxReplacement = true;
		return true;
	}

	const refreshed = parseAxTargets(
		await bridgeCommand(
			"axListTargets",
			{ ...nativeWindowRequest(target), limit: 50 },
			{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
		).catch(() => []),
	);
	if (!refreshed.length) return false;
	runtimeState.currentAxTargets = refreshed;
	const field = refreshed
		.filter((candidate) => candidate.canFocus && candidate.isTextInput && (candidate.role === "AXTextField" || candidate.role === "AXSearchField" || candidate.role === "AXComboBox"))
		.sort((a, b) => a.y - b.y || a.x - b.x)[0];
	if (!field) return false;
	const focused = await focusAxElement(field.elementRef, target, signal);
	if (focused) runtimeState.allowNextTypeTextAxReplacement = true;
	return focused;
}

function semanticActionsForKeys(keys: string[]): string[] {
	if (keys.length !== 1) return [];
	const key = keys[0].trim().toLowerCase();
	if (["enter", "return"].includes(key)) return ["confirm", "press"];
	if (["escape", "esc"].includes(key)) return ["cancel"];
	if (["space", "spacebar", " "].includes(key)) return ["press"];
	return [];
}

function windowButtonForSemanticKey(keys: string[], targets: AxTarget[]): AxTarget | undefined {
	if (keys.length !== 1) return undefined;
	const key = keys[0].trim().toLowerCase();
	const buttons = targets.filter((target) => target.canPress && target.role === "AXButton");
	if (["escape", "esc"].includes(key)) {
		return buttons.find((target) => ["cancel", "don't save", "dont save"].includes(axTargetLabelKey(target)));
	}
	if (["enter", "return"].includes(key)) {
		return (
			buttons.find((target) => normalizeText(target.subrole).includes("default")) ??
			buttons.find((target) => ["ok", "done", "save", "add", "continue", "open", "choose"].includes(axTargetLabelKey(target)))
		);
	}
	return undefined;
}

async function tryWindowAxKeyAction(keys: string[], target: ResolvedTarget, signal?: AbortSignal): Promise<boolean> {
	const refreshed = parseAxTargets(
		await bridgeCommand(
			"axListTargets",
			{ ...nativeWindowRequest(target), limit: 50 },
			{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
		).catch(() => []),
	);
	if (!refreshed.length) return false;
	runtimeState.currentAxTargets = refreshed;
	const button = windowButtonForSemanticKey(keys, refreshed);
	if (!button) return false;
	const result = await bridgeCommand<{ performed?: boolean }>(
		"axPerformActionElement",
		{ elementRef: button.elementRef, pid: target.pid, action: "press" },
		{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
	).catch(() => undefined);
	return toBoolean(result?.performed);
}

async function tryFocusedAxKeyAction(keys: string[], target: ResolvedTarget, signal?: AbortSignal): Promise<boolean> {
	const actions = semanticActionsForKeys(keys);
	if (!actions.length) return false;
	const focused = await focusedTextElementRef(target, signal);
	if (!focused) {
		const rawFocused = await bridgeCommand<FocusedElementResult>(
			"focusedElement",
			nativeWindowRequest(target),
			{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
		).catch(() => undefined);
		if (!rawFocused?.exists || !rawFocused.elementRef) return await tryWindowAxKeyAction(keys, target, signal);
		for (const action of actions) {
			const result = await bridgeCommand<{ performed?: boolean }>(
				"axPerformActionElement",
				{ elementRef: rawFocused.elementRef, pid: target.pid, action },
				{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
			).catch(() => undefined);
			if (toBoolean(result?.performed)) return true;
		}
		return await tryWindowAxKeyAction(keys, target, signal);
	}
	for (const action of actions) {
		const result = await bridgeCommand<{ performed?: boolean }>(
			"axPerformActionElement",
			{ elementRef: focused, pid: target.pid, action },
			{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
		).catch(() => undefined);
		if (toBoolean(result?.performed)) return true;
	}
	return await tryWindowAxKeyAction(keys, target, signal);
}

async function dispatchKeypress(params: KeypressParams, target: ResolvedTarget, signal?: AbortSignal): Promise<ExecutionTrace> {
	const keys = normalizeKeyList(params.keys);
	if (keys.length === 0) {
		throw new Error("keypress.keys must contain at least one key.");
	}

	const openedPendingBrowserLocation = await openBrowserLocationFromPendingAddress(keys, target, signal);
	if (openedPendingBrowserLocation) {
		return executionTrace("browser_open_location", "stealth", { axAttempted: true, axSucceeded: true, fallbackUsed: false });
	}

	const focusedAddressViaAX = await focusBrowserAddressField(keys, target, signal);
	if (focusedAddressViaAX) {
		return executionTrace("ax_focus", "stealth", { axAttempted: true, axSucceeded: true, fallbackUsed: false });
	}

	const performedViaAX = await tryFocusedAxKeyAction(keys, target, signal);
	if (performedViaAX) {
		return executionTrace("ax_action", "stealth", { axAttempted: true, axSucceeded: true, fallbackUsed: false });
	}

	// Stealth keypress path: events are delivered via event.postToPid(pid) on
	// the helper side, NOT via the global CGEventPost session tap. postToPid
	// goes to the target app's event queue and does not move the system cursor
	// or change the frontmost app. That's mechanically stealth-safe — the
	// same primitive OpenAI's Sky CUA helper uses for the same reason.
	//
	// Stealth v2: per-PID delivery is the keypress path. The helper
	// posts via CGEventPostToPid which lands in the target app's queue
	// without changing frontmost. We never raise the window pre-input;
	// if the app gates keypress on foreground (some legacy AppKit apps
	// do), the input is best-effort. Modern apps (Electron/Catalyst/
	// Cocoa) honor per-PID keystrokes whether or not foreground.
	await bridgeCommand("keyPress", { keys, pid: target.pid }, { signal, timeoutMs: COMMAND_TIMEOUT_MS });
	return executionTrace("per_pid_keypress", "stealth", {
		axAttempted: semanticActionsForKeys(keys).length > 0,
		axSucceeded: false,
		fallbackUsed: semanticActionsForKeys(keys).length > 0,
	});
}

function scrollStepCount(delta: number): number {
	return Math.max(1, Math.min(8, Math.ceil(Math.abs(delta) / 500)));
}

interface ScrollAttemptResult {
	scrolled: boolean;
	reason?: string;
}

async function tryAxScrollElement(elementRef: string, target: ResolvedTarget, scrollX: number, scrollY: number, signal?: AbortSignal): Promise<ScrollAttemptResult> {
	const result = await bridgeCommand<{ scrolled?: boolean; reason?: string }>(
		"axScrollElement",
		{ elementRef, pid: target.pid, scrollX, scrollY, steps: Math.max(scrollStepCount(scrollX), scrollStepCount(scrollY)) },
		{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
	).catch((error) => ({ scrolled: false, reason: normalizeError(error).message }));
	return { scrolled: toBoolean(result?.scrolled), reason: toOptionalString(result?.reason) };
}

async function tryAxScrollAtPoint(
	target: ResolvedTarget,
	capture: CurrentCapture,
	x: number,
	y: number,
	scrollX: number,
	scrollY: number,
	signal?: AbortSignal,
): Promise<ScrollAttemptResult> {
	const result = await bridgeCommand<{ scrolled?: boolean; reason?: string }>(
		"axScrollAtPoint",
		{
			...nativeWindowRequest(target),
			x,
			y,
			scrollX,
			scrollY,
			steps: Math.max(scrollStepCount(scrollX), scrollStepCount(scrollY)),
			...captureRequest(capture),
		},
		{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
	).catch((error) => ({ scrolled: false, reason: normalizeError(error).message }));
	return { scrolled: toBoolean(result?.scrolled), reason: toOptionalString(result?.reason) };
}

async function dispatchScroll(
	params: ScrollParams,
	capture: CurrentCapture,
	target: ResolvedTarget,
	signal?: AbortSignal,
): Promise<ExecutionTrace> {
	const ref = trimOrUndefined(params.ref);
	const x = toFiniteNumber(params.x, NaN);
	const y = toFiniteNumber(params.y, NaN);
	const scrollX = normalizeScrollDelta(params.scrollX);
	const scrollY = normalizeScrollDelta(params.scrollY);
	if (scrollX === 0 && scrollY === 0) {
		throw new Error("scroll requires a non-zero scrollX or scrollY.");
	}

	let scrollAttempt: ScrollAttemptResult = { scrolled: false };
	if (ref) {
		const axTarget = axTargetByRef(ref);
		scrollAttempt = await tryAxScrollElement(axTarget.elementRef, target, scrollX, scrollY, signal);
		if (!scrollAttempt.scrolled) {
			const reacquired = await reacquireAxTarget(axTarget, target, signal);
			if (reacquired) {
				scrollAttempt = await tryAxScrollElement(reacquired.elementRef, target, scrollX, scrollY, signal);
			}
		}
	} else if (Number.isFinite(x) && Number.isFinite(y)) {
		ensurePointIsInCapture(x, y, capture);
		scrollAttempt = await tryAxScrollAtPoint(target, capture, x, y, scrollX, scrollY, signal);
	} else {
		throw new Error("scroll requires either ref or both x and y. If the target came from an old state, call screenshot again and retry with a current @e scroll ref or coordinates.");
	}

	if (scrollAttempt.scrolled) {
		return executionTrace("ax_scroll", "stealth", { axAttempted: true, axSucceeded: true, fallbackUsed: false });
	}

	const reasonText = scrollAttempt.reason ? ` Reason: ${scrollAttempt.reason}.` : "";
	// Stealth v2: coordinate-scroll fallback is allowed - it posts via
	// per-PID delivery and does not raise the target window.
	if (!Number.isFinite(x) || !Number.isFinite(y)) {
		throw new Error(`Coordinate scroll fallback requires x and y.${reasonText} Provide coordinates from the latest screenshot or use a current AX scroll target.`);
	}
	ensurePointIsInCapture(x, y, capture);
	await bridgeCommand(
		"scrollWheel",
		{
			...nativeWindowRequest(target),
			x,
			y,
			scrollX,
			scrollY,
			...captureRequest(capture),
		},
		{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
	);
	return executionTrace("coordinate_event_scroll", "default", {
		axAttempted: true,
		axSucceeded: false,
		fallbackUsed: true,
		nonStealthReason: "coordinate_scroll_requires_pointer_event",
	});
}

async function dispatchMoveMouse(
	params: MoveMouseParams,
	capture: CurrentCapture,
	target: ResolvedTarget,
	signal?: AbortSignal,
): Promise<ExecutionTrace> {
	// Stealth v2: mouseMove posts a synthetic .mouseMoved event via
	// CGEventPostToPid - it does NOT call CGWarpMouseCursorPosition, so
	// the user's actual cursor is unaffected. The agent's overlay
	// cursor follows the synthetic position. Allowed in stealth.
	const x = toFiniteNumber(params.x, NaN);
	const y = toFiniteNumber(params.y, NaN);
	ensurePointIsInCapture(x, y, capture);
	await bridgeCommand(
		"mouseMove",
		{ ...nativeWindowRequest(target), x, y, ...captureRequest(capture) },
		{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
	);
	return executionTrace("coordinate_event_move", "default", {
		axAttempted: false,
		axSucceeded: false,
		fallbackUsed: false,
		nonStealthReason: "mouse_move_requires_cursor_control",
	});
}

function dragAdjustment(path: Array<{ x: number; y: number }> | undefined): { action: "increment" | "decrement"; steps: number } | undefined {
	if (!path || path.length < 2) return undefined;
	const first = path[0];
	const last = path[path.length - 1];
	const dx = last.x - first.x;
	const dy = last.y - first.y;
	const primary = Math.abs(dx) >= Math.abs(dy) ? dx : -dy;
	if (Math.abs(primary) < 4) return undefined;
	return { action: primary > 0 ? "increment" : "decrement", steps: Math.max(1, Math.min(20, Math.round(Math.abs(primary) / 20))) };
}

async function tryAxAdjustElement(axTarget: AxTarget, adjustment: { action: "increment" | "decrement"; steps: number }, target: ResolvedTarget, signal?: AbortSignal): Promise<boolean> {
	if (adjustment.action === "increment" && !axTarget.canIncrement) return false;
	if (adjustment.action === "decrement" && !axTarget.canDecrement) return false;
	let performed = false;
	for (let index = 0; index < adjustment.steps; index += 1) {
		const result = await bridgeCommand<{ performed?: boolean }>(
			"axPerformActionElement",
			{ elementRef: axTarget.elementRef, pid: target.pid, action: adjustment.action },
			{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
		).catch(() => undefined);
		if (!toBoolean(result?.performed)) break;
		performed = true;
	}
	return performed;
}

async function dispatchDrag(
	params: DragParams,
	capture: CurrentCapture,
	target: ResolvedTarget,
	signal?: AbortSignal,
): Promise<ExecutionTrace> {
	const path = params.path ? normalizeDragPath(params.path, capture) : undefined;
	const ref = trimOrUndefined(params.ref);
	let adjustedViaAX = false;
	if (ref && path) {
		const axTarget = axTargetByRef(ref);
		const adjustment = dragAdjustment(path);
		if (adjustment) {
			adjustedViaAX = await tryAxAdjustElement(axTarget, adjustment, target, signal);
			if (!adjustedViaAX) {
				const reacquired = await reacquireAxTarget(axTarget, target, signal);
				if (reacquired) adjustedViaAX = await tryAxAdjustElement(reacquired, adjustment, target, signal);
			}
		}
	}
	if (adjustedViaAX) {
		return executionTrace("ax_action", "stealth", { axAttempted: true, axSucceeded: true, fallbackUsed: false });
	}
	// Stealth v2: coordinate drag is allowed - per-PID delivery, no
	// window raise.
	if (!path) {
		throw new Error("drag requires path points for pointer fallback or a ref plus path for AX adjustment.");
	}
	await bridgeCommand(
		"mouseDrag",
		{ ...nativeWindowRequest(target), path, ...captureRequest(capture) },
		{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
	);
	return executionTrace("coordinate_event_drag", "default", {
		axAttempted: Boolean(ref),
		axSucceeded: false,
		fallbackUsed: Boolean(ref),
		nonStealthReason: "drag_requires_pointer_event",
	});
}

async function runCoordinateAction(
	tool: string,
	capture: CurrentCapture,
	signal: AbortSignal | undefined,
	dispatch: (target: ResolvedTarget) => Promise<ExecutionTrace>,
	summaryFactory: (target: ResolvedTarget) => string,
): Promise<AgentToolResult<ComputerUseDetails>> {
	const currentTarget = await resolveCurrentTarget(signal);
	let activation = emptyActivation();
	let stateMayHaveChanged = false;

	try {
		const readyTarget = await ensureTargetWindowId(currentTarget, signal);
		return await withWindowWriteLock(readyTarget, async () => {
			const execution = await dispatch(readyTarget);
			stateMayHaveChanged = true;

			await sleep(settleMsForExecution(execution), signal);
			const captureResult = await captureCurrentTarget(signal, activation);
			return await buildToolResult(tool, summaryFactory(captureResult.target), captureResult, execution, signal);
		});
	} catch (error) {
		if (stateMayHaveChanged) {
			throw addRefreshHint(error);
		}
		throw normalizeError(error);
	}
}

async function performListApps(signal?: AbortSignal): Promise<AgentToolResult<ListAppsDetails>> {
	const apps = await listApps(signal);
	const config = getComputerUseConfig();
	const details: ListAppsDetails = {
		tool: "list_apps",
		apps: apps.map((app) => ({
			app: app.appName,
			bundleId: app.bundleId,
			pid: app.pid,
			isFrontmost: app.isFrontmost === true,
			browserUseAllowed: config.browser_use || !isBrowserApp(app.appName, app.bundleId),
		})),
		config,
	};
	const lines = details.apps.map(formatAppLine);
	const marker = `[${formatModeMarker()}]`;
	const body = lines.length
		? `Found ${lines.length} running app${lines.length === 1 ? "" : "s"}. Use list_windows with app, bundleId, or pid to inspect target windows.\n${lines.join("\n")}`
		: "No running apps were available to pi-computer-use.";
	return { content: [{ type: "text", text: `${marker}\n${body}` }], details };
}

async function performListWindows(params: ListWindowsParams, signal?: AbortSignal): Promise<AgentToolResult<ListWindowsDetails>> {
	const rawParams = params ?? {};
	const query: ListWindowsParams = {
		app: trimOrUndefined(rawParams.app),
		bundleId: trimOrUndefined(rawParams.bundleId),
		pid: Number.isFinite(rawParams.pid) ? Math.trunc(rawParams.pid!) : undefined,
	};
	const apps = (await listApps(signal)).filter((app) => appMatchesWindowQuery(app, query));
	if (apps.length === 0) {
		throw new Error(
			`No running app matched list_windows query${query.app ? ` app='${query.app}'` : ""}${query.bundleId ? ` bundleId='${query.bundleId}'` : ""}${query.pid ? ` pid=${query.pid}` : ""}. Call list_apps to inspect running apps.`,
		);
	}

	const config = getComputerUseConfig();
	const windows: ListWindowsDetails["windows"] = [];
	for (const app of apps) {
		const appWindows = await listWindows(app.pid, signal);
		for (const window of appWindows) {
			const storedRef = storeWindowRefForAppWindow(app, window);
			windows.push({
				app: app.appName,
				bundleId: app.bundleId,
				pid: app.pid,
				windowTitle: window.title || "(untitled)",
				windowId: window.windowId,
				windowRef: storedRef.ref,
				nativeWindowRef: window.windowRef,
				framePoints: window.framePoints,
				scaleFactor: window.scaleFactor,
				isMinimized: window.isMinimized,
				isOnscreen: window.isOnscreen,
				isOnActiveSpace: window.isOnActiveSpace,
				isMain: window.isMain,
				isFocused: window.isFocused,
				browserUseAllowed: config.browser_use || !isBrowserApp(app.appName, app.bundleId),
				score: scoreWindow(window),
			});
		}
	}
	windows.sort((a, b) => b.score - a.score || a.app.localeCompare(b.app) || a.windowTitle.localeCompare(b.windowTitle));

	const details: ListWindowsDetails = { tool: "list_windows", query, windows, config };
	const lines = windows.map(formatWindowLine);
	const offSpaceCount = windows.filter((w) => !w.isOnActiveSpace && !w.isMinimized).length;
	const offSpaceHint = offSpaceCount > 0
		? ` ${offSpaceCount} window${offSpaceCount === 1 ? " is" : "s are"} on another Space; use wake_window({ windowRef }) to bring ${offSpaceCount === 1 ? "it" : "them"} to the active Space.`
		: "";
	const marker = `[${formatModeMarker()}]`;
	const body = lines.length
		? `Found ${lines.length} controllable window${lines.length === 1 ? "" : "s"}. Use the @w refs with screenshot({ window: "@wN" }) or action tools' optional window field.${offSpaceHint}\n${lines.join("\n")}`
		: `No controllable windows matched the query. Try opening a window, or call list_apps to confirm the app is running.`;
	return { content: [{ type: "text", text: `${marker}\n${body}` }], details };
}

function normalizeImageMode(value: unknown): ImageMode {
	return value === "always" || value === "never" ? value : "auto";
}

async function performScreenshot(params: ScreenshotParams, signal?: AbortSignal): Promise<AgentToolResult<ComputerUseDetails>> {
	runtimeState.currentImageMode = normalizeImageMode(params.image);
	const selection = {
		app: trimOrUndefined(params.app),
		windowTitle: trimOrUndefined(params.windowTitle),
		window: normalizeWindowSelector(params.window),
	};

	const requestedTarget = selection.window
		? await resolveTargetByWindowSelector(params.window!, signal)
		: await resolveTargetForScreenshot(selection, signal);
	const captureResult = await captureCurrentTarget(signal);
	if (!matchesScreenshotSelection(captureResult.target, selection)) {
		throw new Error(
			`Screenshot target drifted from the requested selection. Requested ${requestedTarget.appName} — ${requestedTarget.windowTitle}, captured ${captureResult.target.appName} — ${captureResult.target.windowTitle}. Call screenshot again or specify a more exact window title.`,
		);
	}
	const summary = `Captured ${captureResult.target.windowRef ? `${captureResult.target.windowRef} ` : ""}${captureResult.target.appName} — ${captureResult.target.windowTitle}. Returned the latest semantic window state.`;
	return await buildToolResult("screenshot", summary, captureResult, executionTrace("screenshot", "stealth", { fallbackUsed: false }), signal, normalizeImageMode(params.image));
}

async function performClick(params: ClickParams, signal?: AbortSignal): Promise<AgentToolResult<ComputerUseDetails>> {
	runtimeState.currentImageMode = normalizeImageMode(params.image);
	await selectWindowIfProvided(params.window, signal);
	const capture = validateStateId(params.stateId);
	const ref = trimOrUndefined(params.ref);
	const x = toFiniteNumber(params.x, NaN);
	const y = toFiniteNumber(params.y, NaN);
	const button = normalizeMouseButton(params.button);
	const clickCount = normalizeClickCount(params.clickCount);

	return await runCoordinateAction(
		"click",
		capture,
		signal,
		async (target) => await dispatchClick({ ...params, clickCount }, capture, target, signal),
		(target) => {
			if (ref) {
				const axTarget = runtimeState.currentAxTargets?.find((candidate) => candidate.ref === ref);
				return `Clicked ${axTarget ? formatAxTargetLabel(axTarget) : ref} in ${target.appName} — ${target.windowTitle}. Returned the latest semantic window state.`;
			}
			return `${clickCount > 1 ? "Double-clicked" : button === "left" ? "Clicked" : `${button}-clicked`} at (${Math.round(x)},${Math.round(y)}) in ${target.appName} — ${target.windowTitle}. Returned the latest semantic window state.`;
		},
	);
}

async function performTypeText(params: TypeTextParams, signal?: AbortSignal): Promise<AgentToolResult<ComputerUseDetails>> {
	runtimeState.currentImageMode = normalizeImageMode(params.image);
	await selectWindowIfProvided(params.window, signal);
	const text = typeof params.text === "string" ? params.text : "";
	const currentTarget = await resolveCurrentTarget(signal);
	let activation = emptyActivation();
	let stateMayHaveChanged = false;

	try {
		const readyTarget = await ensureTargetWindowId(currentTarget, signal);
		return await withWindowWriteLock(readyTarget, async () => {
			const execution = await dispatchTypeText(text, readyTarget, signal);

			stateMayHaveChanged = true;
			await sleep(settleMsForExecution(execution), signal);
			const captureResult = await captureCurrentTarget(signal, activation);
			const summary = `Inserted text in ${captureResult.target.appName} — ${captureResult.target.windowTitle}. Returned the latest semantic window state.`;
			return await buildToolResult("type_text", summary, captureResult, execution, signal);
		});
	} catch (error) {
		if (stateMayHaveChanged) {
			throw addRefreshHint(error);
		}
		throw normalizeError(error);
	}
}

async function performSetText(params: SetTextParams, signal?: AbortSignal): Promise<AgentToolResult<ComputerUseDetails>> {
	runtimeState.currentImageMode = normalizeImageMode(params.image);
	await selectWindowIfProvided(params.window, signal);
	const text = typeof params.text === "string" ? params.text : "";
	const currentTarget = await resolveCurrentTarget(signal);
	let activation = emptyActivation();
	let stateMayHaveChanged = false;

	try {
		const readyTarget = await ensureTargetWindowId(currentTarget, signal);
		return await withWindowWriteLock(readyTarget, async () => {
			const execution = await dispatchSetText({ ...params, text }, readyTarget, signal);

			stateMayHaveChanged = true;
			await sleep(settleMsForExecution(execution), signal);
			const captureResult = await captureCurrentTarget(signal, activation);
			const summary = `Set text value in ${captureResult.target.appName} — ${captureResult.target.windowTitle}. Returned the latest semantic window state.`;
			return await buildToolResult("set_text", summary, captureResult, execution, signal);
		});
	} catch (error) {
		if (stateMayHaveChanged) {
			throw addRefreshHint(error);
		}
		throw normalizeError(error);
	}
}

async function performKeypress(params: KeypressParams, signal?: AbortSignal): Promise<AgentToolResult<ComputerUseDetails>> {
	runtimeState.currentImageMode = normalizeImageMode(params.image);
	await selectWindowIfProvided(params.window, signal);
	const keys = normalizeKeyList(params.keys);
	const currentTarget = await resolveCurrentTarget(signal);
	let activation = emptyActivation();
	let stateMayHaveChanged = false;

	try {
		const readyTarget = await ensureTargetWindowId(currentTarget, signal);
		return await withWindowWriteLock(readyTarget, async () => {
			const execution = await dispatchKeypress({ keys }, readyTarget, signal);

			stateMayHaveChanged = true;
			await sleep(settleMsForExecution(execution), signal);
			const captureResult = await captureCurrentTarget(signal, activation);
			const summary = `Pressed ${keys.length} key${keys.length === 1 ? "" : "s"} in ${captureResult.target.appName} — ${captureResult.target.windowTitle}. Returned the latest semantic window state.`;
			return await buildToolResult("keypress", summary, captureResult, execution, signal);
		});
	} catch (error) {
		if (stateMayHaveChanged) {
			throw addRefreshHint(error);
		}
		throw normalizeError(error);
	}
}

async function performScroll(params: ScrollParams, signal?: AbortSignal): Promise<AgentToolResult<ComputerUseDetails>> {
	runtimeState.currentImageMode = normalizeImageMode(params.image);
	await selectWindowIfProvided(params.window, signal);
	const capture = validateStateId(params.stateId);
	const ref = trimOrUndefined(params.ref);
	const x = toFiniteNumber(params.x, NaN);
	const y = toFiniteNumber(params.y, NaN);
	return await runCoordinateAction(
		"scroll",
		capture,
		signal,
		async (target) => await dispatchScroll(params, capture, target, signal),
		(target) =>
			ref
				? `Scrolled ${ref} in ${target.appName} — ${target.windowTitle}. Returned the latest semantic window state.`
				: `Scrolled at (${Math.round(x)},${Math.round(y)}) in ${target.appName} — ${target.windowTitle}. Returned the latest semantic window state.`,
	);
}

async function performMoveMouse(params: MoveMouseParams, signal?: AbortSignal): Promise<AgentToolResult<ComputerUseDetails>> {
	runtimeState.currentImageMode = normalizeImageMode(params.image);
	await selectWindowIfProvided(params.window, signal);
	const capture = validateStateId(params.stateId);
	return await runCoordinateAction(
		"move_mouse",
		capture,
		signal,
		async (target) => await dispatchMoveMouse(params, capture, target, signal),
		(target) =>
			`Moved mouse to (${Math.round(params.x)},${Math.round(params.y)}) in ${target.appName} — ${target.windowTitle}. Returned the latest semantic window state.`,
	);
}

async function performDrag(params: DragParams, signal?: AbortSignal): Promise<AgentToolResult<ComputerUseDetails>> {
	runtimeState.currentImageMode = normalizeImageMode(params.image);
	await selectWindowIfProvided(params.window, signal);
	const capture = validateStateId(params.stateId);
	return await runCoordinateAction(
		"drag",
		capture,
		signal,
		async (target) => await dispatchDrag(params, capture, target, signal),
		(target) => `Dragged in ${target.appName} — ${target.windowTitle}. Returned the latest semantic window state.`,
	);
}

async function performDoubleClick(params: ClickParams, signal?: AbortSignal): Promise<AgentToolResult<ComputerUseDetails>> {
	runtimeState.currentImageMode = normalizeImageMode(params.image);
	await selectWindowIfProvided(params.window, signal);
	const capture = validateStateId(params.stateId);
	const ref = trimOrUndefined(params.ref);
	const x = toFiniteNumber(params.x, NaN);
	const y = toFiniteNumber(params.y, NaN);
	return await runCoordinateAction(
		"double_click",
		capture,
		signal,
		async (target) => await dispatchClick({ ...params, clickCount: 2 }, capture, target, signal),
		(target) => {
			if (ref) {
				const axTarget = runtimeState.currentAxTargets?.find((candidate) => candidate.ref === ref);
				return `Double-clicked ${axTarget ? formatAxTargetLabel(axTarget) : ref} in ${target.appName} — ${target.windowTitle}. Returned the latest semantic window state.`;
			}
			return `Double-clicked at (${Math.round(x)},${Math.round(y)}) in ${target.appName} — ${target.windowTitle}. Returned the latest semantic window state.`;
		},
	);
}

async function dispatchComputerAction(
	action: ComputerAction,
	capture: CurrentCapture,
	target: ResolvedTarget,
	signal?: AbortSignal,
): Promise<ExecutionTrace> {
	switch (action.type) {
		case "click":
			return await dispatchClick(action, capture, target, signal);
		case "double_click":
			return await dispatchClick({ ...action, clickCount: 2 }, capture, target, signal);
		case "move_mouse":
			return await dispatchMoveMouse(action, capture, target, signal);
		case "drag":
			return await dispatchDrag(action, capture, target, signal);
		case "scroll":
			return await dispatchScroll(action, capture, target, signal);
		case "keypress":
			return await dispatchKeypress(action, target, signal);
		case "type_text":
			return await dispatchTypeText(action.text, target, signal);
		case "set_text":
			return await dispatchSetText(action, target, signal);
		case "wait": {
			const msRaw = action.ms ?? DEFAULT_WAIT_MS;
			if (!Number.isFinite(msRaw) || msRaw < 0) {
				throw new Error("wait.ms must be a non-negative number.");
			}
			await sleep(Math.min(60_000, Math.round(msRaw)), signal);
			return executionTrace("wait", "stealth", { fallbackUsed: false });
		}
		default:
			throw new Error(`Unsupported computer action '${(action as any)?.type ?? "unknown"}'.`);
	}
}

function actionMayChangeState(action: ComputerAction | undefined): boolean {
	return action?.type !== "wait";
}

function actionWindowMatchesTarget(selector: WindowSelector | undefined, target: ResolvedTarget): boolean {
	const normalized = normalizeWindowSelector(selector);
	if (!normalized) return true;
	if (target.windowRef === normalized) return true;
	const numeric = Number(normalized);
	return Number.isInteger(numeric) && numeric > 0 && target.windowId === numeric;
}

function frameForArrangePreset(params: ArrangeWindowParams, target: ResolvedTarget): { x: number; y: number; width: number; height: number } {
	if (params.preset === "left_half") return { x: 0, y: 25, width: 720, height: 875 };
	if (params.preset === "right_half") return { x: 720, y: 25, width: 720, height: 875 };
	if (params.preset === "top_half") return { x: 80, y: 25, width: 1200, height: 440 };
	if (params.preset === "bottom_half") return { x: 80, y: 465, width: 1200, height: 435 };
	if (params.preset === "center_large") return { x: 80, y: 80, width: 1200, height: 800 };
	return {
		x: toFiniteNumber(params.x, target.framePoints.x),
		y: toFiniteNumber(params.y, target.framePoints.y),
		width: toFiniteNumber(params.width, target.framePoints.w),
		height: toFiniteNumber(params.height, target.framePoints.h),
	};
}

async function performArrangeWindow(params: ArrangeWindowParams, signal?: AbortSignal): Promise<AgentToolResult<ComputerUseDetails>> {
	runtimeState.currentImageMode = normalizeImageMode(params.image);
	await selectWindowIfProvided(params.window, signal);
	const target = await ensureTargetWindowId(await resolveCurrentTarget(signal), signal);
	const frame = frameForArrangePreset(params, target);
	if (![frame.x, frame.y, frame.width, frame.height].every(Number.isFinite) || frame.width < 100 || frame.height < 80) {
		throw new Error("arrange_window requires finite x, y, width, and height values, or a supported preset.");
	}
	return await withWindowWriteLock(target, async () => {
		const result = await bridgeCommand<any>(
			"setWindowFrame",
			{ ...nativeWindowRequest(target), x: frame.x, y: frame.y, width: frame.width, height: frame.height },
			{ signal, timeoutMs: COMMAND_TIMEOUT_MS },
		);
		if (!toBoolean(result?.ok)) {
			throw new Error(`Unable to arrange window${result?.reason ? `: ${result.reason}` : "."}`);
		}
		await sleep(ACTION_SETTLE_MS, signal);
		const captureResult = await captureCurrentTarget(signal);
		return await buildToolResult(
			"arrange_window",
			`Arranged ${captureResult.target.windowRef ? `${captureResult.target.windowRef} ` : ""}${captureResult.target.appName} — ${captureResult.target.windowTitle}. Returned the latest semantic window state.`,
			captureResult,
			executionTrace("window_frame", "stealth", { fallbackUsed: false }),
			signal,
		);
	});
}

async function performNavigateBrowser(params: NavigateBrowserParams, signal?: AbortSignal): Promise<AgentToolResult<ComputerUseDetails>> {
	runtimeState.currentImageMode = normalizeImageMode(params.image);
	await selectWindowIfProvided(params.window, signal);
	const target = await ensureTargetWindowId(await resolveCurrentTarget(signal), signal);
	assertBrowserUseAllowed(target);
	if (!isBrowserApp(target.appName, target.bundleId)) {
		throw new Error(`navigate_browser requires a browser window, but the target is '${target.appName}'.`);
	}
	const url = trimOrUndefined(params.url);
	if (!url) {
		throw new Error("navigate_browser.url must be a non-empty URL or browser-search string.");
	}
	const script = browserOpenLocationAppleScript(target, url);
	if (!script) {
		throw new Error(`navigate_browser does not yet support direct URL navigation for '${target.appName}'. Use keypress Command+L, type_text, Enter instead.`);
	}
	// In stealth mode we promise to never activate the user's apps. Empirically,
	// Chrome's 'set URL of active tab of front window' AppleScript pulls Chrome
	// to the foreground (Safari's 'set URL of front document' may not, but we
	// can't tell which AppleScript dialect this script will execute against
	// without parsing it). The safe thing in stealth is to fail fast and let the
	// model fall back to the AX-only path: focus the address bar via the
	// keypress Command+L AX shortcut, set_text the URL, keypress Enter.
	if (isStrictAxMode()) {
		strictModeBlock(
			`navigate_browser is not stealth-safe for '${target.appName}': the AppleScript URL set activates the browser process. Use keypress({ keys: ['Command+L'] }) to focus the address bar via AX, then set_text the URL and keypress Enter.`,
		);
	}
	return await withWindowWriteLock(target, async () => {
		await focusControlledWindow(target, signal);
		await runAppleScript(script, signal);
		await sleep(ACTION_SETTLE_MS, signal);
		const captureResult = await captureCurrentTarget(signal);
		return await buildToolResult(
			"navigate_browser",
			`Navigated ${captureResult.target.windowRef ? `${captureResult.target.windowRef} ` : ""}${captureResult.target.appName} — ${captureResult.target.windowTitle}. Returned the latest semantic window state.`,
			captureResult,
			executionTrace("browser_open_location", "default", {
				axAttempted: false,
				axSucceeded: false,
				fallbackUsed: true,
				nonStealthReason: "browser_open_location_activates_browser_process",
			}),
			signal,
		);
	});
}

async function performComputerActions(params: ComputerActionsParams, signal?: AbortSignal): Promise<AgentToolResult<ComputerUseDetails>> {
	runtimeState.currentImageMode = normalizeImageMode(params.image);
	await selectWindowIfProvided(params.window, signal);
	const capture = validateStateId(params.stateId);
	const actions = Array.isArray(params.actions) ? params.actions : [];
	if (actions.length === 0) {
		throw new Error("computer_actions.actions must contain at least one action.");
	}
	if (actions.length > BATCH_MAX_ACTIONS) {
		throw new Error(`computer_actions supports at most ${BATCH_MAX_ACTIONS} actions per call.`);
	}

	const currentTarget = await resolveCurrentTarget(signal);
	let activation = emptyActivation();
	let stateMayHaveChanged = false;

	try {
		const readyTarget = await ensureTargetWindowId(currentTarget, signal);
		let axAttempted = false;
		let axSucceeded = false;
		let fallbackUsed = false;
		let stealthCompatible = true;
		const nonStealthReasons = new Set<string>();
		const actionTraces: BatchActionTrace[] = [];

		for (let index = 0; index < actions.length; index += 1) {
			const action = actions[index];
			if (!action || typeof (action as any).type !== "string") {
				throw new Error(`computer_actions action ${index + 1} is missing a valid type.`);
			}
			if (!actionWindowMatchesTarget((action as any).window, readyTarget)) {
				throw new Error(
					`computer_actions action ${index + 1} targets a different window. Use one computer_actions call per window, or set the top-level window field to the intended target.`,
				);
			}
			const actionStateId = (action as any)?.stateId;
			if (actionStateId && actionStateId !== capture.stateId) {
				throw new Error(`computer_actions action ${index + 1} uses stale state '${actionStateId}'. Refresh with screenshot and retry.`);
			}
			let trace: ExecutionTrace;
			const startedAt = Date.now();
			try {
				trace = await dispatchComputerAction(action, capture, readyTarget, signal);
			} catch (error) {
				const actionType = (action as any)?.type ?? "unknown";
				throw new Error(`computer_actions action ${index + 1} (${actionType}) failed: ${normalizeError(error).message}`);
			}
			actionTraces.push({
				index: index + 1,
				type: action.type,
				strategy: trace.strategy,
				durationMs: Math.max(0, Date.now() - startedAt),
				axAttempted: trace.axAttempted,
				axSucceeded: trace.axSucceeded,
				fallbackUsed: trace.fallbackUsed,
				runtimeMode: trace.runtimeMode,
				variant: trace.variant,
				stealthCompatible: trace.stealthCompatible,
				nonStealthReason: trace.nonStealthReason,
			});
			if (actionMayChangeState(action)) {
				stateMayHaveChanged = true;
			}
			axAttempted ||= trace.axAttempted === true;
			axSucceeded ||= trace.axSucceeded === true;
			fallbackUsed ||= trace.fallbackUsed === true;
			stealthCompatible &&= trace.stealthCompatible === true;
			if (trace.nonStealthReason) {
				nonStealthReasons.add(trace.nonStealthReason);
			}
			if (index + 1 < actions.length && action?.type !== "wait") {
				await sleep(BATCH_ACTION_GAP_MS, signal);
			}
		}

		const execution = executionTrace("batch", stealthCompatible ? "stealth" : "default", {
			actionCount: actions.length,
			completedActionCount: actionTraces.length,
			actions: actionTraces,
			axAttempted,
			axSucceeded,
			fallbackUsed,
			nonStealthReason: nonStealthReasons.size > 0 ? [...nonStealthReasons].join(",") : undefined,
		});
		await sleep(settleMsForExecution(execution), signal);
		const captureResult = await captureCurrentTarget(signal, activation);
		const summary = `Executed ${actions.length} computer action${actions.length === 1 ? "" : "s"} in ${captureResult.target.appName} — ${captureResult.target.windowTitle}. Returned the latest semantic window state.`;
		return await buildToolResult("computer_actions", summary, captureResult, execution, signal);
	} catch (error) {
		if (stateMayHaveChanged) {
			await sleep(ACTION_SETTLE_MS, signal).catch(() => undefined);
			await captureCurrentTarget(signal, activation).catch(() => undefined);
			throw addRefreshHint(error);
		}
		throw normalizeError(error);
	}
}

async function performWait(params: WaitParams, signal?: AbortSignal): Promise<AgentToolResult<ComputerUseDetails>> {
	runtimeState.currentImageMode = normalizeImageMode(params.image);
	await selectWindowIfProvided(params.window, signal);
	if (!runtimeState.currentTarget) {
		throw new Error(MISSING_TARGET_ERROR);
	}

	const msRaw = params.ms ?? DEFAULT_WAIT_MS;
	if (!Number.isFinite(msRaw) || msRaw < 0) {
		throw new Error("wait.ms must be a non-negative number.");
	}

	const ms = Math.min(60_000, Math.round(msRaw));
	await sleep(ms, signal);
	const captureResult = await captureCurrentTarget(signal);
	const summary = `Waited ${ms}ms in ${captureResult.target.appName} — ${captureResult.target.windowTitle}. Returned the latest semantic window state.`;
	return await buildToolResult("wait", summary, captureResult, executionTrace("wait", "stealth", { fallbackUsed: false }), signal);
}

async function executeTool<T>(ctx: ExtensionContext, signal: AbortSignal | undefined, run: () => Promise<T>): Promise<T> {
	return await withRuntimeLock(async () => {
		await ensureReady(ctx, signal);
		throwIfAborted(signal);

		return await run();
	});
}

export async function executeListApps(
	_toolCallId: string,
	_params: Record<string, never>,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<ListAppsDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<ListAppsDetails>> {
	return await executeTool(ctx, signal, () => performListApps(signal));
}

export async function executeListWindows(
	_toolCallId: string,
	params: ListWindowsParams,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<ListWindowsDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<ListWindowsDetails>> {
	return await executeTool(ctx, signal, () => performListWindows(params, signal));
}

export async function executeWakeWindow(
	_toolCallId: string,
	params: WakeWindowParams,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<WakeWindowDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<WakeWindowDetails>> {
	return await executeTool(ctx, signal, () => performWakeWindow(params, signal));
}

export async function executeSurfaceWindow(
	_toolCallId: string,
	params: SurfaceWindowParams,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<SurfaceWindowDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<SurfaceWindowDetails>> {
	return await executeTool(ctx, signal, () => performSurfaceWindow(params, signal));
}

/**
 * Resolve a wake/surface params object to a (record, pid, windowId)
 * tuple plus the bridge payload. Both wake_window and surface_window
 * share the same input shape and resolution rules - the difference is
 * what they do with the resolved target.
 */
function resolveWindowTargetForWake(
	params: WakeWindowParams | SurfaceWindowParams,
	toolName: string,
): {
	record: WindowRefRecord | undefined;
	pid: number;
	payload: Record<string, unknown>;
	effectiveWindowId: number | undefined;
} {
	const windowRef = trimOrUndefined(params.windowRef);
	const windowId = Number.isFinite(params.windowId) ? Math.trunc(params.windowId!) : undefined;
	const explicitPid = Number.isFinite(params.pid) ? Math.trunc(params.pid!) : undefined;

	let record: WindowRefRecord | undefined;
	if (windowRef) {
		record = runtimeState.windowRefs.get(windowRef);
		if (!record) {
			throw new Error(`Unknown window ref '${windowRef}'. Call list_windows to get current refs.`);
		}
	}

	const pid = record?.pid ?? explicitPid;
	if (!pid) {
		throw new Error(`${toolName} requires either windowRef or both windowId and pid.`);
	}

	const payload: Record<string, unknown> = { pid };
	if (record?.nativeWindowRef) payload.windowRef = record.nativeWindowRef;
	const effectiveWindowId = record?.windowId ?? windowId;
	if (effectiveWindowId) payload.windowId = effectiveWindowId;

	return { record, pid, payload, effectiveWindowId };
}

async function performWakeWindow(params: WakeWindowParams, signal?: AbortSignal): Promise<AgentToolResult<WakeWindowDetails>> {
	const rawParams = params ?? {};
	const { record, pid, payload, effectiveWindowId } = resolveWindowTargetForWake(rawParams, "wake_window");

	const result = await bridgeCommand<any>("wakeWindow", payload, { signal });
	const isOffActiveSpace = toBoolean(result?.isOffActiveSpace);
	const isMinimized = toBoolean(result?.isMinimized);
	const unminimized = toBoolean(result?.unminimized);
	const action = (result?.action ?? "on_space_status") as WakeWindowDetails["action"];

	// Discover non-GUI alternatives the agent can use instead of
	// surfacing the window. apple_script comes from current config;
	// app instructions come from the existing loadAppInstructions cache
	// (covers user overrides at ~/.pi/agent/extensions/pi-computer-use
	// /instructions/<bundleId>.md and bundled instructions/<bundleId>.md).
	const appleScriptCfg = getAppleScriptConfig();
	let instructions: AppInstructions | null = null;
	try {
		instructions = await loadAppInstructions({
			bundleId: record?.bundleId,
			appName: record?.appName,
		});
	} catch {
		// Loader is best-effort. Never block on instruction lookup.
	}

	const alternatives: WakeWindowAlternatives = {
		appleScript: {
			enabled: appleScriptCfg.enabled,
			hint: appleScriptCfg.enabled
				? `Try apple_script({ app: "${record?.appName ?? "<app>"}", script: "..." }) for any task this app exposes via its scripting dictionary. Apple Events do not raise the window or change Spaces.`
				: "Disabled in current config; ask the user to enable apple_script in the computer-use settings if Apple Events would help.",
		},
		appInstructions: {
			found: !!instructions,
			source: instructions?.source ?? null,
			matchedKey: instructions?.matchedKey ?? null,
		},
		surfaceWindow: {
			tool: "surface_window",
			windowRef: record?.ref,
			hint: "Last resort. surface_window will activate the app and may switch the user's viewport to the window's Space. Ask the user for permission first ('Need to bring <App> forward to do <task>; OK?') before calling it.",
		},
	};

	const details: WakeWindowDetails = {
		tool: "wake_window",
		query: rawParams,
		pid,
		window: {
			windowRef: record?.ref,
			windowId: effectiveWindowId,
			windowTitle: record?.windowTitle,
			appName: record?.appName,
			bundleId: record?.bundleId,
		},
		isOffActiveSpace,
		isMinimized,
		unminimized,
		action,
		alternatives,
	};

	const label = formatWakeLabel(record, pid);
	const lines: string[] = [];

	if (action === "unminimized") {
		lines.push(`Un-minimized ${label}. Window is now on the active Space and ready for screenshot/action tools.`);
	} else if (isOffActiveSpace) {
		lines.push(`${label} is on a different macOS Space. We cannot drive it silently from another Space - macOS blocks cross-process Space manipulation without SIP-disabled tooling, and AX cannot deliver actions to off-Space windows.`);
		lines.push("");
		lines.push("Try these in order before disturbing the user:");
		lines.push(`1. apple_script: ${alternatives.appleScript.hint}`);
		lines.push(`2. app_instructions: ${alternatives.appInstructions.found ? `bundled guidance for ${record?.appName ?? "this app"} is available (source: ${alternatives.appInstructions.source}). Read it via screenshot of an on-Space window of this app, or via the loadAppInstructions cache, and look for URL schemes / shell commands / file-edit paths that avoid the GUI.` : `no bundled instructions found for ${record?.appName ?? "this app"} - check if the app supports a URL scheme, command-line interface, or file-based workflow that bypasses the GUI.`}`);
		lines.push(`3. ask the user to swipe to the Space where ${record?.appName ?? "this window"} is open.`);
		lines.push(`4. surface_window: ${alternatives.surfaceWindow.hint}`);
	} else {
		lines.push(`${label} is already on the active Space and ready for screenshot/action tools.`);
	}

	return { content: [{ type: "text", text: lines.join("\n") }], details };
}

async function performSurfaceWindow(params: SurfaceWindowParams, signal?: AbortSignal): Promise<AgentToolResult<SurfaceWindowDetails>> {
	const rawParams = params ?? {};
	const { record, pid, payload, effectiveWindowId } = resolveWindowTargetForWake(rawParams, "surface_window");

	const result = await bridgeCommand<any>("surfaceWindow", payload, { signal });
	const appActivated = toBoolean(result?.appActivated);
	const windowRaised = toBoolean(result?.windowRaised);

	const details: SurfaceWindowDetails = {
		tool: "surface_window",
		query: rawParams,
		appActivated,
		windowRaised,
		pid,
		window: {
			windowRef: record?.ref,
			windowId: effectiveWindowId,
			windowTitle: record?.windowTitle,
			appName: record?.appName,
		},
	};

	const label = formatWakeLabel(record, pid);
	const statusBits = [`app activated: ${appActivated}`, `window raised: ${windowRaised}`];
	const text = appActivated || windowRaised
		? `Surfaced ${label} (${statusBits.join(", ")}). The user's viewport may have switched. Call screenshot to inspect the window now that it's on the active Space.`
		: `Could not surface ${label} (${statusBits.join(", ")}). The window may already be on the active Space, or the app refused the request.`;

	return { content: [{ type: "text", text }], details };
}

export async function executeLaunchApp(
	_toolCallId: string,
	params: LaunchAppParams,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<LaunchAppDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<LaunchAppDetails>> {
	return await executeTool(ctx, signal, () => performLaunchApp(params, signal));
}

async function performLaunchApp(params: LaunchAppParams, signal?: AbortSignal): Promise<AgentToolResult<LaunchAppDetails>> {
	const rawParams = params ?? {};
	const bundleId = trimOrUndefined(rawParams.bundleId);
	const appName = trimOrUndefined(rawParams.appName);
	const activate = !!rawParams.activate;

	if (!bundleId && !appName) {
		throw new Error("launch_app requires bundleId or appName.");
	}

	// Stealth v2: launching with activate=false is always safe (the
	// app starts in the background, no surprise focus change).
	// Launching with activate=true would steal focus, so it has the
	// same gate as surface_window: agent must ask user permission
	// first. Refuse here so the agent gets a clean error pointing it
	// at the right pattern; outside stealth, activation is allowed
	// because the user opted out of the contract.
	if (activate && isStrictAxMode()) {
		throw new Error(
			"launch_app({ activate: true }) would steal focus and is gated in stealth mode for the same reason as surface_window. Either: (a) launch with activate=false (background launch is always allowed), then ask the user for permission and call surface_window if you need the app foreground, or (b) ask the user for permission first, then launch with activate=true.",
		);
	}

	const payload: Record<string, unknown> = { activate };
	if (bundleId) payload.bundleId = bundleId;
	if (appName) payload.appName = appName;

	const result = await bridgeCommand<any>("launchApp", payload, { signal, timeoutMs: 12_000 });
	const pid = Math.trunc(result?.pid ?? 0);
	const details: LaunchAppDetails = {
		tool: "launch_app",
		query: rawParams,
		pid,
		appName: typeof result?.appName === "string" ? result.appName : appName ?? "",
		bundleId: typeof result?.bundleId === "string" ? result.bundleId : bundleId ?? "",
		alreadyRunning: toBoolean(result?.alreadyRunning),
		activated: toBoolean(result?.activated),
	};

	const statusBits: string[] = [];
	if (details.alreadyRunning) statusBits.push("already running");
	else statusBits.push("launched");
	if (details.activated) statusBits.push("activated (foreground)");
	else statusBits.push("background");
	const text = `${statusBits[0]}: ${details.appName} (pid ${details.pid}, bundleId ${details.bundleId})${details.activated ? " \u2014 user's viewport may have changed" : ""}. Use pid ${details.pid} with screenshot/list_windows to inspect the app.`;

	return { content: [{ type: "text", text }], details };
}

function formatWakeLabel(record: WindowRefRecord | undefined, pid: number): string {
	const pieces: string[] = [];
	if (record?.appName) pieces.push(record.appName);
	if (record?.windowTitle) pieces.push(`'${record.windowTitle}'`);
	return pieces.length ? pieces.join(" ") : `pid ${pid}`;
}

export async function executeScreenshot(
	_toolCallId: string,
	params: ScreenshotParams,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<ComputerUseDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<ComputerUseDetails>> {
	return await executeTool(ctx, signal, () => performScreenshot(params, signal));
}

export async function executeClick(
	_toolCallId: string,
	params: ClickParams,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<ComputerUseDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<ComputerUseDetails>> {
	return await executeTool(ctx, signal, () => performClick(params, signal));
}

export async function executeDoubleClick(
	_toolCallId: string,
	params: ClickParams,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<ComputerUseDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<ComputerUseDetails>> {
	return await executeTool(ctx, signal, () => performDoubleClick(params, signal));
}

export async function executeMoveMouse(
	_toolCallId: string,
	params: MoveMouseParams,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<ComputerUseDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<ComputerUseDetails>> {
	return await executeTool(ctx, signal, () => performMoveMouse(params, signal));
}

export async function executeDrag(
	_toolCallId: string,
	params: DragParams,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<ComputerUseDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<ComputerUseDetails>> {
	return await executeTool(ctx, signal, () => performDrag(params, signal));
}

export async function executeScroll(
	_toolCallId: string,
	params: ScrollParams,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<ComputerUseDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<ComputerUseDetails>> {
	return await executeTool(ctx, signal, () => performScroll(params, signal));
}

export async function executeKeypress(
	_toolCallId: string,
	params: KeypressParams,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<ComputerUseDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<ComputerUseDetails>> {
	return await executeTool(ctx, signal, () => performKeypress(params, signal));
}

export async function executeTypeText(
	_toolCallId: string,
	params: TypeTextParams,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<ComputerUseDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<ComputerUseDetails>> {
	return await executeTool(ctx, signal, () => performTypeText(params, signal));
}

export async function executeSetText(
	_toolCallId: string,
	params: SetTextParams,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<ComputerUseDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<ComputerUseDetails>> {
	return await executeTool(ctx, signal, () => performSetText(params, signal));
}

export async function executeArrangeWindow(
	_toolCallId: string,
	params: ArrangeWindowParams,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<ComputerUseDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<ComputerUseDetails>> {
	return await executeTool(ctx, signal, () => performArrangeWindow(params, signal));
}

export async function executeNavigateBrowser(
	_toolCallId: string,
	params: NavigateBrowserParams,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<ComputerUseDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<ComputerUseDetails>> {
	return await executeTool(ctx, signal, () => performNavigateBrowser(params, signal));
}

export async function executeComputerActions(
	_toolCallId: string,
	params: ComputerActionsParams,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<ComputerUseDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<ComputerUseDetails>> {
	return await executeTool(ctx, signal, () => performComputerActions(params, signal));
}

export async function executeWait(
	_toolCallId: string,
	params: WaitParams,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<ComputerUseDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<ComputerUseDetails>> {
	return await executeTool(ctx, signal, () => performWait(params, signal));
}

export function reconstructStateFromBranch(ctx: ExtensionContext): void {
	runtimeState.currentTarget = undefined;
	runtimeState.currentCapture = undefined;
	runtimeState.currentStateTarget = undefined;
	runtimeState.currentAxTargets = undefined;
	runtimeState.windowRefs.clear();
	runtimeState.windowRefByIdentity.clear();
	runtimeState.nextWindowRefIndex = 1;

	let restoredCurrent = false;
	for (const entry of [...ctx.sessionManager.getBranch()].reverse()) {
		if ((entry as any)?.type !== "message") continue;
		const message = (entry as any).message;
		if (!message || message.role !== "toolResult") continue;
		if (!TOOL_NAMES.has(message.toolName)) continue;

		const rawDetails = message.details as any;
		if (rawDetails?.tool === "list_windows" && Array.isArray(rawDetails.windows)) {
			for (const window of rawDetails.windows) {
				if (typeof window?.windowRef !== "string" || !Number.isFinite(window?.pid)) continue;
				const record: WindowRefRecord = {
					ref: window.windowRef,
					appName: typeof window.app === "string" ? window.app : "Unknown App",
					bundleId: typeof window.bundleId === "string" ? window.bundleId : undefined,
					pid: Math.trunc(window.pid),
					windowTitle: typeof window.windowTitle === "string" ? window.windowTitle : "(untitled)",
					windowId: Number.isFinite(window.windowId) ? Math.trunc(window.windowId) : undefined,
					nativeWindowRef: typeof window.nativeWindowRef === "string" ? window.nativeWindowRef : undefined,
					framePoints: parseFramePoints({ framePoints: window.framePoints }),
					scaleFactor: Math.max(1, toFiniteNumber(window.scaleFactor, 1)),
					isMinimized: toBoolean(window.isMinimized),
					isOnscreen: toBoolean(window.isOnscreen),
					isOnActiveSpace:
						typeof window.isOnActiveSpace === "boolean"
							? window.isOnActiveSpace
							: toBoolean(window.isMinimized) || toBoolean(window.isOnscreen),
					isMain: toBoolean(window.isMain),
					isFocused: toBoolean(window.isFocused),
				};
				runtimeState.windowRefs.set(record.ref, record);
				runtimeState.windowRefByIdentity.set(windowRecordIdentity(record), record.ref);
				const match = /^@w(\d+)$/.exec(record.ref);
				if (match) runtimeState.nextWindowRefIndex = Math.max(runtimeState.nextWindowRefIndex, Number(match[1]) + 1);
			}
			continue;
		}

		if (restoredCurrent) continue;

		const details = rawDetails as Partial<ComputerUseDetails> | undefined;
		if (!details?.target || !details?.capture) continue;

		const app =
			typeof details.target.app === "string"
				? details.target.app
				: typeof (details.target as any).appName === "string"
					? (details.target as any).appName
					: undefined;

		if (!app) continue;
		if (!Number.isFinite(details.target.pid) || !Number.isFinite(details.target.windowId)) continue;
		if (typeof details.capture.stateId !== "string") continue;

		runtimeState.currentTarget = {
			appName: app,
			bundleId: details.target.bundleId,
			pid: Math.trunc(details.target.pid),
			windowTitle: details.target.windowTitle ?? "(untitled)",
			windowId: Math.trunc(details.target.windowId),
			windowRef: typeof details.target.windowRef === "string" ? details.target.windowRef : undefined,
			nativeWindowRef: typeof (details.target as any).nativeWindowRef === "string" ? (details.target as any).nativeWindowRef : undefined,
		};

		const restoredWidth = Math.max(1, Math.trunc(toFiniteNumber(details.capture.width, 1)));
		const restoredHeight = Math.max(1, Math.trunc(toFiniteNumber(details.capture.height, 1)));
		const restoredScale = Math.max(1, toFiniteNumber(details.capture.scaleFactor, 1));
		// Persisted captures from older session shapes may not include the
		// new windowWidth/windowHeight/framePoints fields; derive sane
		// defaults so coordinate validation still works on resume.
		const restoredWindowWidth = Math.max(1, toFiniteNumber((details.capture as any).windowWidth, restoredWidth / restoredScale));
		const restoredWindowHeight = Math.max(1, toFiniteNumber((details.capture as any).windowHeight, restoredHeight / restoredScale));
		runtimeState.currentCapture = {
			stateId: details.capture.stateId,
			width: restoredWidth,
			height: restoredHeight,
			scaleFactor: restoredScale,
			timestamp: Number.isFinite(details.capture.timestamp) ? details.capture.timestamp : Date.now(),
			windowWidth: restoredWindowWidth,
			windowHeight: restoredWindowHeight,
			framePoints: { x: 0, y: 0, w: restoredWindowWidth, h: restoredWindowHeight },
		};
		runtimeState.currentAxTargets = Array.isArray(details.axTargets)
			? details.axTargets.filter((item): item is AxTarget => Boolean(item && typeof item.ref === "string" && typeof item.elementRef === "string"))
			: undefined;

		restoredCurrent = true;
		continue;
	}
}

export type { AppleScriptParams, AppleScriptDetails } from "./apple-script.ts";

export async function executeAppleScript(
	_toolCallId: string,
	params: AppleScriptParams,
	signal: AbortSignal | undefined,
	_onUpdate: AgentToolUpdateCallback<AppleScriptDetails> | undefined,
	ctx: ExtensionContext,
): Promise<AgentToolResult<AppleScriptDetails>> {
	// apple_script does not require the helper bridge or a controlled window;
	// just execute it directly under the runtime lock to serialise with other
	// computer-use calls so concurrent osascript invocations do not contend.
	return await withRuntimeLock(async () => {
		throwIfAborted(signal);
		return await performAppleScript(params, signal);
	});
}

export function stopBridge(): void {
	rejectAllPending(new HelperTransportError("Computer-use helper stopped."));

	const helper = runtimeState.helper;
	runtimeState.helper = undefined;
	runtimeState.helperStdoutBuffer = "";
	runtimeState.currentAxTargets = undefined;

	if (helper && helper.exitCode === null && !helper.killed) {
		helper.kill("SIGTERM");
	}
}
