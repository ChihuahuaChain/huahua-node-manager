#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION=0.2.0
CHAIN_ID=chihuahua-1
DENOM=uhuahua
DAEMON=chihuahuad
GITHUB_REPO=ChihuahuaChain/chihuahua
SNAPSHOT_URL=${HUAHUA_SNAPSHOT_URL:-https://snapshots.huahua.wtf}
GENESIS_URL=https://raw.githubusercontent.com/ChihuahuaChain/chihuahua/main/mainnet/genesis.json
GENESIS_SHA256=200a64f201c6b5799d81bcf52a25ce4eb1c0eac3f7c8c5eaa8335e75c5763f91
REGISTRY_URL=https://raw.githubusercontent.com/cosmos/chain-registry/master/chihuahua/chain.json
PEER_RPCS=${HUAHUA_PEER_RPCS:-https://rpc.chihuahua.wtf https://chihuahua-rpc.kleomedes.network https://rpc.chihuahua.validatus.com}
STATESYNC_RPCS=${HUAHUA_STATESYNC_RPCS:-https://rpc.chihuahua.wtf:443,https://chihuahua-rpc.kleomedes.network:443}
COSMOVISOR_VERSION=v1.7.1
SELF_URL=${HUAHUA_SELF_URL:-https://raw.githubusercontent.com/ChihuahuaChain/huahua-node-manager/main/huahua-node.sh}
CONF_FILE=${HUAHUA_CONF:-$HOME/.huahua-node.env}
SERVICE=chihuahuad
DEFAULT_GAS_PRICE=500$DENOM
TX_GAS_PRICE=1250$DENOM

PRESET_VARS="SETUP_MODE NODE_ROLE INSTALL_TYPE MONIKER NODE_HOME SYNC PRUNING KEEP_RECENT PRUNE_INTERVAL
  MIN_RETAIN_BLOCKS INDEXER LISTEN_IP PORT_OFFSET EXTERNAL_IP RPC_PUBLIC API MIN_GAS_PRICE COSMOVISOR
  AUTO_DOWNLOAD COMPOSE_DIR SERVICE CONTAINER NODE_BINARY KEYRING KEY_NAME P2P_PORT RPC_PORT API_PORT
  GRPC_PORT NODE_USER NODE_PID PUBLIC_IP"
for __v in $PRESET_VARS; do [ -n "${!__v+x}" ] && printf -v "PRESET_$__v" '%s' "${!__v}"; done
restore_presets() {
  local v p
  for v in $PRESET_VARS; do
    p=PRESET_$v
    if [ -n "${!p+x}" ]; then printf -v "$v" '%s' "${!p}"; else unset "$v"; fi
  done
  CONF_LOADED='' MANAGED=''
}

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\e[1m' D=$'\e[2m' R=$'\e[0m' RED=$'\e[31m' GRN=$'\e[32m' YEL=$'\e[33m' CYN=$'\e[36m'
else
  B='' D='' R='' RED='' GRN='' YEL='' CYN=''
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "${CYN}::${R} $*"; }
ok()   { printf '%s\n' "${GRN}✔${R} $*"; }
warn() { printf '%s\n' "${YEL}!${R} $*" >&2; }
die()  { printf '%s\n' "${RED}✘ $*${R}" >&2; exit 1; }
step() { STEP=$((STEP + 1)); printf '\n%s\n' "${B}${YEL}[$STEP/$STEPS]${R} ${B}$*${R}"; }
STEP=0 STEPS=0

trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR


logo_color() {
  local rgb c256 base=38
  [ "$2" = bg ] && base=48
  case $1 in
    Y) rgb=254\;212\;48 c256=220 ;;
    O) rgb=240\;168\;64 c256=214 ;;
    K) rgb=55\;55\;55 c256=237 ;;
    W) rgb=255\;255\;255 c256=231 ;;
    P) rgb=255\;128\;96 c256=209 ;;
    C) rgb=255\;250\;220 c256=230 ;;
  esac
  case ${COLORTERM:-} in
    truecolor|24bit) printf '\e[%s;2;%sm' "$base" "$rgb" ;;
    *) printf '\e[%s;5;%sm' "$base" "$c256" ;;
  esac
}

show_logo() {
  local rows=() line top bot out x t b
  while IFS= read -r line; do [ -n "$line" ] && rows+=("$line"); done <<< "$LOGO_GRID"
  if [ -n "$R" ]; then
    for ((y = 0; y < ${#rows[@]}; y += 2)); do
      top=${rows[y]} bot=${rows[y + 1]:-}
      out='  '
      for ((x = 0; x < ${#top}; x++)); do
        t=${top:x:1} b=${bot:x:1}
        b=${b:-.}
        if [ "$t" = . ] && [ "$b" = . ]; then out+=' '
        elif [ "$t" = . ]; then out+="$(logo_color "$b" fg)▄${R}"
        elif [ "$b" = . ]; then out+="$(logo_color "$t" fg)▀${R}"
        else out+="$(logo_color "$t" fg)$(logo_color "$b" bg)▀${R}"
        fi
      done
      printf '%s\n' "$out"
    done
  fi
  printf '\n  %s\n' "${B}${YEL}C H I H U A H U A${R}  ${B}node manager${R} ${D}v$SCRIPT_VERSION${R}"
  printf '  %s\n\n' "${D}woof woof${R}"
}

has_tty() { ( : < /dev/tty ) 2>/dev/null; }

get_sudo() {
  [ "$(id -u)" = 0 ] && return 0
  sudo -n true 2>/dev/null && return 0
  has_tty || die "sudo asks for a password: run on a terminal, or allow $(id -un) to use sudo without a password"
  sudo -v < /dev/tty
}

native_sudo() {
  local action
  while [ "$(id -u)" != 0 ]; do
    sudo -n true 2>/dev/null && return 0
    say
    info "The systemd service is written to /etc/systemd/system/${SERVICE:-chihuahuad}.service and enabled:"
    info "this needs administrator rights (sudo) once, for $(id -un)."
    if have sudo && has_tty && sudo -v -p "  [sudo] password for %u: " < /dev/tty; then
      ok "sudo granted"
      return 0
    fi
    has_tty || die "sudo asks for a password: run on a terminal, allow $(id -un) to use sudo without a password, or use INSTALL_TYPE=docker"
    have sudo || warn "sudo is not installed on this system"
    action=''
    choose action "sudo did not succeed. How to continue?" retry \
      "retry:try again" \
      "docker:run the node with Docker instead (no sudo needed)" \
      "exit:exit"
    case $action in
      retry) ;;
      docker) INSTALL_TYPE=docker; return 0 ;;
      exit) exit 0 ;;
    esac
  done
}

tty_read() {
  local __v
  if [ -n "${HUAHUA_YES:-}" ]; then return 1; fi
  has_tty || die "no terminal to ask \"$2\": set the answer with an environment variable or HUAHUA_YES=1"
  IFS= read -r -p "$2" __v < /dev/tty || __v=
  printf -v "$1" '%s' "$__v"
}

ask() {
  local __var=$1 __q=$2 __def=${3:-} __ans
  if [ -n "${!__var:-}" ]; then say "  $__q ${D}${!__var}${R}"; return; fi
  if tty_read __ans "  $__q ${D}[$__def]${R} "; then :; else __ans=; say "  $__q ${D}$__def${R}"; fi
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

choose() {
  local __var=$1 __q=$2 __def=$3; shift 3
  local __opts=("$@") __i __ans __defn=1
  local __n=${#__opts[@]}
  for __i in "${!__opts[@]}"; do [ "${__opts[__i]%%:*}" = "$__def" ] && __defn=$((__i + 1)); done
  if [ -n "${!__var:-}" ]; then
    for __i in "${__opts[@]}"; do [ "${__i%%:*}" = "${!__var}" ] && { say "  $__q ${D}${__i#*:}${R}"; return; }; done
    die "invalid $__var=${!__var} (valid: $(printf '%s ' "${__opts[@]%%:*}"))"
  fi
  say "  ${B}$__q${R}"
  for __i in "${!__opts[@]}"; do
    say "    $((__i + 1))) ${__opts[__i]#*:}$([ $((__i + 1)) = "$__defn" ] && printf ' %s' "${D}(default)${R}")"
  done
  while :; do
    if tty_read __ans "  choice ${D}[$__defn]${R} "; then :; else __ans=$__defn; fi
    __ans=${__ans:-$__defn}
    if [[ $__ans =~ ^[0-9]+$ ]] && [ "$__ans" -ge 1 ] && [ "$__ans" -le "$__n" ]; then
      printf -v "$__var" '%s' "${__opts[__ans - 1]%%:*}"
      return
    fi
    warn "choose a number between 1 and $__n"
  done
}

confirm() {
  local __ans __def=${2:-y}
  if tty_read __ans "  $1 ${D}[$([ "$__def" = y ] && echo Y/n || echo y/N)]${R} "; then :; else __ans=$__def; fi
  case ${__ans:-$__def} in [yY]*) return 0 ;; *) return 1 ;; esac
}

as_root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
try_root() {
  if [ "$(id -u)" = 0 ]; then "$@"
  elif sudo -n true 2>/dev/null; then sudo "$@"
  else return 1
  fi
}
have() { command -v "$1" >/dev/null 2>&1; }

toml_set() {
  local f=$1
  S=$2 K=$3 V=$4 awk '
    /^[[:space:]]*\[/ { s = $0; gsub(/^[[:space:]]*\[+|\]+[[:space:]]*$/, "", s); sec = s }
    sec == ENVIRON["S"] && !done && index($0, ENVIRON["K"] " = ") == 1 { print ENVIRON["K"] " = " ENVIRON["V"]; done = 1; next }
    { print }
    END { if (!done) exit 3 }' "$f" > "$f.tmp" || { rm -f "$f.tmp"; die "$f: no key \"$3\" in [${2:-top level}]"; }
  mv "$f.tmp" "$f"
}
q() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}"; }

port_busy() { ss -Hltn "sport = :$1" 2>/dev/null | grep -q . ; }

arch() {
  case $(uname -m) in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "unsupported CPU architecture $(uname -m) (amd64 and arm64 only)" ;;
  esac
}

download() {
  local progress=-sS
  [ -t 2 ] && progress=-#
  curl -fL --retry 3 --retry-delay 2 $progress -o "$2" "$1" || die "download failed: $1"
  if [ -n "${3:-}" ]; then
    echo "$3  $2" | sha256sum -c --status - || { rm -f "$2"; die "checksum mismatch for $1"; }
  fi
}

node_bin() {
  if [ -n "${NODE_BINARY:-}" ] && [ -x "$NODE_BINARY" ]; then echo "$NODE_BINARY"; return; fi
  if [ "${COSMOVISOR:-yes}" = yes ] && [ -x "$NODE_HOME/cosmovisor/current/bin/$DAEMON" ]; then
    echo "$NODE_HOME/cosmovisor/current/bin/$DAEMON"
  elif [ -x "$NODE_HOME/cosmovisor/genesis/bin/$DAEMON" ]; then
    echo "$NODE_HOME/cosmovisor/genesis/bin/$DAEMON"
  else
    echo "$NODE_HOME/bin/$DAEMON"
  fi
}
nd() { "$(node_bin)" "$@"; }
local_rpc() { echo "http://127.0.0.1:${RPC_PORT:-26657}"; }
node_flag() { echo "--node=tcp://127.0.0.1:${RPC_PORT:-26657}"; }
rpc_status() { curl -fs --max-time 5 "$(local_rpc)/status"; }

live_peers() {
  local rpc
  for rpc in $PEER_RPCS; do
    curl -fs --max-time 10 "$rpc/net_info" 2>/dev/null |
      jq -r '.result.peers[]? | "\(.node_info.id)@\(.remote_ip):\(.node_info.listen_addr | split(":") | last)"' 2>/dev/null || true
  done | grep -vE '@(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | sort -u | head -20 | paste -sd, - || true
}

save_conf() {
  local v
  {
    for v in INSTALL_TYPE NODE_ROLE MONIKER NODE_HOME SYNC COSMOVISOR AUTO_DOWNLOAD P2P_PORT RPC_PORT API_PORT GRPC_PORT \
             KEYRING KEY_NAME COMPOSE_DIR SERVICE CONTAINER NODE_BINARY; do
      printf '%s=%q\n' "$v" "${!v:-}"
    done
  } > "$CONF_FILE"
}
load_conf() {
  [ -n "${CONF_LOADED:-}" ] && return
  if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE"
    MANAGED=1 CONF_LOADED=1
    : "${SERVICE:=chihuahuad}" "${CONTAINER:=chihuahuad}" "${AUTO_DOWNLOAD:=no}"
    return
  fi
  detect_running_node || die "no Chihuahua node found: run huahua-node without arguments to set one up"
}

service_ctl() {
  case $INSTALL_TYPE in
    docker)
      case $1 in
        status) docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "not found" ;;
        start|restart)
          if [ -n "${COMPOSE_DIR:-}" ] && [ -f "$COMPOSE_DIR/docker-compose.yml" ]; then
            (cd "$COMPOSE_DIR" && if [ "$1" = restart ]; then docker compose restart; else docker compose up -d; fi)
          else docker "$1" "$CONTAINER" >/dev/null; fi ;;
        stop) docker stop -t 60 "$CONTAINER" >/dev/null ;;
      esac ;;
    manual)
      case $1 in
        status) if [ -n "${NODE_PID:-}" ] && kill -0 "$NODE_PID" 2>/dev/null; then echo running; else echo stopped; fi ;;
        stop) kill -TERM "$NODE_PID"; while kill -0 "$NODE_PID" 2>/dev/null; do sleep 1; done ;;
        *) warn "this node was started by hand: start it the same way, or add cosmovisor to turn it into a service"; return 1 ;;
      esac ;;
    *)
      case $1 in
        status) systemctl is-active "$SERVICE" 2>/dev/null || true ;;
        *) as_root systemctl "$1" "$SERVICE" ;;
      esac ;;
  esac
}

detect_running_node() {
  local pid args home user cg cid comm ppid st cfg p
  for pid in $({ pgrep -x cosmovisor; pgrep -x "$DAEMON"; } 2>/dev/null || true); do
    args=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
    [[ " $args " == *" start "* ]] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null)
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ "$comm" = "$DAEMON" ] && [ "$(ps -o comm= -p "$ppid" 2>/dev/null)" = cosmovisor ] && continue
    user=$(ps -o user= -p "$pid" 2>/dev/null)
    home=$(sed -nE 's/.*--home[= ]([^ ]+).*/\1/p' <<< "$args")
    [ -n "$home" ] || home=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^DAEMON_HOME=//p')
    [ -n "$home" ] || home=$(getent passwd "$user" | cut -d: -f6)/.chihuahuad
    cg=$(cat "/proc/$pid/cgroup" 2>/dev/null)
    cid=$(grep -oE '[0-9a-f]{64}' <<< "$cg" | head -1 || true)
    INSTALL_TYPE=manual SERVICE='' CONTAINER='' COMPOSE_DIR='' NODE_PID=$pid
    if [ -n "$cid" ] && have docker; then
      INSTALL_TYPE=docker
      CONTAINER=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | tr -d /)
      COMPOSE_DIR=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$cid" 2>/dev/null || true)
      home=$(docker inspect -f '{{json .Mounts}}' "$cid" 2>/dev/null | jq -r --arg h "$home" '
        [.[] | select(($h + "/") | startswith(.Destination + "/"))] | max_by(.Destination | length) |
        if . then .Source + ($h | ltrimstr(.Destination)) else $h end' 2>/dev/null || echo "$home")
    elif p=$(grep -oE 'system\.slice/[^/]+\.service' <<< "$cg" | head -1); then
      INSTALL_TYPE=native SERVICE=${p#system.slice/}; SERVICE=${SERVICE%.service}
    fi
    NODE_HOME=$home
    COSMOVISOR=no; [ "$comm" = cosmovisor ] && COSMOVISOR=yes
    NODE_BINARY=''
    if [ "$COSMOVISOR" = no ] && [ "$INSTALL_TYPE" != docker ]; then NODE_BINARY=$(readlink "/proc/$pid/exe" 2>/dev/null || true); fi
    cfg=$NODE_HOME/config/config.toml
    RPC_PORT=$(awk '/^\[rpc\]/ { s = 1 } s && /^laddr = / { gsub(/.*:|"/, ""); print; exit }' "$cfg" 2>/dev/null || true)
    P2P_PORT=$(awk '/^\[p2p\]/ { s = 1 } s && /^laddr = / { gsub(/.*:|"/, ""); print; exit }' "$cfg" 2>/dev/null || true)
    : "${RPC_PORT:=26657}" "${P2P_PORT:=26656}"
    st=$(rpc_status 2>/dev/null) || continue
    [ "$(jq -r .result.node_info.network <<< "$st")" = "$CHAIN_ID" ] || continue
    MONIKER=$(jq -r .result.node_info.moniker <<< "$st")
    NODE_ROLE=full; [ "$(jq -r .result.validator_info.voting_power <<< "$st")" != 0 ] && NODE_ROLE=validator
    NODE_USER=$user AUTO_DOWNLOAD=no KEYRING=file KEY_NAME=wallet MANAGED='' CONF_LOADED=1
    return 0
  done
  return 1
}

find_node() {
  if [ -f "$CONF_FILE" ]; then
    load_conf
    [ -d "$NODE_HOME" ] && return 0
    warn "the node recorded in $CONF_FILE is gone ($NODE_HOME)"
    CONF_LOADED='' MANAGED=''
  fi
  detect_running_node
}

node_panel() {
  local state st how
  state=$(service_ctl status 2>/dev/null || true)
  case $INSTALL_TYPE in
    docker) how="Docker container $CONTAINER" ;;
    manual) how="process $NODE_PID, started by hand" ;;
    *) how="systemd service $SERVICE" ;;
  esac
  say
  say "  ${B}${YEL}Chihuahua node found${R}${D}$([ -z "${MANAGED:-}" ] && echo " (not installed by huahua-node)")${R}"
  say "  name        $MONIKER ($NODE_ROLE)"
  say "  runs as     $how"
  say "  directory   $NODE_HOME"
  say "  cosmovisor  $([ "$COSMOVISOR" = yes ] && echo yes || echo "${YEL}no${R}")"
  if st=$(rpc_status 2>/dev/null); then
    say "  state       ${GRN}${state:-running}${R}, block $(jq -r .result.sync_info.latest_block_height <<< "$st"), $(
      [ "$(jq -r .result.sync_info.catching_up <<< "$st")" = false ] && echo "in sync" || echo "catching up")," \
      "$(curl -fs --max-time 3 "$(local_rpc)/net_info" | jq -r .result.n_peers 2>/dev/null) peers"
  else
    say "  state       ${YEL}${state:-stopped}${R}"
  fi
  say
}

manage_menu() {
  local running opts def
  while :; do
    node_panel
    running=''; rpc_status >/dev/null 2>&1 && running=1
    opts=("status:Status" "watch:Sync progress" "logs:Logs (Ctrl-C to come back)")
    if [ -n "$running" ]; then opts+=("restart:Restart" "stop:Stop"); else opts+=("start:Start"); fi
    [ "$COSMOVISOR" = yes ] || opts+=("cosmovisor:Add cosmovisor (automatic binary switch at upgrades)")
    opts+=("upgrade:Prepare the next chain upgrade")
    [ "$NODE_ROLE" = validator ] || opts+=("validator:Turn this node into a validator")
    [ -n "${MANAGED:-}" ] && opts+=("uninstall:Uninstall")
    opts+=("setup:Set up another node" "exit:Exit")
    MENU_ACTION=${HUAHUA_ACTION:-}; HUAHUA_ACTION=''
    def='status'; [ -n "${HUAHUA_YES:-}" ] && def='exit'
    choose MENU_ACTION "What do you want to do?" "$def" "${opts[@]}"
    say
    case $MENU_ACTION in
      status) (cmd_status) || true ;;
      watch) watch_sync 86400 || true ;;
      logs) trap 'true' INT; show_logs || true; trap - INT; say ;;
      start|stop|restart) service_ctl "$MENU_ACTION" && ok "$MENU_ACTION: done" || warn "$MENU_ACTION failed" ;;
      cosmovisor) add_cosmovisor || true ;;
      upgrade) (cmd_upgrade) || true ;;
      validator) (cmd_validator) || true ;;
      uninstall) cmd_uninstall; exit 0 ;;
      setup) restore_presets; return 0 ;;
      exit) exit 0 ;;
    esac
    [ -n "${HUAHUA_YES:-}" ] && exit 0
    say; confirm "Back to the menu?" y || exit 0
  done
}

show_logs() {
  case $INSTALL_TYPE in
    docker) docker logs -f --tail 100 "$CONTAINER" ;;
    manual) warn "a node started by hand logs where it was started" ; return 1 ;;
    *) journalctl -fu "$SERVICE" -o cat -n 100 2>/dev/null || as_root journalctl -fu "$SERVICE" -o cat -n 100 ;;
  esac
}

install_cosmovisor() {
  local tmp cv sha
  tmp=$(mktemp -d)
  cv="cosmovisor-$COSMOVISOR_VERSION-linux-$ARCH.tar.gz"
  download "https://github.com/cosmos/cosmos-sdk/releases/download/cosmovisor/$COSMOVISOR_VERSION/SHA256SUMS-cosmovisor-$COSMOVISOR_VERSION.txt" "$tmp/sums" >/dev/null
  sha=$(awk -v f="$cv" '$2 == f { print $1 }' "$tmp/sums")
  download "https://github.com/cosmos/cosmos-sdk/releases/download/cosmovisor/$COSMOVISOR_VERSION/$cv" "$tmp/$cv" "$sha"
  tar -xzf "$tmp/$cv" -C "$tmp" cosmovisor
  mkdir -p "$NODE_HOME/bin"
  install -m 0755 "$tmp/cosmovisor" "$NODE_HOME/bin/cosmovisor"
  rm -rf "$tmp"
}

cosmovisor_init() {
  local bin=$1 name
  rm -rf "${NODE_HOME:?}/cosmovisor"
  DAEMON_HOME=$NODE_HOME DAEMON_NAME=$DAEMON "$NODE_HOME/bin/cosmovisor" init "$bin" >/dev/null 2>&1 ||
    die "cosmovisor init failed"
  name=$(jq -r '.name // empty' "$NODE_HOME/data/upgrade-info.json" 2>/dev/null || true)
  if [ -n "$name" ]; then
    mkdir -p "$NODE_HOME/cosmovisor/upgrades/$name/bin"
    cp -p "$bin" "$NODE_HOME/cosmovisor/upgrades/$name/bin/$DAEMON"
    ln -sfn "upgrades/$name" "$NODE_HOME/cosmovisor/current"
  fi
}

write_unit() {
  local exec unit
  if [ "$COSMOVISOR" = yes ]; then exec="$NODE_HOME/bin/cosmovisor run start --home $NODE_HOME${1:+ $1}"
  else exec="${NODE_BINARY:-$NODE_HOME/bin/$DAEMON} start --home $NODE_HOME${1:+ $1}"; fi
  unit="[Unit]
Description=Chihuahua node ($MONIKER)
After=network-online.target
Wants=network-online.target

[Service]
User=${NODE_USER:-$(id -un)}
ExecStart=$exec
Restart=always
RestartSec=5
LimitNOFILE=65535
Environment=DAEMON_NAME=$DAEMON
Environment=DAEMON_HOME=$NODE_HOME
Environment=DAEMON_RESTART_AFTER_UPGRADE=true
Environment=DAEMON_ALLOW_DOWNLOAD_BINARIES=$([ "${AUTO_DOWNLOAD:-no}" = yes ] && echo true || echo false)
Environment=UNSAFE_SKIP_BACKUP=true

[Install]
WantedBy=multi-user.target"
  printf '%s\n' "$unit" | as_root tee "/etc/systemd/system/$SERVICE.service" >/dev/null
  as_root systemctl daemon-reload
}

add_cosmovisor() {
  ARCH=$(arch)
  if [ "$INSTALL_TYPE" = docker ] && [ -z "${MANAGED:-}" ]; then
    warn "this container was not created by huahua-node: add cosmovisor to its image, or set up a new node"; return 1
  fi
  if [ "${NODE_USER:-$(id -un)}" != "$(id -un)" ]; then
    warn "the node runs as ${NODE_USER}: run huahua-node as that user"; return 1
  fi
  local bin extra='' args
  bin=$(node_bin)
  [ -x "$bin" ] || { warn "node binary not found ($bin)"; return 1; }
  if [ "$INSTALL_TYPE" = native ]; then
    args=$(systemctl show -p ExecStart --value "$SERVICE" 2>/dev/null | sed -nE 's/.*argv\[\]=([^;]*);.*/\1/p')
  elif [ "$INSTALL_TYPE" = manual ]; then
    args=$(tr '\0' ' ' < "/proc/$NODE_PID/cmdline" 2>/dev/null)
  fi
  if [ "$INSTALL_TYPE" = manual ]; then
    SERVICE=chihuahuad
    systemctl cat "$SERVICE" >/dev/null 2>&1 && SERVICE=chihuahuad-node
  fi
  extra=$(sed -E 's/.* start ?//; s/--home[= ][^ ]+//; s/  +/ /g; s/^ +| +$//g' <<< "${args:-} ")
  say "  cosmovisor $COSMOVISOR_VERSION will run $("$bin" version 2>&1) from $NODE_HOME/cosmovisor"
  case $INSTALL_TYPE in
    native) say "  the service $SERVICE is rewritten (the current one is backed up) and restarted" ;;
    manual) say "  the node (process $NODE_PID) is stopped and started again as the systemd service $SERVICE" ;;
    docker) say "  the container is recreated" ;;
  esac
  [ "$NODE_ROLE" = validator ] && warn "the validator misses a few blocks during the restart"
  confirm "Proceed?" y || return 1
  if [ "$INSTALL_TYPE" != docker ]; then get_sudo || return 1; fi

  install_cosmovisor
  cosmovisor_init "$bin"
  COSMOVISOR=yes NODE_BINARY=''
  case $INSTALL_TYPE in
    native)
      as_root cp -p "/etc/systemd/system/$SERVICE.service" "/etc/systemd/system/$SERVICE.service.bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
      write_unit "$extra"
      as_root systemctl restart "$SERVICE" ;;
    manual)
      service_ctl stop
      INSTALL_TYPE=native
      write_unit "$extra"
      as_root systemctl enable -q --now "$SERVICE" ;;
    docker)
      write_compose
      (cd "$COMPOSE_DIR" && docker compose up -d --force-recreate >/dev/null 2>&1) ;;
  esac
  local i
  for i in $(seq 1 30); do rpc_status >/dev/null 2>&1 && break; sleep 2; done
  rpc_status >/dev/null 2>&1 || { warn "the node does not answer yet: look at the logs"; }
  [ -n "${MANAGED:-}" ] || { MANAGED=1; : "${COMPOSE_DIR:=}"; }
  save_conf
  ok "cosmovisor added: the node runs under cosmovisor $([ "$INSTALL_TYPE" = native ] && echo "as the service $SERVICE")"
  info "prepare each chain upgrade with \"huahua-node upgrade\""
}

install_deps() {
  local missing=() c pkgs
  for c in curl jq lz4 tar sha256sum awk sed ss; do have "$c" || missing+=("$c"); done
  [ ${#missing[@]} = 0 ] && { ok "tools: all present"; return; }
  pkgs=$(printf '%s\n' "${missing[@]}" | sed 's/^sha256sum$/coreutils/; s/^ss$/iproute2/; s/^awk$/gawk/' | sort -u | tr '\n' ' ')
  warn "missing tools: ${missing[*]}"
  confirm "Install them now ($pkgs)?" y || die "install $pkgs and run again"
  if have apt-get; then
    as_root apt-get update -qq >/dev/null && as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs >/dev/null
  elif have dnf; then as_root dnf install -y -q ${pkgs//iproute2/iproute}
  elif have yum; then as_root yum install -y -q ${pkgs//iproute2/iproute}
  elif have pacman; then as_root pacman -Sy --noconfirm ${pkgs//iproute2/iproute2}
  elif have apk; then as_root apk add --no-cache $pkgs
  elif have zypper; then as_root zypper -n install $pkgs
  else die "no known package manager: install $pkgs and run again"
  fi
  ok "tools installed"
}

preflight() {
  [ "$(uname -s)" = Linux ] || die "Linux only"
  ARCH=$(arch)
  if [ "$(id -u)" != 0 ] && ! have sudo; then
    warn "sudo is not installed: only the Docker mode is available"
  fi
  [ "$(id -u)" = 0 ] && warn "running as root: a dedicated user is safer for a node"
  install_deps

  local cpus ram_gb disk_gb
  cpus=$(nproc)
  ram_gb=$(awk '/MemTotal/ { printf "%d", $2 / 1024 / 1024 + 0.5 }' /proc/meminfo)
  disk_gb=$(df -Pk "$(dirname "${NODE_HOME:-$HOME/.chihuahuad}")" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1024 / 1024 }')
  say "  system: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}"), $ARCH, $cpus CPU, ${ram_gb} GB RAM, ${disk_gb} GB free"
  [ "$cpus" -ge 4 ] || warn "4 CPU cores or more are recommended"
  [ "$ram_gb" -ge 8 ] || warn "8 GB of RAM or more is recommended"
  [ "$disk_gb" -ge 50 ] || warn "50 GB of free disk or more is recommended (much more for an archive node)"
}

detect_public_ip() {
  curl -fs --max-time 5 https://api.ipify.org 2>/dev/null || curl -fs --max-time 5 https://ifconfig.co 2>/dev/null || true
}

set_ports() {
  P2P_PORT=$((26656 + $1)) RPC_PORT=$((26657 + $1)) ABCI_PORT=$((26658 + $1))
  PROM_PORT=$((26660 + $1)) PPROF_PORT=$((6060 + $1)) API_PORT=$((1317 + $1)) GRPC_PORT=$((9090 + $1))
}
ports_free() {
  local p
  for p in $P2P_PORT $RPC_PORT $ABCI_PORT $PPROF_PORT $API_PORT $GRPC_PORT; do
    [[ " ${OWN_PORTS:-} " == *" $p "* ]] && continue
    port_busy "$p" && return 1
  done
  return 0
}

own_ports() {
  cat "$NODE_HOME/config/config.toml" "$NODE_HOME/config/app.toml" 2>/dev/null |
    grep -E '^(laddr|proxy_app|pprof_laddr|address) = ' | grep -oE ':[0-9]+"' | tr -d ':"' | sort -u | tr '\n' ' ' || true
}

settings() {
  step "Settings"
  choose SETUP_MODE "Setup mode" easy \
    "easy:Easy     - a few questions, recommended defaults" \
    "advanced:Advanced - choose every option" \
    "exit:Exit"
  [ "$SETUP_MODE" = exit ] && exit 0
  say
  choose NODE_ROLE "Node type" full \
    "full:Full node  - follows the chain, serves RPC/queries" \
    "validator:Validator  - signs blocks (needs HUAHUA to stake)"
  choose INSTALL_TYPE "Run the node with" native \
    "native:systemd service (native binary)" \
    "docker:Docker (docker compose)"
  if [ "$INSTALL_TYPE" = native ]; then
    have systemctl || { warn "systemd not found: using Docker"; INSTALL_TYPE=docker; }
  fi
  [ "$INSTALL_TYPE" = native ] && native_sudo
  if [ "$INSTALL_TYPE" = docker ]; then
    have docker && docker compose version >/dev/null 2>&1 ||
      die "Docker with the compose plugin is required: https://docs.docker.com/engine/install/"
    docker info >/dev/null 2>&1 ||
      die "$(id -un) cannot use Docker: add it to the docker group (sudo usermod -aG docker $(id -un)) and log in again"
  fi
  ask MONIKER "Node name (moniker):" "$(hostname -s)-huahua"

  local adv=; [ "$SETUP_MODE" = advanced ] && adv=1

  : "${NODE_HOME:=$HOME/.chihuahuad}" "${SYNC:=snapshot}" "${COSMOVISOR:=yes}" "${MIN_GAS_PRICE:=$DEFAULT_GAS_PRICE}"
  : "${PRUNING:=pruned}" "${MIN_RETAIN_BLOCKS:=0}" "${LISTEN_IP:=0.0.0.0}" "${RPC_PUBLIC:=no}" "${API:=no}" "${AUTO_DOWNLOAD:=no}"
  [ "$NODE_ROLE" = validator ] && : "${INDEXER:=null}"
  : "${INDEXER:=kv}"
  COMPOSE_DIR=${COMPOSE_DIR:-$HOME/chihuahua-node}
  SERVICE=${SERVICE:-chihuahuad} CONTAINER=${CONTAINER:-chihuahuad} NODE_BINARY='' 

  if [ -n "$adv" ]; then
    say; say "  ${B}Storage${R}"
    ask NODE_HOME_IN "Node directory:" "$NODE_HOME"; NODE_HOME=$NODE_HOME_IN
    choose PRUNING_IN "State pruning" "$PRUNING" \
      "pruned:Pruned     - keep the last 100 states (smallest disk, recommended)" \
      "default:Default    - SDK default, keep the last 362880 states" \
      "everything:Everything - keep only the last 2 states" \
      "nothing:Nothing    - keep every state from the sync point on (disk grows fastest)" \
      "custom:Custom"
    PRUNING=$PRUNING_IN
    if [ "$PRUNING" = custom ]; then
      ask KEEP_RECENT "pruning-keep-recent:" 100
      ask PRUNE_INTERVAL "pruning-interval:" 10
    fi
    ask MIN_RETAIN_BLOCKS_IN "Blocks to keep (min-retain-blocks, 0 = all):" "$MIN_RETAIN_BLOCKS"
    MIN_RETAIN_BLOCKS=$MIN_RETAIN_BLOCKS_IN
    choose INDEXER_IN "Transaction indexing" "$INDEXER" \
      "null:Off  - lighter, recommended for validators" \
      "kv:On   - needed to search transactions through this node's RPC"
    INDEXER=$INDEXER_IN

    say; say "  ${B}Sync${R}"
    choose SYNC_IN "How to get the chain state" "$SYNC" \
      "snapshot:Snapshot   - download from $SNAPSHOT_URL (fastest)" \
      "statesync:State sync - fetch the state from the network peers"
    SYNC=$SYNC_IN
    [ "$PRUNING" = nothing ] &&
      warn "with pruning \"nothing\" the node keeps every state from the sync point on, not the full history"

    say; say "  ${B}Network${R}"
    local ifs=("0.0.0.0:all interfaces") line
    while read -r line; do ifs+=("${line#* }:${line%% *} (${line#* })"); done < <(
      ip -o -4 addr show scope global 2>/dev/null | awk '{ split($4, a, "/"); print $2, a[1] }')
    choose LISTEN_IP_IN "P2P listen interface" "$LISTEN_IP" "${ifs[@]}"
    LISTEN_IP=$LISTEN_IP_IN
    ask PORT_OFFSET "Port offset (0 = standard ports 26656/26657, 1000 = 27656/27657, ...):" "${PORT_OFFSET:-auto}"
    choose RPC_PUBLIC_IN "RPC (port 26657 + offset) reachable from" "$RPC_PUBLIC" \
      "no:this machine only (recommended)" \
      "yes:the network ($LISTEN_IP)"
    RPC_PUBLIC=$RPC_PUBLIC_IN
    choose API_IN "REST API and gRPC (local only)" "$API" "no:Off" "yes:On"
    API=$API_IN
    ask MIN_GAS_PRICE_IN "Minimum gas price:" "$MIN_GAS_PRICE"; MIN_GAS_PRICE=$MIN_GAS_PRICE_IN

    say; say "  ${B}Upgrades${R}"
    choose COSMOVISOR_IN "Cosmovisor (switches binary automatically at chain upgrades)" "$COSMOVISOR" \
      "yes:Yes (recommended)" "no:No"
    COSMOVISOR=$COSMOVISOR_IN
    if [ "$COSMOVISOR" = yes ]; then
      choose AUTO_DOWNLOAD_IN "Let cosmovisor download upgrade binaries by itself" "$AUTO_DOWNLOAD" \
        "no:No - you prepare them with \"huahua-node upgrade\" (recommended)" \
        "yes:Yes - when the upgrade proposal lists them"
      AUTO_DOWNLOAD=$AUTO_DOWNLOAD_IN
    fi
  fi

  case $SYNC in snapshot|statesync) ;; *) die "invalid SYNC=$SYNC (valid: snapshot statesync)" ;; esac

  OWN_PORTS=$(own_ports)
  if [ "${PORT_OFFSET:-auto}" = auto ]; then
    local off
    for off in 0 1000 2000 3000 4000 5000 6000 7000 8000 9000; do
      set_ports "$off"
      ports_free && break
    done
    ports_free || die "no free ports found: set PORT_OFFSET"
    [ "$off" = 0 ] || warn "standard ports in use: using offset $off (P2P $P2P_PORT, RPC $RPC_PORT)"
  else
    [[ $PORT_OFFSET =~ ^[0-9]+$ ]] || die "invalid port offset: $PORT_OFFSET"
    set_ports "$PORT_OFFSET"
    ports_free || warn "some of the ports are already in use"
  fi

  PUBLIC_IP=${PUBLIC_IP:-$(detect_public_ip)}
  if [ -n "$PUBLIC_IP" ]; then
    if [ -n "$adv" ]; then ask EXTERNAL_IP "Public address announced to peers:" "$PUBLIC_IP"
    else EXTERNAL_IP=${EXTERNAL_IP:-$PUBLIC_IP}; say "  Public address announced to peers: ${D}$EXTERNAL_IP${R}"; fi
  else
    warn "public IP not detected: other nodes will not dial this node (outbound peers still work)"
  fi

  if [ "$INSTALL_TYPE" = docker ]; then COSMOVISOR=${COSMOVISOR:-yes}; fi
  [ "$NODE_ROLE" = validator ] && { KEYRING=${KEYRING:-file}; KEY_NAME=${KEY_NAME:-validator}; }
  : "${KEYRING:=file}" "${KEY_NAME:=wallet}"
}

summary() {
  step "Summary"
  local pr=$PRUNING
  [ "$PRUNING" = pruned ] && pr="pruned (keep 100 states)"
  [ "$PRUNING" = custom ] && pr="custom (keep $KEEP_RECENT, interval $PRUNE_INTERVAL)"
  cat <<EOF
  node        $MONIKER, ${NODE_ROLE} on $CHAIN_ID
  runs with   $([ "$INSTALL_TYPE" = docker ] && echo "Docker ($COMPOSE_DIR)" || echo "systemd service $SERVICE")$([ "$COSMOVISOR" = yes ] && echo ", cosmovisor")
  directory   $NODE_HOME
  sync        $SYNC
  pruning     $pr, min-retain-blocks $MIN_RETAIN_BLOCKS
  indexing    $([ "$INDEXER" = kv ] && echo on || echo off)
  network     P2P $LISTEN_IP:$P2P_PORT$([ -n "${EXTERNAL_IP:-}" ] && echo " (announced as $EXTERNAL_IP:$P2P_PORT)"), RPC $([ "$RPC_PUBLIC" = yes ] && echo "$LISTEN_IP" || echo 127.0.0.1):$RPC_PORT$([ "$API" = yes ] && echo ", API :$API_PORT, gRPC :$GRPC_PORT")
  gas price   $MIN_GAS_PRICE
EOF
  say
  confirm "Proceed?" y || die "cancelled"
}

check_existing() {
  NEW_HOME=''
  [ -e "$NODE_HOME" ] || NEW_HOME=1
  if [ -f "$NODE_HOME/config/config.toml" ] || [ -d "$NODE_HOME/data/application.db" ]; then
    warn "$NODE_HOME already contains a node"
    [ -n "${HUAHUA_REPLACE:-}" ] || confirm "Replace it? Keys and node identity are kept, the chain data is deleted" n ||
      die "cancelled"
    if [ "$INSTALL_TYPE" = native ] && systemctl is-active -q "$SERVICE" 2>/dev/null; then as_root systemctl stop "$SERVICE"; fi
    if [ -f "$COMPOSE_DIR/docker-compose.yml" ]; then (cd "$COMPOSE_DIR" && docker compose down >/dev/null 2>&1) || true; fi
    backup_keys
    wipe_chain_data
    rm -f "$NODE_HOME/config/genesis.json" "$NODE_HOME/config/config.toml" \
      "$NODE_HOME/config/app.toml" "$NODE_HOME/config/addrbook.json"
  fi
}

backup_keys() {
  local dir f
  dir=$HOME/chihuahua-backup-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$dir"; chmod 700 "$dir"
  for f in config/priv_validator_key.json config/node_key.json data/priv_validator_state.json; do
    [ -f "$NODE_HOME/$f" ] && cp -p "$NODE_HOME/$f" "$dir/"
  done
  for f in "$NODE_HOME"/keyring-*; do [ -d "$f" ] && cp -rp "$f" "$dir/"; done
  ok "keys backed up to $dir"
}

chain_version() {
  local v
  v=$(curl -fs --max-time 10 "$SNAPSHOT_URL/latest.json" | jq -r '.version // empty' 2>/dev/null || true)
  [ -n "$v" ] || v=$(curl -fs --max-time 10 "https://api.github.com/repos/$GITHUB_REPO/releases/latest" | jq -r .tag_name)
  [ -n "$v" ] && [ "$v" != null ] || die "cannot determine the chihuahuad version to install"
  echo "$v"
}

fetch_release() {
  local tag=$1 dest=$2 tmp sha
  tmp=$(mktemp -d)
  download "https://github.com/$GITHUB_REPO/releases/download/$tag/chihuahuad_sha256.txt" "$tmp/sha" >/dev/null
  sha=$(awk -v f="chihuahuad_linux_$ARCH" '$2 == f { print $1 }' "$tmp/sha")
  [ -n "$sha" ] || die "no checksum for chihuahuad_linux_$ARCH in release $tag"
  download "https://github.com/$GITHUB_REPO/releases/download/$tag/chihuahuad_linux_$ARCH" "$tmp/bin" "$sha"
  install -m 0755 "$tmp/bin" "$dest"
  rm -rf "$tmp"
}

install_binaries() {
  step "Binaries"
  VERSION=$(chain_version)
  info "chihuahuad $VERSION ($ARCH)"
  mkdir -p "$NODE_HOME/bin"
  fetch_release "$VERSION" "$NODE_HOME/bin/$DAEMON.download"
  mv "$NODE_HOME/bin/$DAEMON.download" "$NODE_HOME/bin/$DAEMON"
  ok "chihuahuad $("$NODE_HOME/bin/$DAEMON" version 2>&1) verified"

  if [ "$COSMOVISOR" = yes ]; then
    install_cosmovisor
    cosmovisor_init "$NODE_HOME/bin/$DAEMON"
    rm -f "$NODE_HOME/bin/$DAEMON"
    ok "cosmovisor $COSMOVISOR_VERSION"
  fi

  local target
  target=$([ "$COSMOVISOR" = yes ] && echo "$NODE_HOME/cosmovisor/current/bin/$DAEMON" || echo "$NODE_HOME/bin/$DAEMON")
  if try_root ln -sfn "$target" /usr/local/bin/$DAEMON 2>/dev/null; then
    ok "chihuahuad available in the PATH"
  else
    mkdir -p "$HOME/.local/bin" && ln -sfn "$target" "$HOME/.local/bin/$DAEMON"
    ok "chihuahuad linked in ~/.local/bin"
  fi
}

configure_node() {
  step "Node configuration"
  local cfg=$NODE_HOME/config/config.toml app=$NODE_HOME/config/app.toml client=$NODE_HOME/config/client.toml
  nd init "$MONIKER" --chain-id "$CHAIN_ID" --home "$NODE_HOME" >/dev/null 2>&1 || die "chihuahuad init failed"
  toml_set "$cfg" "" moniker "$(q "$MONIKER")"

  info "genesis"
  download "$GENESIS_URL" "$NODE_HOME/config/genesis.json" "$GENESIS_SHA256"
  ok "genesis verified"

  info "peers"
  local seeds peers
  seeds=$(curl -fs --max-time 10 "$REGISTRY_URL" | jq -r '[.peers.seeds[] | "\(.id)@\(.address)"] | join(",")' 2>/dev/null || true)
  peers=$(live_peers)
  [ -n "$peers$seeds" ] || warn "no peers found: the node will rely on the address book"
  ok "$(echo "$peers" | tr ',' '\n' | grep -c @ || true) live peers, $(echo "$seeds" | tr ',' '\n' | grep -c @ || true) seeds"
  toml_set "$cfg" p2p seeds "$(q "$seeds")"
  toml_set "$cfg" p2p persistent_peers "$(q "$peers")"

  local rpc_ip=127.0.0.1
  [ "$RPC_PUBLIC" = yes ] && rpc_ip=$LISTEN_IP
  toml_set "$cfg" "" proxy_app "$(q "tcp://127.0.0.1:$ABCI_PORT")"
  toml_set "$cfg" rpc laddr "$(q "tcp://$rpc_ip:$RPC_PORT")"
  toml_set "$cfg" rpc pprof_laddr "$(q "localhost:$PPROF_PORT")"
  toml_set "$cfg" p2p laddr "$(q "tcp://$LISTEN_IP:$P2P_PORT")"
  [ -n "${EXTERNAL_IP:-}" ] && toml_set "$cfg" p2p external_address "$(q "$EXTERNAL_IP:$P2P_PORT")"
  toml_set "$cfg" instrumentation prometheus_listen_addr "$(q ":$PROM_PORT")"
  toml_set "$cfg" tx_index indexer "$(q "$INDEXER")"

  toml_set "$app" api enable "$([ "$API" = yes ] && echo true || echo false)"
  toml_set "$app" api address "$(q "tcp://localhost:$API_PORT")"
  toml_set "$app" grpc enable "$([ "$API" = yes ] && echo true || echo false)"
  toml_set "$app" grpc address "$(q "localhost:$GRPC_PORT")"
  toml_set "$app" grpc-web enable false

  toml_set "$app" "" minimum-gas-prices "$(q "$MIN_GAS_PRICE")"
  case $PRUNING in
    pruned) toml_set "$app" "" pruning '"custom"'; toml_set "$app" "" pruning-keep-recent '"100"'; toml_set "$app" "" pruning-interval '"10"' ;;
    custom) toml_set "$app" "" pruning '"custom"'; toml_set "$app" "" pruning-keep-recent "$(q "$KEEP_RECENT")"; toml_set "$app" "" pruning-interval "$(q "$PRUNE_INTERVAL")" ;;
    *) toml_set "$app" "" pruning "$(q "$PRUNING")" ;;
  esac
  toml_set "$app" "" min-retain-blocks "$MIN_RETAIN_BLOCKS"

  toml_set "$client" "" chain-id "$(q "$CHAIN_ID")"
  toml_set "$client" "" keyring-backend "$(q "$KEYRING")"
  toml_set "$client" "" node "$(q "tcp://127.0.0.1:$RPC_PORT")"
  ok "config.toml, app.toml and client.toml written"
}

wipe_chain_data() {
  local state=$NODE_HOME/data/priv_validator_state.json keep=''
  [ -f "$state" ] && keep=$(cat "$state")
  rm -rf "${NODE_HOME:?}/data" "${NODE_HOME:?}/wasm"
  mkdir -p "$NODE_HOME/data"
  if [ -n "$keep" ]; then printf '%s\n' "$keep" > "$state"
  else echo '{"height":"0","round":0,"step":0}' > "$state"; fi
}

restore_snapshot() {
  local meta file size sha tmp
  meta=$(curl -fs --max-time 15 "$SNAPSHOT_URL/latest.json") || die "snapshot index not reachable: $SNAPSHOT_URL/latest.json"
  file=$(jq -r .file <<< "$meta") sha=$(jq -r .sha256 <<< "$meta") size=$(jq -r .size <<< "$meta")
  info "snapshot at height $(jq -r .height <<< "$meta") from $(jq -r .date <<< "$meta"), $((size / 1024 / 1024)) MiB"
  tmp=$NODE_HOME/snapshot.tar.lz4
  download "$SNAPSHOT_URL/$file" "$tmp" "$sha"
  ok "snapshot verified"
  info "extracting"
  lz4 -dc < "$tmp" | tar -xf - -C "$NODE_HOME"
  rm -f "$tmp"
  [ -f "$NODE_HOME/data/priv_validator_state.json" ] ||
    echo '{"height":"0","round":0,"step":0}' > "$NODE_HOME/data/priv_validator_state.json"
  ok "chain state ready ($(du -sh "$NODE_HOME/data" | cut -f1))"
}

sync_state() {
  step "Chain state"
  case $SYNC in
    snapshot)
      restore_snapshot
      ;;
    statesync)
      local rpc latest trust_height trust_hash
      rpc=${STATESYNC_RPCS%%,*}; rpc=${rpc%:443}
      latest=$(curl -fs --max-time 10 "$rpc/block" | jq -r .result.block.header.height) || die "RPC not reachable: $rpc"
      trust_height=$((latest - 2000))
      trust_hash=$(curl -fs --max-time 10 "$rpc/block?height=$trust_height" | jq -r .result.block_id.hash)
      local cfg=$NODE_HOME/config/config.toml
      toml_set "$cfg" statesync enable true
      toml_set "$cfg" statesync rpc_servers "$(q "$STATESYNC_RPCS")"
      toml_set "$cfg" statesync trust_height "$trust_height"
      toml_set "$cfg" statesync trust_hash "$(q "$trust_hash")"
      ok "state sync from height $trust_height: it runs at the first start (a few minutes)"
      ;;
  esac
}

write_compose() {
  local exec
  if [ "$COSMOVISOR" = yes ]; then exec="$NODE_HOME/bin/cosmovisor run start --home $NODE_HOME"
  else exec="$NODE_HOME/bin/$DAEMON start --home $NODE_HOME"; fi
  mkdir -p "$COMPOSE_DIR"
  cat > "$COMPOSE_DIR/docker-compose.yml" <<EOF
name: chihuahua-node

services:
  chihuahuad:
    image: alpine:3.20
    container_name: $CONTAINER
    user: "$(id -u):$(id -g)"
    network_mode: host
    restart: unless-stopped
    stop_grace_period: 1m
    entrypoint: [$(printf '"%s", ' $exec | sed 's/, $//')]
    environment:
      - DAEMON_NAME=$DAEMON
      - DAEMON_HOME=$NODE_HOME
      - DAEMON_RESTART_AFTER_UPGRADE=true
      - DAEMON_ALLOW_DOWNLOAD_BINARIES=$([ "${AUTO_DOWNLOAD:-no}" = yes ] && echo true || echo false)
      - UNSAFE_SKIP_BACKUP=true
      - HOME=/tmp
    volumes:
      - $NODE_HOME:$NODE_HOME
    ulimits:
      nofile: 65535
    logging:
      driver: json-file
      options:
        max-size: 50m
        max-file: "3"
EOF
}

install_service() {
  step "Service"
  save_conf
  if [ "$INSTALL_TYPE" = native ]; then
    write_unit
    as_root systemctl enable -q "$SERVICE"
    as_root systemctl restart "$SERVICE"
    ok "systemd service $SERVICE enabled and started"
  else
    write_compose
    (cd "$COMPOSE_DIR" && docker compose up -d --quiet-pull 2>&1 | grep -v -e '^ *$' | tail -2)
    ok "container $CONTAINER started ($COMPOSE_DIR/docker-compose.yml)"
  fi
}

firewall() {
  local ports=("$P2P_PORT")
  [ "$RPC_PUBLIC" = yes ] && ports+=("$RPC_PORT")
  if have ufw && try_root ufw status 2>/dev/null | grep -q "Status: active"; then
    if confirm "ufw is active: open port(s) ${ports[*]}/tcp?" y; then
      for p in "${ports[@]}"; do as_root ufw allow "$p/tcp" comment "chihuahua" >/dev/null; done
      ok "ufw: ${ports[*]}/tcp open"
    fi
  elif have firewall-cmd && try_root firewall-cmd --state >/dev/null 2>&1; then
    if confirm "firewalld is active: open port(s) ${ports[*]}/tcp?" y; then
      for p in "${ports[@]}"; do as_root firewall-cmd -q --permanent --add-port="$p/tcp"; done
      as_root firewall-cmd -q --reload
      ok "firewalld: ${ports[*]}/tcp open"
    fi
  fi
}

check_node() {
  step "Checks"
  local i st
  info "waiting for the node to start"
  for i in $(seq 1 60); do st=$(rpc_status 2>/dev/null) && break; sleep 2; done
  [ -n "${st:-}" ] || { warn "the RPC does not answer yet: look at the logs with \"huahua-node logs\""; return; }
  ok "RPC answering on $(local_rpc)"

  if port_busy "$P2P_PORT"; then ok "P2P listening on port $P2P_PORT"; else warn "nothing listening on P2P port $P2P_PORT"; fi

  if [ -n "${EXTERNAL_IP:-}" ] && confirm "Check from the internet that port $P2P_PORT is open (asks ifconfig.co)?" y; then
    local r
    r=$(curl -fs --max-time 15 -H 'Accept: application/json' "https://ifconfig.co/port/$P2P_PORT" | jq -r .reachable 2>/dev/null || true)
    case $r in
      true) ok "port $P2P_PORT is reachable from the internet" ;;
      false) warn "port $P2P_PORT is NOT reachable from the internet: forward it on the router/firewall to get inbound peers (not required to sync)" ;;
      *) warn "port check not available right now" ;;
    esac
  fi

  local rc action why
  while :; do
    rc=0; watch_sync || rc=$?
    [ "$rc" = 0 ] && break
    case $rc in
      2) why="you stopped watching" ;;
      3) why="no progress for $(fmt_duration "${STALL_SECS:-300}")" ;;
      *) why="still syncing after $(fmt_duration 1800)" ;;
    esac
    warn "not in sync yet ($why): ${WATCH_PHASE:-}"
    action=''
    [ "$rc" = 3 ] && [ "$SYNC" = statesync ] && action=snapshot
    SYNC_ACTION=${HUAHUA_SYNC_ACTION:-}
    choose SYNC_ACTION "What now?" "${action:-wait}" \
      "wait:keep watching" \
      "background:finish the setup: the node keeps syncing in the background" \
      "snapshot:switch to the snapshot: restart from $SNAPSHOT_URL" \
      "abort:abort: remove the node and everything downloaded"
    case $SYNC_ACTION in
      wait) ;;
      background) info "the node keeps syncing: \"huahua-node watch\" follows the progress"; break ;;
      snapshot) switch_to_snapshot ;;
      abort) abort_install ;;
    esac
  done
  if [ "${WATCH_PEERS:-0}" = 0 ]; then
    warn "no peers yet. Common causes: outbound TCP blocked by a firewall, or another node already"
    warn "running behind the same public IP (peers refuse a second connection from the same address)"
  fi
}

switch_to_snapshot() {
  info "stopping the node"
  service_ctl stop >/dev/null 2>&1 || true
  wipe_chain_data
  toml_set "$NODE_HOME/config/config.toml" statesync enable false
  SYNC=snapshot
  restore_snapshot
  service_ctl start >/dev/null 2>&1 || die "the node did not restart"
  ok "node restarted from the snapshot"
  local i
  for i in $(seq 1 30); do rpc_status >/dev/null 2>&1 && break; sleep 2; done
}

abort_install() {
  info "removing the node"
  if [ "$INSTALL_TYPE" = docker ]; then
    (cd "$COMPOSE_DIR" && docker compose down >/dev/null 2>&1) || true
    rm -f "$COMPOSE_DIR/docker-compose.yml"; rmdir "$COMPOSE_DIR" 2>/dev/null || true
  else
    as_root systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
    as_root rm -f "/etc/systemd/system/$SERVICE.service"
    as_root systemctl daemon-reload
  fi
  if [ -L /usr/local/bin/$DAEMON ]; then try_root rm -f /usr/local/bin/$DAEMON || true; fi
  rm -f "$HOME/.local/bin/$DAEMON"
  if [ -n "${NEW_HOME:-}" ]; then
    rm -rf "${NODE_HOME:?}"
    ok "removed $NODE_HOME"
  else
    wipe_chain_data
    rm -rf "${NODE_HOME:?}/cosmovisor" "${NODE_HOME:?}/bin"
    ok "removed the chain data and binaries, kept the keys in $NODE_HOME/config"
  fi
  die "setup aborted"
}

node_log_tail() {
  if [ "$INSTALL_TYPE" = docker ]; then docker logs --tail 300 chihuahuad 2>&1
  else try_root journalctl -u "$SERVICE" -n 300 -o cat --no-pager 2>/dev/null || journalctl -u "$SERVICE" -n 300 -o cat --no-pager 2>/dev/null
  fi | sed 's/\x1b\[[0-9;]*m//g' || true
}

statesync_phase() {
  local log line
  log=$(node_log_tail | grep -E 'module=statesync|Snapshot restored|Verified ABCI app' | tail -1 || true)
  case $log in
    *"Snapshot restored"*|*"Verified ABCI app"*) echo "state restored, starting to sync blocks" ;;
    *"Applied snapshot chunk"*)
      line=$(sed -nE 's/.*chunk=([0-9]+).* total=([0-9]+).*/\1 \2/p' <<< "$log")
      echo "restoring the state: chunk $(( ${line% *} + 1 ))/${line#* }" ;;
    *"Fetching snapshot chunk"*) echo "downloading the state from the peers" ;;
    *"Discovering snapshots"*|*"Offering snapshot"*|*"Discovered new snapshot"*) echo "looking for a state snapshot among the peers" ;;
    *) echo "starting" ;;
  esac
}

network_height() {
  local rpc
  for rpc in ${STATESYNC_RPCS//,/ } $PEER_RPCS; do
    rpc=${rpc%:443}
    curl -fs --max-time 5 "$rpc/status" 2>/dev/null | jq -er '.result.sync_info.latest_block_height | tonumber' 2>/dev/null && return
  done
  echo 0
}

fmt_duration() {
  local s=$1
  if [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  else printf '%dm%02ds' $((s / 60)) $((s % 60)); fi
}

watch_sync() {
  local timeout=${1:-1800} start now el i=0 stop='' st
  local h=0 h_first=0 catching=true peers=0 net=0 net_at=0 line='starting' rate=0 h_prev=0 t_prev=0 eta
  local progress='' key progress_at stalled='' text cols
  local frames=('|' '/' '-' '\')
  if [ -t 1 ] && [[ $(locale charmap 2>/dev/null) == UTF-8 ]]; then frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); fi
  start=$(date +%s) progress_at=$start
  info "syncing (Ctrl-C stops watching, the node keeps running)"
  trap 'stop=1' INT
  while [ -z "$stop" ]; do
    now=$(date +%s); el=$((now - start))
    if [ $((i % 4)) = 0 ]; then
      if st=$(rpc_status 2>/dev/null); then
        h=$(jq -r .result.sync_info.latest_block_height <<< "$st")
        catching=$(jq -r .result.sync_info.catching_up <<< "$st")
        peers=$(curl -fs --max-time 3 "$(local_rpc)/net_info" 2>/dev/null | jq -r .result.n_peers 2>/dev/null || echo "$peers")
      fi
      if [ $((now - net_at)) -ge 20 ]; then net=$(network_height || echo "$net"); net_at=$now; fi
      if [ "$h" = 0 ]; then
        line=$(statesync_phase)
      else
        if [ "$t_prev" = 0 ]; then h_prev=$h t_prev=$now
        elif [ $((now - t_prev)) -ge 10 ]; then
          rate=$(( (h - h_prev) * 10 / (now - t_prev) ))
          h_prev=$h t_prev=$now
        fi
        [ "$h_first" = 0 ] && h_first=$h
        line="block $h"
        if [ "$net" -gt 0 ] && [ "$net" -gt "$h" ]; then
          line+="/$net"
          [ "$net" -gt "$h_first" ] && line+=" $(( (h - h_first) * 100 / (net - h_first) ))%"
          line+=" · $((net - h)) behind"
          if [ "$rate" -gt 0 ]; then
            eta=$(( (net - h) * 10 / rate ))
            line+=" · $((rate / 10)).$((rate % 10)) blk/s · ~$(fmt_duration "$eta")"
          fi
        fi
      fi
    fi
    key=$h; [ "$h" = 0 ] && key="0|$line"
    if [ "$key" != "$progress" ]; then progress=$key progress_at=$now
    elif [ $((now - progress_at)) -ge "${STALL_SECS:-300}" ]; then stalled=1; break
    fi
    text="$(fmt_duration "$el")  $line  · peers $peers"
    cols=$(tput cols 2>/dev/null || echo 80)
    printf '\r\033[K  %s %s' "${YEL}${frames[i % ${#frames[@]}]}${R}" "${text:0:cols-5}"
    if [ "$catching" = false ] && [ "$h" != 0 ] && { [ "$net" = 0 ] || [ $((net - h)) -le 5 ]; }; then break; fi
    [ "$el" -ge "$timeout" ] && break
    sleep 0.5 || true
    i=$((i + 1))
  done
  trap - INT
  printf '\r\033[K'
  WATCH_PEERS=$peers WATCH_PHASE=$line
  if [ "$catching" = false ] && [ "$h" != 0 ]; then ok "in sync at block $h ($(fmt_duration "$el")), $peers peers"; return 0; fi
  [ -n "$stop" ] && return 2
  [ -n "$stalled" ] && return 3
  return 1
}

self_install() {
  local dest=/usr/local/bin/huahua-node
  local src=$0 tmp=
  if [ ! -f "$src" ] && [ -n "$SELF_URL" ]; then
    tmp=$(mktemp); curl -fsSL "$SELF_URL" -o "$tmp" && src=$tmp
  fi
  if [ -f "$src" ]; then
    try_root install -m 0755 "$src" "$dest" 2>/dev/null ||
      { mkdir -p "$HOME/.local/bin" && install -m 0755 "$src" "$HOME/.local/bin/huahua-node"; }
  fi
  [ -z "$tmp" ] || rm -f "$tmp"
}

finish() {
  save_conf
  self_install || true
  local cmd=huahua-node
  have huahua-node || cmd="bash $0"
  say
  say "${B}${GRN}Your Chihuahua node is up. Woof woof!${R}"
  say
  say "  status          ${B}$cmd status${R}  (live progress: ${B}$cmd watch${R})"
  say "  logs            ${B}$cmd logs${R}"
  say "  prepare upgrade ${B}$cmd upgrade${R}"
  [ "$NODE_ROLE" = validator ] && say "  create validator ${B}$cmd validator${R}"
  say "  CLI             ${B}chihuahuad status${R}  (already pointing to this node)"
  say
  if [ "$NODE_ROLE" = validator ]; then
    warn "back up $NODE_HOME/config/priv_validator_key.json somewhere safe and offline"
    if confirm "Run the validator setup now?" y; then cmd_validator; fi
  fi
}

cmd_install() {
  show_logo
  if find_node; then manage_menu; fi
  run_setup
}

run_setup() {
  STEP=0 STEPS=8
  step "System check"
  preflight
  settings
  summary
  check_existing
  install_binaries
  configure_node
  sync_state
  install_service
  firewall
  check_node
  finish
}

LOGO_GRID='
..........YYYYYY..........
.......YYYYYYYYYYYY.......
KKKK..YYYYYYYYYYYYYY..KKKK
KYYKKKYYYYYYYYYYYYYYKKKYYK
KYWYYKKYYOOOOOOOOYYKKYYWYK
KYWWWWKKKKKKKKKKKKKKWWWWYK
KYWWWWKKKKKKKKKKKKKKWWWWYK
KYWWWKKKKKKKKKKKKKKKKWWWYK
.KYWWKKKKKKKKKKKKKKKKWWYK.
.KKYWKKKKKKKKKKKKKKKKWYKK.
YYKKKKKKKKKKWWKKKKKKKKKKYY
YYKKKKKKKKKKWWKKKKKKKKKKYY
YYYKKKKYYYKKWWKKYYYKKKKYYY
YYYYKKYKKCYKWWKYKKCYKKYYYY
YYYYKKYKKKYKWWKYKKKYKKYYYY
OYYYKKYKKKYKWWKYKKKYKKYYYY
.OYYKKKYYYKWWWWKYYYKKKYYY.
.OYYYKKKKKWWWWWWKKKKKYYYY.
.OYYYYKKWWWKKKKWWWKKYYYYY.
..OYYYYKKWWWKKWWWKKYYYYY..
...OYYYKWWWWWWWWWWKYYYY...
...OYYYYYWWWWWWWWYYYYYY...
....OYYYYYYYPPYYYYYYYY....
......OYYYYYYYYYYYYY......
.......OOOOOOOOOOOO.......
..........OOOOOO..........
'

TUI_TABS=("Node" "Sync" "Logs" "Upgrade" "Validator" "Setup")

tui_init() {
  if [[ $(locale charmap 2>/dev/null) != UTF-8 ]]; then
    local l; l=$(locale -a 2>/dev/null | grep -iE '^(C|en_US)\.utf-?8$' | head -1)
    [ -n "$l" ] && export LC_ALL=$l
  fi
  shopt -s extglob
  local rows=() line top bot out x t b
  while IFS= read -r line; do [ -n "$line" ] && rows+=("$line"); done <<< "$LOGO_GRID"
  TUI_LOGO=()
  for ((y = 0; y < ${#rows[@]}; y += 2)); do
    top=${rows[y]} bot=${rows[y + 1]:-}
    out=''
    for ((x = 0; x < ${#top}; x++)); do
      t=${top:x:1} b=${bot:x:1}; b=${b:-.}
      if [ "$t" = . ] && [ "$b" = . ]; then out+=' '
      elif [ "$t" = . ]; then out+="$(logo_color "$b" fg)▄${R}"
      elif [ "$b" = . ]; then out+="$(logo_color "$t" fg)▀${R}"
      else out+="$(logo_color "$t" fg)$(logo_color "$b" bg)▀${R}"
      fi
    done
    TUI_LOGO+=("$out")
  done
  REV=$'\e[7m'
}

tui_enter() { printf '\e[?1049h\e[?25l\e[H\e[2J'; }
tui_leave() { printf '\e[?25h\e[?1049l'; }

fit() {
  local w=$1 s=$2 plain
  plain=${s//$'\e'\[*([0-9;])m/}
  if [ "${#plain}" -le "$w" ]; then
    printf '%s%*s' "$s" $((w - ${#plain})) ''
  else
    printf '%s…' "${plain:0:w-1}"
  fi
}

read_key() {
  local k rest
  IFS= read -rsn1 -t "${1:-1}" k || { KEY=''; return; }
  case $k in
    $'\e')
      IFS= read -rsn2 -t 0.02 rest || true
      case $rest in
        '[A') KEY=up ;; '[B') KEY=down ;; '[C') KEY=right ;; '[D') KEY=left ;; '[Z') KEY=btab ;;
        '') KEY=esc ;;
        *) IFS= read -rsn5 -t 0.01 rest || true; KEY='' ;;
      esac ;;
    $'\t') KEY=tab ;;
    '') KEY=enter ;;
    *) KEY=$k ;;
  esac
}

tui_refresh() {
  local now; now=$(date +%s)
  if [ -z "${T_NODE:-}" ]; then return; fi
  if [ $((now - ${T_ST_AT:-0})) -ge 2 ]; then
    T_ST_AT=$now
    T_SVC=$(service_ctl status 2>/dev/null || true)
    if T_ST=$(rpc_status 2>/dev/null); then
      T_H=$(jq -r .result.sync_info.latest_block_height <<< "$T_ST")
      T_CATCH=$(jq -r .result.sync_info.catching_up <<< "$T_ST")
      if [ "$T_CATCH" != "${T_CATCH_PREV:-}" ]; then T_RATE='' T_RATE_AT='' T_BINT='' T_CATCH_PREV=$T_CATCH; fi
      T_BTIME=$(jq -r .result.sync_info.latest_block_time <<< "$T_ST")
      T_VP=$(jq -r .result.validator_info.voting_power <<< "$T_ST")
      T_PEERS=$(curl -fs --max-time 2 "$(local_rpc)/net_info" 2>/dev/null | jq -r .result.n_peers 2>/dev/null || echo "?")
      T_UP=1
      if [ "${T_H:-0}" != 0 ]; then
        [ "${T_HFIRST:-0}" = 0 ] && T_HFIRST=$T_H
        if [ -z "${T_RATE_AT:-}" ]; then T_RATE_AT=$now T_RATE_H=$T_H
        elif [ $((now - T_RATE_AT)) -ge 20 ]; then
          T_RATE=$(( (T_H - T_RATE_H) * 10 / (now - T_RATE_AT) ))
          T_BINT=''; [ "$T_H" -gt "$T_RATE_H" ] && T_BINT=$(( (now - T_RATE_AT) * 10 / (T_H - T_RATE_H) ))
          T_RATE_AT=$now T_RATE_H=$T_H
        fi
      fi
    else
      T_UP='' T_ST='' T_PEERS=0
    fi
  fi
  if [ $((now - ${T_NET_AT:-0})) -ge 20 ]; then T_NET_AT=$now; T_NET=$(network_height || echo 0); fi
  if [ $((now - ${T_SLOW_AT:-0})) -ge 30 ]; then
    T_SLOW_AT=$now
    T_DISK=$(du -sh "$NODE_HOME/data" 2>/dev/null | cut -f1)
    T_VER=$(nd version 2>/dev/null | head -1)
    T_PLAN=''
    [ -n "$T_UP" ] && T_PLAN=$(nd q upgrade plan -o json "$(node_flag)" 2>/dev/null |
      jq -r '(.plan // .) | select(.name) | "\(.name) at height \(.height)"' 2>/dev/null || true)
  fi
  if [ "$T_TAB" = 2 ]; then T_LOG=$(node_log_tail | tail -n 200); fi
  if [ "$T_TAB" = 1 ] && [ "${T_H:-0}" = 0 ] && [ -n "$T_UP" ]; then T_PHASE=$(statesync_phase); fi
}

tui_header() {
  local how state sync
  H_LINES=("${B}${YEL}C H I H U A H U A${R}  ${B}node manager${R} ${D}v$SCRIPT_VERSION${R}" "")
  if [ -z "${T_NODE:-}" ]; then
    H_LINES+=("${D}no node on this machine yet${R}" "" "Open ${B}Setup${R} to create one: a synced node in a few minutes.")
    return
  fi
  case $INSTALL_TYPE in
    docker) how="Docker container $CONTAINER" ;;
    manual) how="process $NODE_PID, started by hand" ;;
    *) how="systemd service $SERVICE" ;;
  esac
  H_LINES+=("${B}$MONIKER${R}  ${D}·${R}  $([ "$NODE_ROLE" = validator ] && echo validator || echo "full node")  ${D}·${R}  $how")
  if [ -n "${T_UP:-}" ]; then
    sync="${GRN}in sync${R}"
    [ "$T_CATCH" = false ] || sync="${YEL}catching up${R}"
    [ "$T_H" = 0 ] && sync="${YEL}state sync${R}"
    H_LINES+=("${GRN}●${R} running   block ${B}$T_H${R}   $sync   ${T_PEERS} peers")
  else
    H_LINES+=("${RED}●${R} ${T_SVC:-stopped}")
  fi
  H_LINES+=("${D}${T_VER:-} · cosmovisor $([ "$COSMOVISOR" = yes ] && echo on || echo off) · ${T_DISK:-?} · $NODE_HOME${R}")
  [ -n "${T_PLAN:-}" ] && H_LINES+=("${YEL}upgrade ${T_PLAN}${R}")
}

tui_actions() {
  ACTS=()
  if [ -z "${T_NODE:-}" ]; then
    [ "$T_TAB" = 5 ] && ACTS=("setup:Set up a new node" "quit:Exit")
    return
  fi
  case $T_TAB in
    0)
      if [ -n "${T_UP:-}" ]; then ACTS+=("restart:Restart the node" "stop:Stop the node")
      else ACTS+=("start:Start the node"); fi
      [ "$COSMOVISOR" = yes ] || ACTS+=("cosmovisor:Add cosmovisor (automatic binary switch at upgrades)")
      ACTS+=("status:Full status") ;;
    1) [ "$SYNC" = statesync ] && ACTS+=("snapshot:Restart from the snapshot") ;;
    3) ACTS+=("upgrade:Prepare the scheduled upgrade")
       [ "$COSMOVISOR" = yes ] || ACTS+=("cosmovisor:Add cosmovisor") ;;
    4) [ "$NODE_ROLE" = validator ] || ACTS+=("validator:Create the validator (guided)") ;;
    5) ACTS+=("setup:Set up another node")
       [ -n "${MANAGED:-}" ] && ACTS+=("uninstall:Uninstall this node")
       ACTS+=("quit:Exit") ;;
  esac
  [ "${T_SEL:-0}" -lt "${#ACTS[@]}" ] || T_SEL=0
}

progress_bar() {
  local w=$1 p=$2 f filled empty
  f=$((w * p / 100))
  printf -v filled '%*s' "$f" ''
  printf -v empty '%*s' $((w - f)) ''
  printf '%s%s%s%s%s' "$GRN" "${filled// /█}" "$D" "${empty// /░}" "$R"
}

tui_body() {
  local h=$1 w=$2 l i age
  BODY=()
  if [ -z "${T_NODE:-}" ]; then
    BODY+=("" "  No Chihuahua node was found on this machine." ""
      "  The setup downloads the official binary, starts from a recent snapshot"
      "  and runs the node as a systemd service or a Docker container, with cosmovisor.")
    return
  fi
  case $T_TAB in
    0)
      BODY+=("" "  ${D}name${R}        $MONIKER" "  ${D}type${R}        $([ "$NODE_ROLE" = validator ] && echo validator || echo "full node")"
        "  ${D}directory${R}   $NODE_HOME" "  ${D}version${R}     ${T_VER:-?}"
        "  ${D}cosmovisor${R}  $([ "$COSMOVISOR" = yes ] && echo "on ($(readlink "$NODE_HOME/cosmovisor/current" 2>/dev/null))" || echo off)"
        "  ${D}ports${R}       P2P ${P2P_PORT:-?} · RPC ${RPC_PORT:-?}" "  ${D}disk${R}        ${T_DISK:-?}") ;;
    1)
      BODY+=("")
      if [ -z "${T_UP:-}" ]; then BODY+=("  ${YEL}the node is not running${R}")
      elif [ "$T_H" = 0 ]; then
        BODY+=("  ${YEL}${SPIN}${R} state sync: ${T_PHASE:-starting}" "" "  ${D}the height stays at 0 until the state is restored (a few minutes)${R}")
      else
        local net=${T_NET:-0} pct=100 behind=0
        [ "$net" -gt "$T_H" ] && behind=$((net - T_H))
        [ "$net" -gt "${T_HFIRST:-0}" ] && [ "$behind" -gt 0 ] && pct=$(( (T_H - T_HFIRST) * 100 / (net - T_HFIRST) ))
        age=$(( $(date +%s) - $(date -d "$T_BTIME" +%s 2>/dev/null || date +%s) ))
        BODY+=("  $([ "$T_CATCH" = false ] && echo "${GRN}● in sync${R}" || echo "${YEL}${SPIN} catching up${R}")" ""
          "  ${D}block${R}        $T_H" "  ${D}network${R}      ${net:-?}  ($behind behind)"
          "  $([ "$T_CATCH" = false ] && echo "${D}last block${R}   ${age}s ago" || echo "${D}processing${R}   blocks from $(fmt_duration "$age") ago")"
          "  ${D}speed${R}        $(if [ -z "${T_RATE:-}" ]; then echo "–  (measuring)"; elif [ "$T_CATCH" = false ] && [ "${T_BINT:-0}" -ge 10 ]; then echo "a block every $((T_BINT / 10)).$((T_BINT % 10))s"; else echo "$((T_RATE / 10)).$((T_RATE % 10)) blocks/s"; fi)"
          "  ${D}peers${R}        ${T_PEERS}")
        if [ "$behind" -gt 5 ]; then
          BODY+=("" "  $(progress_bar $((w - 12)) "$pct") $pct%")
          [ "${T_RATE:-0}" -gt 0 ] && BODY+=("  ${D}about $(fmt_duration $((behind * 10 / T_RATE))) left${R}")
        fi
      fi ;;
    2)
      if [ -z "${T_LOG:-}" ]; then BODY+=("" "  ${D}no log lines (the journal may need: sudo usermod -aG systemd-journal $(id -un))${R}")
      else
        while IFS= read -r l; do
          case $l in
            *ERR*|*error*|*panic*) BODY+=(" ${RED}${l}${R}") ;;
            *WRN*) BODY+=(" ${YEL}${l}${R}") ;;
            *) BODY+=(" ${D}${l%% *}${R} ${l#* }") ;;
          esac
        done < <(tail -n "$h" <<< "$T_LOG")
      fi ;;
    3)
      local prepared
      prepared=$(ls -1 "$NODE_HOME/cosmovisor/upgrades" 2>/dev/null | paste -sd' ' - || true)
      BODY+=("" "  ${D}running${R}     ${T_VER:-?}" "  ${D}scheduled${R}   ${T_PLAN:-none}")
      [ "$COSMOVISOR" = yes ] && BODY+=("  ${D}prepared${R}    ${prepared:-none}  ${D}(cosmovisor/upgrades)${R}")
      [ "$COSMOVISOR" = yes ] || BODY+=("" "  ${YEL}without cosmovisor the binary has to be switched by hand at the upgrade height${R}") ;;
    4)
      BODY+=("" "  ${D}voting power${R}  ${T_VP:-0}"
        "  ${D}status${R}        $([ "${T_VP:-0}" != 0 ] && echo "${GRN}active validator${R}" || echo "not in the active set")")
      [ "$NODE_ROLE" = validator ] || BODY+=("" "  ${D}the node must be in sync; the account needs HUAHUA for the self-delegation and fees${R}") ;;
    5)
      BODY+=("" "  ${D}commands without this interface:${R}"
        "  huahua-node status | watch | logs | upgrade | validator | uninstall") ;;
  esac
}

tui_draw() {
  local W H i line out='' logo_w=26 inner body_h head_h top
  W=$(tput cols 2>/dev/null || echo 80) H=$(tput lines 2>/dev/null || echo 24)
  if [ "$W" -lt 72 ] || [ "$H" -lt 22 ]; then
    printf '\e[H\e[2J  make the terminal at least 72x22 (now %sx%s) · q to quit' "$W" "$H"; return
  fi
  inner=$((W - 4))
  tui_header
  out+="${D}╭$(printf '%*s' $((W - 2)) '' | sed 's/ /─/g')╮${R}\e[K\n"
  if [ "$H" -ge 34 ] && [ "$W" -ge 90 ]; then
    head_h=${#TUI_LOGO[@]}
    top=$(( (head_h - ${#H_LINES[@]}) / 2 ))
    for ((i = 0; i < head_h; i++)); do
      line=''; [ "$i" -ge "$top" ] && line=${H_LINES[i - top]:-}
      out+="${D}│${R} ${TUI_LOGO[i]}   $(fit $((inner - logo_w - 3)) "$line") ${D}│${R}\e[K\n"
    done
  else
    head_h=${#H_LINES[@]}
    for ((i = 0; i < head_h; i++)); do out+="${D}│${R} $(fit "$inner" "${H_LINES[i]}") ${D}│${R}\e[K\n"; done
  fi
  out+="${D}╰$(printf '%*s' $((W - 2)) '' | sed 's/ /─/g')╯${R}\e[K\n"
  line=' '
  for i in "${!TUI_TABS[@]}"; do
    if [ "$i" = "$T_TAB" ]; then line+=" ${REV}${B}${YEL} $((i + 1)) ${TUI_TABS[i]} ${R} "
    else line+=" ${D}$((i + 1))${R} ${TUI_TABS[i]}  "; fi
  done
  out+="$(fit "$W" "$line")\e[K\n"
  out+="${D} $(printf '%*s' $((W - 2)) '' | sed 's/ /─/g')${R}\e[K\n"
  body_h=$((H - head_h - 2 - 2 - 1))
  tui_actions
  tui_body $((body_h - ${#ACTS[@]} - 1)) "$W"
  if [ ${#ACTS[@]} -gt 0 ]; then
    BODY+=("")
    for i in "${!ACTS[@]}"; do
      if [ "$i" = "$T_SEL" ]; then BODY+=("  ${YEL}❯ ${B}${ACTS[i]#*:}${R}")
      else BODY+=("    ${ACTS[i]#*:}"); fi
    done
  fi
  for ((i = 0; i < body_h; i++)); do out+="$(fit "$W" "${BODY[i]:-}")\e[K\n"; done
  out+="${D}$(fit "$W" " ←/→ tabs · ↑/↓ choose · enter run · r refresh · q quit${T_MSG:+   ·   $T_MSG}")${R}\e[K"
  printf '\e[H%b\e[J' "$out"
}

tui_run() {
  tui_leave
  printf '\e[H\e[2J%s\n\n' "${B}${YEL}huahua-node${R} ${D}·${R} ${ACT_LABEL:-$1}"
  ( set -Eeuo pipefail; trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR; "$@" ) && T_MSG="done" || T_MSG="${YEL}not completed${R}"
  printf '\n%s' "${D}press enter to go back${R}"
  IFS= read -rs _ < /dev/tty || true
  tui_enter
  tui_find
}

tui_find() {
  restore_presets
  T_NODE='' T_ST_AT=0 T_NET_AT=0 T_SLOW_AT=0 T_HFIRST=0 T_RATE='' T_RATE_AT='' T_BINT='' T_UP=''
  if find_node >/dev/null 2>&1; then T_NODE=1; : "${SYNC:=snapshot}"; fi
}

tui_do() {
  case $1 in
    quit) exit 0 ;;
    start|stop|restart)
      T_MSG="$1…"; tui_draw
      if service_ctl "$1" >/dev/null 2>&1; then T_MSG="$1: done"; else T_MSG="${RED}$1 failed${R}"; fi
      T_ST_AT=0 ;;
    cosmovisor) tui_run add_cosmovisor ;;
    status) tui_run cmd_status ;;
    snapshot) tui_run switch_to_snapshot ;;
    upgrade) tui_run cmd_upgrade ;;
    validator) tui_run cmd_validator ;;
    uninstall) tui_run cmd_uninstall ;;
    setup) tui_run tui_setup ;;
  esac
}

tui_setup() { restore_presets; show_logo; run_setup; }

cmd_tui() {
  tui_init
  tui_find
  T_TAB=0 T_SEL=0 T_MSG='' SPIN='⠋'
  [ -n "$T_NODE" ] || T_TAB=5
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) f=0
  trap 'tui_leave' EXIT
  trap 'exit 0' INT TERM
  trap - ERR
  set +eu
  tui_enter
  while :; do
    SPIN=${frames[f % 10]}; f=$((f + 1))
    tui_refresh
    tui_draw
    read_key 1
    [ -n "$KEY" ] && T_MSG=''
    case $KEY in
      right|tab|l) T_TAB=$(( (T_TAB + 1) % ${#TUI_TABS[@]} )); T_SEL=0 ;;
      left|btab|h) T_TAB=$(( (T_TAB + ${#TUI_TABS[@]} - 1) % ${#TUI_TABS[@]} )); T_SEL=0 ;;
      [1-6]) T_TAB=$((KEY - 1)); T_SEL=0 ;;
      up|k) [ "$T_SEL" -gt 0 ] && T_SEL=$((T_SEL - 1)) ;;
      down|j) T_SEL=$((T_SEL + 1)); tui_actions; [ "$T_SEL" -lt "${#ACTS[@]}" ] || T_SEL=$((${#ACTS[@]} > 0 ? ${#ACTS[@]} - 1 : 0)) ;;
      enter) tui_actions; [ ${#ACTS[@]} -gt 0 ] && { ACT_LABEL=${ACTS[T_SEL]#*:}; tui_do "${ACTS[T_SEL]%%:*}"; } ;;
      r) T_ST_AT=0 T_NET_AT=0 T_SLOW_AT=0 ;;
      q|Q|esc) exit 0 ;;
    esac
  done
}

cmd_status() {
  load_conf
  local st peers plan
  say "${B}$MONIKER${R} ($NODE_ROLE, $INSTALL_TYPE): $(service_ctl status)"
  st=$(rpc_status) || die "the node RPC does not answer on $(local_rpc)"
  peers=$(curl -fs --max-time 5 "$(local_rpc)/net_info" | jq -r .result.n_peers)
  jq -r --arg peers "$peers" '.result as $r |
    "  height       \($r.sync_info.latest_block_height) (\($r.sync_info.latest_block_time[:19] | sub("T"; " ")) UTC)",
    "  in sync      \(if $r.sync_info.catching_up then "no, catching up" else "yes" end)",
    "  peers        \($peers)",
    "  voting power \($r.validator_info.voting_power)"' <<< "$st"
  say "  version      $(nd version 2>/dev/null || echo "not readable by $(id -un)")"
  say "  disk         $(du -sh "$NODE_HOME/data" 2>/dev/null | cut -f1)"
  plan=$(nd q upgrade plan -o json "$(node_flag)" 2>/dev/null | jq -r '(.plan // .) | select(.name) | "\(.name) at height \(.height)"' 2>/dev/null || true)
  if [ -n "$plan" ]; then say "  ${YEL}upgrade      $plan${R}: prepare it with \"huahua-node upgrade\""; fi
}

cmd_watch() {
  load_conf
  watch_sync 86400
}

cmd_logs() {
  load_conf
  show_logs
}

cmd_upgrade() {
  load_conf
  ARCH=$(arch)
  local plan name height tag=${1:-}
  plan=$(nd q upgrade plan -o json "$(node_flag)" 2>/dev/null || true)
  name=$(jq -r '(.plan // .).name // empty' <<< "$plan" 2>/dev/null || true)
  height=$(jq -r '(.plan // .).height // empty' <<< "$plan" 2>/dev/null || true)
  if [ -z "$name" ]; then
    [ -n "$tag" ] || die "no upgrade scheduled on chain; to install a release anyway: huahua-node upgrade <tag> <upgrade name>"
    name=${2:-} ; [ -n "$name" ] || die "give the upgrade name too: huahua-node upgrade $tag <upgrade name>"
  else
    info "upgrade $name scheduled at height $height"
  fi
  if [ -z "$tag" ]; then
    tag=$(curl -fs "https://api.github.com/repos/$GITHUB_REPO/releases?per_page=50" |
      jq -r --arg n "$name" '[.[] | select(.draft | not) | .tag_name | select(. == $n or startswith($n + "."))] | first // empty')
    [ -n "$tag" ] || die "no release found for $name: huahua-node upgrade <tag>"
    confirm "Install release $tag for upgrade $name?" y || die "cancelled"
  fi
  local tmp; tmp=$(mktemp -d)
  fetch_release "$tag" "$tmp/$DAEMON"
  ok "chihuahuad $("$tmp/$DAEMON" version 2>&1) verified"
  if [ "$COSMOVISOR" = yes ]; then
    DAEMON_HOME=$NODE_HOME DAEMON_NAME=$DAEMON "$NODE_HOME/bin/cosmovisor" add-upgrade "$name" "$tmp/$DAEMON" --force >/dev/null
    ok "ready: cosmovisor switches to $tag at the upgrade height by itself"
  else
    install -m 0755 "$tmp/$DAEMON" "$NODE_HOME/bin/$DAEMON-$name"
    warn "without cosmovisor: when the node halts at height $height, replace $NODE_HOME/bin/$DAEMON with $NODE_HOME/bin/$DAEMON-$name and restart"
  fi
  rm -rf "$tmp"
}

cmd_validator() {
  load_conf
  ARCH=$(arch)
  local st
  st=$(rpc_status) || die "the node RPC does not answer: is the node running?"
  if [ "$(jq -r .result.sync_info.catching_up <<< "$st")" != false ]; then
    info "waiting for the node to be in sync"
    until [ "$(rpc_status | jq -r .result.sync_info.catching_up)" = false ]; do sleep 10; done
  fi
  ok "node in sync"
  if [ "$(jq -r .result.validator_info.voting_power <<< "$st")" != 0 ]; then
    ok "this node is already an active validator"; return
  fi

  say; say "${B}Validator key${R} (keyring: $KEYRING, in $NODE_HOME)"
  local kr=(--keyring-backend "$KEYRING" --home "$NODE_HOME")
  if nd keys show "$KEY_NAME" "${kr[@]}" -a >/dev/null 2>&1 < /dev/tty; then
    ok "using the existing key \"$KEY_NAME\""
  else
    choose KEY_ACTION "The account that creates and funds the validator" new \
      "new:create a new key" "recover:recover a key from its mnemonic"
    if [ "$KEY_ACTION" = recover ]; then nd keys add "$KEY_NAME" --recover "${kr[@]}" < /dev/tty
    else
      warn "write the mnemonic down offline: it is the only way to recover the account"
      nd keys add "$KEY_NAME" "${kr[@]}" < /dev/tty
    fi
  fi
  local addr bal
  addr=$(nd keys show "$KEY_NAME" -a "${kr[@]}" < /dev/tty)
  save_conf
  while :; do
    bal=$(nd q bank balances "$addr" -o json 2>/dev/null | jq -r --arg d "$DENOM" '[.balances[] | select(.denom == $d) | .amount | tonumber] | add // 0')
    say "  address  ${B}$addr${R}"
    say "  balance  $(awk -v b="$bal" 'BEGIN { printf "%.6f", b / 1e6 }') HUAHUA"
    [ "$bal" -gt 1000000 ] && break
    confirm "Send HUAHUA to this address, then check again?" y || die "fund $addr and run: huahua-node validator"
  done

  say; say "${B}Validator details${R}"
  local max_stake=$(( (bal - 1000000) / 1000000 ))
  ask STAKE "Self-delegation in HUAHUA (max $max_stake):" "$max_stake"
  ask V_WEBSITE "Website (optional):" ""
  ask V_IDENTITY "Keybase identity for the logo (optional):" ""
  ask V_CONTACT "Security contact email (optional):" ""
  ask V_DETAILS "Description (optional):" ""
  ask V_RATE "Commission rate:" 0.05
  ask V_MAX_RATE "Maximum commission rate:" 0.20
  ask V_MAX_CHANGE "Maximum daily commission change:" 0.01
  [[ $STAKE =~ ^[0-9]+$ ]] && [ "$STAKE" -ge 1 ] && [ "$STAKE" -le "$max_stake" ] || die "invalid self-delegation: $STAKE"

  local vj=$NODE_HOME/config/validator.json pubkey
  pubkey=$(nd comet show-validator --home "$NODE_HOME" 2>/dev/null || nd tendermint show-validator --home "$NODE_HOME")
  jq -n --argjson pubkey "$pubkey" --arg amount "$((STAKE * 1000000))$DENOM" --arg moniker "$MONIKER" \
    --arg identity "$V_IDENTITY" --arg website "$V_WEBSITE" --arg security "$V_CONTACT" --arg details "$V_DETAILS" \
    --arg rate "$V_RATE" --arg max "$V_MAX_RATE" --arg change "$V_MAX_CHANGE" \
    '{pubkey: $pubkey, amount: $amount, moniker: $moniker, identity: $identity, website: $website,
      security: $security, details: $details, "commission-rate": $rate, "commission-max-rate": $max,
      "commission-max-change-rate": $change, "min-self-delegation": "1"}' > "$vj"
  say; jq . "$vj" | sed 's/^/  /'
  local cmd=(tx staking create-validator "$vj" --from "$KEY_NAME" --chain-id "$CHAIN_ID" "${kr[@]}"
             --gas auto --gas-adjustment 1.5 --gas-prices "$TX_GAS_PRICE" --node "$(local_rpc)")
  say; say "  ${D}chihuahuad ${cmd[*]}${R}"
  confirm "Broadcast the create-validator transaction?" n || { info "not sent: the command above creates the validator"; return; }
  local out
  out=$(nd "${cmd[@]}" -y -o json < /dev/tty) || die "transaction failed"
  local hash code
  hash=$(jq -r .txhash <<< "$out") code=$(jq -r .code <<< "$out")
  [ "$code" = 0 ] || die "transaction rejected: $(jq -r .raw_log <<< "$out")"
  info "tx $hash sent, waiting for the block"
  sleep 12
  if [ "$(nd q tx "$hash" -o json 2>/dev/null | jq -r .code)" = 0 ]; then
    ok "validator created: it signs blocks once its stake is in the active set"
  else
    warn "check the transaction: chihuahuad q tx $hash"
  fi
  warn "back up $NODE_HOME/config/priv_validator_key.json offline, and never run the same key on two nodes"
}

cmd_uninstall() {
  load_conf
  [ -n "${MANAGED:-}" ] || die "this node was not installed by huahua-node: remove it the way it was installed"
  warn "this stops and removes the node $MONIKER ($INSTALL_TYPE, $NODE_HOME)"
  confirm "Continue?" n || die "cancelled"
  if [ "$INSTALL_TYPE" = docker ]; then
    (cd "$COMPOSE_DIR" && docker compose down) || true
    rm -f "$COMPOSE_DIR/docker-compose.yml"; rmdir "$COMPOSE_DIR" 2>/dev/null || true
  else
    as_root systemctl disable --now "$SERVICE" 2>/dev/null || true
    as_root rm -f "/etc/systemd/system/$SERVICE.service"
    as_root systemctl daemon-reload
  fi
  if [ -L /usr/local/bin/$DAEMON ]; then try_root rm -f /usr/local/bin/$DAEMON || true; fi
  rm -f "$HOME/.local/bin/$DAEMON"
  backup_keys
  local answer=
  tty_read answer "  Type DELETE to also delete $NODE_HOME (the keys are backed up above): " || true
  rm -f "$CONF_FILE"
  if [ "$answer" = DELETE ]; then
    rm -rf "${NODE_HOME:?}"
    ok "node removed: $([ "$INSTALL_TYPE" = docker ] && echo container || echo service) and $NODE_HOME deleted"
  else
    [ -n "$answer" ] && info "you typed \"$answer\", not DELETE"
    ok "$([ "$INSTALL_TYPE" = docker ] && echo "container" || echo "service $SERVICE") removed; $NODE_HOME is still on disk (delete it by hand when you want)"
  fi
}

cmd_help() {
  cat <<EOF
Huahua Node Manager $SCRIPT_VERSION: set up and manage a Chihuahua node

usage: huahua-node [command]

  (none)      the interactive interface on a terminal, the setup otherwise
  install     the step by step setup (HUAHUA_PLAIN=1: no full screen interface)
  status      height, sync, peers, version, scheduled upgrade
  watch       live sync progress
  logs        follow the node logs
  upgrade     prepare the binary of the scheduled chain upgrade
  validator   create the validator (key, funds, create-validator)
  uninstall   remove the node (keys are backed up first)

Unattended setup: answer with environment variables, HUAHUA_YES=1 accepts
the defaults of the rest. Variables: SETUP_MODE (easy|advanced), NODE_ROLE
(full|validator), INSTALL_TYPE (native|docker), MONIKER, NODE_HOME, SYNC
(snapshot|statesync), PRUNING (pruned|default|everything|nothing|custom),
KEEP_RECENT, PRUNE_INTERVAL, MIN_RETAIN_BLOCKS, INDEXER (null|kv), LISTEN_IP,
PORT_OFFSET, EXTERNAL_IP, RPC_PUBLIC (yes|no), API (yes|no), MIN_GAS_PRICE,
COSMOVISOR (yes|no), AUTO_DOWNLOAD (yes|no), COMPOSE_DIR. HUAHUA_REPLACE=1 replaces an existing node (keys are kept).
EOF
}

main() {
  local what=${1:-}
  if [ -z "$what" ]; then
    if [ -t 0 ] && [ -t 1 ] && [ -z "${HUAHUA_YES:-}" ] && [ -z "${HUAHUA_PLAIN:-}" ] && [ -n "$R" ]; then what=tui
    else what=install; fi
  fi
  case $what in
    tui) cmd_tui ;;
    install) cmd_install ;;
    status) cmd_status ;;
    watch) cmd_watch ;;
    logs) cmd_logs ;;
    upgrade) shift; cmd_upgrade "$@" ;;
    validator) cmd_validator ;;
    uninstall) cmd_uninstall ;;
    help|-h|--help) cmd_help ;;
    *) cmd_help; exit 1 ;;
  esac
}

main "$@"
