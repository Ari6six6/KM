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
eq "smaller_quants(glm) ascending" "$(smaller_quants glm | awk '{print $1}' | paste -sd, -)" "glm-q4,glm-q5"

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
has "  refusal suggests highest fitting quant (glm-q5, 30<=40)" "$CONN_WHY" "glm-q5"
GPU_COUNT=1; GPU_TOTAL_GB=10
falsy "plan glm refuses 10GB" 'plan glm'
has "  tiny box told to rent bigger" "$CONN_WHY" "won't fit"

echo "== command shaping =="
has "llama_cmd glm uses --hf-repo/--hf-file" "$(_llama_cmd glm 131072 8080)" "--hf-file GLM-4.7-Flash-Uncensored-HauhauCS-Balanced-FP16.gguf"
has "llama_cmd glm has --alias" "$(_llama_cmd glm 131072 8080)" "--alias glm-4.7-flash"
has "llama_cmd glm has --jinja" "$(_llama_cmd glm 131072 8080)" "--jinja"
has "llama_cmd glm-q4 uses -hf repo:quant" "$(_llama_cmd glm-q4 16384 8080)" ":Q4_K_M"
has "vllm_cmd hermes serves repo" "$(_vllm_cmd hermes 2 65536 0.92 8080)" "serve NousResearch/Hermes-4.3-36B"
has "vllm_cmd hermes tensor-parallel" "$(_vllm_cmd hermes 2 65536 0.92 8080)" "--tensor-parallel-size 2"
has "vllm_cmd hermes tool-call-parser" "$(_vllm_cmd hermes 2 65536 0.92 8080)" "--tool-call-parser hermes"

echo "== weights byte parsing =="
eq "glm weights ~62GB" "$(_weights_bytes glm)" "62000000000"
eq "hermes weights ~37GB" "$(_weights_bytes hermes)" "37000000000"

echo "== preflight (pure, injected values) =="
COMPUTE_CAP="7.5"; falsy "capability vetoes FP8 on cc 7.5" 'capability_preflight hermes'; has "  names the fix" "$PF_MSG" "GGUF"
COMPUTE_CAP="9.0"; truthy "capability passes FP8 on Hopper" 'capability_preflight hermes'
COMPUTE_CAP="7.5"; truthy "capability ignores cc for GGUF rows" 'capability_preflight glm'
FREE_BYTES=$((5*1000000000));  falsy "disk vetoes 5GB free for glm (~62GB)" 'disk_preflight glm'
FREE_BYTES=$((200*1000000000)); truthy "disk passes 200GB free for glm" 'disk_preflight glm'

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

echo
echo "----------------------------------------"
printf 'PASS %d  ·  FAIL %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL GREEN"
