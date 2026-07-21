# Hermes — good bones

- **Repo:** hermes-projects (the original provisioner)
- **Grade:** good bones.
- **Fossil position:** where the one perfect organ was born.

Hermes was the provisioner that got the hard part right. Its `provision.py` is the
direct ancestor of `gpu.py` — the SSH-string surgery, the apt/net retry shims that
wait out a fresh box's dpkg locks and DNS blips, the CUDA-environment discovery
that stops the linker from dying on stubs, the vLLM and llama.cpp launch paths, the
readiness poll that draws a download bar and bails on a dead process. Nearly every
scar in KM's provisioning brain was first cut here.

If MoR proved it was *possible*, Hermes proved it could be *reliable* — that a
provisioner could survive the specific, maddening ways a rented box misbehaves in
its first minute of life, and keep going instead of falling over.

Hermes has good bones because its bones are still load-bearing. The organ KM
transplants into `pi` is Hermes's organ, ported through KM1 and hardened by
audits, but Hermes-shaped underneath. When you read `gpu.py`'s comments about
`kex_exchange_identification` or `libcublas.so.NN`, you are reading lessons Hermes
learned first.

We keep the bones and let the rest rest. A provisioner is not a harness, and
Hermes never pretended to be one — which, in hindsight, was wisdom the cathedral
that came after it forgot for a while.
