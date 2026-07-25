# LESSONS — the museum distilled to rules

Every rule below was paid for. Break one and you will re-pay it.

## Provisioning

- **Paste-one-string UX or death.** The Master's whole interface is pasting the
  vast.ai SSH line. Anything that makes him re-type a port, a host, or a forward
  is a regression. When the server slides to a free port, *the tunnel follows it*
  — he does not re-type anything.
- **Fail in seconds, not rental-hours.** Preflight before spending a cent:
  compute-capability vs. the model, free disk vs. the weights, and a ~3-second
  Hugging Face check that the repo and the exact GGUF file resolve. A bad row must
  fail at second three, never at minute thirty of a paid H100.
- **The linker lies about CUDA.** A non-interactive `ssh host "cmd"` never sources
  `.bashrc`, so the box's CUDA exports never apply and `llama-server` dies on exec
  with "cannot open shared object file" — which looks *exactly* like a hung
  download bar. Register the toolkit dirs into `ld.so.conf` (`cuda-km.conf`) and
  export them into the build shell. Both. Belt and suspenders.
- **A booting box resets before it refuses.** `kex_exchange_identification`,
  "reset by peer", "connection refused", a 30s timeout — these are a fresh box
  still coming up. Retry them. "Permission denied" is a wrong key — never retry it.
- **A recycled PID is not a running server.** After a reboot a stray process can
  inherit the old PID. "Serving" means the PID is alive **and** its cmdline is
  `vllm` or `llama-server`. Check both.
- **A dead process looks like a slow download.** If the server crashed on exec,
  the readiness bar sits at 0% forever. After the warm-up window, if the process
  is gone, bail immediately with `tail vllm.log` — do not wait out the deadline
  on a corpse.
- **vast.ai squats 8080.** Kill orphans, and if the port is still held, slide the
  server to `port+10000` and move the forward with it. Never bind-fail in silence.

## Honesty

- **A 200 from `/v1/models` is not a mind.** "Up" must mean the model can work a
  real tool call, not merely that the endpoint lists models. Run the canary. If it
  answers but cannot think, say so and point at `--tool-call-parser`.
- **Anything not live is labelled `DEMO`.** Inherited from MoRE. If no box is
  attached, the served model is `DEMO` until one is. Never dress up an empty
  socket as a working model.

## Shape

- **One perfect organ beats five cathedrals. When in doubt, delete.** KM is one
  script and a context package. If a feature wants to become a subsystem, ask
  whether `pi` already does it, or whether it belongs in an extension instead.
- **Zero dependencies beyond a fresh Ubuntu image.** bash + ssh + curl +
  coreutils. The law from MoR. It is why the script runs on a box you rented
  ninety seconds ago.
- **`--system-prompt` replaces; it does not add.** Handing pi a persona that way
  silently deletes pi's own prompt — the tool discipline goes with it. Roles
  belong in the context package (`~/.pi/agent/AGENTS.md`), which is *appended*.
  This is what the three-terminal crew cost before it was folded into one agent.
