// gpu-status — KM's hello-world pi extension.
//
// Registers a `/gpu-status` command that reads KM's state file (~/.km/state.json)
// and pings the served endpoint, so pi can tell you — from inside a session —
// whether the box the harness is wired to is actually alive.
//
// This is the perfect first extension: small, real, and about *your* box. Read
// it, change the message, `/reload`, and you have written your first pi
// extension. Then package it (`pi install git:...`) — see pi's packages.md.
//
// Docs: pi's packages/coding-agent/docs/extensions.md is the authority on this API.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

interface KmState {
  served?: boolean;
  base_url?: string;
  model?: string;
  model_key?: string;
  local_port?: number;
  tunnel_pid?: number;
}

function readState(): KmState | null {
  const path = join(process.env.KM_HOME ?? join(homedir(), ".km"), "state.json");
  try {
    return JSON.parse(readFileSync(path, "utf8")) as KmState;
  } catch {
    return null;
  }
}

// true if the process is alive (signal 0 does not kill, only tests)
function pidAlive(pid?: number): boolean {
  if (!pid || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function endpointUp(baseUrl?: string): Promise<boolean> {
  if (!baseUrl) return false;
  try {
    const ctl = AbortSignal.timeout(5000);
    const res = await fetch(`${baseUrl.replace(/\/$/, "")}/models`, { signal: ctl });
    return res.ok;
  } catch {
    return false;
  }
}

export default function (pi: ExtensionAPI) {
  pi.registerCommand("gpu-status", {
    description: "Is the KM GPU box live? Show the served model, tunnel, and endpoint.",
    handler: async (_args, ctx) => {
      const st = readState();
      if (!st || !st.served) {
        ctx.ui.notify(
          "KM: no GPU box attached (harness-only / DEMO). Attach one with:\n" +
            '  bash ~/.km/setup.sh --gpu "<ssh… -L port:host:port>" --model glm',
          "warning",
        );
        return;
      }

      const tunnel = pidAlive(st.tunnel_pid);
      const live = await endpointUp(st.base_url);

      const lines = [
        `KM box: ${st.model ?? "?"}  (${st.model_key ?? "?"})`,
        `  endpoint: ${st.base_url ?? "?"}`,
        `  tunnel:   ${tunnel ? `live (pid ${st.tunnel_pid})` : "DOWN — run: km reconnect"}`,
        `  serving:  ${live ? "yes — the endpoint answers" : "not answering (loading, or box gone)"}`,
      ];

      const level = tunnel && live ? "info" : tunnel ? "warning" : "error";
      ctx.ui.notify(lines.join("\n"), level);
    },
  });
}
