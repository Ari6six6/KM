// herald — KM's orchestration layer: three hard gears and a live path to masks.
//
// This is a thin layer *on top of* pi. It adds no tools to the base surface and
// changes nothing about pi's four core tools (read, write, edit, bash) or its
// agent loop. All it does is:
//
//   1. hold a gear   — drive / brake / empty, top-priority, interrupts anything
//   2. wear a mask   — inject a persona (and its tools) for the next turn(s)
//   3. grow a mask   — let the model write a new one, live, while the box runs
//   4. summon the agent — hand one task to a separate pi that reads the
//      Operator's own file and takes everything from it
//   5. brake         — stop, write a checkpoint, go idle; resume from it on drive
//
// State lives in $KM_HOME/herald.json; masks live in $KM_HOME/masks/<name>/ as
// ordinary pi skills, so pi discovers them itself (see resources_discover).
// Brake's checkpoints are plain markdown under $KM_KARTE/checkpoints/.
//
// Docs: pi's packages/coding-agent/docs/extensions.md is the authority on this API.

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

// ---------------------------------------------------------------- paths + state

const KM_HOME = process.env.KM_HOME ?? join(homedir(), ".km");
const MASKS_DIR = join(KM_HOME, "masks");
const STATE_FILE = join(KM_HOME, "herald.json");
const DEFAULT_SEAT = "xai/grok-4.5";

// The Operator's map (German: Karte) and the single file inside it that the
// summoned agent reads before it does anything else. Both are the Operator's:
// we create them once and never write over what he has put there.
const KARTE_DIR = process.env.KM_KARTE ?? join(homedir(), "karte");
const CALLCENTER = process.env.KM_CALLCENTER ?? join(KARTE_DIR, "callcenter.md");
const AGENT_NAME = process.env.KM_AGENT ?? "smith";
const PI_DIR = process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent");

type Gear = "drive" | "brake" | "empty";
const GEARS: Gear[] = ["drive", "brake", "empty"];
const isGear = (s: string): s is Gear => (GEARS as string[]).includes(s);

// Gear names that no longer exist, and what typing one now means. Typing is a
// live intent: the Operator wants everything to stop, so it brakes.
const RETIRED: Record<string, Gear> = { debate: "brake" };
const toGear = (s: unknown): Gear | null => {
  if (typeof s !== "string") return null;
  const v = s.trim().toLowerCase();
  return isGear(v) ? v : (RETIRED[v] ?? null);
};

// A retired gear *found in the state file* is a different thing entirely, and
// treating it like a live shift was a mistake worth naming: nothing was running
// to interrupt, no checkpoint exists behind it, and the gear it braked into is
// mute — so an upgraded box came up silent and looked broken. A stale gear is
// upgrade debris. It becomes Drive, and the Operator is told what happened.
let staleGear: string | null = null;

interface HeraldState {
  gear: Gear;
  mask: string | null;
  seat: string;
}

function readState(): HeraldState {
  try {
    const raw = JSON.parse(readFileSync(STATE_FILE, "utf8")) as Partial<HeraldState>;
    const named = typeof raw.gear === "string" ? raw.gear.trim().toLowerCase() : "";
    if (named && !isGear(named)) staleGear = named;
    return {
      // Anything this version does not know — a retired gear, a typo, a gear from
      // a future version — comes up in Drive. The box is usable first.
      gear: isGear(named) ? named : "drive",
      mask: typeof raw.mask === "string" && raw.mask ? raw.mask : null,
      seat: typeof raw.seat === "string" && raw.seat ? raw.seat : DEFAULT_SEAT,
    };
  } catch {
    return { gear: "drive", mask: null, seat: DEFAULT_SEAT };
  }
}

// The launcher (bin/herald) reads this file too, with sed — keep it flat, one
// field per line, exactly like KM's own state.json.
function writeState(s: HeraldState): void {
  mkdirSync(KM_HOME, { recursive: true });
  writeFileSync(
    STATE_FILE,
    `{\n  "gear": "${s.gear}",\n  "mask": ${s.mask ? `"${s.mask}"` : "null"},\n  "seat": "${s.seat}"\n}\n`,
  );
}

// ---------------------------------------------------------------------- masks

interface Mask {
  name: string;
  description: string;
  persona: string;
  tools?: string[];
  toolsFile?: string;
  dir: string;
}

// Enough YAML for a skill's frontmatter: top-level `key: value` plus one level of
// indented keys under a bare `key:` (that is all the Agent Skills spec asks for).
function parseFrontmatter(src: string): { fm: Record<string, unknown>; body: string } {
  if (!src.startsWith("---")) return { fm: {}, body: src };
  const end = src.indexOf("\n---", 3);
  if (end === -1) return { fm: {}, body: src };
  const head = src.slice(src.indexOf("\n") + 1, end);
  const body = src.slice(end + 4).replace(/^\r?\n/, "");

  const fm: Record<string, unknown> = {};
  let section: string | null = null;
  for (const line of head.split(/\r?\n/)) {
    if (!line.trim() || line.trim().startsWith("#")) continue;
    const nested = /^\s/.test(line);
    const m = line.trim().match(/^([A-Za-z0-9_-]+)\s*:\s*(.*)$/);
    if (!m) continue;
    const key = m[1];
    const value = m[2].trim().replace(/^["']|["']$/g, "");
    if (nested && section) {
      (fm[section] as Record<string, string>)[key] = value;
      continue;
    }
    if (!value) {
      section = key;
      fm[key] = {};
      continue;
    }
    section = null;
    fm[key] = value;
  }
  return { fm, body: body.trim() };
}

// pi's skill name rules (docs/skills.md): 1-64 chars, lowercase/digits/hyphens,
// no leading, trailing, or doubled hyphen.
const NAME_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const validName = (n: string): boolean => n.length >= 1 && n.length <= 64 && NAME_RE.test(n);

function readMask(name: string): Mask | null {
  const dir = join(MASKS_DIR, name);
  const file = join(dir, "SKILL.md");
  if (!validName(name) || !existsSync(file)) return null;

  const { fm, body } = parseFrontmatter(readFileSync(file, "utf8"));
  const meta = (fm.metadata ?? {}) as Record<string, string>;
  const toolsFile = join(dir, "tools.ts");
  const declared = typeof meta.tools === "string" ? meta.tools.split(/[,\s]+/).filter(Boolean) : undefined;

  return {
    name: typeof fm.name === "string" && fm.name ? fm.name : name,
    description: typeof fm.description === "string" ? fm.description : "",
    persona: body,
    tools: declared && declared.length > 0 ? declared : undefined,
    toolsFile: existsSync(toolsFile) ? toolsFile : undefined,
    dir,
  };
}

function listMasks(): string[] {
  if (!existsSync(MASKS_DIR)) return [];
  return readdirSync(MASKS_DIR, { withFileTypes: true })
    .filter((e) => e.isDirectory() && existsSync(join(MASKS_DIR, e.name, "SKILL.md")))
    .map((e) => e.name)
    .sort();
}

const oneLine = (s: string): string => s.replace(/\s+/g, " ").trim();

// ------------------------------------------------------------------- the agent
//
// One named agent, summoned on demand. It is a separate `pi` with the four core
// tools and a three-line brief: know your name, read the Operator's file, do the
// task. Everything it needs to know about itself and the work lives in that
// file, written by hand. There is no generated persona here and there must never
// be one — growing the agent means the Operator editing callcenter.md.

// Make the map directory, and the file if it is missing. A file that already
// exists is left exactly as it is: what is in there is the Operator's.
function ensureCallcenter(): boolean {
  mkdirSync(dirname(CALLCENTER), { recursive: true });
  if (existsSync(CALLCENTER)) return false;
  writeFileSync(
    CALLCENTER,
    [
      "# callcenter",
      "",
      `The Operator writes here. \`${AGENT_NAME}\` reads this file first on every summon:`,
      "who it is for this job, the context it needs, and the work in front of it.",
      "Nothing else configures the agent.",
      "",
    ].join("\n"),
  );
  return true;
}

// An older improvised sub-agent extension, still loaded, fires on Drive next to
// agent_summon — two paths summoning two different things. `km --herald` parks
// it; by the time we run here pi has already loaded it, so all we can honestly
// do is say so, and say exactly what fixes it.
function improvisedSubagents(): string[] {
  const dir = join(PI_DIR, "extensions");
  if (!existsSync(dir)) return [];
  try {
    return readdirSync(dir, { withFileTypes: true })
      .filter((e) => e.isDirectory() && /sub-?agent/i.test(e.name))
      .map((e) => e.name);
  } catch {
    return [];
  }
}

// Which model the agent runs on. KM_AGENT_MODEL wins; then a pin in
// ~/.km/agent-model; then pi's own default. The pin is a file on purpose — env
// is frozen when the seat starts, and the Operator has to be able to repoint the
// agent on a live box without restarting the Herald.
const AGENT_MODEL_PIN = join(KM_HOME, "agent-model");

function agentModel(): { value: string; source: string } {
  const env = (process.env.KM_AGENT_MODEL ?? "").trim();
  if (env) return { value: env, source: "KM_AGENT_MODEL" };
  try {
    if (existsSync(AGENT_MODEL_PIN)) {
      const pinned = readFileSync(AGENT_MODEL_PIN, "utf8").trim();
      if (pinned) return { value: pinned, source: AGENT_MODEL_PIN };
    }
  } catch {
    /* unreadable pin — pi's default is the honest answer */
  }
  return { value: "", source: "pi's default" };
}

function agentBrief(): string {
  return [
    `You are ${AGENT_NAME}.`,
    `Before anything else, read ${CALLCENTER}. The Operator maintains that file by hand and it is the only source of truth about your role and the current work.`,
    "Then carry out the task you were given and report back plainly.",
  ].join("\n");
}

// pi launched us, so pi is reachable — through the script we are running under
// when there is one (a bun-compiled pi has no such script), else off the PATH,
// which setup.sh guarantees.
function piInvocation(args: string[]): { command: string; args: string[] } {
  const script = process.argv[1];
  if (script && !script.startsWith("/$bunfs/") && existsSync(script))
    return { command: process.execPath, args: [script, ...args] };
  return { command: "pi", args };
}

interface SummonResult {
  code: number;
  out: string;
  err: string;
}

function summon(task: string, signal?: AbortSignal): Promise<SummonResult> {
  const args = [
    "-p",
    "--no-session",
    // The four core tools, and nothing but them.
    "--tools",
    "read,write,edit,bash",
    // No extensions: the cockpit must not load in the child, or the gear it
    // inherits would switch those four tools straight back off.
    "--no-extensions",
    // No AGENTS.md, no CLAUDE.md. The call-center file is the source of truth,
    // and it can only be that if nothing else is loaded behind it.
    "--no-context-files",
    "--append-system-prompt",
    agentBrief(),
  ];
  // No model by default: the agent runs on pi's default, which on a provisioned
  // box is the model you already pay for. A "provider/model" pin is split into
  // the two flags pi wants; a bare name is passed as-is.
  const { value: model } = agentModel();
  if (model) {
    if (model.includes("/")) {
      const [prov, ...rest] = model.split("/");
      const mid = rest.join("/");
      if (prov) args.push("--provider", prov);
      args.push("--model", mid || model);
    } else {
      args.push("--model", model);
    }
  }
  args.push(task);

  const { command, args: argv } = piInvocation(args);
  return new Promise<SummonResult>((resolve) => {
    // --no-extensions already keeps the cockpit out of this child; the env flag
    // is the backstop that reaches further, so a `pi` the agent itself starts
    // from bash also comes up bare instead of inheriting a gear.
    //
    // detached puts the agent in its own process group. That is what makes the
    // gear hard: signalling -pid takes down the whole tree, including whatever
    // the agent started from bash. Signal the pi alone and its children live on,
    // holding these pipes open, and an abort waits for work nobody wants.
    const child = spawn(command, argv, {
      env: { ...process.env, KM_HERALD_CHILD: "1" },
      stdio: ["ignore", "pipe", "pipe"],
      detached: true,
    });
    let out = "";
    let err = "";
    child.stdout.on("data", (d: Buffer) => { out += d.toString(); });
    child.stderr.on("data", (d: Buffer) => { err += d.toString(); });
    child.on("error", (e: Error) => resolve({ code: 1, out, err: `${err}${e.message}` }));
    // A killed agent exits on a signal with no code. Say so — an interrupted
    // summon reporting a clean run with no output is the kind of quiet lie this
    // box does not tell.
    child.on("close", (code: number | null, sig: NodeJS.Signals | null) =>
      resolve({
        code: code ?? (sig ? 143 : 0),
        out,
        err: sig ? `${err}\nsummon stopped (${sig}).` : err,
      }),
    );

    if (signal) {
      const signalTree = (sig: NodeJS.Signals): void => {
        const pid = child.pid;
        if (pid === undefined) return;
        try {
          process.kill(-pid, sig);
        } catch {
          try { child.kill(sig); } catch { /* already gone */ }
        }
      };
      const kill = (): void => {
        signalTree("SIGTERM");
        setTimeout(() => {
          signalTree("SIGKILL");
          // Anything still holding the pipes open after a group SIGKILL is not
          // something to keep the Operator waiting on. Resolving twice is a
          // no-op; the close handler wins whenever it gets there first.
          resolve({ code: 143, out, err: `${err}\nsummon aborted.` });
        }, 2000).unref();
      };
      if (signal.aborted) kill();
      else signal.addEventListener("abort", kill, { once: true });
    }
  });
}

// -------------------------------------------------------------- checkpoints
//
// Brake is the stop gear, and a stop is only worth anything if the work can be
// picked up again. So the shift itself writes the checkpoint — from what this
// extension already watched go past, not from anything the model has to think
// up. That is the whole point: braking costs a file write and zero tokens, and
// it still works when the model is mid-sentence, looping, or wrong.
//
// The file is plain markdown in the Operator's own map, next to callcenter.md,
// so the next reader — the Herald after a /drive, a summoned agent, a human with
// `cat` — needs nothing to read it.

const CHECKPOINTS = process.env.KM_CHECKPOINTS ?? join(KARTE_DIR, "checkpoints");

// A checkpoint nobody has resumed from yet says so in its own second line. That
// is the marker, and it lives in the file on purpose: it survives a restart, a
// new seat, and a launcher that rewrites herald.json behind us.
const OPEN = "status: open";
const RESUME_LIMIT = 6000;

// Names are ISO timestamps, so lexical order is chronological — the last name is
// the newest checkpoint, with no stat() and no clock to trust.
function checkpointNames(): string[] {
  if (!existsSync(CHECKPOINTS)) return [];
  try {
    return readdirSync(CHECKPOINTS).filter((f) => f.endsWith(".md")).sort();
  } catch {
    return [];
  }
}

function latestCheckpoint(): string | null {
  const names = checkpointNames();
  return names.length > 0 ? join(CHECKPOINTS, names[names.length - 1]) : null;
}

function openCheckpoint(): { path: string; text: string } | null {
  for (const name of checkpointNames().reverse()) {
    const path = join(CHECKPOINTS, name);
    try {
      const text = readFileSync(path, "utf8");
      if (text.includes(OPEN)) return { path, text };
    } catch {
      /* unreadable — the next one down is still a checkpoint */
    }
  }
  return null;
}

function closeCheckpoint(path: string, text: string): void {
  try {
    writeFileSync(path, text.replace(OPEN, `status: resumed ${new Date().toISOString()}`));
  } catch {
    /* best effort: a checkpoint that cannot be marked is still readable */
  }
}

// One tool call as the checkpoint records it. pi's event shape is not ours to
// assume, so read the names it plausibly uses and fall back to something true
// rather than to a guess dressed up as a fact.
interface Call {
  tool: string;
  target?: string;
}

const firstString = (...vals: unknown[]): string | undefined =>
  vals.find((v) => typeof v === "string" && v.trim() !== "") as string | undefined;

function readCall(event: unknown): Call {
  const e = (event ?? {}) as Record<string, unknown>;
  const raw = [e.arguments, e.args, e.params, e.input, e.parameters].find(
    (v) => v !== null && typeof v === "object",
  ) as Record<string, unknown> | undefined;
  const args = raw ?? {};
  const target = firstString(args.file_path, args.filePath, args.path, args.command, args.task, args.name);
  return {
    tool: firstString(e.toolName, e.tool, e.name) ?? "tool",
    target: target ? oneLine(target).slice(0, 160) : undefined,
  };
}

// Which calls left something behind. Used for the "what exists now" section — a
// resuming agent needs the paths before it needs the narrative.
const TOUCHES = /^(write|edit|create|patch|apply|multi_?edit|notebook_?edit)/i;

// A checkpoint is a handover, not a log: keep the tail and drop the rest.
function remember<T>(list: T[], item: T, keep: number): void {
  list.push(item);
  if (list.length > keep) list.splice(0, list.length - keep);
}

// The checkpoint itself. Everything in it is something the cockpit watched go
// past; nothing in it is inferred. `interrupted` says whether a turn was still
// running when the brake landed, which is the difference between "this is done"
// and "this may be half-done" for the last line of the trail.
function writeCheckpoint(
  state: HeraldState,
  from: Gear,
  asked: string[],
  calls: Call[],
  interrupted: boolean,
): string | null {
  const now = new Date();
  const path = join(CHECKPOINTS, `${now.toISOString().replace(/[:.]/g, "-")}.md`);
  const touched = [...new Set(calls.filter((c) => TOUCHES.test(c.tool) && c.target).map((c) => c.target as string))];
  const line = (c: Call): string => `${c.tool}${c.target ? ` — ${c.target}` : ""}`;

  const body = [
    `# checkpoint — ${now.toISOString()}`,
    "",
    OPEN,
    `gear: brake (from ${from})`,
    `seat: ${state.seat}`,
    `mask: ${state.mask ?? "none"}`,
    `turn: ${interrupted ? "interrupted mid-flight by the brake" : "idle when the brake landed"}`,
    "",
    "## In progress",
    "",
    asked.length > 0 ? asked[asked.length - 1].trim() : "(nothing was asked in this session)",
    "",
  ];

  if (asked.length > 1) {
    body.push("## Asked earlier, same session", "", ...asked.slice(0, -1).map((a) => `- ${oneLine(a).slice(0, 200)}`), "");
  }

  body.push(
    "## Trail — what actually ran, oldest first",
    "",
    ...(calls.length > 0
      ? calls.map((c, i) =>
          `- ${line(c)}${interrupted && i === calls.length - 1 ? "   ← last call before the brake; it may not have finished" : ""}`,
        )
      : ["- (no tool calls this session)"]),
    "",
    "## Files touched",
    "",
    ...(touched.length > 0 ? touched.map((t) => `- ${t}`) : ["- (none recorded)"]),
    "",
    "## Resume",
    "",
    "Shift back with `drive`. The Herald is handed the newest open checkpoint on its",
    "next turn, marks it resumed, and carries on from here instead of starting over.",
    "",
  );

  try {
    mkdirSync(CHECKPOINTS, { recursive: true });
    writeFileSync(path, body.join("\n"));
    return path;
  } catch {
    return null;
  }
}

// ------------------------------------------------------- the prompt the gear adds

function gearContract(gear: Gear): string {
  const head = "# Herald gear (KM orchestration layer)\n\nThe Operator sets the gear. You never set it yourself; you report it.";
  if (gear === "drive")
    return `${head}\n\nCurrent gear: **DRIVE**. You act. You decide, you run skills, and you may switch masks (mask_wear) or grow a new one (mask_create) when a real need shows up in this session — not speculatively.`;
  if (gear === "brake") {
    const cp = latestCheckpoint();
    return `${head}\n\nCurrent gear: **BRAKE**. Stop. The checkpoint is already written${cp ? ` (${cp})` : ""} — you do not write it and you do not add to it. No tools, no work, no long reasoning. If you are given a turn at all, say in one line that the Herald is braked, and stop.`;
  }
  return `${head}\n\nCurrent gear: **EMPTY**. Freewheel. Nothing is driving and nothing is stopped mid-job. If you are somehow given a turn, say only that the Herald is in Empty.`;
}

function resumeContract(path: string, text: string): string {
  return [
    "# Resume from checkpoint",
    `The Herald was braked mid-job. This is where the work stopped (${path}). Continue from it — do not start the job again from the top, and do not redo what the trail says is already done. Say in one line what you are resuming, then act.`,
    text.slice(0, RESUME_LIMIT).trim(),
  ].join("\n\n");
}

function maskContract(mask: Mask): string {
  const parts = [
    `# Active mask: ${mask.name}`,
    "You are wearing this mask. It is who you are for this turn and the turns after it,\nuntil the Operator or you switch it. Only one mask is ever worn at a time.",
  ];
  if (mask.description) parts.push(`_${oneLine(mask.description)}_`);
  parts.push(mask.persona);
  return parts.join("\n\n");
}

// ------------------------------------------------------------------- extension

// The Herald's own controls. They survive every mask allowlist.
const HERALD_TOOLS = ["mask_create", "mask_wear"];

export default function (pi: ExtensionAPI) {
  // Inside a summoned agent (or any pi it starts itself), stand down: no gear
  // switches its tools off, no mask speaks for it, and it summons nothing.
  if (process.env.KM_HERALD_CHILD === "1") return;

  let state = readState();
  // pi's tool surface as the Operator launched it — the four core tools plus
  // whatever else was configured. We restore exactly this; we never edit it.
  let baseTools: string[] = [];
  // tool names each mask's tools.ts contributed, and which ones we have imported
  const maskTools = new Map<string, string[]>();
  const loaded = new Set<string>();

  // What the brake will write down, collected as the session runs so that the
  // shift itself needs no thinking: what the Operator asked for, and what went
  // past on the way. Both are capped — a checkpoint is a handover, not a log.
  const asked: string[] = [];
  const calls: Call[] = [];

  const gearLabel = (g: Gear): string =>
    g === "drive" ? "DRIVE ▶" : g === "brake" ? "BRAKE ■" : "EMPTY ○";

  function paint(ctx: ExtensionContext): void {
    if (!ctx.hasUI) return;
    ctx.ui.setStatus("herald", `${gearLabel(state.gear)}${state.mask ? ` · ${state.mask}` : ""}`);
  }

  // The only thing that touches the tool surface: which of the existing tools are
  // switched on. Brake and Empty switch them all off; Drive restores the base set
  // (narrowed to the worn mask's allowlist, widened by the tools it brought).
  function applyTools(ctx?: ExtensionContext): void {
    if (state.gear !== "drive") {
      pi.setActiveTools([]);
      return;
    }
    const mask = state.mask ? readMask(state.mask) : null;
    let names = [...baseTools];
    if (mask?.tools) {
      const known = new Set(pi.getAllTools().map((t) => t.name));
      const allowed = mask.tools.filter((t) => known.has(t));
      if (allowed.length > 0) names = allowed;
      else ctx?.ui.notify(`mask ${mask.name}: none of its declared tools exist — keeping the base tools.`, "warning");
    }
    if (state.mask) names = [...new Set([...names, ...(maskTools.get(state.mask) ?? [])])];
    // A mask never takes the mask controls away, or a narrow allowlist would trap
    // the Herald inside it with no way to switch.
    pi.setActiveTools([...new Set([...names, ...HERALD_TOOLS])]);
  }

  // A gear is hard: it interrupts whatever is running below it, immediately.
  // Brake also writes the checkpoint, here, in the shift — before the model is
  // given any chance to keep going, and without asking it for anything.
  function shiftGear(next: Gear, ctx: ExtensionContext): void {
    const previous = state.gear;
    state = { ...state, gear: next };
    writeState(state);
    const interrupted = !ctx.isIdle();
    if (interrupted) ctx.abort();
    applyTools(ctx);
    paint(ctx);

    if (next === "brake" && previous !== "brake") {
      const path = writeCheckpoint(state, previous, asked, calls, interrupted);
      ctx.ui.notify(
        path
          ? `Herald → ${gearLabel(next)} — stopped. Checkpoint: ${path}\nType drive to resume from it.`
          : `Herald → ${gearLabel(next)} — stopped, but no checkpoint could be written under ${CHECKPOINTS}.`,
        path ? "warning" : "error",
      );
      return;
    }

    if (previous !== next) ctx.ui.notify(`Herald → ${gearLabel(next)}`, next === "drive" ? "info" : "warning");
    else ctx.ui.notify(`Herald is already in ${gearLabel(next)}`, "info");
  }

  async function wearMask(name: string, ctx: ExtensionContext): Promise<string> {
    const mask = readMask(name);
    if (!mask) throw new Error(`no mask named "${name}" — see /mask list`);

    // A mask's tools.ts is an ordinary pi extension factory. jiti loads the
    // extension we live in, so a dynamic import of another .ts resolves too.
    if (mask.toolsFile && !loaded.has(name)) {
      const before = new Set(pi.getAllTools().map((t) => t.name));
      const mod = (await import(pathToFileURL(mask.toolsFile).href)) as { default?: unknown };
      const factory = mod.default ?? mod;
      if (typeof factory !== "function") throw new Error(`${mask.toolsFile} must export a default function (pi) => void`);
      await (factory as (api: ExtensionAPI) => unknown)(pi);
      maskTools.set(name, pi.getAllTools().map((t) => t.name).filter((n) => !before.has(n)));
      loaded.add(name);
    }

    state = { ...state, mask: name };
    writeState(state);
    applyTools(ctx);
    paint(ctx);
    const extra = maskTools.get(name) ?? [];
    return `wearing mask "${name}"${extra.length ? ` (tools: ${extra.join(", ")})` : ""}`;
  }

  function bare(ctx: ExtensionContext): void {
    state = { ...state, mask: null };
    writeState(state);
    applyTools(ctx);
    paint(ctx);
  }

  function statusLines(): string[] {
    const masks = listMasks();
    const cp = latestCheckpoint();
    return [
      `Herald · gear ${gearLabel(state.gear)} · seat ${state.seat}`,
      `  mask:  ${state.mask ?? "(bare — the four core tools, nothing added)"}`,
      `  masks: ${masks.length ? masks.join(", ") : "none yet — /mask new <name> <what it is for>"}`,
      `  agent: ${AGENT_NAME} — reads ${CALLCENTER}${existsSync(CALLCENTER) ? "" : " (not written yet)"}`,
      `  brake: ${cp ? `${cp}${openCheckpoint()?.path === cp ? " (open — drive resumes from it)" : " (resumed)"}` : `no checkpoint yet — they land in ${CHECKPOINTS}`}`,
      `  gears: /drive  /brake  /empty   (or just type: drive · brake · empty)`,
    ];
  }

  // ------------------------------------------------------------------ lifecycle

  pi.on("session_start", async (_event, ctx) => {
    state = readState();
    baseTools = pi.getActiveTools();
    // On /reload out of Drive, pi hands back the empty set *we* installed. Taking
    // that as the base would strand the Operator with no tools on the way back to
    // Drive, so recover the real surface from the registry instead. In Drive an
    // empty set is the Operator's own doing (--no-tools) and is left alone —
    // unless we got here by dropping a stale gear into Drive, in which case the
    // empty set is the old stopped gear's and recovering it is the whole point.
    if (baseTools.length === 0 && (state.gear !== "drive" || staleGear)) baseTools = pi.getAllTools().map((t) => t.name);
    mkdirSync(MASKS_DIR, { recursive: true });
    if (state.mask && !readMask(state.mask)) state = { ...state, mask: null };
    if (state.mask) await wearMask(state.mask, ctx).catch(() => bare(ctx));
    else applyTools(ctx);
    writeState(state); // so the launcher and `km status` can see the cockpit from the first run
    paint(ctx);

    // An upgrade must never leave the box mute. If the state file held a gear
    // this version does not have, say so out loud — the Operator is looking at a
    // cockpit whose gearstick just changed shape.
    if (staleGear && ctx.hasUI) {
      ctx.ui.notify(
        `herald.json held "${staleGear}", a gear this version does not have. The Herald is in ${gearLabel(state.gear)} — type brake to stop and checkpoint.`,
        "warning",
      );
      staleGear = null;
    }

    // A box that was braked yesterday comes up braked, and says so with the file
    // that lets you pick the job back up.
    if (state.gear === "brake" && ctx.hasUI) {
      const cp = latestCheckpoint();
      ctx.ui.notify(
        `Herald is in ${gearLabel(state.gear)} — stopped.${cp ? ` Checkpoint: ${cp}.` : ""} Type drive to resume from it.`,
        "warning",
      );
    }

    const improvised = improvisedSubagents();
    if (improvised.length > 0 && ctx.hasUI)
      ctx.ui.notify(
        `${improvised.join(", ")} is still loaded in ${join(PI_DIR, "extensions")} and will fire on Drive alongside ${AGENT_NAME}. Park it: km --herald`,
        "warning",
      );
  });

  // Masks are ordinary pi skills, so pi registers and lists them itself.
  pi.on("resources_discover", async () => {
    mkdirSync(MASKS_DIR, { recursive: true });
    return { skillPaths: [MASKS_DIR] };
  });

  pi.on("before_agent_start", async (event) => {
    const blocks = [gearContract(state.gear)];
    const mask = state.mask ? readMask(state.mask) : null;
    if (mask) blocks.push(maskContract(mask));
    // Coming back to Drive: hand over the newest checkpoint nobody has picked up
    // yet, once, and mark it taken. This is the other half of the brake — the
    // stop is only cheap because the resume is automatic.
    if (state.gear === "drive") {
      const cp = openCheckpoint();
      if (cp) {
        blocks.push(resumeContract(cp.path, cp.text));
        closeCheckpoint(cp.path, cp.text);
      }
    }
    return { systemPrompt: `${event.systemPrompt}\n\n${blocks.join("\n\n")}` };
  });

  // Belt and braces: tools are already switched off outside Drive, but a tool
  // registered mid-turn must not slip through either. What we see here is also
  // what the brake writes down, so the checkpoint costs nothing to produce.
  pi.on("tool_call", async (event) => {
    if (state.gear === "drive") {
      remember(calls, readCall(event), 40);
      return;
    }
    return {
      block: true,
      reason:
        state.gear === "brake"
          ? "Herald is in BRAKE — stopped, the checkpoint is written. The Operator shifts to Drive with /drive."
          : `Herald is in ${state.gear.toUpperCase()} — tools are off. The Operator shifts to Drive with /drive.`,
    };
  });

  // Phone-operable: the gear names work as bare words, no slash to hunt for on a
  // soft keyboard. Extension commands are matched before this fires, so /drive
  // and friends never reach here.
  pi.on("input", async (event, ctx) => {
    if (event.source === "extension") return { action: "continue" };
    const text = event.text.trim().toLowerCase();
    if (isGear(text)) {
      shiftGear(text, ctx);
      return { action: "handled" };
    }
    // Retired gear names still work as words, so an Operator with the old habit
    // (or an old note pinned somewhere) gets the stop he meant, not a prompt.
    const retired = RETIRED[text];
    if (retired) {
      ctx.ui.notify(`"${text}" is retired — shifting to ${gearLabel(retired)} instead.`, "warning");
      shiftGear(retired, ctx);
      return { action: "handled" };
    }
    // Braked means idle: nothing reaches the model, so the stop stays a stop and
    // costs nothing to hold.
    if (state.gear === "brake") {
      const cp = latestCheckpoint();
      ctx.ui.notify(
        `Herald is in BRAKE — stopped and idle.${cp ? ` Checkpoint: ${cp}.` : ""} Type drive to resume from it.`,
        "warning",
      );
      return { action: "handled" };
    }
    if (state.gear === "empty") {
      ctx.ui.notify("Herald is in EMPTY — freewheeling. Type drive to engage, or brake to stop and checkpoint.", "warning");
      return { action: "handled" };
    }
    remember(asked, event.text.trim(), 5);
    return { action: "continue" };
  });

  // -------------------------------------------------------------------- commands

  for (const gear of GEARS) {
    pi.registerCommand(gear, {
      description:
        gear === "drive"
          ? "Gear: Herald acts — decides, runs skills, switches masks"
          : gear === "brake"
            ? "Gear: stop now, write a checkpoint, go idle"
            : "Gear: freewheel — nothing drives, nothing is stopped mid-job",
      handler: async (_args, ctx) => shiftGear(gear, ctx),
    });
  }

  pi.registerCommand("gear", {
    description: "Show the gear, or shift it: /gear drive|brake|empty",
    getArgumentCompletions: (prefix) =>
      GEARS.filter((g) => g.startsWith(prefix)).map((g) => ({ value: g, label: g })),
    handler: async (args, ctx) => {
      const want = args.trim().toLowerCase();
      if (!want) {
        ctx.ui.notify(statusLines().join("\n"), "info");
        return;
      }
      const gear = toGear(want);
      if (!gear) {
        ctx.ui.notify(`unknown gear "${want}" — drive, brake, or empty`, "error");
        return;
      }
      if (gear !== want) ctx.ui.notify(`"${want}" is retired — shifting to ${gearLabel(gear)} instead.`, "warning");
      shiftGear(gear, ctx);
    },
  });

  pi.registerCommand("checkpoint", {
    description: "The brake's checkpoints: where they live, and what the newest one says",
    handler: async (_args, ctx) => {
      const cp = latestCheckpoint();
      if (!cp) {
        ctx.ui.notify(`No checkpoint yet. One is written every time you shift to brake; they land in ${CHECKPOINTS}.`, "info");
        return;
      }
      let text = "";
      try {
        text = readFileSync(cp, "utf8");
      } catch (err) {
        ctx.ui.notify(`checkpoint at ${cp} could not be read: ${(err as Error).message}`, "error");
        return;
      }
      ctx.ui.notify([`Checkpoints · ${CHECKPOINTS}`, `newest: ${cp}`, "", text.trim()].join("\n"), "info");
    },
  });

  pi.registerCommand("herald", {
    description: "The cockpit: gear, seat, worn mask, and the masks you have grown",
    handler: async (_args, ctx) => ctx.ui.notify(statusLines().join("\n"), "info"),
  });

  pi.registerCommand("agent", {
    description: `The agent: ${AGENT_NAME}, and the Operator file it reads on every summon`,
    handler: async (_args, ctx) =>
      ctx.ui.notify(
        [
          `Agent · ${AGENT_NAME}`,
          `  reads: ${CALLCENTER}${existsSync(CALLCENTER) ? "" : "   (not there yet — created on the first summon)"}`,
          `  model: ${agentModel().value || "pi's default"}   (${agentModel().source}${agentModel().value ? "" : ` — pin one: echo <provider/model> > ${AGENT_MODEL_PIN}`})`,
          "  tools: read, write, edit, bash",
          "  summon: ask the Herald, in Drive. Everything else the agent knows, you write in that file.",
        ].join("\n"),
        "info",
      ),
  });

  pi.registerCommand("mask", {
    description: "Masks: /mask · list · wear <name> · bare · new <name> <what it is for> · reload",
    getArgumentCompletions: (prefix) => {
      const verbs = ["list", "wear", "bare", "new", "reload"];
      const items = [...verbs, ...listMasks().map((m) => `wear ${m}`)]
        .filter((v) => v.startsWith(prefix))
        .map((v) => ({ value: v, label: v }));
      return items.length > 0 ? items : null;
    },
    handler: async (args, ctx) => {
      const [verb = "", ...rest] = args.trim().split(/\s+/).filter(Boolean);
      const masks = listMasks();

      if (!verb || verb === "list") {
        ctx.ui.notify(
          [
            `worn: ${state.mask ?? "(bare)"}`,
            ...(masks.length
              ? masks.map((m) => `  ${m === state.mask ? "*" : "·"} ${m} — ${oneLine(readMask(m)?.description ?? "")}`)
              : ["  none yet — /mask new <name> <what it is for>"]),
          ].join("\n"),
          "info",
        );
        return;
      }

      if (verb === "bare") {
        bare(ctx);
        ctx.ui.notify("mask off — back to the base surface", "info");
        return;
      }

      if (verb === "reload") {
        await ctx.reload();
        return;
      }

      if (verb === "wear") {
        const name = rest[0] ?? (await ctx.ui.select("Wear which mask?", masks));
        if (!name) return;
        try {
          ctx.ui.notify(await wearMask(name, ctx), "info");
        } catch (err) {
          ctx.ui.notify(`could not wear "${name}": ${(err as Error).message}`, "error");
        }
        return;
      }

      if (verb === "new") {
        const name = rest[0];
        const brief = rest.slice(1).join(" ");
        if (!name) {
          ctx.ui.notify("usage: /mask new <name> <what it is for>", "error");
          return;
        }
        if (!validName(name)) {
          ctx.ui.notify(`"${name}" is not a usable mask name — lowercase letters, digits and single hyphens`, "error");
          return;
        }
        if (state.gear !== "drive") {
          ctx.ui.notify(`masks are grown in Drive — the Herald is in ${gearLabel(state.gear)}. Type drive first.`, "warning");
          return;
        }
        // The models write masks, never the Operator. Hand the request to the
        // Herald and let it call mask_create.
        pi.sendUserMessage(
          [
            `Grow a new persona-mask named "${name}".`,
            brief ? `What the Operator wants from it: ${brief}` : "The Operator gave no brief — ask for one if you cannot infer it from this session.",
            "",
            "Design the persona yourself, then call mask_create. Keep the persona short and",
            "concrete: who it is, how it thinks, and any fixed behaviour it must always follow.",
            "Do not write the file by hand with write/edit — mask_create is the registered path.",
          ].join("\n"),
          // sendUserMessage throws mid-stream unless it is told how to queue
          ctx.isIdle() ? undefined : { deliverAs: "followUp" },
        );
        return;
      }

      ctx.ui.notify(`unknown: /mask ${verb} — try list, wear, bare, new, reload`, "error");
    },
  });

  // ----------------------------------------------------------------------- tools

  pi.registerTool({
    name: "agent_summon",
    label: `Summon ${AGENT_NAME}`,
    description:
      `Summon ${AGENT_NAME}, the Operator's named agent, and hand it exactly one task. It is a separate pi run with the four core tools (read, write, edit, bash). It reads ${CALLCENTER} first — the Operator's own file — and takes its role and its context from there, not from you. Use it to hand off a self-contained job while the Herald keeps the cockpit.`,
    promptSnippet: `Summon ${AGENT_NAME} and hand it one task`,
    promptGuidelines: [
      `${AGENT_NAME} does not see this conversation. Put everything the task needs into the task text; everything about who ${AGENT_NAME} is belongs in ${CALLCENTER}, which only the Operator writes.`,
    ],
    parameters: Type.Object({
      task: Type.String({
        description: "The task, in plain words, self-contained. The agent sees only this text and its call-center file.",
      }),
    }),
    async execute(_id, params, signal, _onUpdate, _ctx) {
      const task = params.task.trim();
      if (!task)
        return { content: [{ type: "text", text: "agent_summon needs a task." }], isError: true, details: {} };

      const seeded = ensureCallcenter();
      const { code, out, err } = await summon(task, signal);
      const text = out.trim();
      const note = seeded ? `\n\n(${CALLCENTER} did not exist — an empty one was created for the Operator to write.)` : "";

      if (code !== 0)
        return {
          content: [{ type: "text", text: `${AGENT_NAME} exited ${code}.\n${(err || text).trim() || "(no output)"}${note}` }],
          isError: true,
          details: { agent: AGENT_NAME, code },
        };

      return {
        content: [{ type: "text", text: `${text || "(no output)"}${note}` }],
        details: { agent: AGENT_NAME, code, callcenter: CALLCENTER },
      };
    },
  });

  pi.registerTool({
    name: "mask_create",
    label: "Grow mask",
    description:
      "Write a new persona-mask and register it with pi, live, without restarting. A mask is an ordinary pi skill (SKILL.md) holding a persona, plus optional TypeScript tools. Use when a real need for a distinct persona shows up in this session.",
    promptSnippet: "Grow a new persona-mask (persona + optional TypeScript tools) and register it live",
    promptGuidelines: [
      "Use mask_create only when this session has shown a real need for a distinct persona — never to pre-populate a roster.",
    ],
    parameters: Type.Object({
      name: Type.String({ description: 'Mask id: lowercase letters, digits and single hyphens, e.g. "archivist".' }),
      description: Type.String({ description: "One or two sentences: what this mask is for and when to wear it. pi shows this in its skill list." }),
      persona: Type.String({ description: "The mask itself, in markdown: who it is, how it thinks, and any fixed behaviour it must always follow." }),
      tools: Type.Optional(
        Type.String({ description: 'Optional comma-separated allowlist of existing tool names this mask may use while worn, e.g. "read, grep, find". Omit to keep the normal tool set.' }),
      ),
      typescript: Type.Optional(
        Type.String({ description: "Optional TypeScript source for extra tools this mask brings. Must export a default function (pi) => void that calls pi.registerTool(). Loaded when the mask is worn." }),
      ),
      wear: Type.Optional(Type.Boolean({ description: "Wear the mask immediately after creating it. Defaults to false." })),
    }),
    async execute(_id, params, _signal, _onUpdate, ctx) {
      const { name, description, persona } = params;
      if (!validName(name))
        return {
          content: [{ type: "text", text: `"${name}" is not a usable mask name: lowercase letters, digits and single hyphens, 1-64 chars.` }],
          isError: true,
          details: {},
        };

      const dir = join(MASKS_DIR, name);
      const existed = existsSync(join(dir, "SKILL.md"));
      mkdirSync(dir, { recursive: true });

      const frontmatter = [
        "---",
        `name: ${name}`,
        `description: "${oneLine(description).replace(/"/g, "'")}"`,
        "metadata:",
        '  km-mask: "true"',
        ...(params.tools ? [`  tools: "${oneLine(params.tools).replace(/"/g, "'")}"`] : []),
        "---",
        "",
      ].join("\n");
      writeFileSync(join(dir, "SKILL.md"), `${frontmatter}${persona.trim()}\n`);
      if (params.typescript) writeFileSync(join(dir, "tools.ts"), `${params.typescript.trim()}\n`);

      let worn = "";
      if (params.wear) {
        try {
          worn = `\n${await wearMask(name, ctx)}`;
        } catch (err) {
          worn = `\ncreated, but could not be worn: ${(err as Error).message}`;
        }
      }
      paint(ctx);

      return {
        content: [
          {
            type: "text",
            text:
              `${existed ? "Updated" : "Created"} mask "${name}" at ${dir}.\n` +
              `It is wearable now (mask_wear, or /mask wear ${name}); pi lists it as a skill after /mask reload.${worn}`,
          },
        ],
        details: { name, dir, created: !existed },
      };
    },
  });

  pi.registerTool({
    name: "mask_wear",
    label: "Wear mask",
    description:
      "Put on one of the grown masks, or take the current one off. Only one mask is worn at a time. Its persona and tools apply from the next turn.",
    promptSnippet: "Wear one of the grown persona-masks, or go bare",
    parameters: Type.Object({
      name: Type.Optional(Type.String({ description: "Mask to wear. Omit (or pass an empty string) to take the current mask off." })),
    }),
    async execute(_id, params, _signal, _onUpdate, ctx) {
      const name = (params.name ?? "").trim();
      if (!name) {
        bare(ctx);
        return { content: [{ type: "text", text: "Mask off — back to the base surface." }], details: { mask: null } };
      }
      try {
        const msg = await wearMask(name, ctx);
        return { content: [{ type: "text", text: `${msg}. The persona applies from the next turn.` }], details: { mask: name } };
      } catch (err) {
        const masks = listMasks();
        return {
          content: [{ type: "text", text: `${(err as Error).message}. Grown masks: ${masks.length ? masks.join(", ") : "none yet"}.` }],
          isError: true,
          details: {},
        };
      }
    },
  });
}
