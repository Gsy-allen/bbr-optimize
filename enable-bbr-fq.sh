#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
TARGET_SYSCTL_FILE="/etc/sysctl.d/99-bbr-fq-tuned.conf"
BACKUP_PREFIX="/root/bbr-fq-backup-"
MAX_BACKUP_COUNT=5
HAS_DEFAULT_QDISC=0
TARGET_KEYS=(
  "net.core.default_qdisc"
  "net.ipv4.tcp_congestion_control"
  "net.core.netdev_max_backlog"
  "net.core.somaxconn"
  "net.ipv4.tcp_max_syn_backlog"
  "net.ipv4.tcp_notsent_lowat"
)
SCENARIOS=(
  "streaming-relay"
  "proxy-relay"
  "high-concurrency-edge"
  "general-server"
  "auto"
)

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "请使用 root 身份运行此脚本，例如：sudo bash $SCRIPT_NAME"
  fi
}

ensure_supported_os() {
  [[ -r /etc/os-release ]] || fail "未找到 /etc/os-release"
  # shellcheck disable=SC1091
  source /etc/os-release

  case "${ID:-}" in
    ubuntu|debian)
      ;;
    *)
      fail "仅支持 Ubuntu 和 Debian，当前检测到：${ID:-unknown}"
      ;;
  esac
}

check_virtualization() {
  local marker=""
  local line

  if command -v systemd-detect-virt >/dev/null 2>&1; then
    marker="$(systemd-detect-virt 2>/dev/null || true)"
  fi

  if [[ -z "$marker" ]] && [[ -f /proc/1/environ ]]; then
    while IFS= read -r line; do
      [[ "$line" == container=* ]] || continue
      marker="${line#container=}"
      break
    done < <(tr '\0' '\n' </proc/1/environ 2>/dev/null)
  fi

  case "$marker" in
    openvz|docker|podman|container-other)
      fail "检测到受限虚拟化环境（$marker），拒绝修改宿主网络栈参数。"
      ;;
    lxc|lxc-libvirt)
      warn "检测到 LXC 环境，继续执行，但内核/网络参数可能受宿主机限制。"
      ;;
  esac
}

get_primary_iface() {
  local iface
  iface="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
  [[ -n "$iface" ]] || fail "无法检测主网络接口"
  printf '%s\n' "$iface"
}

get_cpu_cores() {
  nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo
}

get_mem_mb() {
  awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo
}

get_link_mbps() {
  local iface="$1"
  local speed=""

  if [[ -r "/sys/class/net/$iface/speed" ]]; then
    speed="$(tr -d '[:space:]' <"/sys/class/net/$iface/speed" 2>/dev/null || true)"
    if [[ "$speed" =~ ^[0-9]+$ ]] && (( speed > 0 )); then
      printf '%s\n' "$speed"
      return
    fi
  fi

  if command -v ethtool >/dev/null 2>&1; then
    speed="$(ethtool "$iface" 2>/dev/null | awk -F': ' '/Speed:/ {gsub(/Mb\/s/, "", $2); print $2; exit}')"
    if [[ "$speed" =~ ^[0-9]+$ ]] && (( speed > 0 )); then
      printf '%s\n' "$speed"
      return
    fi
  fi

  printf '1000\n'
}

get_sysctl_value() {
  local key="$1"
  sysctl -n "$key" 2>/dev/null || true
}

has_sysctl_key() {
  local key="$1"
  [[ -e "/proc/sys/${key//./\/}" ]]
}

normalize_value() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf '%s\n' '(未设置)'
  else
    printf '%s\n' "$value"
  fi
}

ensure_bbr_support() {
  local available
  available="$(get_sysctl_value net.ipv4.tcp_available_congestion_control)"

  if [[ " $available " == *" bbr "* ]]; then
    return
  fi

  if command -v modprobe >/dev/null 2>&1; then
    modprobe tcp_bbr >/dev/null 2>&1 || true
    available="$(get_sysctl_value net.ipv4.tcp_available_congestion_control)"
    if [[ " $available " == *" bbr "* ]]; then
      return
    fi
  fi

  fail "当前内核未提供 tcp_bbr，请先升级或更换内核。"
}

ensure_fq_support() {
  command -v tc >/dev/null 2>&1 || fail "未找到 tc 命令，请先安装 iproute2。"
}

usage() {
  cat <<EOF
用法：
  sudo bash $SCRIPT_NAME [--scenario <场景名>]
  sudo bash $SCRIPT_NAME --restore <备份目录>

可用场景：
  streaming-relay       流媒体中转
  proxy-relay           代理转发
  high-concurrency-edge 高并发入口机
  general-server        通用服务器
  auto                  自动保守模式
EOF
}

validate_scenario() {
  local scenario="$1"
  local item

  for item in "${SCENARIOS[@]}"; do
    if [[ "$item" == "$scenario" ]]; then
      return
    fi
  done

  fail "无效的场景：$scenario"
}

parse_args() {
  local scenario=""
  local restore_dir=""

  while (( $# > 0 )); do
    case "$1" in
      --scenario)
        shift
        [[ $# -gt 0 ]] || fail "--scenario 缺少参数值"
        scenario="$1"
        ;;
      --restore)
        shift
        [[ $# -gt 0 ]] || fail "--restore 缺少备份目录"
        restore_dir="$1"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "未知参数：$1"
        ;;
    esac
    shift
  done

  if [[ -n "$scenario" && -n "$restore_dir" ]]; then
    fail "--scenario 和 --restore 不能同时使用"
  fi

  if [[ -n "$scenario" ]]; then
    validate_scenario "$scenario"
  fi

  printf '%s|%s\n' "$scenario" "$restore_dir"
}

select_scenario() {
  local preset="$1"
  local choice=""

  if [[ -n "$preset" ]]; then
    printf '%s\n' "$preset"
    return
  fi

  if [[ ! -t 0 ]]; then
    fail "未提供 --scenario，且当前不是交互终端，无法显示选择菜单。请使用 --scenario <场景名> 方式运行。"
  fi

  cat >&2 <<'EOF'
请选择业务场景：
  1) streaming-relay       - 流媒体中转，偏持续吞吐
  2) proxy-relay           - 代理转发，均衡通用
  3) high-concurrency-edge - 高并发入口机，偏大量新连接接入
  4) general-server        - 通用服务器，保守稳妥
  5) auto                  - 自动保守模式，用途不明确时使用
EOF
  printf '请输入编号 [1-5]：' >&2
  read -r choice

  case "$choice" in
    1) printf 'streaming-relay\n' ;;
    2) printf 'proxy-relay\n' ;;
    3) printf 'high-concurrency-edge\n' ;;
    4) printf 'general-server\n' ;;
    5) printf 'auto\n' ;;
    *) fail "无效的菜单编号：$choice" ;;
  esac
}

detect_resource_tier() {
  local cpu_cores="$1"
  local mem_mb="$2"
  local link_mbps="$3"

  if (( mem_mb < 1024 || cpu_cores <= 1 || link_mbps <= 100 )); then
    printf 'small\n'
    return
  fi

  if (( mem_mb < 4096 || cpu_cores <= 2 || link_mbps <= 1000 )); then
    printf 'medium\n'
    return
  fi

  printf 'large\n'
}

scenario_values() {
  local scenario="$1"
  local tier="$2"

  if [[ "$scenario" == "auto" ]]; then
    scenario="general-server"
  fi

  case "$scenario:$tier" in
    general-server:small)
      emit_scenario_values 8192 512 1024 8192
      ;;
    general-server:medium)
      emit_scenario_values 16384 1024 2048 16384
      ;;
    general-server:large)
      emit_scenario_values 32768 2048 4096 32768
      ;;
    proxy-relay:small)
      emit_scenario_values 16384 1024 2048 16384
      ;;
    proxy-relay:medium)
      emit_scenario_values 32768 2048 4096 32768
      ;;
    proxy-relay:large)
      emit_scenario_values 65536 4096 8192 65536
      ;;
    streaming-relay:small)
      emit_scenario_values 20480 1024 2048 32768
      ;;
    streaming-relay:medium)
      emit_scenario_values 40960 2048 4096 65536
      ;;
    streaming-relay:large)
      emit_scenario_values 65536 4096 8192 131072
      ;;
    high-concurrency-edge:small)
      emit_scenario_values 24576 2048 4096 16384
      ;;
    high-concurrency-edge:medium)
      emit_scenario_values 49152 4096 8192 32768
      ;;
    high-concurrency-edge:large)
      emit_scenario_values 98304 8192 16384 65536
      ;;
    *)
      fail "不支持的场景/资源档位组合：$scenario / $tier"
      ;;
  esac
}

emit_scenario_values() {
  local netdev_max_backlog="$1"
  local somaxconn="$2"
  local tcp_max_syn_backlog="$3"
  local tcp_notsent_lowat="$4"

  cat <<EOF
net.core.netdev_max_backlog=$netdev_max_backlog
net.core.somaxconn=$somaxconn
net.ipv4.tcp_max_syn_backlog=$tcp_max_syn_backlog
net.ipv4.tcp_notsent_lowat=$tcp_notsent_lowat
EOF
}

make_backup_dir() {
  local dir
  dir="${BACKUP_PREFIX}$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

cleanup_old_backups() {
  local backups=()
  local path
  local index

  shopt -s nullglob
  for path in "${BACKUP_PREFIX}"*; do
    [[ -d "$path" ]] || continue
    backups+=("$path")
  done
  shopt -u nullglob

  if (( ${#backups[@]} <= MAX_BACKUP_COUNT )); then
    return
  fi

  mapfile -t backups < <(printf '%s\n' "${backups[@]}" | sort -r)

  for (( index = MAX_BACKUP_COUNT; index < ${#backups[@]}; index++ )); do
    rm -rf -- "${backups[$index]}"
  done
}

backup_file_if_exists() {
  local source_path="$1"
  local backup_dir="$2"

  if [[ -f "$source_path" ]]; then
    cp -a "$source_path" "$backup_dir/"
  fi
}

backup_runtime_state() {
  local backup_dir="$1"
  local iface="$2"

  uname -a >"$backup_dir/uname.txt"
  cp /etc/os-release "$backup_dir/os-release.txt"

  {
    for key in "${TARGET_KEYS[@]}"; do
      sysctl "$key" 2>/dev/null || true
    done
  } >"$backup_dir/sysctl-target-keys.txt"

  tc qdisc show >"$backup_dir/tc-qdisc-all.txt" 2>&1 || true
  tc qdisc show dev "$iface" >"$backup_dir/tc-qdisc-$iface.txt" 2>&1 || true
}

backup_conflicts() {
  local backup_dir="$1"
  local matches_file="$backup_dir/conflicting-sysctl-files.txt"
  : >"$matches_file"

  if [[ -d /etc/sysctl.d ]]; then
    for key in "${TARGET_KEYS[@]}"; do
      grep -R -n -F "$key" /etc/sysctl.conf /etc/sysctl.d 2>/dev/null || true
    done | sort -u >"$matches_file"
  else
    for key in "${TARGET_KEYS[@]}"; do
      grep -n -F "$key" /etc/sysctl.conf 2>/dev/null || true
    done | sort -u >"$matches_file"
  fi
}

render_sysctl_file() {
  local scenario="$1"
  local tier="$2"

  cat <<EOF
# Managed by $SCRIPT_NAME
# Backup before change is stored separately by this script.
# Scenario: $scenario
# Resource tier: $tier
EOF

  if (( HAS_DEFAULT_QDISC )); then
    printf '%s\n' 'net.core.default_qdisc=fq'
  fi

  cat <<EOF
net.ipv4.tcp_congestion_control=bbr
$(scenario_values "$scenario" "$tier")
EOF
}

write_sysctl_config() {
  local scenario="$1"
  local tier="$2"
  render_sysctl_file "$scenario" "$tier" >"$TARGET_SYSCTL_FILE"
}

apply_changes() {
  local iface="$1"

  sysctl --system >/dev/null
  tc qdisc replace dev "$iface" root fq
}

verify_changes() {
  local iface="$1"
  local cc
  local qdisc
  local iface_qdisc

  cc="$(get_sysctl_value net.ipv4.tcp_congestion_control)"
  iface_qdisc="$(tc qdisc show dev "$iface" 2>/dev/null || true)"

  [[ "$cc" == "bbr" ]] || fail "验证失败：tcp_congestion_control=$cc"

  if (( HAS_DEFAULT_QDISC )); then
    qdisc="$(get_sysctl_value net.core.default_qdisc)"
    [[ "$qdisc" == "fq" ]] || fail "验证失败：default_qdisc=$qdisc"
  fi

  [[ "$(extract_root_qdisc_kind "$iface_qdisc")" == "fq" ]] || fail "验证失败：$iface 上的 root qdisc 不是 fq"

  printf '%s\n' "$iface_qdisc"
}

extract_root_qdisc_kind() {
  local qdisc_output="$1"
  local line

  while IFS= read -r line; do
    [[ "$line" == qdisc\ *\ root\ * ]] || continue
    line="${line#qdisc }"
    printf '%s\n' "${line%% *}"
    return
  done <<<"$qdisc_output"

  printf '%s\n' ''
}

restore_iface_qdisc_from_backup() {
  local iface="$1"
  local restore_dir="$2"
  local qdisc_backup_file="$restore_dir/tc-qdisc-$iface.txt"
  local root_qdisc_kind=""

  if [[ -f "$qdisc_backup_file" ]]; then
    root_qdisc_kind="$(extract_root_qdisc_kind "$(<"$qdisc_backup_file")")"
  fi

  if [[ -n "$root_qdisc_kind" ]]; then
    tc qdisc replace dev "$iface" root "$root_qdisc_kind"
    return
  fi

  tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
}

collect_current_values() {
  local prefix="$1"
  local key
  local var_name

  for key in "${TARGET_KEYS[@]}"; do
    var_name="${key//./_}"
    printf -v "${prefix}_${var_name}" '%s' "$(get_sysctl_value "$key")"
  done
}

print_value_changes() {
  local before_prefix="$1"
  local after_prefix="$2"
  local key var_name before_var after_var before_value after_value

  printf '[INFO] 已应用的 sysctl 变更：\n'
  printf '%-36s | %-18s | %-18s\n' '参数' '旧值' '新值'
  printf '%-36s-+-%-18s-+-%-18s\n' '------------------------------------' '------------------' '------------------'

  for key in "${TARGET_KEYS[@]}"; do
    var_name="${key//./_}"
    before_var="${before_prefix}_${var_name}"
    after_var="${after_prefix}_${var_name}"
    before_value="$(normalize_value "${!before_var:-}")"
    after_value="$(normalize_value "${!after_var:-}")"
    printf '%-36s | %-18s | %-18s\n' "$key" "$before_value" "$after_value"
  done
}

print_generated_config() {
  printf '[INFO] 生成的 %s 内容如下：\n' "$TARGET_SYSCTL_FILE"
  printf '%s\n' '----------------------------------------'
  cat "$TARGET_SYSCTL_FILE"
  printf '%s\n' '----------------------------------------'
}

print_qdisc_changes() {
  local iface="$1"
  local before_qdisc="$2"
  local after_qdisc="$3"

  printf '[INFO] 网卡 %s 的 qdisc 变更：\n' "$iface"
  printf '  旧值：%s\n' "$(normalize_value "$before_qdisc")"
  printf '  新值：%s\n' "$(normalize_value "$after_qdisc")"
}

restore_file_if_present() {
  local source_name="$1"
  local restore_dir="$2"
  local destination_path="$3"

  if [[ -f "$restore_dir/$source_name" ]]; then
    cp -a "$restore_dir/$source_name" "$destination_path"
  fi
}

restore_from_backup() {
  local restore_dir="$1"
  local iface current_iface_qdisc restored_iface_qdisc

  [[ -d "$restore_dir" ]] || fail "备份目录不存在：$restore_dir"
  [[ -f "$restore_dir/sysctl-target-keys.txt" ]] || fail "备份目录缺少 sysctl-target-keys.txt，无法确认它是有效备份。"

  command -v ip >/dev/null 2>&1 || fail "未找到 ip 命令，请先安装 iproute2。"
  ensure_fq_support

  iface="$(get_primary_iface)"
  current_iface_qdisc="$(tc qdisc show dev "$iface" 2>/dev/null || true)"

  if [[ -f "$restore_dir/99-bbr-fq-tuned.conf" ]]; then
    cp -a "$restore_dir/99-bbr-fq-tuned.conf" "$TARGET_SYSCTL_FILE"
  else
    rm -f "$TARGET_SYSCTL_FILE"
  fi

  restore_file_if_present "sysctl.conf" "$restore_dir" "/etc/sysctl.conf"
  sysctl --system >/dev/null
  restore_iface_qdisc_from_backup "$iface" "$restore_dir"

  restored_iface_qdisc="$(tc qdisc show dev "$iface" 2>/dev/null || true)"

  log "已从备份恢复配置：$restore_dir"
  print_qdisc_changes "$iface" "$current_iface_qdisc" "$restored_iface_qdisc"
  printf '[INFO] 当前 %s 内容如下：\n' "$TARGET_SYSCTL_FILE"
  printf '%s\n' '----------------------------------------'
  if [[ -f "$TARGET_SYSCTL_FILE" ]]; then
    cat "$TARGET_SYSCTL_FILE"
  else
    printf '(文件不存在)\n'
  fi
  printf '%s\n' '----------------------------------------'
}

main() {
  local parsed_args preset_scenario restore_dir scenario iface cpu_cores mem_mb link_mbps resource_tier backup_dir
  local current_cc current_qdisc before_iface_qdisc after_iface_qdisc

  require_root
  parsed_args="$(parse_args "$@")"
  preset_scenario="${parsed_args%%|*}"
  restore_dir="${parsed_args#*|}"
  ensure_supported_os
  check_virtualization

  if [[ -n "$restore_dir" ]]; then
    restore_from_backup "$restore_dir"
    exit 0
  fi

  command -v ip >/dev/null 2>&1 || fail "未找到 ip 命令，请先安装 iproute2。"
  ensure_fq_support
  ensure_bbr_support
  HAS_DEFAULT_QDISC=0
  if has_sysctl_key net.core.default_qdisc; then
    HAS_DEFAULT_QDISC=1
  else
    warn "当前内核未提供 net.core.default_qdisc，跳过该 sysctl，仅设置 BBR 和网卡 root qdisc。"
  fi

  iface="$(get_primary_iface)"
  cpu_cores="$(get_cpu_cores)"
  mem_mb="$(get_mem_mb)"
  link_mbps="$(get_link_mbps "$iface")"
  resource_tier="$(detect_resource_tier "$cpu_cores" "$mem_mb" "$link_mbps")"
  scenario="$(select_scenario "$preset_scenario")"
  current_cc="$(get_sysctl_value net.ipv4.tcp_congestion_control)"
  current_qdisc="$(get_sysctl_value net.core.default_qdisc)"
  before_iface_qdisc="$(tc qdisc show dev "$iface" 2>/dev/null || true)"

  collect_current_values before

  backup_dir="$(make_backup_dir)"
  backup_file_if_exists /etc/sysctl.conf "$backup_dir"
  backup_file_if_exists "$TARGET_SYSCTL_FILE" "$backup_dir"
  backup_runtime_state "$backup_dir" "$iface"
  backup_conflicts "$backup_dir"
  cleanup_old_backups

  write_sysctl_config "$scenario" "$resource_tier"
  apply_changes "$iface"
  after_iface_qdisc="$(verify_changes "$iface")"
  collect_current_values after

  log "系统：${NAME:-unknown} ${VERSION_ID:-unknown}"
  log "内核版本：$(uname -r)"
  log "主网络接口：$iface"
  log "检测到的资源：CPU=${cpu_cores}，内存=${mem_mb}MB，带宽=${link_mbps}Mbps"
  log "选中的业务场景：$scenario"
  log "选中的资源档位：$resource_tier"
  log "之前的拥塞控制算法：${current_cc:-unknown}"
  if (( HAS_DEFAULT_QDISC )); then
    log "之前的默认 qdisc：${current_qdisc:-unknown}"
  else
    log "当前内核未暴露默认 qdisc sysctl，已跳过该项"
  fi
  log "备份目录：$backup_dir"
  log "最多保留最近 ${MAX_BACKUP_COUNT} 份备份"

  print_value_changes before after
  print_generated_config
  print_qdisc_changes "$iface" "$before_iface_qdisc" "$after_iface_qdisc"

  if [[ -s "$backup_dir/conflicting-sysctl-files.txt" ]]; then
    warn "发现可能冲突的 sysctl 配置，请检查：$backup_dir/conflicting-sysctl-files.txt"
  fi

  cat <<EOF
[INFO] 恢复提示：
  1. 将旧配置文件从以下目录恢复回去：$backup_dir
  2. 或直接执行：sudo bash $SCRIPT_NAME --restore $backup_dir
EOF
}

main "$@"
