/**
 * Per-app instruction loader.
 *
 * Looks up hand-written guidance for the app a tool is currently targeting.
 * Bundled files live under `<repo>/instructions/`; user overrides at
 * `~/.pi/computer-use/instructions/` win over bundled files with the same name.
 *
 * Lookup order, first hit wins:
 *   1. user/<bundle-id>.md
 *   2. user/<App Name>.md
 *   3. bundled/<bundle-id>.md
 *   4. bundled/<App Name>.md
 *
 * Cached in-process so each file is read at most once per pi session.
 * Result text is capped at MAX_RENDERED_BYTES (~3 KB).
 */

import { readFile, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export interface AppInstructions {
	/** Where the file came from. */
	source: "user" | "bundled";
	/** App identifier this file matched on. Bundle id when available, else app name. */
	matchedKey: string;
	/** Trimmed, length-capped markdown body. */
	text: string;
	/** True if the file was longer than MAX_RENDERED_BYTES and got truncated. */
	truncated: boolean;
}

interface AppLookup {
	bundleId?: string;
	appName?: string;
}

const MAX_RENDERED_BYTES = 3 * 1024;

const moduleDir = path.dirname(fileURLToPath(import.meta.url));
// `src/` lives next to `instructions/` in the repo and in the published tarball.
const BUNDLED_INSTRUCTIONS_DIR = path.resolve(moduleDir, "..", "instructions");
const USER_INSTRUCTIONS_DIR = path.join(os.homedir(), ".pi", "computer-use", "instructions");

// Cache by absolute file path. `null` means "we looked, file does not exist".
const fileCache = new Map<string, AppInstructions | null>();

function sanitizeFilenameComponent(value: string): string {
	// Strip path separators and control chars; keep dots, spaces, hyphens, underscores.
	return value.replace(/[/\\\u0000-\u001f\u007f]/g, "").trim();
}

function candidatePaths(lookup: AppLookup): Array<{ source: "user" | "bundled"; matchedKey: string; absPath: string }> {
	const results: Array<{ source: "user" | "bundled"; matchedKey: string; absPath: string }> = [];
	const bundleId = lookup.bundleId ? sanitizeFilenameComponent(lookup.bundleId) : "";
	const appName = lookup.appName ? sanitizeFilenameComponent(lookup.appName) : "";

	const dirsInOrder: Array<{ source: "user" | "bundled"; dir: string }> = [
		{ source: "user", dir: USER_INSTRUCTIONS_DIR },
		{ source: "bundled", dir: BUNDLED_INSTRUCTIONS_DIR },
	];

	for (const { source, dir } of dirsInOrder) {
		if (bundleId) {
			results.push({ source, matchedKey: bundleId, absPath: path.join(dir, `${bundleId}.md`) });
		}
		if (appName && appName !== bundleId) {
			results.push({ source, matchedKey: appName, absPath: path.join(dir, `${appName}.md`) });
		}
	}

	return results;
}

async function loadFromFile(absPath: string): Promise<AppInstructions | null> {
	if (fileCache.has(absPath)) return fileCache.get(absPath) ?? null;

	let text: string;
	try {
		const info = await stat(absPath);
		if (!info.isFile()) {
			fileCache.set(absPath, null);
			return null;
		}
		text = await readFile(absPath, "utf8");
	} catch {
		fileCache.set(absPath, null);
		return null;
	}

	const trimmed = text.trim();
	if (!trimmed) {
		fileCache.set(absPath, null);
		return null;
	}

	let body = trimmed;
	let truncated = false;
	const byteLength = Buffer.byteLength(body, "utf8");
	if (byteLength > MAX_RENDERED_BYTES) {
		// Cut on a UTF-8 byte boundary by taking a Buffer slice and decoding.
		body = Buffer.from(body, "utf8").slice(0, MAX_RENDERED_BYTES).toString("utf8").trimEnd();
		truncated = true;
	}

	const placeholder: AppInstructions = {
		source: "user",
		matchedKey: "",
		text: body,
		truncated,
	};
	fileCache.set(absPath, placeholder);
	return placeholder;
}

/**
 * Look up app instructions for a screenshot/inspection target. Returns null if
 * no matching file exists in either the user or bundled directory. Safe to call
 * repeatedly: hits are cached per file path for the lifetime of the process.
 */
export async function loadAppInstructions(lookup: AppLookup): Promise<AppInstructions | null> {
	if (!lookup.bundleId && !lookup.appName) return null;

	for (const candidate of candidatePaths(lookup)) {
		const loaded = await loadFromFile(candidate.absPath);
		if (loaded) {
			// Reattach source/matchedKey since the cache value's placeholders are generic.
			return {
				source: candidate.source,
				matchedKey: candidate.matchedKey,
				text: loaded.text,
				truncated: loaded.truncated,
			};
		}
	}
	return null;
}

/** Test/dev hook — clear the in-memory cache so changes to instruction files take effect. */
export function clearAppInstructionsCache(): void {
	fileCache.clear();
}
