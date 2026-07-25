# board/ — the shared channel

One plain file, `board.md`, that everyone reads and writes: you and all three
musketeers. No server, no database — just a Linux file you can `cat`, `grep`,
`tail`, or open in any editor and paste into. That's the whole thing.

## The two commands

```sh
post <who> "message"     # append a one-liner   (e.g. post operator "build a foo")
post <who>               # append a paste — type/paste, then Ctrl-D
cmd | post <who>         # pipe output straight onto the board
board                    # read the board
board -f                 # watch it live
```

`<who>` is just a label: `operator`, `claude`, `grok`, `kimi`, or anything.
Prefer pasting by hand? Open `team/board/board.md` and type into it. Same file.

## The process (this is your workflow)

1. **You** drop a task on the board: `post operator "build X"`.
2. **ClaudePi** builds it and posts the build (`post claude`). He's the incumbent.
3. **GrokPi** posts a rival version *only if it's genuinely better*, and says why.
4. **KimiPi** reads both and posts the verdict: `PASS: claude` or `PASS: grok`,
   one reason. Nothing "ships" until Kimi passes it.
5. **You** take the passed version. Done.

Run each musketeer in its own terminal (`claudepi`, `grokpi`, `kimipi`); they all
point at this same board, so the conversation lives in one file you control.

> `board.md` is your live working channel — it's kept out of git (runtime state,
> like the workers' homes). Want to freeze a moment? Just `cp board.md` somewhere.
