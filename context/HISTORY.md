# HISTORY — the line you stand at the end of

An honest chronicle, so you understand why this repo is deliberately small.

## The line

```
MoR  →  Hermes / rig  →  MoRE / KM1  →  KM (you are here)
```

Five ancestors, one per season of a single project: a man on a phone trying to
will a thinking machine onto hardware he rents by the hour, and improve the
machine that builds the machine. Each ancestor is graded honestly in `museum/`.
None is a failure. Each is an iteration that bought knowledge.

## July 2026, in brief

- **MoR** — the seed. Zero-dependency Python, `scp`-to-box workflow. It proved the
  Master could summon a system into existence from Termux on an Android phone.
  Pretty good for its time.
- **Hermes / rig** — the provisioners. `gpu.py`, KM's one perfect organ, was born
  here. `rig` reached too far (v1–v4) and died of ambition — the super-harness
  dream that never shipped.
- **MoRE / KM1** — the cathedral. Our most complete work: a multi-agent realm with
  work orders, a daemon that survives its own `kill -9`, a night shift that
  improves its own source under a benchmark it cannot game, a cost ledger, a
  dashboard. It survived adversarial audits (`docs/KM1_AUDIT.pdf`, the audit
  response, the rejoinder). It was *good*. It was also **too heavy.** We built a
  cathedral in the year the world shipped `pi`.

## The turn that made KM

Two lessons, learned the hard way, made this repo:

1. **We are provisioners, not harness-smiths.** Of everything KM1 built, exactly
   one organ survived every audit clean: the GPU module. The rest was a harness —
   and a minimal, self-extending harness (`pi`) already exists, built better than
   we would build it. So we stopped competing with it.
2. **One perfect organ beats five cathedrals.** We keep the organ (GPU
   provisioning), transplant it into `pi`, and spend the rest of our effort on
   the things only we have: the Master's context, the lore, and the speed from
   rental-receipt to first thinking turn.

KM is the synthesis: **their GPU module · pi's harness · our lore.** It is small
on purpose. When you feel the urge to make it bigger, re-read this file. `main`
is not a museum — but it does have one, right next door, so we never forget what
the cathedrals cost.
