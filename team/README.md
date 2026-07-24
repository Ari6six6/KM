# team/ — the KM three-musketeer crew

Three `pi` instances, three locked personalities, one box. Run them in separate
terminals against the same project and let each be who it is.

| Command    | Persona  | Role |
|------------|----------|------|
| `grokpi`   | GrokPi   | The adult in the room. Primary coding lead — writes real code, makes the calls, drives. |
| `claudepi` | ClaudePi | The process babysitter and quality gate. Questions requirements, nags about tests/structure. Polite but relentless. |
| `kimipi`   | KimiPi   | The silent observer. Stays quiet until something's actually broken or you're stuck — then unblocks you, fast. |

The contracts are the three markdown files in [`personas/`](personas). Each
launcher in [`bin/`](bin) hands its persona to `pi` with `--system-prompt`, so the
personality is fixed the moment the session starts. Edit a persona file to tune a
voice; the launchers read it fresh every run — nothing to rebuild.

## Isolated session trees

Each musketeer runs with its **own Pi home** under `team/homes/<name>/`
(`export HOME=…` in the launcher). So GrokPi, ClaudePi and KimiPi keep separate
session histories, settings, and state — they never step on each other, even
pointed at the same project. `team/homes/` is runtime state and stays out of git.

> Note: because the home is isolated, a persona does **not** pick up your global
> `~/.pi/agent/AGENTS.md` context. That's deliberate — the persona *is* the
> prompt. Want the KM lore in a musketeer too? Symlink it once:
> `ln -s ~/.pi team/homes/grok/.pi` (repeat per home).

## Install & use

```bash
./install-team.sh        # symlinks grokpi/claudepi/kimipi into ~/.local/bin
                         # and creates the per-persona homes under team/homes/

cd your-project
grokpi                   # your primary driver
claudepi                 # a second terminal — the babysitter
kimipi                   # a third — only when something's on fire
```

Requires `pi` on your PATH — install it with KM's [`setup.sh`](../setup.sh).
