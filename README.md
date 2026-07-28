# KM

**One script. It turns a rented GPU box into a thinking endpoint wired into a real
coding harness — from one pasted SSH string, in about ninety seconds.**

KM is the leanest thing this line has ever shipped: a repo whose beating heart is
one bash script. You rent a GPU box (vast.ai hands you an `ssh` line). You paste it
into KM. KM installs [`pi`](https://pi.dev) — a minimal, self-extending coding
harness — provisions the box to serve a model **you** control, opens a tunnel,
wires pi to it, loads your context, and proves it can think. Then you type `pi` and
work.

We are done building harnesses. Five ancestors taught us one perfect organ (GPU
provisioning) and one hard lesson (we are provisioners, not harness-smiths). So we
keep the organ, transplant it into `pi` — the harness the ecosystem finally got
right — and spend the rest of our effort on **context, lore, and speed.**

```
their GPU module  ·  pi's harness  ·  our lore
```

---

## Zero to hero

You need two machines (they can be the same one, but usually aren't):

- **A harness machine** — where you run KM and pi. A plain Ubuntu VPS (`michael@hello`),
  or Termux on Android. Needs only `bash`, `ssh`, `curl`, `coreutils`.
- **A GPU box** — a vast.ai H100/H200 you rent by the hour. The console hands you an
  SSH line like `ssh -p 24439 root@1.2.3.4`. Add a `-L` port forward and give the
  whole thing to KM.

### 1. Run the one command (on the harness machine)

```sh
curl -fsSL https://raw.githubusercontent.com/Ari6six6/KM/main/setup.sh | bash -s -- \
    --gpu "-p 24439 root@1.2.3.4 -L 8080:localhost:8080" --model glm
```

That single line, in order: installs Node + `pi` → lays down `~/.pi/agent` config →
reaches the box (retrying while it boots) → detects the GPUs and picks a
VRAM/context tier → **preflights** (does the model repo + exact file resolve on
Hugging Face? does the disk fit the weights? does the GPU support the quant? — each
a ~3-second answer *before* any paid install) → builds llama.cpp (or installs vLLM)
→ launches the server with tool-calling on → opens a PID-tracked SSH tunnel → runs
a **canary** (one real tool call — "up" means *can think*, not just *lists models*)
→ writes `~/.pi/agent/models.json` pointing pi at it → installs your context
package → prints the three commands to type next.

### 2. The three commands it prints

```sh
pi -p "what model are you and who is the operator?"   # proof: the box answers, context loaded
pi                                                    # start working
km status                                             # is the tunnel live? what's served?
```

Or type `herald` and fly the [cockpit](#the-herald--the-cockpit) instead.

If you time it, rental receipt → first agent turn should be under ten minutes of
your own typing — most of it the one-time model download.

### No box yet? Harness-only

```sh
curl -fsSL https://raw.githubusercontent.com/Ari6six6/KM/main/setup.sh | bash -s -- --no-gpu
```

Installs pi and the context package with cloud keys only. **Honesty law:** the
served model is labelled `DEMO` until a real box attaches.

---

## The Herald — the cockpit

`pi` is the harness. **The Herald is the seat you fly it from** — one top-level
process that is your sole interface to the box, model-agnostic, with three hard
gears and a live path to personas.

```sh
herald                              # start the cockpit
herald --seat km-box/glm-4.7-flash  # any model can hold the seat (default: xai/grok-4.5)
```

**Three gears.** They outrank everything below them: shifting interrupts a
running skill, a mask mid-thought, a tool call about to land.

| Gear | |
|------|--|
| **Drive** | The Herald acts — decides, runs skills, wears masks, grows new ones. |
| **Brake** | Stop. It writes a checkpoint and goes idle. `drive` picks the job back up. |
| **Empty** | Freewheel. Nothing drives, nothing is stopped mid-job. |

Shift with `/drive`, `/brake`, `/empty`, or just type the bare word `drive`,
`brake`, `empty` — because the cockpit has to fly from a phone, and hunting for
`/` on a soft keyboard is the whole friction. The gear persists in
`~/.km/herald.json`; `km --check` prints it.

**The brake stops without losing the job.** Shifting to `brake` interrupts the
turn, switches every tool off, and writes a checkpoint — the task in progress,
what actually ran, the files touched — to `~/karte/checkpoints/`. The *extension*
writes it, from what it watched go past, so braking costs one file write and zero
tokens and works mid-sentence. Then the Herald is idle: prompts stop reaching the
model. Shift back to `drive` and the first turn is handed that checkpoint and told
to continue, not to start over. `/checkpoint` shows the newest one.

Because a stopped cockpit does not answer prompts, `herald --gear drive` sets the
gear from the shell without starting it — the way back in if you left the box
stopped and it looks dead.

**Masks grow, they don't ship.** A mask is a persona the Herald wears — one at a
time, one box, one GPU. **You start with zero, and that is correct.** No roster,
no starter pack, no fixed number. When a session shows a real need for a
different head, you ask for one and *the model writes it*:

```sh
/mask new archivist keeps the museum honest    # you ask
                                               # the Herald designs it and calls mask_create
/mask wear archivist                           # wearable immediately, on the live box
```

That writes `~/.km/masks/archivist/SKILL.md` — an ordinary pi skill, registered
with pi, listed alongside everything else. A mask that needs tools of its own
gets a `tools.ts` next to it, also written by the model, imported the moment the
mask is first worn. You never write TypeScript by hand.

**One agent, and you write its file.** A mask changes who the Herald *is*; the
agent is someone else — a separate `pi`, summoned from Drive with one task while
the Herald keeps the cockpit. There is exactly one, it has a name (`smith`), and
it is configured entirely by a file you maintain by hand:

```
~/karte/callcenter.md      # the only thing that configures the agent — yours to write
```

On every summon it is told three things: its name, to read that file first, and
the task. Everything else it knows, you put in the file. No generated persona, no
orientation package, nothing written on your behalf. It runs with the four core
tools and nothing else — no extensions, no `AGENTS.md` — because the file can
only be the source of truth if nothing loads behind it. `km --uninstall` leaves
`~/karte` alone; it is yours, not KM's.

Nothing here touches pi's four core tools or its agent loop; the Herald only
switches existing tools on and off. Full details in [`herald/`](herald).

---

## The Team

Beyond the box, KM ships a crew — three `pi` instances with locked roles that you
run side by side in separate terminals, all pointed at the same project:

| Command    | Persona  | Role |
|------------|----------|------|
| `claudepi` | ClaudePi | **The adult in the room — the primary coder.** Builds by default; his work is what ships unless something better replaces it. |
| `grokpi`   | GrokPi   | **The challenger.** Only puts code up when it genuinely beats ClaudePi's — and must say why. |
| `kimipi`   | KimiPi   | **The judge.** Reads both and passes exactly one. Nothing ships until Kimi passes it. |

They coordinate through **the board** — one shared file (`team/board/board.md`)
everyone reads and writes. No server, no database, just a Linux file you paste
into:

```sh
team/install-team.sh          # links claudepi/grokpi/kimipi + post/board onto PATH
post operator "build X"       # you drop a task on the board
board                         # read it   (board -f follows live)
```

The loop: you post a task → ClaudePi builds → GrokPi challenges only if he's got
something better → KimiPi passes one → you take it. Each worker keeps its own
isolated session tree. Full details in [`team/`](team).

---

## Managing the box (`km`)

After the first run, KM drops a `km` command (and keeps a copy of the script at
`~/.km/setup.sh`). Every sub-command is also `bash ~/.km/setup.sh --<name>`.

```sh
km status        # is the tunnel live? what is served?
km watch         # keep the tunnel alive automatically (self-heals with backoff)
km reconnect     # re-open the tunnel to the last box
km off           # drop the tunnel (leave the server running on the box)
km down          # stop the server AND drop the tunnel
km --check       # verify the whole install; meaningful exit codes
km --herald      # (re)install the cockpit alone — safe on a live box
km --list-models # print the model catalog
km --uninstall   # clean reversal
```

Killed the tunnel by accident? `km reconnect` restores it, or run `km watch` (or
`nohup km watch >/dev/null 2>&1 &`) and it re-dials itself the moment it drops — no
more noticing it's down and fixing it by hand.

---

## The model catalog

`km --list-models` prints it. The default is **GLM-4.7-Flash** — the operator's
daily driver — as an FP16 GGUF served through a hand-built CUDA llama.cpp.

| key | model | floor | runtime |
|-----|-------|-------|---------|
| `glm` *(default)* | GLM-4.7-Flash (HauhauCS Balanced, uncensored) · FP16 GGUF | ~66 GB | llama.cpp |
| `glm-q4` | GLM-4.7-Flash · Q4_K_M GGUF (small boxes) | ~24 GB | llama.cpp |
| `glm-q6` | GLM-4.7-Flash · Q6_K GGUF | ~34 GB | llama.cpp |
| `hermes` | Hermes-4.3-36B · FP8 | ~44 GB | vLLM |
| `qwen-official` | Qwen3.6-27B (official) · FP8 | ~30 GB | vLLM |
| `qwen` | Qwen3.6-27B (uncensored) · Q5_K_P GGUF | ~22 GB | llama.cpp |
| `qwen-40b` | Qwen3.6-40B (Opus-Deckard Heretic) · Q5_K_M GGUF | ~30 GB | llama.cpp |

If the box is too small for the row you picked, KM refuses **before** spending a
cent and names the largest quant that *would* fit. Edit the catalog in `setup.sh`
(SECTION 1) to add your own rows.

---

## Learning pi (this repo is a curriculum)

KM installs pi and wires your box in; **pi itself is the harness you're learning.**
Don't re-read pi's docs from here — this is a guided path *through* them, annotated
with your box. pi is a minimal terminal coding agent: a handful of built-in tools
(`read`, `write`, `edit`, `bash`, plus `grep`/`find`/`ls`) and a tiny system
prompt. Everything else — subagents, plan mode, permission gates — you *add*, as
TypeScript extensions, skills, and prompt templates. It can even modify itself in
place: `/reload` and keep going.

Walk it in this order:

1. **Switch models.** Inside pi, `/model` lists what's available — your `km-box`
   model plus any cloud providers whose keys are in your environment. `Ctrl+P`
   cycles the models you scope with `--models`. Your box is the default; the
   clouds are the council. → pi docs: *Using Pi*, *Providers*.
2. **Thinking levels.** `pi --model glm-4.7-flash:high "…"`, or `/settings` to set
   the level; the editor border colour shows it. → pi docs: *Using Pi*.
3. **One-shots and pipes.** `pi -p "summarize this repo"`, and
   `cat README.md | pi -p "summarize this"` — print mode reads piped stdin. → pi
   docs: *Using Pi → Modes*.
4. **Branch your history.** `/tree` walks the session tree; `/fork`, `/export`,
   `/share`. Sessions are trees in a single file. → pi docs: *Sessions*.
5. **Write your first extension.** KM ships one: `/gpu-status` (see
   [`pi/extensions/gpu-status/`](pi/extensions/gpu-status)). It reads KM's state
   and pings your endpoint — the perfect hello-world because it's about *your*
   box. Edit `index.ts`, `/reload`, watch it change. → pi docs: *Extensions*.
6. **Package it.** Turn the extension into a shareable pi package
   (`pi install git:…`). → pi docs: *Pi packages*.
7. **Automate later.** pi's RPC (`--mode rpc`) and SDK (`createAgentSession`) modes
   are how you script it once you're fluent. → pi docs: *RPC mode*, *SDK*.

pi's docs live at **https://pi.dev** and in its repo
(`earendil-works/pi`, `packages/coding-agent/docs`). We annotate pi; we don't
re-document it.

### The context package — pi wakes up knowing who you are

KM installs [`context/`](context) into pi's global context file
(`~/.pi/agent/AGENTS.md`), so every session starts already knowing the operator,
the line of harnesses it stands at the end of, and the rules paid for in rental
hours:

- [`context/OPERATOR.md`](context/OPERATOR.md) — who you serve, and how.
- [`context/HISTORY.md`](context/HISTORY.md) — MoR → Hermes/rig → KM1 → KM.
- [`context/THESIS.md`](context/THESIS.md) — why now.
- [`context/LESSONS.md`](context/LESSONS.md) — the museum distilled to rules.

Edit them, re-run `setup.sh`, and `/reload` inside pi.

---

## How it works

```
KM/
├── setup.sh            # the script. the point.
├── README.md           # this file — zero-to-hero + the pi curriculum + the thesis
├── context/            # OPERATOR · HISTORY · THESIS · LESSONS  (loaded by pi)
├── herald/             # the cockpit — launcher + contract (gears, brake, masks)
├── museum/             # MoR · hermes · rig · KM1 — one honest essay per ancestor
├── pi/                 # models.json template + the gpu-status and herald extensions
└── tests/              # a no-box, no-network bash suite (CI on ubuntu-latest)
```

`setup.sh` runs on the harness machine and does two jobs: it installs pi locally,
and it provisions the GPU box you paste over SSH (installing the runtime *there*,
launching the server, opening a local tunnel back). State lives in `~/.km/`; pi's
config in `~/.pi/agent/`. Artifacts that touch the box's system are named `km-*`
(e.g. `/etc/ld.so.conf.d/cuda-km.conf`).

The provisioning brain — SSH-string surgery, the boot-race retry shims, CUDA linker
registration, VRAM/context planning, the auto-port slide, the readiness poll, the
canary — is ported quirk-for-quirk from **KM1**'s `mor/gpu.py`, `gpucmd.py`,
`preflight.py`, `models.py` and `tunnel.py`. Every oddity was paid for with a
burned rental hour; see [`museum/KM1.md`](museum/KM1.md).

**Requirements:** the harness machine needs `bash`, `ssh`, `curl`, `coreutils`, and
Node 20+ (KM installs it via nvm if missing). The GPU box needs an NVIDIA GPU and
the vast.ai base Ubuntu image — nothing else; KM installs the rest.

**No secrets in this repo.** Cloud keys stay in your environment
(`ANTHROPIC_API_KEY`, …); pi's `models.json` references a dummy key for the box.

---

## The thesis — why now

For three years the 10x was a promise. This decade it is a shipping product, and
the proof is `pi` itself: a harness small enough to hold in your head, that extends
itself on command and treats models as config — turning "build your own agent" from
a cathedral project into an afternoon.

Our contribution to the moment is the last unsolved inch: **compute.** Any box, one
pasted string, ninety seconds to a thinking endpoint wired into a real harness.

> **pi's extensibility  ×  KM's provisioning  ×  your context = the 10x, made personal.**

We don't wait for the decade. We want to see it now. Read it in full:
[`context/THESIS.md`](context/THESIS.md).

---

*KM is the synthesis of a long line — MoR, Hermes, rig, KM1. `main` is not a
museum, but it does have [one](museum), so we never forget what the cathedrals cost.*
