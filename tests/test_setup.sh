#!/usr/bin/env bash
#
# KM test suite — pure bash, no dependencies (bats-free by design; the whole repo
# runs on bash + coreutils, so the tests do too). It sources setup.sh with the
# main guard tripped (BASH_SOURCE != $0), exercises every function that is pure
# over injected I/O — SSH-string surgery, planning, the catalog, command shaping,
# state, and the models.json writer — and asserts the results. No box, no network.
#
# Run:  bash tests/test_setup.sh          (exit 0 = green)
#
# Many assignments below (GPU_COUNT, GPU_TOTAL_GB, COMPUTE_CAP, FREE_BYTES, …) are
# read by the functions we source from setup.sh via global scope. The linter
# cannot see that cross-file use and would flag them as unused; they are not. This
# file-wide directive must sit before the first command to apply globally.
# shellcheck disable=SC2034
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$HERE/../setup.sh"

# isolate all state under a scratch HOME so we never touch the real ~/.km or ~/.pi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

# shellcheck source=/dev/null
source "$SETUP"   # main() does not run: BASH_SOURCE[0] != $0 while sourced

PASS=0; FAIL=0
eq()   { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL %s\n  got:  [%s]\n  want: [%s]\n' "$1" "$2" "$3"; fi; }
truthy() { if eval "$2" >/dev/null 2>&1; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL %s (expected success: %s)\n' "$1" "$2"; fi; }
falsy()  { if eval "$2" >/dev/null 2>&1; then FAIL=$((FAIL+1)); printf 'FAIL %s (expected failure: %s)\n' "$1" "$2"; else PASS=$((PASS+1)); fi; }
has()  { case "$2" in *"$3"*) PASS=$((PASS+1));; *) FAIL=$((FAIL+1)); printf 'FAIL %s\n  [%s] does not contain [%s]\n' "$1" "$2" "$3";; esac; }

echo "== SSH-string surgery =="
conn_args -p 24439 root@1.2.3.4 -L 8080:localhost:8080
eq "conn_args drops -L forward" "${CARGS[*]}" "-p 24439 root@1.2.3.4"
conn_args -p 22 root@h -N -L8080:localhost:8080
eq "conn_args drops -N and combined -L" "${CARGS[*]}" "-p 22 root@h"

truthy "parse_forward accepts 3-part" 'parse_forward -p 1 h -L 8080:localhost:9090'
eq "  local" "$FWD_LOCAL" "8080"; eq "  rhost" "$FWD_RHOST" "localhost"; eq "  rport" "$FWD_RPORT" "9090"
truthy "parse_forward accepts 2-part" 'parse_forward -L 5000:7000'
eq "  2-part rhost defaults" "$FWD_RHOST" "127.0.0.1"
falsy "parse_forward rejects missing -L" 'parse_forward -p 22 root@h'
falsy "parse_forward rejects bad port"  'parse_forward -L a:b:c'

SSH_ARGS=(-p 24439 root@1.2.3.4 -L 8080:localhost:8080); replace_forward 18080
eq "replace_forward split form" "${SSH_ARGS[*]}" "-p 24439 root@1.2.3.4 -L 8080:localhost:18080"
SSH_ARGS=(-p 22 root@h -L8080:localhost:8080); replace_forward 18080
eq "replace_forward combined form" "${SSH_ARGS[*]}" "-p 22 root@h -L8080:localhost:18080"

echo "== catalog =="
eq "default model is glm" "$DEFAULT_MODEL" "glm"
eq "glm served name" "${M_SERVED[glm]}" "glm-4.7-flash"
eq "glm is llama_cpp" "${M_SERVER[glm]}" "llama_cpp"
eq "hermes is vllm" "${M_SERVER[hermes]}" "vllm"
eq "seven rows" "${#MODELS[@]}" "7"
eq "no dead glm-q5 row" "${M_LABEL[glm-q5]:-absent}" "absent"
eq "glm-q6 serves Q6_K (real quant)" "${M_GGUF_QUANT[glm-q6]}" "Q6_K"
eq "smaller_quants(glm) ascending" "$(smaller_quants glm | awk '{print $1}' | paste -sd, -)" "glm-q4,glm-q6"

echo "== plan: tiers, util, refusal, suggestion =="
GPU_COUNT=1; GPU_TOTAL_GB=79
truthy "plan glm fits at 79GB (floor 66)" 'plan glm'
eq "  tier <80 -> 16384" "$PLAN_MAXLEN" "16384"
eq "  util >=72 -> 0.92" "$PLAN_UTIL" "0.92"
GPU_COUNT=1; GPU_TOTAL_GB=70
plan glm >/dev/null 2>&1; eq "  util <72 -> 0.95" "$PLAN_UTIL" "0.95"
GPU_COUNT=4; GPU_TOTAL_GB=320
truthy "plan glm at 320GB" 'plan glm'; eq "  beyond all tiers -> 131072" "$PLAN_MAXLEN" "131072"; eq "  tp = gpu count" "$PLAN_TP" "4"
GPU_COUNT=1; GPU_TOTAL_GB=40
falsy "plan glm refuses 40GB (floor 66)" 'plan glm'
has "  refusal suggests highest fitting quant (glm-q6, 34<=40)" "$CONN_WHY" "glm-q6"
GPU_COUNT=1; GPU_TOTAL_GB=10
falsy "plan glm refuses 10GB" 'plan glm'
has "  tiny box told to rent bigger" "$CONN_WHY" "won't fit"

echo "== command shaping =="
has "llama_cmd glm uses --hf-repo/--hf-file" "$(_llama_cmd glm 131072 8080)" "--hf-file GLM-4.7-Flash-Uncensored-HauhauCS-Balanced-FP16.gguf"
has "llama_cmd glm has --alias" "$(_llama_cmd glm 131072 8080)" "--alias glm-4.7-flash"
has "llama_cmd glm has --jinja" "$(_llama_cmd glm 131072 8080)" "--jinja"
has "llama_cmd glm-q4 uses -hf repo:quant" "$(_llama_cmd glm-q4 16384 8080)" ":Q4_K_M"
has "llama_cmd glm-q6 uses -hf repo:Q6_K" "$(_llama_cmd glm-q6 16384 8080)" ":Q6_K"
has "vllm_cmd hermes serves repo" "$(_vllm_cmd hermes 2 65536 0.92 8080)" "serve NousResearch/Hermes-4.3-36B"
has "vllm_cmd hermes tensor-parallel" "$(_vllm_cmd hermes 2 65536 0.92 8080)" "--tensor-parallel-size 2"
has "vllm_cmd hermes tool-call-parser" "$(_vllm_cmd hermes 2 65536 0.92 8080)" "--tool-call-parser hermes"

echo "== weights byte parsing (disk gate reads the DOWNLOAD size) =="
eq "glm weights ~62GB" "$(_weights_bytes glm)" "62000000000"
# vLLM rows must report the BF16 DOWNLOAD size, not the resident FP8 size, or the
# disk gate green-lights a box that dies mid-download (the exact failure it exists
# to prevent).
eq "hermes weights ~72GB BF16 download (not 37 resident)" "$(_weights_bytes hermes)" "72000000000"
eq "qwen-official weights ~56GB BF16 download (not 27 resident)" "$(_weights_bytes qwen-official)" "56000000000"

echo "== preflight (pure, injected values) =="
COMPUTE_CAP="7.5"; falsy "capability vetoes FP8 on cc 7.5" 'capability_preflight hermes'; has "  names the fix" "$PF_MSG" "GGUF"
COMPUTE_CAP="9.0"; truthy "capability passes FP8 on Hopper" 'capability_preflight hermes'
COMPUTE_CAP="7.5"; truthy "capability ignores cc for GGUF rows" 'capability_preflight glm'
FREE_BYTES=$((5*1000000000));  falsy "disk vetoes 5GB free for glm (~62GB)" 'disk_preflight glm'
FREE_BYTES=$((200*1000000000)); truthy "disk passes 200GB free for glm" 'disk_preflight glm'
# regression: a 45GB box must now be REFUSED for hermes (72GB BF16 download), the
# case that previously slipped through when the note quoted the 37GB resident size.
FREE_BYTES=$((45*1000000000)); falsy "disk vetoes 45GB free for hermes (72GB download)" 'disk_preflight hermes'
FREE_BYTES=$((90*1000000000)); truthy "disk passes 90GB free for hermes" 'disk_preflight hermes'

echo "== models.json writer (valid JSON, honest DEMO) =="
export PI_DIR="$TMP/pi"; MODELS_JSON="$PI_DIR/models.json"
wire_models_json "glm-4.7-flash" "" 131072 >/dev/null
has "DEMO id when no port" "$(cat "$MODELS_JSON")" "glm-4.7-flash-DEMO"
has "km-box provider present" "$(cat "$MODELS_JSON")" '"km-box"'
has "compat flags off" "$(cat "$MODELS_JSON")" '"supportsDeveloperRole": false'
if command -v python3 >/dev/null 2>&1; then
  truthy "DEMO models.json is valid JSON" "python3 -c 'import json;json.load(open(\"$MODELS_JSON\"))'"
fi
M_LABEL_ONELINE="glm-4.7-flash (KM box)" wire_models_json "glm-4.7-flash" 8080 131072 >/dev/null
has "attached baseUrl has real port" "$(cat "$MODELS_JSON")" "http://localhost:8080/v1"
has "attached id is not DEMO" "$(cat "$MODELS_JSON")" '"id": "glm-4.7-flash"'
if command -v python3 >/dev/null 2>&1; then
  truthy "attached models.json is valid JSON" "python3 -c 'import json;json.load(open(\"$MODELS_JSON\"))'"
fi

echo "== state round-trip =="
export STATE="$TMP/state.json"
STATE_SERVED=true STATE_BASE_URL="http://localhost:8080/v1" STATE_MODEL="glm-4.7-flash" \
  STATE_MODEL_KEY="glm" STATE_LOCAL_PORT=8080 STATE_REMOTE_PORT=18080 \
  STATE_TUNNEL_PID=4242 STATE_SSH_CONN="-p 22 root@h" save_state
eq "state served" "$(state_get served)" "true"
eq "state base_url" "$(state_get base_url)" "http://localhost:8080/v1"
eq "state local_port" "$(state_get local_port)" "8080"
eq "state tunnel_pid" "$(state_get tunnel_pid)" "4242"
eq "state ssh_conn" "$(state_get ssh_conn)" "-p 22 root@h"
if command -v python3 >/dev/null 2>&1; then
  truthy "state.json is valid JSON" "python3 -c 'import json;json.load(open(\"$STATE\"))'"
fi

echo "== Herald: cockpit state + mask files =="
export KM_HOME="$TMP/km"; HERALD_STATE="$KM_HOME/herald.json"; MASKS_DIR="$KM_HOME/masks"
mkdir -p "$MASKS_DIR"
eq "herald_get on a missing file is empty" "$(herald_get gear)" ""
printf '{\n  "gear": "brake",\n  "mask": "archivist",\n  "seat": "xai/grok-4.5"\n}\n' > "$HERALD_STATE"
eq "herald gear"  "$(herald_get gear)" "brake"
eq "herald mask"  "$(herald_get mask)" "archivist"
eq "herald seat"  "$(herald_get seat)" "xai/grok-4.5"
printf '{\n  "gear": "drive",\n  "mask": null,\n  "seat": "km-box/glm-4.7-flash"\n}\n' > "$HERALD_STATE"
eq "bare mask reads as null" "$(herald_get mask)" "null"
eq "seat with a slash survives"  "$(herald_get seat)" "km-box/glm-4.7-flash"
if command -v python3 >/dev/null 2>&1; then
  truthy "herald.json is valid JSON" "python3 -c 'import json;json.load(open(\"$HERALD_STATE\"))'"
fi
# the extension writes this file; the launcher (bin/herald) reads it back with the
# same sed idiom. Prove the two agree on the shape.
HERALD_BIN="$HERE/../herald/bin/herald"
truthy "herald launcher is executable" "[ -x '$HERALD_BIN' ]"
truthy "herald launcher parses syntactically" "bash -n '$HERALD_BIN'"
eq "launcher reads the seat the extension wrote" \
   "$(KM_HOME="$KM_HOME" bash "$HERALD_BIN" --seat)" "herald seat: km-box/glm-4.7-flash"
KM_HOME="$KM_HOME" bash "$HERALD_BIN" --seat xai/grok-4.5 >/dev/null
eq "launcher --seat writes a seat setup.sh can read back" "$(herald_get seat)" "xai/grok-4.5"
eq "  and leaves the gear alone" "$(herald_get gear)" "drive"
eq "  and leaves a bare mask bare" "$(herald_get mask)" "null"
printf '{\n  "gear": "empty",\n  "mask": "surveyor",\n  "seat": "a/b"\n}\n' > "$HERALD_STATE"
KM_HOME="$KM_HOME" bash "$HERALD_BIN" --seat c/d >/dev/null
eq "launcher --seat preserves a worn mask" "$(herald_get mask)" "surveyor"
eq "launcher --seat preserves the gear"    "$(herald_get gear)" "empty"

echo "== Herald: the shipped pieces exist =="
truthy "herald extension ships"  "[ -f '$HERE/../pi/extensions/herald/index.ts' ]"
truthy "herald contract ships"   "[ -f '$HERE/../herald/HERALD.md' ]"
eq "herald is in the extension install list" \
   "$(printf '%s\n' "${PI_EXTENSIONS[@]}" | grep -c '^herald$')" "1"
# The spec is explicit: the base stays pi's four tools. The Herald is allowed
# the two mask controls and the one summon, and nothing else. If this list ever
# grows, that is a decision, not an accident.
eq "herald registers exactly the mask controls and the summon" \
   "$(grep -o 'name: "[a-z_]*"' "$HERE/../pi/extensions/herald/index.ts" | sed 's/name: //;s/"//g' | sort | paste -sd, -)" \
   "agent_summon,mask_create,mask_wear"

# The summon's contract with the child, in four flags. Each one is load-bearing:
# drop --no-extensions and the cockpit loads in the agent and switches its tools
# off; drop --no-context-files and AGENTS.md loads behind the call-center file,
# which then is not the source of truth. detached is what makes the gear hard —
# abort signals the group, so the agent's own children die with it.
HERALD_TS="$HERE/../pi/extensions/herald/index.ts"
has "summon gives the agent the four core tools" "$(cat "$HERALD_TS")" '"read,write,edit,bash"'
has "summon keeps the cockpit out of the child"  "$(cat "$HERALD_TS")" '"--no-extensions"'
has "summon keeps AGENTS.md out of the child"    "$(cat "$HERALD_TS")" '"--no-context-files"'
has "summon spawns the agent in its own group"   "$(cat "$HERALD_TS")" "detached: true"
has "abort signals the group, not just the pi"   "$(cat "$HERALD_TS")" "process.kill(-pid, sig)"
has "the extension stands down inside an agent"  "$(cat "$HERALD_TS")" 'process.env.KM_HERALD_CHILD === "1"'

echo "== Herald: brake replaced debate =="
# Debate was a stop-gear that switched the tools off and left nothing behind.
# Brake is the same stop with a checkpoint, and it is the *extension* that writes
# the file — a stop the model has to summarise first is not a stop.
has "the gears are drive · brake · empty" "$(cat "$HERALD_TS")" 'Gear = "drive" | "brake" | "empty"'
has "the brake writes the checkpoint itself"   "$(cat "$HERALD_TS")" "writeCheckpoint(state, previous, asked, calls, interrupted)"
has "drive is handed the open checkpoint"      "$(cat "$HERALD_TS")" "openCheckpoint()"
has "  and marks it taken, once"               "$(cat "$HERALD_TS")" "closeCheckpoint(cp.path, cp.text)"
has "checkpoints land in the Operator's map"   "$(cat "$HERALD_TS")" 'join(KARTE_DIR, "checkpoints")'
has "a state file left in debate comes up braked" "$(cat "$HERALD_TS")" 'RETIRED: Record<string, Gear> = { debate: "brake" }'
# Nothing the Operator reads may still offer the retired gear. Two files still say
# the word, and both only to retire it: herald/README.md documents the change, and
# setup.sh translates an old state file when it reports the gear.
for f in README.md pi/README.md herald/HERALD.md herald/bin/herald; do
  eq "no debate gear left in $f" "$(grep -ci 'debate' "$HERE/../$f" || true)" "0"
done
eq "setup.sh says debate once, to retire it" "$(grep -ci 'debate' "$HERE/../setup.sh" || true)" "1"
has "  and km --check translates it" "$(grep -i 'debate' "$HERE/../setup.sh")" 'gear="brake (was debate — retired)"'
has "the retirement is documented" "$(cat "$HERE/../herald/README.md")" "Debate is retired"
has "so is the brake, where the gears are"  "$(cat "$HERE/../herald/README.md")" "checkpoint"
has "and in the contract the model reads"   "$(cat "$HERE/../herald/HERALD.md")" "**Brake**"

echo "== the agent: call-center file and the parked improvisation =="
export KM_KARTE="$TMP/karte"; KARTE_DIR="$KM_KARTE"; CALLCENTER="$KARTE_DIR/callcenter.md"
CHECKPOINTS="$KARTE_DIR/checkpoints"
KM_AGENT="smith"; PARKED_DIR="$KM_HOME/parked"
install_callcenter >/dev/null
truthy "install_callcenter creates the map directory" "[ -d '$KARTE_DIR' ]"
truthy "install_callcenter creates the call-center file" "[ -f '$CALLCENTER' ]"
has "  and names the agent in it" "$(cat "$CALLCENTER")" "smith"
# The Operator curates this file by hand. A re-run must never write over it.
printf 'MINE — do not touch\n' > "$CALLCENTER"
install_callcenter >/dev/null
eq "a second install leaves the Operator's file alone" "$(cat "$CALLCENTER")" "MINE — do not touch"

# The improvised subagent extension is moved aside, not deleted.
mkdir -p "$PI_DIR/extensions/subagent" "$PI_DIR/extensions/gpu-status"
printf 'improvised\n' > "$PI_DIR/extensions/subagent/index.ts"
park_improvised_subagents >/dev/null
falsy "park removes the improvised subagent from pi's path" "[ -d '$PI_DIR/extensions/subagent' ]"
truthy "park keeps our own extensions" "[ -d '$PI_DIR/extensions/gpu-status' ]"
eq "park moves it aside rather than deleting it" \
   "$(cat "$PARKED_DIR"/subagent-*/index.ts 2>/dev/null)" "improvised"
truthy "park is a no-op when there is nothing to park" "park_improvised_subagents"

echo "== the brake: where the checkpoints land =="
# The brake's checkpoints share the Operator's map with the call-center file, so
# install makes the directory whether or not anything has braked yet.
truthy "install makes the checkpoint directory a signpost" "[ -d '$CHECKPOINTS' ]"
eq "no checkpoint until something brakes" "$(latest_checkpoint)" ""
printf 'first\n'  > "$CHECKPOINTS/2026-07-28T10-00-00-000Z.md"
printf 'second\n' > "$CHECKPOINTS/2026-07-28T11-00-00-000Z.md"
# Names are ISO timestamps, so the newest checkpoint is simply the last name —
# no stat(1), whose flags differ between GNU and BSD.
eq "the newest checkpoint is the last name" \
   "$(latest_checkpoint)" "$CHECKPOINTS/2026-07-28T11-00-00-000Z.md"

echo
echo "----------------------------------------"
printf 'PASS %d  ·  FAIL %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL GREEN"
