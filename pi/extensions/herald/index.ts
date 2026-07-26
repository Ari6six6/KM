// herald — KM's orchestration layer: three hard gears and a live path to masks.
//
// This is a thin layer *on top of* pi. It adds no tools to the base surface and
// changes nothing about pi's four core tools (read, write, edit, bash) or its
// agent loop. All it does is:
//
//   1. hold a gear   — drive / debate / empty, top-priority, interrupts anything
//   2. wear a mask   — inject a persona (and its tools) for the next turn(s)
//   3. grow a mask   — let the model write a new one, live, while the box runs
//
// State lives in $KM_HOME/herald.json; masks live in $KM_HOME/masks/<name>/ as
// ordinary pi skills, so pi discovers them itself (see resources_discover).
//
// Docs: pi's packages/coding-agent/docs/extensions.md is the authority on this API.

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

// ---------------------------------------------------------------- paths + state

const KM_HOME = process.env.KM_HOME ?? join(homedir(), ".km");
const MASKS_DIR = join(KM_HOME, "masks");
const STATE_FILE = join(KM_HOME, "herald.json");
const DEFAULT_SEAT = "xai/grok-4.5";

type Gear = "drive" | "debate" | "empty";
const GEARS: Gear[] = ["drive", "debate", "empty"];
const isGear = (s: string): s is Gear => (GEARS as string[]).includes(s);

interface HeraldState {
  gear: Gear;
  mask: string | null;
  seat: string;
}

function readState(): HeraldState {
  try {
    const raw = JSON.parse(readFileSync(STATE_FILE, "utf8")) as Partial<HeraldState>;
    return {
      gear: raw.gear && isGear(raw.gear) ? raw.gear : "drive",
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

// ------------------------------------------------------- the prompt the gear adds

function gearContract(gear: Gear): string {
  const head = "# Herald gear (KM orchestration layer)\n\nThe Operator sets the gear. You never set it yourself; you report it.";
  if (gear === "drive")
    return `${head}\n\nCurrent gear: **DRIVE**. You act. You decide, you run skills, and you may switch masks (mask_wear) or grow a new one (mask_create) when a real need shows up in this session — not speculatively.`;
  if (gear === "debate")
    return `${head}\n\nCurrent gear: **DEBATE**. All other activity is stopped. Your tools are switched off and any tool call will be blocked. Talk with the Operator and nothing else: think out loud, argue, plan. Do not promise to do work — you cannot act until the Operator shifts back to Drive.`;
  return `${head}\n\nCurrent gear: **EMPTY**. Freewheel. Nothing is driving and nothing is being debated. If you are somehow given a turn, say only that the Herald is in Empty.`;
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
  let state = readState();
  // pi's tool surface as the Operator launched it — the four core tools plus
  // whatever else was configured. We restore exactly this; we never edit it.
  let baseTools: string[] = [];
  // tool names each mask's tools.ts contributed, and which ones we have imported
  const maskTools = new Map<string, string[]>();
  const loaded = new Set<string>();

  const gearLabel = (g: Gear): string =>
    g === "drive" ? "DRIVE ▶" : g === "debate" ? "DEBATE ‖" : "EMPTY ○";

  function paint(ctx: ExtensionContext): void {
    if (!ctx.hasUI) return;
    ctx.ui.setStatus("herald", `${gearLabel(state.gear)}${state.mask ? ` · ${state.mask}` : ""}`);
  }

  // The only thing that touches the tool surface: which of the existing tools are
  // switched on. Debate and Empty switch them all off; Drive restores the base set
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
  function shiftGear(next: Gear, ctx: ExtensionContext): void {
    const previous = state.gear;
    state = { ...state, gear: next };
    writeState(state);
    if (!ctx.isIdle()) ctx.abort();
    applyTools(ctx);
    paint(ctx);
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
    return [
      `Herald · gear ${gearLabel(state.gear)} · seat ${state.seat}`,
      `  mask:  ${state.mask ?? "(bare — the four core tools, nothing added)"}`,
      `  masks: ${masks.length ? masks.join(", ") : "none yet — /mask new <name> <what it is for>"}`,
      `  gears: /drive  /debate  /empty   (or just type: drive · debate · empty)`,
    ];
  }

  // ------------------------------------------------------------------ lifecycle

  pi.on("session_start", async (_event, ctx) => {
    state = readState();
    baseTools = pi.getActiveTools();
    // On /reload out of Drive, pi hands back the empty set *we* installed. Taking
    // that as the base would strand the Operator with no tools on the way back to
    // Drive, so recover the real surface from the registry instead. In Drive an
    // empty set is the Operator's own doing (--no-tools) and is left alone.
    if (baseTools.length === 0 && state.gear !== "drive") baseTools = pi.getAllTools().map((t) => t.name);
    mkdirSync(MASKS_DIR, { recursive: true });
    if (state.mask && !readMask(state.mask)) state = { ...state, mask: null };
    if (state.mask) await wearMask(state.mask, ctx).catch(() => bare(ctx));
    else applyTools(ctx);
    writeState(state); // so the launcher and `km status` can see the cockpit from the first run
    paint(ctx);
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
    return { systemPrompt: `${event.systemPrompt}\n\n${blocks.join("\n\n")}` };
  });

  // Belt and braces: tools are already switched off outside Drive, but a tool
  // registered mid-turn must not slip through either.
  pi.on("tool_call", async () => {
    if (state.gear === "drive") return;
    return {
      block: true,
      reason: `Herald is in ${state.gear.toUpperCase()} — tools are off. The Operator shifts to Drive with /drive.`,
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
    if (state.gear === "empty") {
      ctx.ui.notify("Herald is in EMPTY — freewheeling. Type drive to engage, or debate to talk.", "warning");
      return { action: "handled" };
    }
    return { action: "continue" };
  });

  // -------------------------------------------------------------------- commands

  for (const gear of GEARS) {
    pi.registerCommand(gear, {
      description:
        gear === "drive"
          ? "Gear: Herald acts — decides, runs skills, switches masks"
          : gear === "debate"
            ? "Gear: stop everything and talk only with the Operator"
            : "Gear: freewheel — no driving, no debating",
      handler: async (_args, ctx) => shiftGear(gear, ctx),
    });
  }

  pi.registerCommand("gear", {
    description: "Show the gear, or shift it: /gear drive|debate|empty",
    getArgumentCompletions: (prefix) =>
      GEARS.filter((g) => g.startsWith(prefix)).map((g) => ({ value: g, label: g })),
    handler: async (args, ctx) => {
      const want = args.trim().toLowerCase();
      if (!want) {
        ctx.ui.notify(statusLines().join("\n"), "info");
        return;
      }
      if (!isGear(want)) {
        ctx.ui.notify(`unknown gear "${want}" — drive, debate, or empty`, "error");
        return;
      }
      shiftGear(want, ctx);
    },
  });

  pi.registerCommand("herald", {
    description: "The cockpit: gear, seat, worn mask, and the masks you have grown",
    handler: async (_args, ctx) => ctx.ui.notify(statusLines().join("\n"), "info"),
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
