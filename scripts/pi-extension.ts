// claude-monitor pi-extension v1
//
// Claude Monitor extension for the pi coding agent — installed to
// <agent-dir>/extensions/claude-monitor.ts by Claude Monitor. Changes made to
// the installed copy are overwritten when the app updates.
//
// Normalizes pi lifecycle events into Claude Monitor's event vocabulary
// (SessionStart, UserPromptSubmit, PostToolUse, Stop, Notification, SessionEnd),
// namespaces the session id as "pi:<id>", and POSTs to the local Claude Monitor
// server whose port is in ~/.claude-monitor/port.
//
// This extension runs inside pi's terminal UI, so it must stay a pure observer:
// never write to stdout/stderr, never throw, and never change pi's behavior.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type Hook = "SessionStart" | "UserPromptSubmit" | "PostToolUse" | "Stop" | "Notification" | "SessionEnd";

// Structural subset of pi's ExtensionAPI/ExtensionContext, so the file needs no
// imports from the pi package and loads in any pi version with these events.
interface Context {
	mode?: string;
	cwd?: string;
	sessionManager?: { getSessionId(): string };
}
interface PiAPI {
	on(event: string, handler: (event: any, ctx: Context) => unknown): unknown;
}

const PORT_FILE = join(homedir(), ".claude-monitor", "port");
const POST_TIMEOUT_MS = 2000;

function readPort(): string | undefined {
	try {
		const port = readFileSync(PORT_FILE, "utf8").trim();
		return /^\d+$/.test(port) ? port : undefined;
	} catch {
		return undefined;
	}
}

// ps reports the controlling terminal as e.g. "ttys003"; map it to the /dev
// path the terminal providers match on.
function controllingTTY(): string {
	try {
		const raw = execFileSync("ps", ["-o", "tty=", "-p", String(process.pid)], {
			encoding: "utf8",
			stdio: ["ignore", "pipe", "ignore"],
			timeout: 1000,
		}).trim();
		if (!raw || raw.startsWith("?")) return "";
		if (raw.startsWith("/dev/")) return raw;
		if (raw.startsWith("tty")) return `/dev/${raw}`;
		if (/^[sp]\d/.test(raw)) return `/dev/tty${raw}`;
		return `/dev/${raw}`;
	} catch {
		return "";
	}
}

export default function (pi: PiAPI) {
	let tty: string | undefined;
	// True between agent_start and agent_settled. Prompts outside a run come
	// from slash commands the user just typed, so they are not reported: the
	// user is already at the keyboard, and each Stop would push "Done".
	let running = false;

	async function post(hook: Hook, ctx: Context, extra: Record<string, unknown> = {}): Promise<void> {
		try {
			// Only interactive sessions get tiles; subagents and scripts run pi in
			// print/json/rpc mode.
			if (ctx.mode !== "tui") return;
			const sessionId = ctx.sessionManager?.getSessionId();
			if (!sessionId) return;
			const port = readPort();
			if (!port) return;
			tty ??= controllingTTY();
			const body = {
				hook,
				provider: "pi",
				session_id: `pi:${sessionId}`,
				tty,
				pid: process.pid,
				cwd: ctx.cwd || process.cwd(),
				ts: Math.floor(Date.now() / 1000),
				...extra,
			};
			await fetch(`http://127.0.0.1:${port}/event`, {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify(body),
				signal: AbortSignal.timeout(POST_TIMEOUT_MS),
			});
		} catch {
			// Monitoring must never affect the pi session.
		}
	}

	pi.on("session_start", async (event, ctx) => {
		running = false;
		// /reload replaces the extension runtime of the same session; the tile
		// already reflects its state.
		if (event?.reason === "reload") return;
		await post("SessionStart", ctx, typeof event?.reason === "string" ? { source: event.reason } : {});
	});

	pi.on("before_agent_start", async (event, ctx) => {
		running = true;
		const prompt = typeof event?.prompt === "string" ? event.prompt : "";
		await post("UserPromptSubmit", ctx, prompt ? { prompt_preview: prompt.slice(0, 120) } : {});
	});

	pi.on("agent_start", () => {
		running = true;
	});

	pi.on("ui_prompt_start", async (event, ctx) => {
		if (!running) return;
		const title = typeof event?.title === "string" && event.title ? event.title : undefined;
		await post("Notification", ctx, {
			notification_type: event?.kind === "confirm" ? "permission_prompt" : "elicitation_dialog",
			message: title ?? "Pi is waiting for your answer",
		});
	});

	pi.on("ui_prompt_end", async (_event, ctx) => {
		if (!running) return;
		await post("PostToolUse", ctx);
	});

	// agent_end can be followed by retries, compaction or queued follow-ups;
	// agent_settled means pi will not continue on its own.
	pi.on("agent_settled", async (_event, ctx) => {
		running = false;
		await post("Stop", ctx);
	});

	pi.on("session_shutdown", async (event, ctx) => {
		running = false;
		if (event?.reason === "reload") return;
		await post("SessionEnd", ctx);
	});
}
