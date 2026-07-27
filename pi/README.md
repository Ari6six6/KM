# pi/ — KM's extras for the harness

Three things live here: the models.json incantation that points pi at the box, a
hello-world extension that teaches you to write your own, and the Herald — KM's
orchestration layer.

`setup.sh` installs both for you. This directory is the annotated original —
edit it, re-run `setup.sh`, and `/reload` inside pi.

---

## `models.json` — wiring pi to the served model (the §4 incantation)

`setup.sh` writes a resolved copy to `~/.pi/agent/models.json` with the tunnel's
real port. This file is the clean, copy-paste-safe template. Every field is
load-bearing:

| Field | Why it matters |
|-------|----------------|
| `baseUrl` | The box, reached through KM's SSH tunnel. `setup.sh` sets the port to whatever the tunnel landed on (it can slide if the box squats 8080). |
| `api: "openai-completions"` | vLLM and llama-server both speak the OpenAI Chat Completions dialect. Most compatible choice. |
| `apiKey: "km"` | A **dummy literal**. llama-server/vLLM ignore it, but pi wants a key present before a model appears in `/model`. Your real cloud keys stay in the environment (`ANTHROPIC_API_KEY`, …), **never** in this file. |
| `compat.supportsDeveloperRole: false` | vLLM/llama-server-class backends choke on the OpenAI `developer` role. This makes pi send a plain `system` message instead. |
| `compat.supportsReasoningEffort: false` | Same class of backend rejects `reasoning_effort`. Off. |
| `models[].id` | **Must exactly equal** the `--served-model-name` (vLLM) / `--alias` (llama-server) the GPU module launched with. For the default GLM row that is `glm-4.7-flash`. |
| `contextWindow` | Set to the tier KM planned for the box's VRAM. |

Docs: pi's own `packages/coding-agent/docs/models.md` is the authority on this
schema — this file only annotates KM's use of it.

### The council

Once the box model is wired, set cloud keys in your environment and pi's built-in
providers wake up on their own — Anthropic, Moonshot (Kimi For Coding), and the
rest. The box model is your **default**; the clouds are the **council** you call
when you need them (`/model`, or Ctrl+P to cycle). Yes: pi on the box can run
Opus as a resident model — the coder moves into the house he built.

---

## `extensions/gpu-status/` — your first extension

A `/gpu-status` command that reads KM's state file and pings the endpoint, so pi
can tell you — from inside a session — whether the box is live. It is the perfect
hello-world: small, real, and about *your* box.

`setup.sh` copies it to `~/.pi/agent/extensions/gpu-status/` (auto-discovered).
Inside pi, type `/gpu-status`. To hack on it: edit `index.ts`, then `/reload`.

Package it and share it later with `pi` packages (`pi install git:…`); see pi's
`packages.md`.

---

## `extensions/herald/` — the orchestration layer

The other end of the scale from gpu-status: the extension behind the
[cockpit](../herald). It holds the three gears (`/drive`, `/debate`, `/empty`),
wears and grows persona-masks, and gates which of pi's *existing* tools are
switched on. It registers three tools of its own — `mask_create`, `mask_wear`,
and `agent_summon` — and changes nothing about `read`, `write`, `edit`, `bash`,
or pi's agent loop.

Worth reading as a second lesson after gpu-status: it uses `resources_discover`
to hand pi a whole skill directory, `before_agent_start` to rewrite the system
prompt per turn, `setActiveTools` to change the surface without touching the
tools, and a dynamic `import()` to load a mask's TypeScript the moment it is
first worn. `agent_summon` is the fourth lesson: a tool that shells out to a
second `pi` (`-p --no-session --tools read,write,edit,bash --no-extensions
--no-context-files`) and honours the tool's `AbortSignal`, so a gear shift kills
the child. The launcher and the contract live in [`herald/`](../herald).
