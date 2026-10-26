// Open Island plugin for OpenCode (OpenCode 2+ plugin definition).
// Bridges OpenCode events to the Open Island desktop app via Unix socket.
// Install: copy to ~/.config/opencode/plugins/open-island.js
import { connect } from "net";
import { appendFileSync } from "fs";
import { homedir } from "os";
import { execSync } from "child_process";

const DEBUG_LOG = "/tmp/open-island-opencode-debug.log";
function debugLog(msg) {
  try { appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] ${msg}\n`); } catch {}
}

const SOCKET_PATH =
  process.env.OPEN_ISLAND_SOCKET_PATH ||
  `${process.env.HOME || homedir()}/Library/Application Support/OpenIsland/bridge.sock`;

function encodeEnvelope(command) {
  return JSON.stringify({ type: "command", command }) + "\n";
}

function sendToSocket(json) {
  return new Promise((resolve) => {
    try {
      const sock = connect({ path: SOCKET_PATH }, () => {
        sock.end(encodeEnvelope(json));
      });
      let buf = "";
      sock.on("data", (chunk) => { buf += chunk.toString(); });
      sock.on("end", () => { resolve(true); });
      sock.on("error", () => resolve(false));
      sock.setTimeout(3000, () => { sock.destroy(); resolve(false); });
    } catch { resolve(false); }
  });
}

function sendAndWaitResponse(json, timeoutMs = 300000) {
  return new Promise((resolve) => {
    try {
      const sock = connect({ path: SOCKET_PATH }, () => {
        sock.write(encodeEnvelope(json));
      });
      let buf = "";
      sock.on("data", (chunk) => {
        buf += chunk.toString();
        const lines = buf.split("\n").filter(Boolean);
        if (lines.length >= 2) {
          sock.destroy();
          try { resolve(JSON.parse(lines[1])); } catch { resolve(null); }
        }
      });
      sock.on("end", () => {
        const lines = buf.split("\n").filter(Boolean);
        if (lines.length >= 2) {
          try { resolve(JSON.parse(lines[1])); } catch { resolve(null); }
        } else {
          resolve(null);
        }
      });
      sock.on("error", () => resolve(null));
      sock.setTimeout(timeoutMs, () => { sock.destroy(); resolve(null); });
    } catch { resolve(null); }
  });
}

// Terminal environment detection
let detectedTty = null;
try {
  let walkPid = process.pid;
  for (let i = 0; i < 8; i++) {
    const info = execSync(`ps -o tty=,ppid= -p ${walkPid}`, { timeout: 1000 }).toString().trim();
    const parts = info.split(/\s+/);
    const tty = parts[0], ppid = parseInt(parts[1]);
    if (tty && tty !== "??" && tty !== "?") { detectedTty = `/dev/${tty}`; break; }
    if (!ppid || ppid <= 1) break;
    walkPid = ppid;
  }
} catch {}

const ENV_KEYS = [
  "TERM_PROGRAM", "ITERM_SESSION_ID", "TERM_SESSION_ID",
  "TMUX", "TMUX_PANE", "KITTY_WINDOW_ID",
  "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_SOCKET_PATH",
  "ZELLIJ", "ZELLIJ_PANE_ID", "ZELLIJ_SESSION_NAME",
];

function nonEmpty(value) {
  return typeof value === "string" && value.length > 0;
}

function terminalFields() {
  const env = process.env;
  const result = {};
  const bundleID = (env.__CFBundleIdentifier || "").toLowerCase();

  // OpenChamber hosts managed OpenCode as a TTY-less server inside its desktop
  // app. Prefer its identity over any leaked TERM_PROGRAM from the launching
  // shell (same ordering as Claude.app / Conductor on the Swift side).
  if (
    bundleID === "dev.openchamber.desktop"
    || nonEmpty(env.OPENCHAMBER_RUNTIME)
    || nonEmpty(env.OPENCHAMBER_AGENT_TOOL_URL)
    || (env.OPENCODE_CONFIG || "").includes("openchamber")
  ) {
    result.terminal_app = "OpenChamber";
    if (detectedTty) result.terminal_tty = detectedTty;
    return result;
  }

  // T3 Code is a multi-agent cockpit; when it hosts OpenCode, jump-back should
  // activate T3 Code rather than a missing terminal pane.
  if (
    bundleID === "com.t3tools.t3code"
    || bundleID.startsWith("com.t3tools.t3code.")
    || nonEmpty(env.T3CODE_HOME)
    || nonEmpty(env.T3CODE_MODE)
    || nonEmpty(env.T3CODE_WORKTREE_PATH)
  ) {
    result.terminal_app = "T3 Code";
    if (detectedTty) result.terminal_tty = detectedTty;
    return result;
  }

  if (env.ITERM_SESSION_ID) {
    result.terminal_app = "iTerm";
    result.terminal_session_id = env.ITERM_SESSION_ID;
  } else if (env.CMUX_WORKSPACE_ID || env.CMUX_SOCKET_PATH) {
    result.terminal_app = "cmux";
    if (env.CMUX_SURFACE_ID) result.terminal_session_id = env.CMUX_SURFACE_ID;
  } else if (env.ZELLIJ != null) {
    result.terminal_app = "Zellij";
    const paneID = env.ZELLIJ_PANE_ID || "";
    const sessionName = env.ZELLIJ_SESSION_NAME || "";
    if (paneID) result.terminal_session_id = `${paneID}:${sessionName}`;
  } else if (env.GHOSTTY_RESOURCES_DIR || (env.TERM_PROGRAM || "").toLowerCase().includes("ghostty")) {
    result.terminal_app = "Ghostty";
  } else if (env.TERM_PROGRAM === "Apple_Terminal") {
    result.terminal_app = "Terminal";
  } else if (env.TERM_PROGRAM) {
    result.terminal_app = env.TERM_PROGRAM;
  }
  if (detectedTty) result.terminal_tty = detectedTty;
  return result;
}

function makePayload(hookEventName, sessionID, cwd, extra = {}) {
  return {
    type: "processOpenCodeHook",
    openCodeHook: {
      hook_event_name: hookEventName,
      session_id: `opencode-${sessionID}`,
      cwd: cwd || ".",
      ...terminalFields(),
      ...extra,
    },
  };
}

/** OpenCode 2 admits prompts as `{ text }` (and sometimes nested). Bridge expects a string. */
function promptText(value) {
  if (typeof value === "string") return value;
  if (value && typeof value === "object") {
    if (typeof value.text === "string") return value.text;
    if (typeof value.content === "string") return value.content;
    if (typeof value.prompt === "string") return value.prompt;
    if (value.prompt && typeof value.prompt === "object" && typeof value.prompt.text === "string") {
      return value.prompt.text;
    }
  }
  return "";
}

function normalizeQuestionOption(option) {
  if (typeof option === "string") {
    return { label: option };
  }
  if (!option || typeof option !== "object") {
    return null;
  }

  const label = option.label || option.text || option.value || option.name;
  if (!label) return null;

  return {
    label: String(label),
    description: option.description || option.hint || option.detail || "",
    allows_freeform: Boolean(option.allowsFreeform || option.allows_freeform),
  };
}

function normalizeQuestion(question, index) {
  if (!question || typeof question !== "object") {
    return null;
  }

  const questionText = question.question || question.title || question.prompt;
  if (!questionText) return null;

  const options = Array.isArray(question.options)
    ? question.options.map(normalizeQuestionOption).filter(Boolean)
    : [];
  if (options.length === 0) return null;

  return {
    question: String(questionText),
    header: question.header || question.label || `Question ${index + 1}`,
    options,
    multi_select: Boolean(question.multiSelect || question.multi_select),
  };
}

/**
 * Legacy OpenCode 1-style plugin factory. Also used as `server` on the OpenCode 2
 * definition so both loaders can find a callable entry.
 */
async function OpenIslandOpenCodePlugin({ client, serverUrl } = {}) {
  const serverPort = serverUrl ? parseInt(serverUrl.port) || 4096 : 4096;
  const internalFetch = client?._client?.getConfig?.()?.fetch || null;
  const msgRoles = new Map();
  const sessionCwd = new Map();
  const sessions = new Map();

  debugLog(`plugin factory start host=${terminalFields().terminal_app || "unknown"}`);

  function getSession(sid) {
    if (!sessions.has(sid)) sessions.set(sid, { lastAssistantText: "" });
    return sessions.get(sid);
  }

  function mapEvent(ev) {
    const t = ev.type;
    const p = ev.properties || {};

    // session.created — OpenCode 1: properties.info; OpenCode 2 stream: sessionID
    if (t === "session.created") {
      const info = p.info || p;
      const id = info.id || info.sessionID || p.sessionID;
      if (!id) return null;
      const cwd = info.directory || p.directory || sessionCwd.get(id) || "";
      sessionCwd.set(id, cwd);
      return makePayload("SessionStart", id, cwd);
    }

    // session.deleted
    if (t === "session.deleted") {
      const info = p.info || p;
      const id = info.id || info.sessionID || p.sessionID;
      if (!id) return null;
      const cwd = sessionCwd.get(id);
      sessions.delete(id);
      sessionCwd.delete(id);
      return makePayload("SessionEnd", id, cwd);
    }

    // session.updated (archived)
    if (t === "session.updated" && p.info) {
      if (p.info.directory) sessionCwd.set(p.info.id, p.info.directory);
      if (p.info.time?.archived) {
        const cwd = sessionCwd.get(p.info.id);
        sessions.delete(p.info.id);
        sessionCwd.delete(p.info.id);
        return makePayload("SessionEnd", p.info.id, cwd);
      }
      return null;
    }

    // session.status → idle = Stop; busy keeps the island card alive
    if (t === "session.status" && p.sessionID) {
      if (p.status?.type === "idle" || p.error) {
        const s = getSession(p.sessionID);
        return makePayload("Stop", p.sessionID, sessionCwd.get(p.sessionID), {
          last_assistant_message: s.lastAssistantText || undefined,
        });
      }
      if (p.status?.type === "busy") {
        return makePayload("UserPromptSubmit", p.sessionID, sessionCwd.get(p.sessionID) || ".", {
          prompt: getSession(p.sessionID).lastPrompt || "OpenCode is working…",
        });
      }
      return null;
    }

    // OpenCode 2 tool stream (session.tool.*) — map to Pre/PostToolUse
    if (t === "session.tool.called" && p.sessionID) {
      const toolName = (p.name || p.tool || p.input?.name || "Tool");
      const pretty = String(toolName).charAt(0).toUpperCase() + String(toolName).slice(1);
      return makePayload("PreToolUse", p.sessionID, sessionCwd.get(p.sessionID) || ".", {
        tool_name: pretty,
        tool_input: typeof p.input === "string" ? p.input : JSON.stringify(p.input || {}).slice(0, 200),
      });
    }
    if ((t === "session.tool.success" || t === "session.tool.error" || t === "session.tool.failed") && p.sessionID) {
      const toolName = (p.name || p.tool || "Tool");
      const pretty = String(toolName).charAt(0).toUpperCase() + String(toolName).slice(1);
      return makePayload("PostToolUse", p.sessionID, sessionCwd.get(p.sessionID) || ".", {
        tool_name: pretty,
      });
    }

    // message.updated — track role for message parts
    if (t === "message.updated" && p.info?.id && p.info?.sessionID) {
      msgRoles.set(p.info.id, { role: p.info.role, sessionID: p.info.sessionID });
      if (msgRoles.size > 200) { msgRoles.delete(msgRoles.keys().next().value); }
      return null;
    }

    // message.part.updated — text
    if (t === "message.part.updated" && p.part?.type === "text" && p.part?.messageID) {
      const meta = msgRoles.get(p.part.messageID);
      if (!meta) return null;
      const text = p.part.text || "";
      if (meta.role === "user" && text) {
        return makePayload("UserPromptSubmit", meta.sessionID, sessionCwd.get(meta.sessionID), {
          prompt: text,
        });
      }
      if (meta.role === "assistant" && text) {
        getSession(meta.sessionID).lastAssistantText = text;
      }
      return null;
    }

    // OpenCode 2 text stream fallbacks when message.updated metadata is missing
    if (t === "session.next.text.ended" || t === "session.text.ended") {
      const sid = p.sessionID;
      const text = p.text || p.content || "";
      if (sid && text) getSession(sid).lastAssistantText = text;
      return null;
    }

    // message.part.updated — tool
    if (t === "message.part.updated" && p.part?.type === "tool" && p.part?.sessionID) {
      const st = p.part.state?.status;
      const cwd = sessionCwd.get(p.part.sessionID);
      const toolName = (p.part.tool || "").charAt(0).toUpperCase() + (p.part.tool || "").slice(1);
      if (st === "running" || st === "pending") {
        return makePayload("PreToolUse", p.part.sessionID, cwd, {
          tool_name: toolName,
          tool_input: typeof p.part.state?.input === "string"
            ? p.part.state.input
            : JSON.stringify(p.part.state?.input || {}).slice(0, 200),
        });
      }
      if (st === "completed" || st === "error") {
        return makePayload("PostToolUse", p.part.sessionID, cwd, {
          tool_name: toolName,
        });
      }
      return null;
    }

    // permission.asked
    if (t === "permission.asked" && p.id && p.sessionID) {
      const toolName = (p.permission || p.action || "").charAt(0).toUpperCase()
        + (p.permission || p.action || "").slice(1);
      const patterns = p.patterns || p.resources || [];
      const toolInput = { patterns, metadata: p.metadata };
      if ((p.permission === "bash" || p.action === "bash") && patterns.length > 0) {
        toolInput.command = patterns.join(" && ");
      }
      if ((p.permission === "edit" || p.permission === "write"
          || p.action === "edit" || p.action === "write") && patterns.length > 0) {
        toolInput.file_path = patterns[0];
      }
      return makePayload("PermissionRequest", p.sessionID, sessionCwd.get(p.sessionID), {
        tool_name: toolName,
        tool_input: JSON.stringify(toolInput).slice(0, 200),
        permission_id: p.id,
        permission_title: `Allow ${toolName}`,
        permission_description: patterns.length > 0
          ? `OpenCode wants to run ${toolName}: ${patterns[0]}`
          : `OpenCode wants to run ${toolName}`,
        _opencode_request_id: p.id,
      });
    }

    // permission.replied
    if (t === "permission.replied" && p.sessionID) {
      return makePayload("PostToolUse", p.sessionID, sessionCwd.get(p.sessionID));
    }

    // question.asked
    if (t === "question.asked" && p.id && p.sessionID) {
      const questions = Array.isArray(p.questions)
        ? p.questions.map(normalizeQuestion).filter(Boolean)
        : [];
      return makePayload("QuestionAsked", p.sessionID, sessionCwd.get(p.sessionID), {
        question_id: p.id,
        question_text: (p.questions || []).map(q => q.question).join("; ") || "OpenCode has a question",
        questions,
        _opencode_request_id: p.id,
      });
    }

    // question.replied / question.rejected
    if ((t === "question.replied" || t === "question.rejected") && p.sessionID) {
      return makePayload("PostToolUse", p.sessionID, sessionCwd.get(p.sessionID));
    }

    // session.next.prompt.admitted — user prompt on OpenCode 2
    if (t === "session.next.prompt.admitted" && p.sessionID) {
      const text = promptText(p.prompt) || promptText(p.text) || promptText(p.content);
      if (text) {
        getSession(p.sessionID).lastPrompt = text;
        return makePayload("UserPromptSubmit", p.sessionID, sessionCwd.get(p.sessionID) || p.directory || ".", {
          prompt: text,
        });
      }
    }

    return null;
  }

  return {
    "event": async ({ event }) => {
      try {
        debugLog(`EVENT: ${event.type} | props: ${JSON.stringify(event.properties || {}).slice(0, 300)}`);
        const mapped = mapEvent(event);
        if (mapped) {
          debugLog(`MAPPED: ${mapped.openCodeHook.hook_event_name} sid=${mapped.openCodeHook.session_id} app=${mapped.openCodeHook.terminal_app}`);
        }
        if (!mapped) return;

        // Permission request — hold connection for approval
        if (mapped.openCodeHook.hook_event_name === "PermissionRequest" && internalFetch) {
          const requestId = mapped.openCodeHook._opencode_request_id;
          sendAndWaitResponse(mapped).then(async (response) => {
            if (!response) return;
            const directive = response?.response?.directive;
            if (!directive) return;
            const reply = directive.type === "allow" ? "once" : "reject";
            const message = directive.type === "deny" ? directive.reason : undefined;
            try {
              await internalFetch(new Request(`http://localhost:${serverPort}/permission/${requestId}/reply`, {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ reply, message }),
              }));
            } catch {}
          });
          return;
        }

        // Question — hold connection for answer
        if (mapped.openCodeHook.hook_event_name === "QuestionAsked" && internalFetch) {
          const requestId = mapped.openCodeHook._opencode_request_id;
          sendAndWaitResponse(mapped).then(async (response) => {
            if (!response) return;
            const directive = response?.response?.directive;
            if (!directive) return;
            if (directive.type === "answer") {
              try {
                await internalFetch(new Request(`http://localhost:${serverPort}/question/${requestId}/reply`, {
                  method: "POST",
                  headers: { "Content-Type": "application/json" },
                  body: JSON.stringify({ answers: [[directive.text]] }),
                }));
              } catch {}
            }
          });
          return;
        }

        // Regular events — fire and forget
        const ok = await sendToSocket(mapped);
        debugLog(`SEND ${ok ? "ok" : "fail"} ${mapped.openCodeHook.hook_event_name} sid=${mapped.openCodeHook.session_id}`);
      } catch (error) {
        debugLog(`event handler error: ${error?.message || error}`);
        // Fail open: if Open Island is unavailable, don't block OpenCode
      }
    },

    "shell.env": async (input, output) => {
      output.env.OPEN_ISLAND_ACTIVE = "1";
      for (const v of ENV_KEYS) {
        if (process.env[v]) output.env["_OI_" + v] = process.env[v];
      }
    },
  };
}

/**
 * OpenCode 2 setup entry: subscribe to the event bus and forward into the
 * legacy hooks.event mapper (same adaptation pattern as orca-opencode-status).
 */
async function setupOpenIslandOpenCode2(ctx) {
  const noop = async () => {};
  try {
    if (!ctx || typeof ctx.event?.subscribe !== "function") {
      debugLog("setup: missing ctx.event.subscribe — skip");
      return noop;
    }

    debugLog(`setup: start host=${terminalFields().terminal_app || "unknown"}`);
    const hooks = await OpenIslandOpenCodePlugin({
      client: ctx.client || ctx,
      serverUrl: ctx.serverUrl,
    });
    if (!hooks || typeof hooks.event !== "function") return noop;

    const controller = new AbortController();
    let promptRegistration = null;
    if (typeof ctx.session?.hook === "function") {
      try {
        promptRegistration = await ctx.session.hook("prompt", async (properties) => {
          await hooks.event({
            event: { type: "session.next.prompt.admitted", properties },
          });
        });
      } catch (error) {
        debugLog(`setup: prompt hook failed: ${error?.message || error}`);
      }
    }

    const consume = async () => {
      for await (const input of ctx.event.subscribe({ signal: controller.signal })) {
        if (controller.signal.aborted) break;
        let type = input.type;
        let properties = input.data ?? input.properties ?? {};

        if (type === "session.created") {
          properties = {
            info: {
              id: properties.sessionID || properties.id,
              directory: properties.directory,
              ...properties,
            },
          };
        } else if (type === "session.deleted") {
          properties = {
            info: {
              id: properties.sessionID || properties.id,
              ...properties,
            },
          };
        } else if (type === "session.execution.started") {
          type = "session.status";
          properties = { ...properties, sessionID: properties.sessionID, status: { type: "busy" } };
        } else if (
          type === "session.execution.succeeded"
          || type === "session.execution.failed"
          || type === "session.execution.interrupted"
        ) {
          type = "session.status";
          properties = { ...properties, sessionID: properties.sessionID, status: { type: "idle" } };
        } else if (type === "permission.v2.asked" || type === "permission.asked") {
          type = "permission.asked";
          properties = {
            ...properties,
            id: properties.id,
            permission: properties.action || properties.permission,
            patterns: properties.resources || properties.patterns,
          };
        } else if (type === "form.created") {
          const form = properties.form || properties;
          if (!form) continue;
          const fields = Array.isArray(form.fields) ? form.fields : [];
          type = "question.asked";
          properties = {
            ...form,
            id: form.id || properties.id,
            sessionID: form.sessionID || properties.sessionID,
            questions: fields.map((field) => ({
              header: field.title || form.title,
              question: field.description || field.title || form.title,
              options: (field.options || []).map((option) => ({
                label: option.label || option.value,
                description: option.description || "",
              })),
              multiple: field.type === "multiselect",
            })),
          };
        } else if (type === "form.replied" || type === "form.cancelled") {
          type = type === "form.replied" ? "question.replied" : "question.rejected";
          properties = { ...properties, requestID: properties.id, sessionID: properties.sessionID };
        } else if (
          type === "session.text.started"
          || type === "session.text.delta"
          || type === "session.text.ended"
        ) {
          type = type.replace("session.", "session.next.");
        }

        await hooks.event({ event: { type, properties } });
      }
    };

    const consuming = consume().catch((error) => {
      if (!controller.signal.aborted) {
        debugLog(`setup: event subscription failed: ${error?.message || error}`);
      }
    });

    if (typeof hooks["shell.env"] === "function" && typeof ctx.shell?.hook === "function") {
      try {
        await ctx.shell.hook("env", async (input, output) => {
          await hooks["shell.env"](input, output);
        });
      } catch {}
    }

    debugLog("setup: subscribed");
    return async () => {
      try {
        controller.abort();
        await promptRegistration?.dispose?.();
        await consuming;
      } catch {}
    };
  } catch (error) {
    debugLog(`setup: failed ${error?.message || error}`);
    return noop;
  }
}

// OpenCode 2 requires a default object with id + setup (and optionally server).
export default {
  id: "open-island",
  server: OpenIslandOpenCodePlugin,
  setup: setupOpenIslandOpenCode2,
};
