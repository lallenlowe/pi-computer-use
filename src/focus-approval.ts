import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { isFocusAutoApprove } from "./config.ts";

/**
 * Single chokepoint for any tool that would change the user's frontmost
 * app/window. Currently: surface_window and launch_app({activate:true}).
 *
 * Behaviour:
 *  - If `focus_auto_approve` config is true, returns immediately.
 *  - Otherwise calls ctx.ui.confirm with a prompt naming the app and the
 *    reason the agent wants to take focus.
 *  - If pi is running without a UI surface (print mode, JSON mode), no
 *    prompt is possible: throws a structured error pointing the agent at
 *    non-focus alternatives (wake_window recipes, apple_script,
 *    bundled instructions).
 *  - If the user declines, throws so the agent surfaces the rejection
 *    instead of silently proceeding.
 *
 * Approval is per-call. There is no session-scoped cache; two
 * surface_window calls = two prompts (unless focus_auto_approve is on).
 * Keeps the contract trivial; we can add per-session opt-in later if it
 * becomes annoying in practice.
 */
export async function requireFocusChangeApproval(opts: {
	ctx: ExtensionContext;
	appName: string;
	toolName: string;
	reason: string;
	signal?: AbortSignal;
}): Promise<void> {
	const { ctx, appName, toolName, reason, signal } = opts;

	if (isFocusAutoApprove()) {
		return;
	}

	if (!ctx.hasUI) {
		throw new Error(
			`${toolName} would change the user's frontmost app to '${appName}', which requires user approval. ` +
			`focus_auto_approve is off and pi has no interactive UI to prompt the user (e.g. print/JSON mode). ` +
			`Either: (a) ask the user out-of-band to enable focus_auto_approve in the pi-computer-use config and ` +
			`retry, or (b) use a non-focus-changing alternative - call wake_window({windowRef}) for a recipe of ` +
			`apple_script / app_instructions / URL-scheme paths that drive the app without raising it.`,
		);
	}

	const trimmedReason = reason.trim();
	if (!trimmedReason) {
		throw new Error(
			`${toolName} requires a non-empty 'reason' parameter so the user understands why you need to change ` +
			`their frontmost app. Pass something like reason: "open Obsidian Settings to install update".`,
		);
	}

	const approved = await ctx.ui.confirm(
		`Bring ${appName} forward?`,
		`The agent wants to call ${toolName} and take focus.\n\nReason: ${trimmedReason}\n\nThis will activate ${appName} and may switch your Space.`,
		signal ? { signal } : undefined,
	);

	if (!approved) {
		throw new Error(
			`User declined to bring ${appName} forward. Either: (a) re-ask the user directly via your own prompt ` +
			`and try again with a clearer reason, or (b) use a non-focus-changing alternative - wake_window ` +
			`recipes, apple_script, or bundled app instructions.`,
		);
	}
}
