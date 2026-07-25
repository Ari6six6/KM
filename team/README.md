# team/ — the KM crew

Three `pi` instances with locked roles, plus one shared file they all talk on.
Run each in its own terminal, all pointed at the same project.

| Command    | Persona  | Role |
|------------|----------|------|
| `claudepi` | ClaudePi | **The adult in the room — the primary coder.** Builds by default. Whatever ships is his unless something better replaces it. |
| `grokpi`   | GrokPi   | **The challenger.** Only puts code up when it genuinely beats ClaudePi's — and must say why. Doesn't decide what ships. |
| `kimipi`   | KimiPi   | **The judge.** Reads both versions and passes exactly one. Nothing ships until Kimi passes it. |

The contracts are the three markdown files in [`personas/`](personas). Each
launcher in [`bin/`](bin) hands its persona to `pi` with `--system-prompt`.

## The board — your process, in one file

Everyone reads and writes one shared file, `board/board.md`. No server, no
database — a plain Linux file you can `cat`, `grep`, `tail`, or paste into.

```sh
post operator "build X"    # you drop a task
board                      # read the board   (board -f follows it live)
```

The loop: **you** post a task → **ClaudePi** builds → **GrokPi** challenges only
if he's got something better → **KimiPi** passes exactly one → **you** take it.
Full details in [`board/`](board).

## Isolated session trees

Each musketeer runs with its **own Pi home** under `team/homes/<name>/`
(`export HOME=…` in the launcher), so their session histories, settings, and
state never mix — even pointed at the same project. `team/homes/` and the live
`board/board.md` are runtime state, kept out of git.

> Note: because the home is isolated, a persona does **not** pick up your global
> `~/.pi/agent/AGENTS.md` context or your box wiring. Want the KM lore + your GLM
> box in a worker too? Symlink once: `ln -s ~/.pi team/homes/claude/.pi`.

## Install & use

```sh
./install-team.sh          # links claudepi/grokpi/kimipi + post/board into ~/.local/bin,
                           # creates the per-persona homes, seeds the board

cd your-project
claudepi                   # the coder — your default builder
grokpi                     # the challenger — a second terminal
kimipi                     # the judge — a third
```

Requires `pi` on your PATH — install it with KM's [`setup.sh`](../setup.sh).
