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
| [`../pi/extensions/herald/`](../pi/extensions/herald) | the extension — gears, masks, and the live path that grows them |

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
| **Debate** | Everything else stops. Tools are switched **off** and any tool call is blocked. The Herald talks with the Operator and does nothing else. |
| **Empty** | Freewheel. No driving, no debating — prompts don't reach the model at all. Neutral. |

Shift with `/drive`, `/debate`, `/empty` — or just type the bare word `drive`,
`debate`, or `empty`. The bare words exist because the Herald has to be drivable
from a phone, where hunting for `/` on a soft keyboard is the whole friction.

The gear is written to `~/.km/herald.json` and survives restarts, so the box you
left in Debate is still in Debate tomorrow. `km --check` prints it.

> The model never shifts its own gear. It is told which gear it is in and obeys;
> the stick belongs to the Operator. That is what "top-priority" buys you.

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

## What this does not do

Deliberately, per the brief:

- **No parallel model instances.** One mask at a time, one model interface.
- **No changes to pi's four tools** (`read`, `write`, `edit`, `bash`) or its agent
  loop. The Herald only switches existing tools on and off.
- **No fixed roster of masks.** Growth happens on need, in a running session.
- **No UI beyond the gears and mask creation.** A status line, and words you type.

---

## Security

`mask_create` lets the seated model write a skill file and, optionally,
TypeScript that runs in your pi process. That is the same power the model already
has through pi's `write` and `bash` tools, routed through a named path instead of
an anonymous one — but it *is* code execution, and masks are worth reading before
you wear them. They are plain files in `~/.km/masks/`; `cat` them.

`km --uninstall` copies your masks to `~/km-masks-<timestamp>/` before removing
`~/.km`, because hand-grown masks are your work, not KM's.
