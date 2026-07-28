#!/usr/bin/env bash
#
# KM — one script. It turns a rented GPU box + a fresh harness machine into a
# living `pi` coding agent wired to a model you own, in one pasted SSH string.
#
#   curl -fsSL https://raw.githubusercontent.com/Ari6six6/KM/main/setup.sh | bash -s -- \
#       --gpu "-p 24439 root@1.2.3.4 -L 8080:localhost:8080" --model glm
#
# What it does, in order (harness side): install Node -> install pi -> lay down
# ~/.pi/agent config -> provision the GPU box you pasted (detect/plan/preflight/
# install/launch/tunnel/wait) -> wire pi at http://localhost:<port>/v1 -> install
# the context package -> run the canary -> print the three commands to type next.
#
# Dependencies: bash + ssh + curl + coreutils only. Nothing a fresh vast.ai
# Ubuntu image (or a plain Ubuntu VPS) does not already have. This is the law
# inherited from MoR.
#
# The GPU provisioning logic is ported, quirk for quirk, from KM1's mor/gpu.py,
# mor/gpucmd.py, mor/preflight.py, mor/models.py and mor/tunnel.py — every
# oddity below was paid for with a burned rental hour. See museum/KM1.md.
#
set -euo pipefail

# ============================================================================
#  SECTION 0 — constants, paths, honest logging
# ============================================================================

KM_VERSION="1.0.0"
RAW_URL="https://raw.githubusercontent.com/Ari6six6/KM/main/setup.sh"

KM_HOME="${KM_HOME:-$HOME/.km}"
STATE="$KM_HOME/state.json"
TUNNEL_LOG="$KM_HOME/gpu-tunnel.log"

# the Herald (orchestration layer): cockpit state, and the masks it grows
HERALD_STATE="$KM_HOME/herald.json"
MASKS_DIR="$KM_HOME/masks"

# The Operator's map (German: Karte) and the one file inside it the summoned
# agent reads before it does anything else. This is Operator space: KM creates
# it once, and from then on only the Operator writes here.
KARTE_DIR="${KM_KARTE:-$HOME/karte}"
CALLCENTER="${KM_CALLCENTER:-$KARTE_DIR/callcenter.md}"
KM_AGENT="${KM_AGENT:-smith}"
# Where the brake gear leaves a checkpoint: one markdown file per stop, named for
# the moment it was written, so the newest name is the newest checkpoint.
CHECKPOINTS="${KM_CHECKPOINTS:-$KARTE_DIR/checkpoints}"

# Anything KM moves out of the way rather than deletes lands here, with a stamp.
PARKED_DIR="$KM_HOME/parked"

PI_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
MODELS_JSON="$PI_DIR/models.json"

# extensions we install into pi's auto-discovered path (pi/extensions/<name>/)
PI_EXTENSIONS=(gpu-status herald)

# Where the repo (context/, pi/) is read from. When run from a clone this is the
# script's own directory; when run via curl|bash it is fetched into KM_HOME.
SELF_SRC="${BASH_SOURCE[0]:-}"
if [ -n "$SELF_SRC" ] && [ -f "$SELF_SRC" ]; then
  REPO_DIR="$(cd "$(dirname "$SELF_SRC")" && pwd)"
else
  REPO_DIR=""
fi

# colours only on a tty — plain pipes stay plain
if [ -t 1 ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'
  C_D=$'\033[2m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_C=""; C_D=""; C_B=""; C_0=""
fi

step() { printf '%s▸%s %s\n' "$C_C" "$C_0" "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s!%s %s\n' "$C_Y" "$C_0" "$*"; }
info() { printf '%s%s%s\n' "$C_D" "$*" "$C_0"; }
erro() { printf '%s✗%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { erro "$*"; exit 1; }

# ============================================================================
#  SECTION 1 — the model catalog (ported from KM1 mor/models.py)
#
#  One row per model. GLM is the default — the Master's daily driver. Never
#  auto-default to Qwen; keep the rows, but glm leads.
#  context_tiers are "gb:len" pairs, ascending: first threshold total_gb is
#  *below* wins; if it exceeds them all, use BEYOND.
# ============================================================================

MODELS=(glm glm-q4 glm-q6 hermes qwen-official qwen qwen-40b)
DEFAULT_MODEL="glm"

declare -A M_LABEL M_REPO M_SERVED M_MINGB M_TIERS M_BEYOND M_NOTE \
           M_SERVER M_QUANT M_PARSER M_GGUF_FILE M_GGUF_QUANT M_TOKENIZER

_row() { # key label repo served mingb "tiers" beyond "note" server quant parser gguf_file gguf_quant tokenizer
  local k="$1"
  M_LABEL[$k]="$2";  M_REPO[$k]="$3";     M_SERVED[$k]="$4"; M_MINGB[$k]="$5"
  M_TIERS[$k]="$6";  M_BEYOND[$k]="$7";   M_NOTE[$k]="$8";   M_SERVER[$k]="$9"
  M_QUANT[$k]="${10}"; M_PARSER[$k]="${11}"; M_GGUF_FILE[$k]="${12}"
  M_GGUF_QUANT[$k]="${13}"; M_TOKENIZER[$k]="${14}"
}

_row glm \
  "GLM-4.7-Flash (HauhauCS Balanced, uncensored) · FP16 GGUF" \
  "HauhauCS/GLM-4.7-Flash-Uncensored-HauhauCS-Balanced" "glm-4.7-flash" 66 \
  "80:16384 88:32768 100:65536 120:98304" 131072 \
  "first run downloads the ~62GB FP16 GGUF" \
  llama_cpp gguf hermes \
  "GLM-4.7-Flash-Uncensored-HauhauCS-Balanced-FP16.gguf" "" ""

_row glm-q4 \
  "GLM-4.7-Flash (HauhauCS Balanced, uncensored) · Q4_K_M GGUF" \
  "HauhauCS/GLM-4.7-Flash-Uncensored-HauhauCS-Balanced" "glm-4.7-flash" 24 \
  "28:16384 36:32768 56:65536 96:98304" 131072 \
  "first run downloads the ~18GB Q4_K_M GGUF" \
  llama_cpp gguf hermes "" "Q4_K_M" ""

# Q6_K, not Q5_K_M: the HauhauCS repo ships FP16/Q4_K_M/Q6_K/Q8_0 — there is no
# Q5_K_M row to serve (verified live). Q6_K is the mid-tier that actually exists.
_row glm-q6 \
  "GLM-4.7-Flash (HauhauCS Balanced, uncensored) · Q6_K GGUF" \
  "HauhauCS/GLM-4.7-Flash-Uncensored-HauhauCS-Balanced" "glm-4.7-flash" 34 \
  "40:16384 48:32768 68:65536 104:98304" 131072 \
  "first run downloads the ~25GB Q6_K GGUF" \
  llama_cpp gguf hermes "" "Q6_K" ""

_row hermes \
  "Hermes-4.3-36B (NousResearch) · FP8" \
  "NousResearch/Hermes-4.3-36B" "NousResearch/Hermes-4.3-36B" 44 \
  "56:16384 72:32768 96:65536 120:131072 168:196608" 262144 \
  "first run downloads ~72GB BF16, quantized to FP8 on load (~37GB resident)" \
  vllm fp8 hermes "" "" ""

_row qwen-official \
  "Qwen3.6-27B (Alibaba, official) · FP8" \
  "Qwen/Qwen3.6-27B" "qwen3.6-27b-official" 30 \
  "40:32768 56:65536 80:131072 140:196608" 262144 \
  "first run downloads ~56GB BF16, quantized to FP8 on load (~27GB resident)" \
  vllm fp8 hermes "" "" ""

_row qwen \
  "Qwen3.6-27B (HauhauCS Balanced, uncensored) · Q5_K_P GGUF" \
  "HauhauCS/Qwen3.6-27B-Uncensored-HauhauCS-Balanced" "qwen3.6-27b" 22 \
  "28:16384 40:32768 56:65536 96:98304" 131072 \
  "first run downloads the ~19GB Q5_K_P GGUF" \
  llama_cpp gguf hermes \
  "Qwen3.6-27B-Uncensored-HauhauCS-Balanced-Q5_K_P.gguf" "" ""

_row qwen-40b \
  "Qwen3.6-40B (DavidAU, Opus-Deckard Heretic, uncensored) · Q5_K_M GGUF" \
  "DavidAU/Qwen3.6-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking-NEO-CODE-Di-IMatrix-MAX-GGUF" \
  "qwen3.6-40b" 30 \
  "36:16384 48:32768 72:65536 120:98304" 131072 \
  "first run downloads the ~28GB Q5_K_M GGUF" \
  llama_cpp gguf hermes "" "Q5_K_M" ""

list_models() {
  printf '%sKM model catalog%s  (default: %s)\n\n' "$C_B" "$C_0" "$DEFAULT_MODEL"
  local k mark
  for k in "${MODELS[@]}"; do
    [ "$k" = "$DEFAULT_MODEL" ] && mark="${C_G}→${C_0}" || mark=" "
    printf '  %s %s%-14s%s %s\n' "$mark" "$C_C" "$k" "$C_0" "${M_LABEL[$k]}"
    printf '       %sneeds ~%sGB VRAM · %s%s\n' "$C_D" "${M_MINGB[$k]}" "${M_NOTE[$k]}" "$C_0"
  done
  printf '\n  pick with %s--model <key>%s\n' "$C_C" "$C_0"
}

# largest-first list of rows serving the same model at a lower VRAM floor
smaller_quants() { # $1=key ; echoes "key mingb" lines ascending by mingb
  local key="$1" served="${M_SERVED[$1]}" min="${M_MINGB[$1]}" k
  for k in "${MODELS[@]}"; do
    if [ "${M_SERVED[$k]}" = "$served" ] && [ "${M_MINGB[$k]}" -lt "$min" ]; then
      printf '%s %s\n' "$k" "${M_MINGB[$k]}"
    fi
  done | sort -k2 -n
}

# ============================================================================
#  SECTION 2 — SSH-string surgery (ported from gpu.py conn_args / parse_forward
#  / replace_forward). The Master's whole UX is "paste one string"; a malformed
#  paste must never take the shell down with it.
# ============================================================================

# fills global CARGS (connection args, minus -N and the -L forward)
conn_args() {
  CARGS=()
  local -a a=("$@"); local i=0 n=${#a[@]}
  while [ $i -lt $n ]; do
    case "${a[$i]}" in
      -N) : ;;                                   # belongs to the tunnel, drop
      -L) i=$((i+1)) ;;                          # drop -L and its value
      -L?*) : ;;                                 # drop combined -Llp:host:rp
      *) CARGS+=("${a[$i]}") ;;
    esac
    i=$((i+1))
  done
}

# fills FWD_LOCAL FWD_RHOST FWD_RPORT from a -L forward; returns 1 if malformed
parse_forward() {
  local -a a=("$@"); local i=0 n=${#a[@]} val=""
  while [ $i -lt $n ]; do
    case "${a[$i]}" in
      -L)   [ $((i+1)) -lt $n ] && val="${a[$((i+1))]}"; break ;;
      -L?*) val="${a[$i]#-L}"; break ;;
    esac
    i=$((i+1))
  done
  [ -n "$val" ] || return 1
  local -a bits; IFS=':' read -r -a bits <<< "$val"
  case ${#bits[@]} in
    3) FWD_LOCAL="${bits[0]}"; FWD_RHOST="${bits[1]}"; FWD_RPORT="${bits[2]}" ;;
    2) FWD_LOCAL="${bits[0]}"; FWD_RHOST="127.0.0.1"; FWD_RPORT="${bits[1]}" ;;
    *) return 1 ;;
  esac
  case "$FWD_LOCAL$FWD_RPORT" in *[!0-9]*) return 1 ;; esac
  [ -n "$FWD_RHOST" ] || return 1
  [ "$FWD_LOCAL" -ge 1 ] && [ "$FWD_LOCAL" -le 65535 ] || return 1
  [ "$FWD_RPORT" -ge 1 ] && [ "$FWD_RPORT" -le 65535 ] || return 1
  return 0
}

# rewrites SSH_ARGS in place, swapping the -L forward's box-side (remote) port —
# when the launch slides the server to a free port, the tunnel must follow it.
replace_forward() { # $1=new_remote_port ; edits global SSH_ARGS
  local new="$1" i=0 n=${#SSH_ARGS[@]}
  while [ $i -lt $n ]; do
    case "${SSH_ARGS[$i]}" in
      -L)
        if [ $((i+1)) -lt $n ]; then
          local -a b; IFS=':' read -r -a b <<< "${SSH_ARGS[$((i+1))]}"
          b[$(( ${#b[@]} - 1 ))]="$new"
          SSH_ARGS[$((i+1))]="$(IFS=':'; printf '%s' "${b[*]}")"
        fi
        return 0 ;;
      -L?*)
        local -a b; IFS=':' read -r -a b <<< "${SSH_ARGS[$i]#-L}"
        b[$(( ${#b[@]} - 1 ))]="$new"
        SSH_ARGS[$i]="-L$(IFS=':'; printf '%s' "${b[*]}")"
        return 0 ;;
    esac
    i=$((i+1))
  done
}

# ============================================================================
#  SECTION 3 — remote exec + the apt/net/cuda shims (lifted from gpu.py)
# ============================================================================

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

# rrun "<command>" [timeout] -> sets RC, ROUT, RERR ; never trips set -e
rrun() {
  local cmd="$1" to="${2:-120}"
  set +e
  ROUT="$(timeout "$to" ssh "${SSH_OPTS[@]}" "${CARGS[@]}" "$cmd" 2>"$KM_HOME/.rerr")"
  RC=$?
  set -e
  RERR="$(cat "$KM_HOME/.rerr" 2>/dev/null || true)"
  return 0
}

# apt-get waits out the dpkg lock a fresh box's unattended-upgrades holds (60×5s);
# network ops wait out DNS blips (24×5s). Already bash in KM1 — lifted verbatim.
_APT_WAIT='apt_wait() { for _i in $(seq 1 60); do apt-get "$@" 2>/tmp/.km_apt && return 0; grep -q "Could not get lock\|is held by process" /tmp/.km_apt || { cat /tmp/.km_apt >&2; return 1; }; sleep 5; done; cat /tmp/.km_apt >&2; return 1; }; '
_NET_WAIT='net_wait() { for _i in $(seq 1 24); do "$@" 2>/tmp/.km_net && return 0; grep -qiE "could not resolve host|temporary failure in name resolution|network is unreachable|could not connect to|connection timed out" /tmp/.km_net || { cat /tmp/.km_net >&2; return 1; }; sleep 5; done; cat /tmp/.km_net >&2; return 1; }; '
# A non-interactive `ssh host "cmd"` never sources .bashrc, so the box's CUDA
# exports never apply and the linker falls back to broken stubs — "undefined
# reference to ...@libcublas.so.NN". Find the real toolkit dirs and export them.
_CUDA_ENV='for _d in /usr/local/cuda*/lib64 /usr/local/cuda*/targets/*/lib; do [ -d "$_d" ] && export LD_LIBRARY_PATH="$_d:$LD_LIBRARY_PATH" LIBRARY_PATH="$_d:$LIBRARY_PATH"; done; for _b in /usr/local/cuda*/bin; do [ -d "$_b" ] && export PATH="$_b:$PATH"; done; '

# These are REMOTE paths — the ~ must survive to the box's shell, which expands
# it. Local expansion would be wrong, so the single-quotes (and the tilde) stay.
# shellcheck disable=SC2088
VENV_DIR='~/.km-venv'
VLLM_BIN="$VENV_DIR/bin/vllm"
# shellcheck disable=SC2088
LLAMA_DIR='~/.km-llama'
LLAMA_BIN="$LLAMA_DIR/llama-server"
LLAMA_REPO="https://github.com/ggml-org/llama.cpp"

# ============================================================================
#  SECTION 4 — reach the box (transient vs permanent, from check_connection)
# ============================================================================

# sets CONN_WHY and CONN_TRANSIENT(0/1); returns 0 if reachable
check_connection() {
  rrun "echo KM_OK" 30
  local low
  low="$(printf '%s%s' "$RERR" "$ROUT" | tr '[:upper:]' '[:lower:]')"
  if [ "$RC" -eq 0 ] && printf '%s' "$ROUT" | grep -q KM_OK; then
    CONN_WHY="ok"; CONN_TRANSIENT=0; return 0
  fi
  CONN_TRANSIENT=0
  if [ "$RC" -eq 127 ]; then CONN_WHY="ssh binary not found on this machine"; return 1; fi
  case "$low" in
    *"permission denied"*|*"no such identity"*)
      CONN_WHY="auth denied — the box isn't accepting your SSH key (add it / ssh-agent)"; return 1 ;;
    *kex_exchange_identification*|*"reset by peer"*|*"connection reset"*)
      CONN_WHY="the box reset the SSH handshake — almost always still booting, or briefly rate-limiting new connections"
      CONN_TRANSIENT=1; return 1 ;;
    *"connection refused"*)
      CONN_WHY="connection refused — sshd isn't up yet; the box may still be booting"
      CONN_TRANSIENT=1; return 1 ;;
  esac
  if [ "$RC" -eq 124 ]; then
    CONN_WHY="no answer in 30s — wrong host/port, or the box is still booting"
    CONN_TRANSIENT=1; return 1
  fi
  local msg; msg="$(printf '%s' "$RERR" | head -c 160)"
  CONN_WHY="ssh failed: ${msg:-exit $RC}"; return 1
}

# ============================================================================
#  SECTION 5 — detect GPUs + plan the tier (from detect_gpus / plan)
# ============================================================================

# sets GPU_COUNT, GPU_TOTAL_GB, GPU_NAMES ; returns 1 on failure
detect_gpus() {
  rrun "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits" 30
  if [ "$RC" -ne 0 ]; then
    CONN_WHY="nvidia-smi failed: $(printf '%s' "${RERR:-$ROUT}" | head -c 200)"; return 1
  fi
  GPU_COUNT=0; local total_mb=0; GPU_NAMES=""
  local line name mem
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name="${line%,*}"; mem="${line##*,}"
    mem="$(printf '%s' "$mem" | tr -dc '0-9')"
    [ -n "$mem" ] || continue
    GPU_COUNT=$((GPU_COUNT+1)); total_mb=$((total_mb+mem))
    GPU_NAMES="${GPU_NAMES:+$GPU_NAMES, }$(printf '%s' "$name" | sed 's/^ *//;s/ *$//')"
  done <<< "$ROUT"
  GPU_TOTAL_GB=$((total_mb/1024))
  [ "$GPU_COUNT" -gt 0 ] || { CONN_WHY="no GPUs detected on the box (nvidia-smi empty)"; return 1; }
  return 0
}

# sets PLAN_TP, PLAN_MAXLEN, PLAN_UTIL ; returns 1 if the box is too small
plan() { # $1=model key
  local key="$1" min="${M_MINGB[$1]}"
  if [ "$GPU_TOTAL_GB" -lt "$min" ]; then
    local hint fits best
    fits="$(smaller_quants "$key" | awk -v g="$GPU_TOTAL_GB" '$2<=g{print}')"
    if [ -n "$fits" ]; then
      best="$(printf '%s\n' "$fits" | tail -1 | awk '{print $1}')"
      hint="this box fits \`--model $best\` (~${M_MINGB[$best]}GB)."
    else
      local sm; sm="$(smaller_quants "$key" | head -1 | awk '{print $1}')"
      if [ -n "$sm" ]; then
        hint="even the smallest ${M_SERVED[$key]} row (\`--model $sm\`, ~${M_MINGB[$sm]}GB) won't fit — rent a bigger box."
      else
        hint="pick a smaller model or a bigger box."
      fi
    fi
    CONN_WHY="only ${GPU_TOTAL_GB}GB VRAM across ${GPU_COUNT} GPU(s) — ${M_LABEL[$key]} needs ~${min}GB+. $hint"
    return 1
  fi
  PLAN_MAXLEN="${M_BEYOND[$key]}"
  local pair th len
  for pair in ${M_TIERS[$key]}; do
    th="${pair%:*}"; len="${pair#*:}"
    if [ "$GPU_TOTAL_GB" -lt "$th" ]; then PLAN_MAXLEN="$len"; break; fi
  done
  PLAN_TP="$GPU_COUNT"
  [ "$GPU_TOTAL_GB" -lt 72 ] && PLAN_UTIL="0.95" || PLAN_UTIL="0.92"
  return 0
}

# ============================================================================
#  SECTION 6 — preflight: prove the box can serve before it spends the hour
#  (from preflight.py). Fail in seconds, not at minute 30 of a paid rental.
# ============================================================================

# P1-2 capability — FP8 needs Ada(8.9)/Hopper(9.0)
detect_compute_cap() {
  rrun "nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1" 20
  COMPUTE_CAP=""
  [ "$RC" -eq 0 ] && COMPUTE_CAP="$(printf '%s' "$ROUT" | tr -dc '0-9.')"
  return 0   # detection failure is non-fatal — an empty cap just skips the veto
}

capability_preflight() { # $1=key ; returns 1 (bad) with PF_MSG set
  local key="$1"
  if [ "${M_QUANT[$key]}" = "fp8" ] && [ -n "$COMPUTE_CAP" ]; then
    if awk -v c="$COMPUTE_CAP" 'BEGIN{exit !(c+0 < 8.9)}'; then
      PF_MSG="FP8 needs compute capability 8.9+ (Ada/Hopper); this GPU is $COMPUTE_CAP — pick a GGUF row, e.g. --model qwen"
      return 1
    fi
  fi
  PF_MSG="capability ok"; return 0
}

# P0-2 disk — df vs weights × 1.1
_weights_bytes() { # $1=key ; echoes bytes or empty
  local gb
  gb="$(printf '%s' "${M_NOTE[$1]}" | grep -oE '[0-9]+(\.[0-9]+)?[[:space:]]*GB' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || true)"
  [ -n "$gb" ] || return 0
  awk -v g="$gb" 'BEGIN{printf "%d", g*1000000000}'
}

remote_free_bytes() {
  rrun "df -PB1 ~/.cache 2>/dev/null | awk 'NR==2{print \$4}' || df -PB1 ~ 2>/dev/null | awk 'NR==2{print \$4}'" 20
  FREE_BYTES=""
  [ "$RC" -eq 0 ] && FREE_BYTES="$(printf '%s' "$ROUT" | tr -dc '0-9')"
  return 0   # a box that won't report free space just skips the disk gate
}

disk_preflight() { # $1=key ; returns 1 (bad) with PF_MSG
  local need; need="$(_weights_bytes "$1")"
  if [ -z "$need" ] || [ -z "$FREE_BYTES" ]; then PF_MSG="disk need unknown — proceeding"; return 0; fi
  need="$(awk -v n="$need" 'BEGIN{printf "%d", n*1.1}')"
  if [ "$FREE_BYTES" -lt "$need" ]; then
    PF_MSG="needs ~$(awk -v n="$need" 'BEGIN{printf "%.0f", n/1e9}')GB, box has $(awk -v n="$FREE_BYTES" 'BEGIN{printf "%.0f", n/1e9}')GB — resize the disk in the console and re-run"
    return 1
  fi
  PF_MSG="disk ok ($(awk -v n="$FREE_BYTES" 'BEGIN{printf "%.0f", n/1e9}')GB free, need ~$(awk -v n="$need" 'BEGIN{printf "%.0f", n/1e9}')GB)"
  return 0
}

# P0-1 resolution — the repo AND the exact GGUF file resolve on Hugging Face, in
# ~3s, before any paid install. Near-match suggestions land in PF_SUGGEST.
model_preflight() { # $1=key ; returns 1 (bad) with PF_MSG / PF_SUGGEST
  local key="$1" repo="${M_REPO[$1]}" code
  PF_SUGGEST=""
  code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 8 \
          "https://huggingface.co/api/models/$repo" 2>/dev/null || echo 000)"
  case "$code" in
    404) PF_MSG="model repo '$repo' does not resolve on Hugging Face"; return 1 ;;
    401|403) PF_MSG="'$repo' is gated — set HF_TOKEN and accept the license first"; return 1 ;;
    200) : ;;
    *) PF_MSG="could not verify '$repo' (HF unreachable) — proceeding"; return 0 ;;
  esac
  local want="${M_GGUF_FILE[$key]}" quant="${M_GGUF_QUANT[$key]}"
  if [ -n "$want" ] || [ -n "$quant" ]; then
    local tree ggufs
    tree="$(curl -fsS --max-time 8 "https://huggingface.co/api/models/$repo/tree/main" 2>/dev/null || true)"
    ggufs="$(printf '%s' "$tree" | grep -oE '"path":"[^"]+\.gguf"' | sed 's/"path":"//;s/"$//' || true)"
    if [ -n "$ggufs" ]; then
      if [ -n "$want" ] && ! printf '%s\n' "$ggufs" | grep -qxF "$want"; then
        PF_MSG="file '$want' is not in repo '$repo'"; PF_SUGGEST="$(printf '%s\n' "$ggufs" | head -5)"; return 1
      fi
      if [ -n "$quant" ] && ! printf '%s\n' "$ggufs" | grep -qi "$quant"; then
        PF_MSG="no '$quant' GGUF in repo '$repo' — available quants below"
        PF_SUGGEST="$(printf '%s\n' "$ggufs" | head -8)"; return 1
      fi
    fi
  fi
  PF_MSG="'$repo' resolves"; return 0
}

# ============================================================================
#  SECTION 7 — install runtime + register CUDA libs (from _install_* / _register)
# ============================================================================

_register_cuda_libs() {
  # Teach the box's linker where CUDA lives, once, system-wide — so llama-server
  # finds libcudart/libcublas on exec no matter which shell launched it. A
  # crash-on-exec ("libcudart.so.NN: cannot open shared object file") looks
  # exactly like a hung download bar. Best-effort (needs root; a box gives it).
  rrun "ls -d /usr/local/cuda*/lib64 /usr/local/cuda*/targets/*/lib 2>/dev/null > /etc/ld.so.conf.d/cuda-km.conf && ldconfig" 30
}

install_llama() {
  step "building llama.cpp with CUDA on the box (first time takes several minutes)…"
  local cmd="${_APT_WAIT}${_NET_WAIT}test -x $LLAMA_BIN && exit 0; mkdir -p $LLAMA_DIR && apt_wait update -qq && apt_wait install -y -qq git cmake build-essential libcurl4-openssl-dev && rm -rf $LLAMA_DIR/src && net_wait git clone --depth 1 $LLAMA_REPO $LLAMA_DIR/src && CUDA_ARCH=\$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '. '); ${_CUDA_ENV}cmake -S $LLAMA_DIR/src -B $LLAMA_DIR/src/build -DGGML_CUDA=ON -DLLAMA_CURL=ON -DCMAKE_BUILD_TYPE=Release \${CUDA_ARCH:+-DCMAKE_CUDA_ARCHITECTURES=\$CUDA_ARCH} && cmake --build $LLAMA_DIR/src/build --config Release -j --target llama-server && cp $LLAMA_DIR/src/build/bin/llama-server $LLAMA_BIN"
  rrun "$cmd" 3600
  [ "$RC" -eq 0 ] || die "llama.cpp build failed: $(printf '%s' "$RERR" | tail -c 500)"
}

install_vllm() {
  step "installing vLLM on the box (first time takes several minutes)…"
  local cmd="${_APT_WAIT}test -x $VLLM_BIN && exit 0; python3 -m venv --system-site-packages $VENV_DIR 2>/dev/null || { apt_wait update -qq && apt_wait install -y -qq python3-venv && python3 -m venv --system-site-packages $VENV_DIR; } && $VENV_DIR/bin/pip install -q -U pip vllm hf_transfer"
  rrun "$cmd" 1800
  [ "$RC" -eq 0 ] || die "vLLM install failed: $(printf '%s' "$RERR" | tail -c 500)"
}

# ============================================================================
#  SECTION 8 — launch server (auto-port slide) + server_running
# ============================================================================

# pid-alive AND cmdline-match: a recycled pid after a box reboot must not read
# as "serving".
server_running() {
  rrun "P=\$(cat ~/vllm.pid 2>/dev/null) && kill -0 \$P 2>/dev/null && tr '\\0' ' ' < /proc/\$P/cmdline 2>/dev/null | grep -qE 'vllm|llama-server' && echo RUNNING" 20
  printf '%s' "$ROUT" | grep -q RUNNING
}

# kill orphaned servers; echo what still holds $port (vast.ai loves 8080), '' if free
_clear_stale_and_check_port() { # $1=port
  rrun "pkill -9 -f llama-server 2>/dev/null; pkill -9 -f 'vllm serve' 2>/dev/null; sleep 1" 20
  rrun "ss -tln 2>/dev/null | grep ':$1 ' || true" 20
  printf '%s' "$ROUT" | sed 's/^ *//;s/ *$//'
}

_launch_prefix() {
  local p="HF_HUB_ENABLE_HF_TRANSFER=1"
  [ -n "${HF_TOKEN:-}" ] && p="HF_TOKEN=$(printf '%q' "$HF_TOKEN") $p"
  printf '%s ' "$p"
}

_llama_cmd() { # $1=key $2=maxlen $3=port
  local key="$1" maxlen="$2" port="$3" weights
  if [ -n "${M_GGUF_FILE[$key]}" ]; then
    weights="--hf-repo ${M_REPO[$key]} --hf-file ${M_GGUF_FILE[$key]}"
  else
    weights="-hf ${M_REPO[$key]}:${M_GGUF_QUANT[$key]}"
  fi
  printf '%s %s --alias %s --host 127.0.0.1 --port %s --ctx-size %s --n-gpu-layers 999 --jinja' \
    "$LLAMA_BIN" "$weights" "${M_SERVED[$key]}" "$port" "$maxlen"
}

_vllm_cmd() { # $1=key $2=tp $3=maxlen $4=util $5=port
  local key="$1" tok="${M_TOKENIZER[$1]}"
  printf '%s serve %s --served-model-name %s --quantization %s --tensor-parallel-size %s --max-model-len %s --gpu-memory-utilization %s --enable-auto-tool-choice --tool-call-parser %s --host 127.0.0.1 --port %s%s' \
    "$VLLM_BIN" "${M_REPO[$key]}" "${M_SERVED[$key]}" "${M_QUANT[$key]}" "$2" "$3" "$4" "${M_PARSER[$key]}" "$5" \
    "${tok:+ --tokenizer $tok}"
}

# sets LAUNCHED_PORT to the box-side port the server actually bound (may slide off
# a squatted port); dies on failure. A global, not an echo, so the install steps'
# own stdout can never be mistaken for the port.
launch() { # $1=key $2=tp $3=maxlen $4=util $5=port
  local key="$1" tp="$2" maxlen="$3" util="$4" port="$5" cmd env=""
  if server_running; then
    warn "a model server is already running on the box (--down to relaunch)."
    LAUNCHED_PORT="$port"; return 0
  fi
  # install the runtime
  if [ "${M_SERVER[$key]}" = "llama_cpp" ]; then
    install_llama
    _register_cuda_libs      # so llama-server finds libcudart/libcublas on exec
    env="$_CUDA_ENV"
  else
    install_vllm
  fi
  # clear orphans and slide off a squatted box port — BOTH runtimes bind --port,
  # so both get the slide (vast.ai squats 8080 whichever we launch).
  local held; held="$(_clear_stale_and_check_port "$port")"
  if [ -n "$held" ]; then
    local alt; [ "$port" -lt 55535 ] && alt=$((port+10000)) || alt=8000
    if [ -n "$(_clear_stale_and_check_port "$alt")" ]; then
      die "ports $port and $alt are both held on the box — pick a free remote port for your -L forward by hand."
    fi
    warn "port $port is held on the box — sliding the server to $alt (your local side stays as is)."
    port="$alt"
  fi
  # build the launch command now that the port is settled
  if [ "${M_SERVER[$key]}" = "llama_cpp" ]; then
    cmd="$(_llama_cmd "$key" "$maxlen" "$port")"
  else
    cmd="$(_vllm_cmd "$key" "$tp" "$maxlen" "$util" "$port")"
  fi
  step "launching: $(printf '%s' "$cmd" | cut -c1-110)…"
  rrun "${env}$(_launch_prefix)nohup $cmd > ~/vllm.log 2>&1 & echo \$! > ~/vllm.pid" 60
  [ "$RC" -eq 0 ] || die "launch failed: $(printf '%s' "$RERR" | tail -c 400)"
  LAUNCHED_PORT="$port"
}

stop_server() {
  rrun "kill \$(cat ~/vllm.pid) 2>/dev/null; rm -f ~/vllm.pid" 30 || true
}

# ============================================================================
#  SECTION 9 — the tunnel: detached ssh -N, PID-tracked in state (from gpucmd)
# ============================================================================

tunnel_alive() { # $1=pid
  [ -n "${1:-}" ] || return 1
  kill -0 "$1" 2>/dev/null
}

kill_tunnel() { # $1=pid
  if tunnel_alive "${1:-}"; then kill -TERM "$1" 2>/dev/null || true; fi
}

# opens a detached tunnel; echoes its PID, or empty on failure. nohup (not setsid)
# because nohup execs ssh in place, so $! is ssh's own PID — the thing we track,
# reconnect, and kill. It ignores SIGHUP, so the tunnel outlives this script and
# the shell that started it, exactly like KM1's start_new_session Popen.
open_tunnel() { # remaining args = ssh args (incl -L forward)
  mkdir -p "$KM_HOME"
  nohup ssh -N \
    -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes -o ConnectTimeout=15 \
    "$@" </dev/null >/dev/null 2>>"$TUNNEL_LOG" &
  local pid=$!
  # give it a moment to fail fast (bad forward, auth) before we trust it
  local i
  for i in $(seq 1 25); do
    if ! kill -0 "$pid" 2>/dev/null; then
      erro "tunnel failed to come up — $(tail -n1 "$TUNNEL_LOG" 2>/dev/null | head -c 200)"
      return 1
    fi
    sleep 0.1
  done
  printf '%s' "$pid"
}

# ============================================================================
#  SECTION 10 — readiness + canary (from wait_ready / preflight.canary)
# ============================================================================

endpoint_up() { # $1=local_port
  curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$1/v1/models" 2>/dev/null
}

# poll until the endpoint answers; bail the instant the process dies (a crash on
# exec looks identical to a slow download bar — don't burn the deadline on it)
wait_ready() { # $1=local_port $2=key ; returns 1 on timeout/crash
  local lp="$1" key="$2" deadline=2400 start now
  local total; total="$(_weights_bytes "$key")"
  start="$(date +%s)"
  info "waiting for the oracle to wake — ${M_NOTE[$key]}"
  while :; do
    now="$(date +%s)"; [ $((now-start)) -lt "$deadline" ] || break
    if endpoint_up "$lp"; then printf '\r%*s\r' 60 '' >&2; return 0; fi
    if [ $((now-start)) -gt 8 ] && ! server_running; then
      printf '\r%*s\r' 60 '' >&2
      erro "the server process died before it came up."
      rrun "tail -n 15 ~/vllm.log 2>/dev/null" 20
      printf '%s' "$ROUT" | sed 's/^/  | /' >&2
      return 1
    fi
    if [ -n "$total" ]; then
      rrun "du -sb ~/.cache/llama.cpp ~/.cache/huggingface 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 20
      local cur got frac; cur="$(printf '%s' "$ROUT" | tr -dc '0-9')"
      if [ -n "$cur" ]; then
        got="$cur"; frac="$(awk -v g="$got" -v t="$total" 'BEGIN{f=g/t; if(f>0.99)f=0.99; printf "%d", f*100}')"
        printf '\r  %sweights %sGB/%sGB  %s%%%s' "$C_C" \
          "$(awk -v n="$got" 'BEGIN{printf "%.1f", n/1e9}')" \
          "$(awk -v n="$total" 'BEGIN{printf "%.1f", n/1e9}')" "$frac" "$C_0" >&2
      fi
    else
      rrun "tail -n 2 ~/vllm.log 2>/dev/null" 20
      [ -n "$ROUT" ] && printf '%s' "$ROUT" | sed 's/^/  | /' >&2
    fi
    sleep 4
  done
  printf '\r%*s\r' 60 '' >&2
  return 1
}

# "up" must mean *can think*: one real tool-calling completion through the tunnel
canary() { # $1=local_port $2=served_name ; returns 1 with CANARY_MSG
  local lp="$1" served="$2" body resp
  body='{"model":"'"$served"'","messages":[{"role":"user","content":"Add 2 and 2 using the add tool."}],"tools":[{"type":"function","function":{"name":"add","description":"add two numbers","parameters":{"type":"object","properties":{"a":{"type":"number"},"b":{"type":"number"}},"required":["a","b"]}}}],"tool_choice":"auto","max_tokens":128}'
  resp="$(curl -fsS --max-time 30 -H 'Content-Type: application/json' \
          -d "$body" "http://127.0.0.1:$lp/v1/chat/completions" 2>/dev/null || true)"
  if [ -z "$resp" ]; then
    CANARY_MSG="the endpoint did not answer a completion"; return 1
  fi
  if printf '%s' "$resp" | grep -q '"tool_calls"'; then
    CANARY_MSG="the model answered a tool call — it can think"; return 0
  fi
  CANARY_MSG="the server lists models but tool-calling failed — check the --tool-call-parser or the chat template"
  return 1
}

# ============================================================================
#  SECTION 11 — state file (flat JSON, one field per line for grep-back)
# ============================================================================

state_get() { # $1=key
  [ -f "$STATE" ] || return 0
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$STATE" | head -1
}

save_state() { # writes global STATE_* into $STATE
  mkdir -p "$KM_HOME"
  cat > "$STATE" <<EOF
{
  "served": ${STATE_SERVED:-false},
  "base_url": "${STATE_BASE_URL:-}",
  "model": "${STATE_MODEL:-}",
  "model_key": "${STATE_MODEL_KEY:-}",
  "local_port": ${STATE_LOCAL_PORT:-0},
  "remote_port": ${STATE_REMOTE_PORT:-0},
  "tunnel_pid": ${STATE_TUNNEL_PID:-0},
  "ssh_conn": "${STATE_SSH_CONN:-}"
}
EOF
}

# ============================================================================
#  SECTION 12 — harness side: Node, pi, config, context package, models.json
# ============================================================================

ensure_node() {
  if command -v node >/dev/null 2>&1 && [ "$(node -v 2>/dev/null | tr -dc '0-9.' | cut -d. -f1)" -ge 20 ] 2>/dev/null; then
    ok "Node $(node -v) already present"; return 0
  fi
  # nvm over nodesource: the harness may be an unprivileged user (michael@hello),
  # and both the pi installer and `npm i -g` want a writable prefix. nvm keeps
  # Node in $HOME, so nothing here needs root.
  step "installing Node 22 via nvm (user-local, no root)…"
  export NVM_DIR="$HOME/.nvm"
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash >/dev/null 2>&1 \
      || die "nvm install failed — install Node 20+ yourself and re-run"
  fi
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  nvm install 22 >/dev/null 2>&1 || die "nvm could not install Node 22"
  nvm use 22 >/dev/null 2>&1 || true
  command -v node >/dev/null 2>&1 || die "Node still not on PATH after nvm install"
  ok "Node $(node -v) ready"
}

_pi_on_path() {
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && { . "$NVM_DIR/nvm.sh"; nvm use 22 >/dev/null 2>&1 || true; }
  export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
  command -v pi >/dev/null 2>&1
}

ensure_pi() {
  if _pi_on_path; then ok "pi already installed ($(pi --version 2>/dev/null | head -1))"; return 0; fi
  step "installing pi (the harness)…"
  # official installer first, npm global (per pi's docs) as the fallback
  curl -fsSL https://pi.dev/install.sh 2>/dev/null | sh >/dev/null 2>&1 || true
  if ! _pi_on_path; then
    info "  installer path didn't land pi on PATH — falling back to npm global"
    npm install -g --ignore-scripts @earendil-works/pi-coding-agent >/dev/null 2>&1 \
      || die "pi install failed (both installer and npm). Install Node 20+ and retry."
  fi
  _pi_on_path || die "pi installed but not found on PATH — open a new shell and re-run --check"
  ok "pi ready ($(pi --version 2>/dev/null | head -1))"
}

install_context() {
  # pi loads AGENTS.md/CLAUDE.md globally from ~/.pi/agent/AGENTS.md and by
  # walking up from the cwd. We install our lore as the global context file so
  # pi wakes up knowing who the Master is, everywhere.
  local src="$REPO_DIR/context"
  if [ -z "$REPO_DIR" ] || [ ! -d "$src" ]; then
    # curl|bash path: fetch the context files from the repo
    src="$KM_HOME/context"; mkdir -p "$src"
    local f
    for f in OPERATOR.md HISTORY.md THESIS.md LESSONS.md; do
      curl -fsSL "${RAW_URL%setup.sh}context/$f" -o "$src/$f" 2>/dev/null || true
    done
  fi
  mkdir -p "$PI_DIR"
  local out="$PI_DIR/AGENTS.md" f
  {
    echo "# KM context — loaded by pi at startup"
    echo
    echo "This file is assembled by KM's setup.sh from context/. It tells pi who"
    echo "the operator is, the line of harnesses it stands at the end of, and the"
    echo "rules paid for in rental hours. Edit context/*.md in the KM repo, re-run"
    echo "setup.sh, and /reload."
    echo
    for f in OPERATOR HISTORY THESIS LESSONS; do
      if [ -f "$src/$f.md" ]; then
        echo "---"; echo; cat "$src/$f.md"; echo
      fi
    done
  } > "$out"
  ok "context installed → $out"
}

# copy pi/extensions (gpu-status, herald) into pi's auto-discovered path
install_pi_extras() {
  local name dst
  for name in "${PI_EXTENSIONS[@]}"; do
    dst="$PI_DIR/extensions/$name"
    mkdir -p "$dst"
    if [ -n "$REPO_DIR" ] && [ -f "$REPO_DIR/pi/extensions/$name/index.ts" ]; then
      cp "$REPO_DIR/pi/extensions/$name/index.ts" "$dst/index.ts"
    else
      curl -fsSL "${RAW_URL%setup.sh}pi/extensions/$name/index.ts" -o "$dst/index.ts" 2>/dev/null || true
    fi
    [ -f "$dst/index.ts" ] && ok "extension installed → $dst" \
      || warn "could not install the $name extension (non-fatal)"
  done
}

# Park anything under pi's extensions path that improvises its own sub-agents.
# The Herald summons one named agent through agent_summon; a second, older path
# firing on Drive is how you get two of them arguing. Moved, never deleted — it
# may hold work, and it is not ours to throw away.
park_improvised_subagents() {
  local dir base parked
  [ -d "$PI_DIR/extensions" ] || return 0
  for dir in "$PI_DIR"/extensions/*subagent*/ "$PI_DIR"/extensions/*sub-agent*/; do
    [ -d "$dir" ] || continue          # unmatched globs come back literal
    base="$(basename "$dir")"
    parked="$PARKED_DIR/$base-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$PARKED_DIR"
    if mv "$dir" "$parked" 2>/dev/null; then
      ok "parked the $base extension → $parked"
      info "  it no longer loads. The Herald's own agent is: $KM_AGENT (see $CALLCENTER)."
    else
      warn "could not park $dir — disable it by hand, or Drive will still fire it"
    fi
  done
  return 0
}

# The call-center file: one directory the Operator owns, one file he curates. We
# create them if they are not there and never rewrite them if they are. The
# brake's checkpoints land in the same map, so the directory exists from the
# start — an empty one is a signpost, not clutter.
install_callcenter() {
  mkdir -p "$KARTE_DIR" "$CHECKPOINTS"
  if [ -f "$CALLCENTER" ]; then
    ok "call-center file already there → $CALLCENTER (left untouched)"
    return 0
  fi
  cat > "$CALLCENTER" <<EOF
# callcenter

The Operator writes here. \`$KM_AGENT\` reads this file first on every summon:
who it is for this job, the context it needs, and the work in front of it.
Nothing else configures the agent.
EOF
  ok "call-center file created → $CALLCENTER (yours to write)"
}

# read a field out of the Herald's cockpit state (same flat-JSON idiom as state_get)
herald_get() { # $1=key
  [ -f "$HERALD_STATE" ] || return 0
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$HERALD_STATE" | head -1
}

# the newest checkpoint the brake wrote, if any. Names are ISO timestamps, so the
# last line is the newest file — no stat(1), which differs on every OS.
latest_checkpoint() {
  ls -1 "$CHECKPOINTS"/*.md 2>/dev/null | tail -1
}

# the Herald: the cockpit process (its launcher + contract) and the masks it grows.
# The extension itself rides along in install_pi_extras; this is the process.
install_herald() {
  mkdir -p "$KM_HOME/bin" "$MASKS_DIR"
  local f
  for f in HERALD.md bin/herald; do
    if [ -n "$REPO_DIR" ] && [ -f "$REPO_DIR/herald/$f" ]; then
      cp "$REPO_DIR/herald/$f" "$KM_HOME/$f"
    else
      curl -fsSL "${RAW_URL%setup.sh}herald/$f" -o "$KM_HOME/$f" 2>/dev/null || true
    fi
  done
  if [ -s "$KM_HOME/bin/herald" ] && [ -s "$KM_HOME/HERALD.md" ]; then
    chmod +x "$KM_HOME/bin/herald"
    mkdir -p "$HOME/.local/bin"
    ln -sf "$KM_HOME/bin/herald" "$HOME/.local/bin/herald"
    ok "Herald installed → herald   (gears: drive · brake · empty ·  masks: /mask)"
  else
    warn "could not install the Herald launcher (non-fatal) — retry with: km --herald"
  fi
}

# write ~/.pi/agent/models.json pointing pi at the served endpoint (§4 incantation)
wire_models_json() { # $1=served_name $2=local_port $3=ctx  (DEMO if $2 empty)
  local served="$1" port="${2:-}" ctx="${3:-131072}"
  mkdir -p "$PI_DIR"
  if [ -f "$MODELS_JSON" ] && ! grep -q '"km-box"' "$MODELS_JSON"; then
    cp "$MODELS_JSON" "$MODELS_JSON.km-backup.$(date +%s)" 2>/dev/null || true
    warn "an existing models.json without a km-box provider was backed up before rewrite"
  fi
  local base name
  if [ -n "$port" ]; then
    base="http://localhost:$port/v1"; name="${M_LABEL_ONELINE:-$served (KM box)}"
  else
    # honesty law: nothing live yet -> label it DEMO until a box attaches
    base="http://localhost:8080/v1"; served="${served}-DEMO"; name="$served (no box attached — DEMO)"
  fi
  cat > "$MODELS_JSON" <<EOF
{
  "providers": {
    "km-box": {
      "baseUrl": "$base",
      "api": "openai-completions",
      "apiKey": "km",
      "compat": { "supportsDeveloperRole": false, "supportsReasoningEffort": false },
      "models": [
        { "id": "$served", "name": "$name",
          "reasoning": false, "input": ["text"],
          "contextWindow": $ctx, "maxTokens": 8192 }
      ]
    }
  }
}
EOF
  ok "wired pi → $MODELS_JSON (provider km-box, model $served)"
}

# drop a `km` shim so sub-commands are `km status`, `km watch`, …
self_install() {
  mkdir -p "$KM_HOME"
  if [ -n "$SELF_SRC" ] && [ -f "$SELF_SRC" ]; then
    cp "$SELF_SRC" "$KM_HOME/setup.sh" 2>/dev/null || true
  elif [ ! -f "$KM_HOME/setup.sh" ]; then
    curl -fsSL "$RAW_URL" -o "$KM_HOME/setup.sh" 2>/dev/null || true
  fi
  [ -f "$KM_HOME/setup.sh" ] && chmod +x "$KM_HOME/setup.sh" 2>/dev/null || true
  local bindir="$HOME/.local/bin"
  mkdir -p "$bindir"
  cat > "$bindir/km" <<EOF
#!/usr/bin/env bash
exec bash "$KM_HOME/setup.sh" "\$@"
EOF
  chmod +x "$bindir/km" 2>/dev/null || true
}

# ============================================================================
#  SECTION 13 — the zero-to-hero card
# ============================================================================

hero_card() { # $1=served_name (or DEMO)
  local served="$1"
  printf '\n'
  printf '%s  ┌──────────────────────────────────────────────────────────┐%s\n' "$C_G" "$C_0"
  printf '%s  │  KM is up. Three commands to your first agent turn:       │%s\n' "$C_G" "$C_0"
  printf '%s  └──────────────────────────────────────────────────────────┘%s\n' "$C_G" "$C_0"
  printf '\n'
  printf '     %s1.%s  %spi -p "what model are you and who is the operator?"%s\n' "$C_B" "$C_0" "$C_C" "$C_0"
  printf '         %s(proves the box model answers and the context loaded)%s\n' "$C_D" "$C_0"
  printf '     %s2.%s  %spi%s                 %sstart working — /model to switch, /tree to branch%s\n' "$C_B" "$C_0" "$C_C" "$C_0" "$C_D" "$C_0"
  printf '     %s3.%s  %skm status%s          %sis the tunnel live? what is served?%s\n' "$C_B" "$C_0" "$C_C" "$C_0" "$C_D" "$C_0"
  printf '\n'
  printf '     served model: %s%s%s   ·   manage: %skm watch / km down / km off%s\n' "$C_B" "$served" "$C_0" "$C_D" "$C_0"
  printf '     cockpit: %sherald%s  %s— gears: drive · brake · empty. Masks grow when you need one.%s\n' "$C_C" "$C_0" "$C_D" "$C_0"
  printf '     (if %skm%s is not found yet, open a new shell, or use %sbash ~/.km/setup.sh%s)\n\n' "$C_C" "$C_0" "$C_C" "$C_0"
}

# ============================================================================
#  SECTION 14 — the GPU flow (from gpucmd.handle "ssh")
# ============================================================================

gpu_flow() { # $1=model key ; SSH_ARGS is the full pasted args
  local key="$1"
  # forgive a pasted full `ssh` line — the leading ssh is redundant
  while [ "${#SSH_ARGS[@]}" -gt 0 ] && [ "${SSH_ARGS[0]}" = "ssh" ]; do
    SSH_ARGS=("${SSH_ARGS[@]:1}")
  done
  if ! parse_forward "${SSH_ARGS[@]}"; then
    erro "your --gpu string needs an -L forward, e.g.:"
    info "  --gpu \"-p 24439 root@1.2.3.4 -L 8080:localhost:8080\""
    exit 2
  fi
  conn_args "${SSH_ARGS[@]}"

  # 1. reach the box, waiting out the transient resets of a booting box
  step "reaching the box…"
  local tries=0
  until check_connection; do
    if [ "$CONN_TRANSIENT" = "1" ] && [ "$tries" -lt 4 ]; then
      tries=$((tries+1))
      info "  $CONN_WHY — still coming up; retry $tries/4 in 12s (Ctrl-C to stop)"
      sleep 12
    else
      die "can't reach the box: $CONN_WHY"
    fi
  done
  ok "box reachable"

  # 2. detect GPUs + plan the tier
  detect_gpus || die "$CONN_WHY"
  plan "$key" || die "$CONN_WHY"
  ok "${GPU_COUNT}× GPU · ${GPU_TOTAL_GB}GB VRAM  ($GPU_NAMES)"
  info "  serving ${M_LABEL[$key]} · context $PLAN_MAXLEN · box port $FWD_RPORT"

  # 2.5 preflight — the two most expensive failures fail in seconds, not minute 30
  detect_compute_cap
  remote_free_bytes
  if ! capability_preflight "$key"; then die "preflight: $PF_MSG"; fi;  ok "$PF_MSG"
  if ! disk_preflight "$key"; then die "preflight: $PF_MSG"; fi;        ok "$PF_MSG"
  if ! model_preflight "$key"; then
    erro "preflight: $PF_MSG"
    [ -n "$PF_SUGGEST" ] && printf '%s' "$PF_SUGGEST" | sed 's/^/      near match: /' >&2
    exit 3
  fi
  ok "$PF_MSG"

  # 3. install runtime + launch (slides off a squatted box port)
  launch "$key" "$PLAN_TP" "$PLAN_MAXLEN" "$PLAN_UTIL" "$FWD_RPORT"
  local new_rport="$LAUNCHED_PORT"
  if [ "$new_rport" != "$FWD_RPORT" ]; then
    replace_forward "$new_rport"
    info "  tunnel follows the slide → -L $FWD_LOCAL:localhost:$new_rport"
  fi

  # 4. open the tunnel (detached, survives this command)
  kill_tunnel "$(state_get tunnel_pid)"
  local pid; pid="$(open_tunnel "${SSH_ARGS[@]}")" || true
  [ -n "$pid" ] || die "tunnel did not come up"
  ok "tunnel up (pid $pid)"

  # 5. wait for weights + endpoint, then persist and wire pi
  local base_url="http://localhost:$FWD_LOCAL/v1" served="${M_SERVED[$key]}"
  local ready=1; wait_ready "$FWD_LOCAL" "$key" || ready=0

  STATE_SERVED=true STATE_BASE_URL="$base_url" STATE_MODEL="$served" \
    STATE_MODEL_KEY="$key" STATE_LOCAL_PORT="$FWD_LOCAL" STATE_REMOTE_PORT="$new_rport" \
    STATE_TUNNEL_PID="$pid" STATE_SSH_CONN="${CARGS[*]}" save_state
  M_LABEL_ONELINE="${M_SERVED[$key]} (KM box)" \
    wire_models_json "$served" "$FWD_LOCAL" "$PLAN_MAXLEN"

  if [ "$ready" = "1" ]; then
    if canary "$FWD_LOCAL" "$served"; then
      ok "the model is up at $base_url  ($CANARY_MSG)"
    else
      warn "the endpoint answers, but it can't think yet — $CANARY_MSG"
      info "     tail ~/vllm.log on the box, or try a different --tool-call-parser; re-check with km status."
    fi
  else
    warn "tunnel up and the server is launching, but it didn't answer in time — weights may still be loading."
    info "     check with km status (or pi -p 'ping') in a few minutes."
  fi
  hero_card "$served"
}

# ============================================================================
#  SECTION 15 — sub-commands (reconnect / watch / down / off / status)
# ============================================================================

_reload_cargs() { # rebuild CARGS from saved state
  local conn; conn="$(state_get ssh_conn)"
  [ -n "$conn" ] || return 1
  read -r -a CARGS <<< "$conn"
  return 0
}

cmd_status() {
  if [ "$(state_get served)" = "true" ]; then
    local pid; pid="$(state_get tunnel_pid)"
    if tunnel_alive "$pid"; then
      ok "served: $(state_get base_url) (model: $(state_get model)) — tunnel live (pid $pid)"
    else
      warn "served: $(state_get base_url) (model: $(state_get model)) — tunnel down; run 'km reconnect' or 'km watch'"
    fi
  else
    info "no GPU attached. Run with --gpu \"<ssh… -L port:host:port>\" to serve a model."
  fi
}

cmd_reconnect() {
  _reload_cargs || die "nothing to reconnect to — run --gpu first."
  local lp rp key; lp="$(state_get local_port)"; rp="$(state_get remote_port)"; key="$(state_get model_key)"
  [ -n "$lp" ] && [ -n "$rp" ] || die "no saved ports — run --gpu first."
  kill_tunnel "$(state_get tunnel_pid)"
  step "reopening the tunnel…"
  local pid; pid="$(open_tunnel "${CARGS[@]}" -L "$lp:localhost:$rp")" || true
  [ -n "$pid" ] || die "tunnel did not come up"
  STATE_SERVED=true STATE_BASE_URL="http://localhost:$lp/v1" STATE_MODEL="$(state_get model)" \
    STATE_MODEL_KEY="$key" STATE_LOCAL_PORT="$lp" STATE_REMOTE_PORT="$rp" \
    STATE_TUNNEL_PID="$pid" STATE_SSH_CONN="${CARGS[*]}" save_state
  if wait_ready "$lp" "$key"; then ok "reconnected at http://localhost:$lp/v1"
  else warn "tunnel reopened, but the server didn't answer yet — it may still be waking, or the box is gone."; fi
}

cmd_watch() {
  _reload_cargs || die "nothing to watch — run --gpu first."
  local lp rp; lp="$(state_get local_port)"; rp="$(state_get remote_port)"
  [ -n "$lp" ] && [ -n "$rp" ] || die "no saved ports — run --gpu first."
  ok "watching the tunnel — it self-heals with backoff. Ctrl-C to stop."
  info "  (headless: nohup km watch >/dev/null 2>&1 &)"
  local backoff=(2 5 10 20 30) fails=0
  while :; do
    local pid; pid="$(state_get tunnel_pid)"
    if tunnel_alive "$pid"; then fails=0; sleep 5; continue; fi
    fails=$((fails+1))
    info "  tunnel down — redialing (attempt $fails)"
    local newpid; newpid="$(open_tunnel "${CARGS[@]}" -L "$lp:localhost:$rp" || true)"
    if [ -n "$newpid" ]; then
      STATE_SERVED=true STATE_BASE_URL="http://localhost:$lp/v1" STATE_MODEL="$(state_get model)" \
        STATE_MODEL_KEY="$(state_get model_key)" STATE_LOCAL_PORT="$lp" STATE_REMOTE_PORT="$rp" \
        STATE_TUNNEL_PID="$newpid" STATE_SSH_CONN="${CARGS[*]}" save_state
      ok "  tunnel restored (pid $newpid)"; fails=0; sleep 5
    else
      local idx=$((fails-1)); [ "$idx" -ge "${#backoff[@]}" ] && idx=$((${#backoff[@]}-1))
      sleep "${backoff[$idx]}"
    fi
  done
}

cmd_down() {
  if _reload_cargs; then step "stopping the model server on the box…"; stop_server; fi
  kill_tunnel "$(state_get tunnel_pid)"
  STATE_SERVED=false STATE_TUNNEL_PID=0 save_state
  info "server stopped, tunnel down — the harness falls back offline."
}

cmd_off() {
  kill_tunnel "$(state_get tunnel_pid)"
  STATE_SERVED=false STATE_TUNNEL_PID=0 save_state
  info "tunnel down — offline. (server left running on the box; 'km down' stops it.)"
}

# ============================================================================
#  SECTION 16 — --check (meaningful exit codes) and --uninstall
# ============================================================================

cmd_check() {
  local fail=0
  printf '%sKM --check%s\n' "$C_B" "$C_0"
  if _pi_on_path && command -v node >/dev/null 2>&1; then ok "node $(node -v) · pi $(pi --version 2>/dev/null | head -1)"
  else erro "node/pi not on PATH"; fail=1; fi
  if [ -f "$MODELS_JSON" ] && grep -q '"km-box"' "$MODELS_JSON" && grep -q '"baseUrl"' "$MODELS_JSON"; then
    ok "models.json present and has the km-box provider"
  else erro "models.json missing or has no km-box provider ($MODELS_JSON)"; fail=1; fi
  if [ -f "$PI_DIR/AGENTS.md" ]; then ok "context package installed ($PI_DIR/AGENTS.md)"
  else warn "no context package at $PI_DIR/AGENTS.md"; fi
  if [ -f "$PI_DIR/extensions/gpu-status/index.ts" ]; then ok "gpu-status extension installed"
  else warn "no gpu-status extension at $PI_DIR/extensions/gpu-status/"; fi
  if [ -f "$PI_DIR/extensions/herald/index.ts" ] && [ -x "$KM_HOME/bin/herald" ]; then
    local gear mask nmasks cp
    gear="$(herald_get gear)"; mask="$(herald_get mask)"
    [ "$mask" = "null" ] && mask=""   # bare: no mask worn
    # a gear retired in a later version, still sitting in an old state file
    [ "$gear" = "debate" ] && gear="brake (was debate — retired)"
    nmasks="$(ls -1 "$MASKS_DIR" 2>/dev/null | wc -l | tr -d ' ')"
    ok "Herald installed (gear ${gear:-drive} · mask ${mask:-none} · ${nmasks:-0} mask(s) grown)"
    cp="$(latest_checkpoint)"
    [ -n "$cp" ] && info "  newest brake checkpoint → $cp"
  else warn "no Herald — install with: km --herald"; fi
  if [ -f "$CALLCENTER" ]; then ok "agent $KM_AGENT reads $CALLCENTER"
  else warn "no call-center file at $CALLCENTER — create it with: km --herald"; fi
  if compgen -G "$PI_DIR/extensions/*subagent*" >/dev/null 2>&1; then
    warn "an improvised subagent extension is still live in $PI_DIR/extensions — park it with: km --herald"
  fi
  if [ "$(state_get served)" = "true" ]; then
    local pid lp; pid="$(state_get tunnel_pid)"; lp="$(state_get local_port)"
    if tunnel_alive "$pid"; then ok "tunnel live (pid $pid)"
    else erro "tunnel down — km reconnect"; fail=1; fi
    if [ -n "$lp" ] && endpoint_up "$lp"; then
      ok "endpoint answers on :$lp"
      if canary "$lp" "$(state_get model)"; then ok "canary: $CANARY_MSG"
      else erro "canary: $CANARY_MSG"; fail=1; fi
    else warn "no live endpoint to canary (no box attached, or still loading)"; fi
  else info "no box attached (harness-only / DEMO)."; fi
  [ "$fail" -eq 0 ] && { ok "all green"; exit 0; } || { erro "check found problems"; exit 1; }
}

# Install just the orchestration layer. Safe on a live box: it touches the Herald
# and the extensions only, never models.json or the tunnel.
cmd_herald() {
  step "installing the Herald (cockpit + masks)…"
  ensure_node
  ensure_pi
  install_pi_extras
  install_herald
  park_improvised_subagents
  install_callcenter
  info "  gears:  drive · brake · empty   (type the word, or /drive /brake /empty)"
  info "  brake:  stops now and writes a checkpoint to $CHECKPOINTS — drive resumes from it"
  info "  masks:  /mask · /mask new <name> <what it is for>   — none exist until you need one"
  info "  agent:  $KM_AGENT — summon it in Drive; it reads $CALLCENTER"
  ok "type: herald"
}

cmd_uninstall() {
  local keep ext
  step "reversing KM…"
  if _reload_cargs; then stop_server || true; fi
  kill_tunnel "$(state_get tunnel_pid)" 2>/dev/null || true
  # Masks are hand-grown by the Operator and live under KM_HOME. A clean reversal
  # removes KM, not the Operator's work — copy them out before the rm.
  if [ -d "$MASKS_DIR" ] && [ -n "$(ls -A "$MASKS_DIR" 2>/dev/null)" ]; then
    keep="$HOME/km-masks-$(date +%Y%m%d-%H%M%S)"
    if cp -r "$MASKS_DIR" "$keep" 2>/dev/null; then info "  masks kept → $keep"
    else warn "  could not save $MASKS_DIR — it goes with $KM_HOME"; fi
  fi
  # Same rule for anything KM parked rather than deleted: it was not ours to
  # throw away when we moved it, and it is not ours to throw away now.
  if [ -d "$PARKED_DIR" ] && [ -n "$(ls -A "$PARKED_DIR" 2>/dev/null)" ]; then
    keep="$HOME/km-parked-$(date +%Y%m%d-%H%M%S)"
    if cp -r "$PARKED_DIR" "$keep" 2>/dev/null; then info "  parked extensions kept → $keep"
    else warn "  could not save $PARKED_DIR — it goes with $KM_HOME"; fi
  fi
  rm -f "$HOME/.local/bin/km" "$HOME/.local/bin/herald"
  rm -rf "$KM_HOME"
  if [ -f "$MODELS_JSON" ] && grep -q '"km-box"' "$MODELS_JSON"; then
    rm -f "$MODELS_JSON"; info "  removed $MODELS_JSON (km-box provider)"
  fi
  rm -f "$PI_DIR/AGENTS.md"
  for ext in "${PI_EXTENSIONS[@]}"; do rm -rf "${PI_DIR:?}/extensions/$ext"; done
  info "  KM state, tunnel, km + herald shims, models.json, context and extensions removed."
  # The map is the Operator's, written by hand. Reversing KM does not touch it.
  if [ -e "$KARTE_DIR" ]; then info "  left alone: $KARTE_DIR — it is yours, not KM's."; fi
  info "  pi and Node were left installed (uninstall pi with: npm uninstall -g @earendil-works/pi-coding-agent)."
  ok "done."
}

# ============================================================================
#  SECTION 17 — usage + argument parsing + dispatch
# ============================================================================

usage() {
  cat <<EOF
${C_B}KM${C_0} v$KM_VERSION — one script: a pi harness wired to a model you own.

${C_B}Provision + wire (first run):${C_0}
  setup.sh --gpu "<pasted ssh string incl. -L forward>" [--model glm]
  setup.sh --no-gpu                 harness-only (cloud keys; served model is DEMO)

${C_B}Manage (after first run — also available as the ${C_C}km${C_0}${C_B} command):${C_0}
  setup.sh --status                 is the tunnel live? what is served?
  setup.sh --watch                  keep the tunnel alive (self-healing, backoff)
  setup.sh --reconnect              re-open the tunnel to the last box
  setup.sh --off                    drop the tunnel (leave the server running)
  setup.sh --down                   stop the server AND drop the tunnel

${C_B}The Herald (cockpit — one process, three gears, masks it grows itself):${C_0}
  herald                            start it   (gears: drive · brake · empty)
  herald --seat <model>             assign the seat (default xai/grok-4.5; any model may hold it)
  setup.sh --herald                 (re)install the Herald alone, without touching the box
  brake                             (inside the Herald) stop now; the checkpoint lands in
                                    $CHECKPOINTS
  drive                             (inside the Herald) resume from the newest checkpoint

${C_B}The agent (one, named, summoned from Drive):${C_0}
  $CALLCENTER
                                    the only file that configures $KM_AGENT — you write it by hand
  /agent                            (inside the Herald) its name and the file it reads

${C_B}Utility:${C_0}
  setup.sh --check                  verify install (meaningful exit codes)
  setup.sh --list-models            print the catalog
  setup.sh --uninstall              clean reversal
  setup.sh --help

${C_B}Example:${C_0}
  curl -fsSL $RAW_URL | bash -s -- \\
      --gpu "-p 24439 root@1.2.3.4 -L 8080:localhost:8080" --model glm
EOF
}

main() {
  mkdir -p "$KM_HOME"
  local action="" model="$DEFAULT_MODEL" gpu_str="" no_gpu=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --gpu)          gpu_str="${2:-}"; [ -n "$gpu_str" ] || die "--gpu needs a value: the pasted ssh string incl. its -L forward, e.g. --gpu \"-p 24439 root@1.2.3.4 -L 8080:localhost:8080\""; shift 2 ;;
      --gpu=*)        gpu_str="${1#--gpu=}"; shift ;;
      --model)        model="${2:-}"; [ -n "$model" ] || die "--model needs a value (see --list-models)"; shift 2 ;;
      --model=*)      model="${1#--model=}"; shift ;;
      --no-gpu)       no_gpu=1; shift ;;
      --list-models)  action="list"; shift ;;
      --status|status)        action="status"; shift ;;
      --watch|watch)          action="watch"; shift ;;
      --reconnect|reconnect)  action="reconnect"; shift ;;
      --off|off)              action="off"; shift ;;
      --down|down)            action="down"; shift ;;
      --check|check)          action="check"; shift ;;
      --herald|herald)        action="herald"; shift ;;
      --uninstall|uninstall)  action="uninstall"; shift ;;
      -h|--help|help)         usage; exit 0 ;;
      *) erro "unknown argument: $1"; echo; usage; exit 2 ;;
    esac
  done

  # model validation for the paths that use it
  case "$action" in
    ""|list) : ;;
  esac
  if [ -n "${model:-}" ] && [ -z "${M_LABEL[$model]:-}" ]; then
    die "unknown model '$model' — one of: ${MODELS[*]}  (see --list-models)"
  fi

  case "$action" in
    list)      list_models; exit 0 ;;
    status)    cmd_status; exit 0 ;;
    watch)     cmd_watch; exit 0 ;;
    reconnect) cmd_reconnect; exit 0 ;;
    off)       cmd_off; exit 0 ;;
    down)      cmd_down; exit 0 ;;
    check)     cmd_check ;;
    herald)    cmd_herald; exit 0 ;;
    uninstall) cmd_uninstall; exit 0 ;;
  esac

  # default action: install/provision
  printf '%s╔═ KM setup ═══════════════════════════════════════════════╗%s\n' "$C_B" "$C_0"
  ensure_node
  ensure_pi
  self_install

  if [ "$no_gpu" = "1" ] || [ -z "$gpu_str" ]; then
    if [ "$no_gpu" != "1" ] && [ -z "$gpu_str" ]; then
      warn "no --gpu string given — installing harness-only (honesty law: served model is DEMO)."
      info "  attach a box later with:  km --gpu \"<ssh… -L port:host:port>\" --model $model"
    fi
    install_context
    install_pi_extras
    install_herald
    park_improvised_subagents
    install_callcenter
    wire_models_json "${M_SERVED[$model]}" "" "${M_BEYOND[$model]}"
    STATE_SERVED=false STATE_MODEL="${M_SERVED[$model]}" STATE_MODEL_KEY="$model" save_state
    ok "harness ready (DEMO until a box attaches)."
    hero_card "${M_SERVED[$model]}-DEMO"
    exit 0
  fi

  install_context
  install_pi_extras
  install_herald
  park_improvised_subagents
  install_callcenter
  # shellcheck disable=SC2206
  read -r -a SSH_ARGS <<< "$gpu_str"
  gpu_flow "$model"
}

# run main unless the file is being sourced (e.g. by the test suite)
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
