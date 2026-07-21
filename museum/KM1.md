# MoRE / KM1 — the cathedral

- **Repo:** https://github.com/Ari6six6/KM1
- **Grade:** the cathedral — our most complete work, and too heavy.
- **Fossil position:** the immediate parent. KM is its child and its editor.

KM1 (shipped as **MoRE**) is the most complete thing this line ever built. A small,
honest, multi-agent CLI harness for local LLMs: a crew of agents sharing one
workspace and one transcript, taking turns by name, steered from the top. But it
was far more than a chat loop:

- **Work orders** that deliver files, durably.
- A **daemon** that survives its own `kill -9`.
- A **cost ledger** — wallet-safe, per-minute, because rental money is real.
- **Memory** and a daily ritual.
- A **night shift** that improves its own source under a benchmark it cannot game.
- A **dashboard** — the whole realm rendered as one page you can point at.
- Every subsystem an append-only event log you can `cat`; every claim covered by a
  test; every piece running offline, labelled `DEMO`, until you gave it a model.

And it was *tested against attack.* KM1 survived adversarial audits — see
`docs/KM1_AUDIT.pdf`, the audit response, and the rejoinder. It did not merely
claim to work; it defended the claim.

So why is its child so much smaller?

Because a harness is a means, not an end. In the year KM1 was built, `pi` shipped:
a minimal, self-extending harness that does — leaner and better — most of what
KM1's harness layer did, and gives it away. KM1 built a cathedral in the season the
world started handing out cathedrals for free. That is not a failure of
craftsmanship. It is a failure of *timing*, which is the most expensive kind, and
the most honest to admit.

The audits found KM1's harness solid. They also, implicitly, asked the question
that made KM: *of everything here, what is truly ours — the part no one else
shipped better?* One answer survived clean every time: the **GPU provisioning
module.** `gpu.py`, `gpucmd.py`, `preflight.py`, `models.py`, `tunnel.py` — the
one perfect organ.

So KM keeps the organ and lets the rest rest. Not deleted, not disowned — *rested.*
KM1 is right here, one repository away, the whole cathedral intact for anyone who
wants to walk it. We simply stopped worshipping in it. We took the one thing that
was ours, transplanted it into the harness the world already built, and spent the
rest of our effort on lore, context, and speed.

That is the synthesis KM is: **their GPU module · pi's harness · our lore.** KM1 is
the parent that made it possible, and the cathedral we chose not to build again.
