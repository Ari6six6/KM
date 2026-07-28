# herald/ — the cockpit

One top-level process that is the Operator's sole interface to the box. It is
**model-agnostic**: the seat defaults to Grok 4.5, but any model pi can reach may
hold it — including the GLM on your own GPU.

```sh
herald                            # start the cockpit
herald --seat km-box/glm-4.7-flash   # assign the seat to your own box
herald --seat                     # who is seated?
```

The Herald is a thin layer, not a framework. It is two files and one extension:

| Path | What it is |
|------|-----------|
| [`bin/herald`](bin/herald) | the launcher — `pi` with the contract appended and a seat assigned |
| [`HERALD.md`](HERALD.md) | the contract — appended to pi's system prompt, never replacing it |
| [`../pi/extensions/herald/`](../pi/extensions/herald) | the extension — gears, the brake's checkpoints, masks, and the live path that grows them |

`setup.sh` installs all three (`km --herald` reinstalls just these, safely, on a
live box). Nothing here modifies pi's four core tools or its agent loop.

---

## The three gears

The Operator holds the gearstick. Gears are **hard**: shifting interrupts
whatever is running below — a skill mid-flight, a mask mid-thought, a tool call
about to land.

| Gear | What it means |
|------|---------------|
| **Drive** | The Herald acts. It decides, runs skills, wears masks, and grows new ones. Full tool surface. |
| **Brake** | Stop. The shift interrupts the turn, writes a checkpoint, switches every tool **off**, and the Herald goes idle — prompts stop reaching the model. `drive` resumes from the checkpoint. |
| **Empty** | Freewheel. Nothing drives and nothing is stopped mid-job — prompts don't reach the model at all. Neutral. |

Shift with `/drive`, `/brake`, `/empty` — or just type the bare word `drive`,
`brake`, or `empty`. The bare words exist because the Herald has to be drivable
from a phone, where hunting for `/` on a soft keyboard is the whole friction.

The gear is written to `~/.km/herald.json` and survives restarts, so the box you
left braked is still braked tomorrow — and still holding the checkpoint that says
where it stopped. `km --check` prints the gear.

> The model never shifts its own gear. It is told which gear it is in and obeys;
> the stick belongs to the Operator. That is what "top-priority" buys you.

> **Debate is retired.** It was the old stop-gear: tools off, talk only. A gear
> that cannot act is not a mode this box has any use for, and a stop that leaves
> nothing behind is worse than no stop at all. Typing `debate` now brakes and says
> so. A `debate` still sitting in an old `herald.json` is a different thing —
> upgrade debris, with nothing running to interrupt and no checkpoint behind it —
> so the Herald comes up in **Drive** and tells you the gear is gone. An upgrade
> must never leave the box mute.

### Locked out?

The gear persists and Brake does not answer prompts. That is the point of a hard
gear, and it is also how you lock yourself out of your own box. The way back does
not need the cockpit to answer you:

```sh
herald --gear          # what gear is it in?
herald --gear drive    # set it from the shell, without starting the cockpit
```

`km --check` prints the gear too, and names it if it is one this version dropped.

---

## The brake — stop now, lose nothing

Braking is the cheapest thing the cockpit does. It costs **one file write and
zero tokens**: the extension writes the checkpoint itself, out of what it already
watched go past, so it works when the model is mid-sentence, looping, or wrong,
and it never asks the model to "wrap up first".

```sh
brake              # or /brake — stop, checkpoint, idle
/checkpoint        # where they live, and what the newest one says
drive              # resume from it
```

Checkpoints are plain markdown, one file per brake, in the Operator's own map
next to `callcenter.md`:

```
~/karte/checkpoints/2026-07-28T11-03-11-927Z.md
```

Names are ISO timestamps, so the last name is the newest one. Each file holds the
gear it braked out of, the seat, the mask, whether a turn was cut mid-flight, the
task in progress, what the Operator asked earlier, the trail of what actually ran
(the last line flagged, honestly, as possibly unfinished), and the files touched.
Nothing in it is inferred; it is all things the cockpit watched.

Set `KM_CHECKPOINTS` to put them somewhere else.

**Resuming.** The first turn back in Drive is handed the newest checkpoint that
nobody has picked up yet, and told to continue rather than start over. Being
picked up is recorded *in the file* — `status: open` becomes `status: resumed
<when>` — so it survives a restart, a new seat, and a launcher that rewrites
`herald.json`. One handover per brake, not one per turn. Any other reader (a
summoned agent, you, `cat`) just reads the newest file; nothing else is needed.

---

## Masks

A **mask** is a persona the Herald puts on: a name, how it thinks, and any fixed
behaviour it must keep. One is worn at a time — one box, one GPU, one model
interface. Wearing a mask does not spawn anything; it changes who the Herald *is*
for the next turns.

```sh
/mask                     # what is worn, and what has been grown
/mask wear archivist      # put one on
/mask bare                # take it off
/mask new <name> <why>    # ask the Herald to grow one
/mask reload              # re-register masks with pi (after growing several)
```

**You start with zero masks, and that is correct.** There is no roster of twelve,
no starter pack, no fixed number at all. A mask appears when a real need for one
shows up in a running session — and not before.

### How one gets grown

The Operator never writes TypeScript. The models write masks.

1. In Drive, `/mask new archivist keeps the museum honest`, or the Herald decides
   on its own that this session needs a different head.
2. The Herald designs the persona and calls its `mask_create` tool.
3. That writes `~/.km/masks/archivist/SKILL.md` — an ordinary pi skill — and pi
   registers it. It is wearable immediately, in the same session, on the live box.

A mask that needs tools of its own gets a `tools.ts` beside its `SKILL.md`: an
ordinary pi extension factory, written by the model, imported when the mask is
first worn. Its tools become callable in that same turn.

```
~/.km/masks/
└── archivist/
    ├── SKILL.md      # frontmatter + the persona
    └── tools.ts      # optional — export default (pi) => { pi.registerTool(...) }
```

```yaml
---
name: archivist
description: Keeps the museum honest. Wear when writing history or post-mortems.
metadata:
  km-mask: "true"
  tools: "read, bash"      # optional: narrow the tool surface while worn
---

You are the Archivist.

- You write what happened, not what was meant to happen.
- Every claim gets a date or it does not go in.
```

`metadata.tools` narrows the tools available while the mask is worn. It can never
remove the mask controls themselves — a narrow mask must not be able to trap the
Herald inside itself.

Because masks are ordinary pi skills, pi lists them, describes them to the model,
and exposes them as `/skill:archivist` too. Nothing bespoke to learn.

---

## The agent — one name, one file you write

A mask changes who the Herald *is*. The agent is someone **else**: one separate
`pi`, summoned from Drive with a single task, while the Herald keeps the cockpit.

There is exactly one, it has a fixed name (`smith` unless you set `KM_AGENT`),
and it is configured by **one file that you write by hand**:

```
~/karte/callcenter.md
```

That is the whole design. On every summon the agent is told three things — its
name, to read that file before anything else, and the task. Everything else it
knows about its role and the current work, you put in the file. There is no
generated persona, no orientation package, and nothing for the Herald to write
on your behalf. Growing the agent means editing `callcenter.md`.

```sh
/agent                    # (inside the Herald) its name, and the file it reads
```

The agent runs with the four core tools (`read`, `write`, `edit`, `bash`) and
nothing else: no extensions, no `AGENTS.md`, no session saved. That is deliberate
— the call-center file can only be the source of truth if nothing loads behind
it. It runs on pi's default model (on a provisioned box, the one you own);
`KM_AGENT_MODEL` overrides that.

`km` creates `~/karte/callcenter.md` once, with three lines saying it is yours.
After that KM never writes to it, and `km --uninstall` leaves `~/karte` alone.

> The agent does not see your conversation with the Herald. Whatever the job
> needs goes in the task; whatever the agent *is* goes in the file.

---

## What this does not do

Deliberately, per the brief:

- **No parallel model instances.** One mask at a time, one model interface.
- **No changes to pi's four tools** (`read`, `write`, `edit`, `bash`) or its agent
  loop. The Herald only switches existing tools on and off.
- **No fixed roster of masks.** Growth happens on need, in a running session.
- **No team of agents.** One name, summoned one task at a time. If you want a
  second, that is a decision you make later, not a framework you get now.
- **No UI beyond the gears, the checkpoint, mask creation, and the summon.** A
  status line, and words you type.
- **No resume engine.** The brake writes a file and Drive reads it back once.
  There is no queue, no scheduler, and nothing that replays a session.

---

## Security

`mask_create` lets the seated model write a skill file and, optionally,
TypeScript that runs in your pi process. That is the same power the model already
has through pi's `write` and `bash` tools, routed through a named path instead of
an anonymous one — but it *is* code execution, and masks are worth reading before
you wear them. They are plain files in `~/.km/masks/`; `cat` them.

`km --uninstall` copies your masks to `~/km-masks-<timestamp>/` before removing
`~/.km`, because hand-grown masks are your work, not KM's.
