#!/usr/bin/env bash
# =====================================================================
#  lu.sh —— 个人节点一键菜单脚本（Debian 12 / root 运行）
#
#  功能：swap、系统更新、新用户与 SSH 加固、防火墙、fail2ban、BBR、
#        VLESS Reality、Hysteria2、套 Cloudflare 的 VLESS XHTTP、
#        节点链接（含 IPv6）、改端口、状态检查、收紧 SSH、卸载。
#
#  运行方式（先 sudo -i 切到 root）：
#    bash <(curl -fsSL 你的脚本地址)
#  装过一次后，直接输入 lu 打开菜单；lu links 看链接；lu status 看状态。
#
#  设计原则：出错立即停止该项操作；不上报任何数据；
#            快捷命令 lu 只运行本机保存的副本，不会自动联网更新。
# =====================================================================

# 改成你自己 GitHub 仓库里这个文件的 Raw 地址（用于“更新本脚本”）
SCRIPT_URL="https://raw.githubusercontent.com/LLQ148/vps/main/lu.sh"
VERSION="1.0.1"

LU_DIR=/etc/lu
STATE=$LU_DIR/state
LINKS_FILE=/root/lu-links.txt
XRAY_BIN=/usr/local/bin/xray
SSHD_CONF=/etc/ssh/sshd_config
HY2_DIR=/etc/hysteria
CF_PORTS="2053 2083 2087 2096 8443"

# ---------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------
c_red=$'\033[1;31m'; c_grn=$'\033[1;32m'; c_yel=$'\033[1;33m'
c_cyn=$'\033[1;36m'; c_off=$'\033[0m'
say()  { printf '\n%s== %s%s\n' "$c_grn" "$*" "$c_off"; }
info() { printf '%s\n' "$*"; }
warn() { printf '%s!! %s%s\n' "$c_yel" "$*" "$c_off"; }
err()  { printf '%sXX %s%s\n' "$c_red" "$*" "$c_off" >&2; }
die()  { err "$*"; exit 1; }
ok()   { printf '  %s[正常]%s %s\n' "$c_grn" "$c_off" "$*"; }
bad()  { printf '  %s[问题]%s %s\n' "$c_red" "$c_off" "$*"; }

pause() { echo; read -r -p "按回车返回菜单……" _ || true; }

# ask "提示" "默认值" → 输出用户输入（空则默认值）
ask() {
  local prompt="$1" def="${2:-}" ans
  if [ -n "$def" ]; then
    read -r -p "$prompt [默认 $def]: " ans
  else
    read -r -p "$prompt: " ans
  fi
  printf '%s' "${ans:-$def}"
}

# confirm "提示" → 只有输入 yes 才返回成功
confirm_yes() {
  local ans
  read -r -p "$1 输入 yes 继续，其他任意键取消：" ans
  [ "$ans" = "yes" ]
}

# ---------------------------------------------------------------------
# 状态文件（key=value，权限 600）
# ---------------------------------------------------------------------
state_get() {
  [ -f "$STATE" ] || return 0
  grep -m1 "^$1=" "$STATE" 2>/dev/null | cut -d= -f2- || true
}

state_set() {
  mkdir -p "$LU_DIR"
  touch "$STATE"
  chmod 600 "$STATE"
  local tmp
  tmp=$(mktemp)
  grep -v "^$1=" "$STATE" > "$tmp" || true
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  cat "$tmp" > "$STATE"
  rm -f "$tmp"
}

state_del() {
  [ -f "$STATE" ] || return 0
  local tmp
  tmp=$(mktemp)
  grep -v "^$1=" "$STATE" > "$tmp" || true
  cat "$tmp" > "$STATE"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------
# 基础检查与工具
# ---------------------------------------------------------------------
need_root() {
  [ "$(id -u)" -eq 0 ] || die "请先切换到 root（sudo -i）再运行。"
}

check_os() {
  [ -f /etc/debian_version ] || die "只支持 Debian / Ubuntu 系统。"
  if ! grep -q 'VERSION_ID="12"' /etc/os-release 2>/dev/null; then
    warn "本脚本按 Debian 12 编写和测试，其他版本可能有差异。"
  fi
}

nogroup() { id -gn nobody 2>/dev/null || echo nogroup; }

valid_port() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# port_in_use tcp|udp 端口
port_in_use() {
  local flag=-ltn
  [ "$1" = "udp" ] && flag=-lun
  ss "$flag" 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$2\$"
}

rand_hex() { openssl rand -hex "$1"; }

ufw_on() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; }
fw_allow()  { if ufw_on; then ufw allow "$1" >/dev/null; info "防火墙已放行 $1"; fi; }
fw_delete() { if ufw_on; then ufw delete allow "$1" >/dev/null 2>&1 || true; fi; }

ipv4_addr() {
  local ip
  ip=$(curl -4 -s --max-time 6 https://api.ipify.org 2>/dev/null || true)
  [ -n "$ip" ] || ip=$(curl -4 -s --max-time 6 https://ip.sb 2>/dev/null || true)
  [ -n "$ip" ] || ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  printf '%s' "$ip"
}

ipv6_addr() {
  # 只取公网 IPv6（2 或 3 开头，scope global，非临时地址）
  ip -6 addr show scope global 2>/dev/null \
    | awk '/inet6/ && !/temporary/ && !/deprecated/ {print $2}' \
    | cut -d/ -f1 | grep -E '^[23]' | head -n1
}

# 把 IPv6 地址加上方括号，IPv4 和域名原样返回
host_fmt() {
  case "$1" in *:*) printf '[%s]' "$1" ;; *) printf '%s' "$1" ;; esac
}

reboot_hint() {
  if [ -f /var/run/reboot-required ]; then
    warn "系统更新了内核，等全部装完后建议执行 reboot 重启一次。"
  fi
}

# ---------------------------------------------------------------------
# swap / 系统更新 / BBR
# ---------------------------------------------------------------------
setup_swap() {
  say "检查 swap"
  if swapon --show --noheadings 2>/dev/null | grep -q .; then
    info "已有 swap，跳过：$(swapon --show --noheadings | awk '{print $1, $3}' | tr '\n' ' ')"
    return 0
  fi
  local size_mb=1024
  info "创建 ${size_mb}MB 的 /swapfile（防止小内存机器装软件时被撑爆）"
  if ! fallocate -l "${size_mb}M" /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=none
  fi
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  info "swap 已启用。"
}

sys_update() {
  say "更新系统并安装依赖（单核机器可能要几分钟，CPU 跑满属正常，请耐心等）"
  export DEBIAN_FRONTEND=noninteractive
  dpkg --configure -a
  apt-get update
  apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
  apt-get -y install curl openssl ca-certificates ufw fail2ban python3-systemd nano unzip
  reboot_hint
}

enable_bbr() {
  say "开启 BBR"
  modprobe tcp_bbr 2>/dev/null || true
  cat > /etc/sysctl.d/99-lu-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1 || true
  local cc
  cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control)
  if [ "$cc" = "bbr" ]; then info "BBR 已生效。"; else warn "当前仍是 $cc，内核可能不支持 BBR。"; fi
}

# ---------------------------------------------------------------------
# SSH 加固
# ---------------------------------------------------------------------
# 删除某项的所有旧行（含注释掉的），在文件第一行写入新值。
# sshd 以最先读到的值为准，写在第一行可以压过后面的设置和 Include 的文件。
# 只删除第一个 Match 块之前的全局设置，Match 块里的规则不动
sshd_del_key() {
  local tmp
  tmp=$(mktemp)
  awk -v k="$1" '
    { line = tolower($0) }
    line ~ /^[ \t]*match[ \t]/ { m = 1 }
    !m && line ~ ("^[ \t]*#?[ \t]*" tolower(k) "[ \t]") { next }
    { print }
  ' "$SSHD_CONF" > "$tmp"
  cat "$tmp" > "$SSHD_CONF"
  rm -f "$tmp"
}

sshd_set() {
  sshd_del_key "$1"
  sed -i "1i $1 $2" "$SSHD_CONF"
}

sshd_ports() {
  sshd_del_key Port
  local p
  for p in "$@"; do sed -i "1i Port ${p}" "$SSHD_CONF"; done
}

sshd_apply() {
  if ! sshd -t; then
    cp -f "${SSHD_CONF}.lu.bak" "$SSHD_CONF"
    die "SSH 配置检查失败，已恢复原配置，没有做任何改动。"
  fi
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl daemon-reload
    systemctl restart ssh.socket
  fi
  systemctl restart ssh 2>/dev/null || systemctl restart sshd
}

write_fail2ban() {
  local ports="$1"
  mkdir -p /etc/fail2ban/jail.d
  cat > /etc/fail2ban/jail.d/lu-sshd.local <<EOF
[sshd]
enabled  = true
backend  = systemd
port     = $ports
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban || warn "fail2ban 没起来，不影响使用，稍后可用 systemctl status fail2ban 查看。"
}

valid_pubkey() {
  printf '%s' "$1" | grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/=]+( .*)?$'
}

ssh_base() {
  say "创建普通用户 + SSH 加固 + 防火墙"
  command -v ufw >/dev/null 2>&1 || apt-get -y install ufw
  command -v fail2ban-client >/dev/null 2>&1 || apt-get -y install fail2ban python3-systemd

  local user port home key
  local def
  def=$(state_get SSH_USER); [ -n "$def" ] || def="lulongqiang"
  user=$(ask "新用户名" "$def")
  printf '%s' "$user" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' || die "用户名只能用小写字母、数字、下划线和连字符。"

  if id "$user" >/dev/null 2>&1; then
    info "用户 $user 已存在，继续使用。"
  else
    adduser --disabled-password --gecos "" "$user" >/dev/null
    info "已创建用户 $user"
  fi
  usermod -aG sudo "$user"

  if passwd -S "$user" 2>/dev/null | awk '{print $2}' | grep -q '^P$'; then
    info "$user 已设置过密码（sudo 时要用）。"
  else
    info "给 $user 设置一个复杂密码（sudo 时要用，至少 10 位，输入时屏幕不显示）："
    until passwd "$user"; do warn "没设置成功，再来一次。"; done
  fi

  home=$(getent passwd "$user" | cut -d: -f6)
  mkdir -p "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  if [ -s "$home/.ssh/authorized_keys" ]; then
    info "$user 已有 $(grep -c . "$home/.ssh/authorized_keys") 把公钥。"
    key=$(ask "再添加一把公钥就粘贴进来，不添加直接回车" "")
  else
    info "在你电脑的 PowerShell 运行：type \$env:USERPROFILE\\.ssh\\id_ed25519.pub"
    info "把整行（以 ssh-ed25519 开头）粘贴到这里："
    key=$(ask "公钥" "")
    [ -n "$key" ] || die "没有公钥就无法安全登录，已停止。"
  fi
  if [ -n "$key" ]; then
    valid_pubkey "$key" || die "公钥格式不对，必须以 ssh-ed25519 等开头（常见问题：开头被截掉）。"
    grep -qxF "$key" "$home/.ssh/authorized_keys" || printf '%s\n' "$key" >> "$home/.ssh/authorized_keys"
  fi
  chown -R "$user:$user" "$home/.ssh"
  chmod 700 "$home/.ssh"
  chmod 600 "$home/.ssh/authorized_keys"

  def=$(state_get SSH_PORT); [ -n "$def" ] || def="23456"
  port=$(ask "新的 SSH 端口" "$def")
  valid_port "$port" || die "端口不对：$port"

  say "修改 SSH 配置（过渡期 22 和 $port 都能登录）"
  cp -f "$SSHD_CONF" "${SSHD_CONF}.lu.bak"
  sshd_ports 22 "$port"
  sshd_set PubkeyAuthentication yes
  sshd_apply

  say "防火墙"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp >/dev/null
  ufw allow "$port/tcp" >/dev/null
  # 已装好的节点端口一并放行，避免开启防火墙后节点断掉
  local p
  for p in "$(state_get REALITY_PORT)/tcp" "$(state_get HY2_PORT)/udp" "$(state_get CF_PORT)/tcp"; do
    case "$p" in /*) ;; *) ufw allow "$p" >/dev/null ;; esac
  done
  ufw --force enable >/dev/null
  info "ufw 已启用：放行 22/tcp、$port/tcp 和已装节点的端口。"

  say "fail2ban（防暴力破解）"
  write_fail2ban "22,$port"

  state_set SSH_USER "$user"
  state_set SSH_PORT "$port"

  local myip
  myip=$(ipv4_addr); [ -n "$myip" ] || myip=$(ipv6_addr); [ -n "$myip" ] || myip="服务器IP"
  cat <<EOF

${c_cyn}现在先别关这个窗口！另开一个 PowerShell 测试：${c_off}
  ssh -p $port $user@$myip
  sudo whoami
要求：不问服务器密码就能登录；sudo whoami 输出 root。
两条都满足后，再用菜单里的“收紧 SSH”关掉 22 端口、root 登录和密码登录。
EOF
}

ssh_lockdown() {
  say "收紧 SSH"
  local user port home
  user=$(state_get SSH_USER); port=$(state_get SSH_PORT)
  [ -n "$user" ] && [ -n "$port" ] || die "请先完成“系统初始化 + SSH 加固”。"
  home=$(getent passwd "$user" | cut -d: -f6)
  [ -s "$home/.ssh/authorized_keys" ] || die "$user 没有公钥，收紧后会无法登录，已停止。"

  cat <<EOF
将要做的改动：
  - 只保留 SSH 端口 $port，关闭 22
  - 禁止 root 登录
  - 禁止密码登录，只能用密钥
以后登录：ssh -p $port $user@服务器IP
确认你已经在另一个窗口用 $user 登录成功、并且 sudo whoami 输出 root。
EOF
  confirm_yes "确认收紧？" || { info "已取消。"; return 0; }

  cp -f "$SSHD_CONF" "${SSHD_CONF}.lu.bak"
  sshd_ports "$port"
  sshd_set PermitRootLogin no
  sshd_set PasswordAuthentication no
  sshd_set KbdInteractiveAuthentication no
  sshd_set PubkeyAuthentication yes
  sshd_apply
  fw_delete 22/tcp
  write_fail2ban "$port"
  state_set LOCKED 1
  info "完成。另开窗口验证：$user 能登录，root 登录被拒绝。"
  info "万一进不去，用服务商后台的网页控制台（VNC / View Console）登录修复。"
}

# ---------------------------------------------------------------------
# Xray 公共部分（每个节点一个独立服务，一个配错不影响其他）
# ---------------------------------------------------------------------
install_xray_core() {
  if [ -x "$XRAY_BIN" ]; then
    info "Xray 已安装：$("$XRAY_BIN" version 2>/dev/null | head -n1)"
    return 0
  fi
  say "安装 Xray（官方脚本）"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  [ -x "$XRAY_BIN" ] || die "Xray 安装失败。"
  # 官方脚本自带的 xray.service 不用，节点由 lu-* 服务各自运行
  systemctl disable --now xray >/dev/null 2>&1 || true
}

prepare_lu_dir() {
  mkdir -p "$LU_DIR"
  chown root:"$(nogroup)" "$LU_DIR"
  chmod 750 "$LU_DIR"
}

# write_unit 名称 配置文件 描述
write_unit() {
  cat > "/etc/systemd/system/$1.service" <<EOF
[Unit]
Description=$3
After=network-online.target
Wants=network-online.target

[Service]
User=nobody
Group=$(nogroup)
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$XRAY_BIN run -config $2
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

xray_test() {
  chown root:"$(nogroup)" "$1"
  chmod 640 "$1"
  runuser -u nobody -- "$XRAY_BIN" run -test -config "$1" >/tmp/lu-xray-test.log 2>&1
}

start_unit() {
  systemctl enable "$1" >/dev/null 2>&1
  systemctl restart "$1"
  sleep 2
  if systemctl is-active --quiet "$1"; then
    info "服务 $1：运行中"
  else
    journalctl -u "$1" -n 20 --no-pager || true
    die "服务 $1 没有起来，上面是日志。"
  fi
}

# 解析 xray x25519 的输出（兼容新旧两种格式）
parse_x25519() {
  # $1 = 输出内容；$2 = private | public
  if [ "$2" = "private" ]; then
    printf '%s\n' "$1" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}'
  else
    printf '%s\n' "$1" | awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}'
  fi
}

# ---------------------------------------------------------------------
# VLESS Reality
# ---------------------------------------------------------------------
reality_config() {
  # $1 = target 字段名（target 或 dest）
  local port uuid priv sid sni
  port=$(state_get REALITY_PORT); uuid=$(state_get REALITY_UUID)
  priv=$(state_get REALITY_PRIV); sid=$(state_get REALITY_SID); sni=$(state_get REALITY_SNI)
  cat > "$LU_DIR/reality.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$uuid", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "$1": "$sni:443",
          "serverNames": [ "$sni" ],
          "privateKey": "$priv",
          "shortIds": [ "$sid" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
}

install_reality() {
  say "安装 VLESS Reality"
  install_xray_core
  prepare_lu_dir

  local port sni old
  old=$(state_get REALITY_PORT)
  port=$(ask "Reality 端口（TCP）" "${old:-443}")
  valid_port "$port" || die "端口不对：$port"
  if [ "$port" != "$old" ] && port_in_use tcp "$port"; then die "TCP $port 已被占用，换一个。"; fi
  sni=$(state_get REALITY_SNI); [ -n "$sni" ] || sni="www.microsoft.com"
  sni=$(ask "伪装的网站（SNI）" "$sni")

  if [ -z "$(state_get REALITY_UUID)" ]; then
    local out priv pub
    out=$("$XRAY_BIN" x25519)
    priv=$(parse_x25519 "$out" private)
    pub=$(parse_x25519 "$out" public)
    [ -n "$priv" ] && [ -n "$pub" ] || die "密钥生成失败：$out"
    state_set REALITY_UUID "$("$XRAY_BIN" uuid)"
    state_set REALITY_PRIV "$priv"
    state_set REALITY_PUB "$pub"
    state_set REALITY_SID "$(rand_hex 8)"
  else
    info "沿用已有的 UUID 和密钥（客户端只需要改端口或 SNI）。"
  fi
  state_set REALITY_PORT "$port"
  state_set REALITY_SNI "$sni"

  reality_config target
  if ! xray_test "$LU_DIR/reality.json"; then
    reality_config dest
    xray_test "$LU_DIR/reality.json" || { cat /tmp/lu-xray-test.log; die "Reality 配置检查失败。"; }
  fi
  write_unit lu-reality "$LU_DIR/reality.json" "lu VLESS Reality"
  if [ -n "$old" ] && [ "$old" != "$port" ]; then fw_delete "$old/tcp"; fi
  fw_allow "$port/tcp"
  start_unit lu-reality
}

# ---------------------------------------------------------------------
# Hysteria2
# ---------------------------------------------------------------------
hy2_config() {
  cat > "$HY2_DIR/config.yaml" <<EOF
listen: :$(state_get HY2_PORT)
tls:
  cert: $HY2_DIR/server.crt
  key: $HY2_DIR/server.key
auth:
  type: password
  password: $(state_get HY2_PASS)
masquerade:
  type: proxy
  proxy:
    url: https://$(state_get HY2_SNI)
    rewriteHost: true
EOF
  if id hysteria >/dev/null 2>&1; then
    chown hysteria "$HY2_DIR/config.yaml" "$HY2_DIR/server.crt" "$HY2_DIR/server.key"
  fi
  chmod 600 "$HY2_DIR/server.key" "$HY2_DIR/config.yaml"
}

install_hy2() {
  say "安装 Hysteria2"
  local port old sni
  old=$(state_get HY2_PORT)
  port=$(ask "Hysteria2 端口（UDP）" "${old:-34567}")
  valid_port "$port" || die "端口不对：$port"
  if [ "$port" != "$old" ] && port_in_use udp "$port"; then die "UDP $port 已被占用，换一个。"; fi
  sni=$(state_get HY2_SNI); [ -n "$sni" ] || sni="bing.com"

  if ! command -v hysteria >/dev/null 2>&1; then
    bash -c "$(curl -fsSL https://get.hy2.sh/)"
  fi
  command -v hysteria >/dev/null 2>&1 || die "Hysteria2 安装失败。"

  mkdir -p "$HY2_DIR"
  # 证书必须带 subjectAltName，否则 sing-box 等客户端固定证书时会校验失败
  if [ ! -s "$HY2_DIR/server.crt" ] || [ ! -s "$HY2_DIR/server.key" ] \
     || ! openssl x509 -noout -ext subjectAltName -in "$HY2_DIR/server.crt" 2>/dev/null | grep -q "DNS:$sni"; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -keyout "$HY2_DIR/server.key" -out "$HY2_DIR/server.crt" -subj "/CN=$sni" \
      -addext "subjectAltName=DNS:$sni" -days 3650 2>/dev/null
    info "已生成自签证书（10 年，含 subjectAltName）。客户端如果固定过旧证书，需要重新获取。"
  fi
  # 密码只用十六进制，避免 / + = 等符号让链接导入失败
  if ! printf '%s' "$(state_get HY2_PASS)" | grep -Eq '^[0-9a-f]{16,}$'; then
    state_set HY2_PASS "$(rand_hex 12)"
  fi
  state_set HY2_PORT "$port"
  state_set HY2_SNI "$sni"
  state_set HY2_FP "$(openssl x509 -noout -fingerprint -sha256 -in "$HY2_DIR/server.crt" | cut -d= -f2 | tr -d ':')"
  hy2_config
  if [ -n "$old" ] && [ "$old" != "$port" ]; then fw_delete "$old/udp"; fi
  fw_allow "$port/udp"
  systemctl enable hysteria-server.service >/dev/null 2>&1 || true
  systemctl restart hysteria-server.service
  sleep 2
  if systemctl is-active --quiet hysteria-server.service; then
    info "服务 hysteria-server：运行中"
  else
    journalctl -u hysteria-server -n 20 --no-pager || true
    die "Hysteria2 没有起来，上面是日志。"
  fi
}

# ---------------------------------------------------------------------
# 套 Cloudflare 的 VLESS + XHTTP + TLS
# ---------------------------------------------------------------------
paste_pem() {
  local file="$1" label="$2" line got=0 tmp
  tmp=$(mktemp)
  echo
  echo "请粘贴【$label】，从 -----BEGIN 那行到 -----END 那行，粘贴完按回车："
  while IFS= read -r line; do
    line="${line%$'\r'}"
    case "$line" in *-----BEGIN*) got=1 ;; esac
    [ "$got" -eq 1 ] || continue
    printf '%s\n' "$line" >> "$tmp"
    case "$line" in *-----END*) break ;; esac
  done
  if ! grep -q -- "-----BEGIN" "$tmp" || ! grep -q -- "-----END" "$tmp"; then
    rm -f "$tmp"; die "$label 不完整，没读到 BEGIN 和 END 两行。"
  fi
  install -o root -g "$(nogroup)" -m 640 "$tmp" "$file"
  rm -f "$tmp"
}

cf_config() {
  local port uuid path domain
  port=$(state_get CF_PORT); uuid=$(state_get CF_UUID)
  path=$(state_get CF_PATH); domain=$(state_get CF_DOMAIN)
  cat > "$LU_DIR/cf.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $port,
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$uuid" } ], "decryption": "none" },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "alpn": [ "h2", "http/1.1" ],
          "certificates": [ { "certificateFile": "$LU_DIR/cf.crt", "keyFile": "$LU_DIR/cf.key" } ]
        },
        "xhttpSettings": { "host": "$domain", "path": "$path", "mode": "auto" }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
}

install_cf() {
  say "安装 CF 节点（VLESS + XHTTP + TLS，经 Cloudflare 中转）"
  cat <<EOF
准备工作（在 Cloudflare 后台）：
  1. DNS 加一条 A 记录（如 hd）指向本机 IPv4，橙色云朵打开；
     只有 IPv6 的机器就加 AAAA 记录指向本机 IPv6。
  2. SSL/TLS 模式设为“完全（严格）”。
  3. SSL/TLS → 源服务器 → 创建证书（保持默认），页面先别关。
注意：用 Cloudflare 跑代理违反它的服务条款，账号有被封的可能。
EOF
  confirm_yes "准备好了吗？" || { info "已取消。"; return 0; }
  install_xray_core
  prepare_lu_dir

  local domain port old
  domain=$(ask "节点子域名（例如 hd.example.com）" "$(state_get CF_DOMAIN)")
  printf '%s' "$domain" | grep -Eq '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' || die "域名格式不对：$domain"
  old=$(state_get CF_PORT)
  port=$(ask "端口，只能是 $CF_PORTS" "${old:-8443}")
  case " $CF_PORTS " in *" $port "*) ;; *) die "Cloudflare 只转发这几个端口：$CF_PORTS" ;; esac
  if [ "$port" != "$old" ] && port_in_use tcp "$port"; then die "TCP $port 已被占用，换一个。"; fi

  if [ -s "$LU_DIR/cf.crt" ] && [ -s "$LU_DIR/cf.key" ]; then
    local ans
    ans=$(ask "已有源服务器证书，重新粘贴吗？(y/N)" "N")
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
      paste_pem "$LU_DIR/cf.crt" "源证书"; paste_pem "$LU_DIR/cf.key" "私钥"
    fi
  else
    paste_pem "$LU_DIR/cf.crt" "源证书"
    paste_pem "$LU_DIR/cf.key" "私钥"
  fi
  openssl x509 -noout -in "$LU_DIR/cf.crt" >/dev/null 2>&1 || die "源证书格式不对。"

  [ -n "$(state_get CF_UUID)" ] || state_set CF_UUID "$("$XRAY_BIN" uuid)"
  [ -n "$(state_get CF_PATH)" ] || state_set CF_PATH "/$(rand_hex 6)"
  state_set CF_DOMAIN "$domain"
  state_set CF_PORT "$port"

  cf_config
  xray_test "$LU_DIR/cf.json" || { cat /tmp/lu-xray-test.log; die "CF 节点配置检查失败。"; }
  write_unit lu-cf "$LU_DIR/cf.json" "lu VLESS XHTTP via Cloudflare"
  if [ -n "$old" ] && [ "$old" != "$port" ]; then fw_delete "$old/tcp"; fi
  fw_allow "$port/tcp"
  start_unit lu-cf
  info "关掉代理用浏览器打开 https://$domain:$port$(state_get CF_PATH) ，显示 404 或空白说明通了；显示 CF 错误页 521/522/525 见教程排障表。"
}

# ---------------------------------------------------------------------
# 链接
# ---------------------------------------------------------------------
reality_link() {
  local host
  host=$(host_fmt "$1")
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
    "$(state_get REALITY_UUID)" "$host" "$(state_get REALITY_PORT)" "$(state_get REALITY_SNI)" \
    "$(state_get REALITY_PUB)" "$(state_get REALITY_SID)" "$2"
}

hy2_link() {
  local host
  host=$(host_fmt "$1")
  printf 'hysteria2://%s@%s:%s/?insecure=1&sni=%s#%s' \
    "$(state_get HY2_PASS)" "$host" "$(state_get HY2_PORT)" "$(state_get HY2_SNI)" "$2"
}

cf_link() {
  local d path
  d=$(state_get CF_DOMAIN)
  path=$(state_get CF_PATH | sed 's|/|%2F|g')
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h2%%2Chttp%%2F1.1&type=xhttp&host=%s&path=%s&mode=auto#%s' \
    "$(state_get CF_UUID)" "$d" "$(state_get CF_PORT)" "$d" "$d" "$path" "$1"
}

show_links() {
  say "节点链接（等于账号密码，不要发给任何人）"
  local v4 v6 tag out=""
  v4=$(ipv4_addr); v6=$(ipv6_addr)
  tag=$(hostname -s)
  [ -n "$v4" ] && info "IPv4：$v4"
  [ -n "$v6" ] && info "IPv6：$v6（只有在有 IPv6 的网络里才能连，例如手机 5G）"
  echo

  if [ -n "$(state_get REALITY_PORT)" ]; then
    [ -n "$v4" ] && out+="[Reality IPv4] $(reality_link "$v4" "$tag-Reality")"$'\n'
    [ -n "$v6" ] && out+="[Reality IPv6] $(reality_link "$v6" "$tag-Reality-v6")"$'\n'
  fi
  if [ -n "$(state_get HY2_PORT)" ]; then
    [ -n "$v4" ] && out+="[Hy2 IPv4] $(hy2_link "$v4" "$tag-Hy2")"$'\n'
    [ -n "$v6" ] && out+="[Hy2 IPv6] $(hy2_link "$v6" "$tag-Hy2-v6")"$'\n'
  fi
  if [ -n "$(state_get CF_PORT)" ]; then
    out+="[CF] $(cf_link "$tag-CF")"$'\n'
  fi
  if [ -z "$out" ]; then
    warn "还没有安装任何节点。"
    return 0
  fi
  printf '%s\n' "$out"
  if [ -n "$(state_get HY2_FP)" ]; then
    info "Hy2 证书指纹（SHA-256，可公开）：$(state_get HY2_FP)"
    info "  手机 v2rayNG 填到“证书指纹”后可关掉“跳过证书验证”。"
  fi
  cat <<EOF

客户端提示：
  v2rayN 里 Hy2 节点的 Core 类型选 sing_box；Reality 和 CF 节点保持 Xray。
  复制链接时只复制 vless:// 或 hysteria2:// 开头的部分，不要带前面的 [方括号说明]。
EOF
  {
    printf '%s\n' "$out"
    [ -n "$(state_get HY2_FP)" ] && printf 'Hy2 证书指纹：%s\n' "$(state_get HY2_FP)"
  } > "$LINKS_FILE"
  chmod 600 "$LINKS_FILE"
  info "以上内容已保存到 $LINKS_FILE"
}

# ---------------------------------------------------------------------
# 改端口 / 状态 / 卸载
# ---------------------------------------------------------------------
change_port() {
  say "修改节点端口"
  echo "  1. Reality（TCP，当前 $(state_get REALITY_PORT)）"
  echo "  2. Hysteria2（UDP，当前 $(state_get HY2_PORT)）"
  echo "  3. CF 节点（TCP，当前 $(state_get CF_PORT)）"
  local c
  c=$(ask "选择" "")
  case "$c" in
    1) [ -n "$(state_get REALITY_PORT)" ] || die "Reality 还没安装。"; install_reality ;;
    2) [ -n "$(state_get HY2_PORT)" ] || die "Hysteria2 还没安装。"; install_hy2 ;;
    3) [ -n "$(state_get CF_PORT)" ] || die "CF 节点还没安装。"; install_cf ;;
    *) info "已取消。"; return 0 ;;
  esac
  show_links
}

status() {
  say "服务"
  local s
  for s in lu-reality hysteria-server lu-cf ssh fail2ban; do
    if systemctl cat "$s.service" >/dev/null 2>&1; then
      if systemctl is-active --quiet "$s"; then ok "$s 运行中"; else bad "$s 没有运行（journalctl -u $s -n 20 看原因）"; fi
    fi
  done

  say "端口"
  local p
  p=$(state_get REALITY_PORT); [ -n "$p" ] && { port_in_use tcp "$p" && ok "Reality 在监听 $p/tcp" || bad "Reality 没在监听 $p/tcp"; }
  p=$(state_get HY2_PORT);     [ -n "$p" ] && { port_in_use udp "$p" && ok "Hy2 在监听 $p/udp" || bad "Hy2 没在监听 $p/udp"; }
  p=$(state_get CF_PORT);      [ -n "$p" ] && { port_in_use tcp "$p" && ok "CF 节点在监听 $p/tcp" || bad "CF 节点没在监听 $p/tcp"; }
  p=$(state_get SSH_PORT);     [ -n "$p" ] && { port_in_use tcp "$p" && ok "SSH 在监听 $p/tcp" || bad "SSH 没在监听 $p/tcp"; }

  say "防火墙"
  if ufw_on; then
    ok "ufw 已启用"
    ufw status | sed -n '/^--/,$p' | sed 's/^/    /'
  else
    bad "ufw 未启用（服务商后台若有防火墙，也要放行节点端口）"
  fi

  say "系统"
  local cc
  cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control)
  [ "$cc" = "bbr" ] && ok "BBR 已开启" || bad "拥塞控制是 $cc，可在菜单开启 BBR"
  if swapon --show --noheadings 2>/dev/null | grep -q .; then ok "swap 已启用"; else bad "没有 swap"; fi
  if [ -n "$(ipv6_addr)" ]; then ok "公网 IPv6：$(ipv6_addr)"; else info "  没有公网 IPv6"; fi
  if sshd -T 2>/dev/null | grep -q '^passwordauthentication no'; then ok "SSH 已禁用密码登录"; else bad "SSH 仍允许密码登录（菜单“收紧 SSH”）"; fi
  [ -f /var/run/reboot-required ] && warn "系统提示需要重启（reboot）。"
  return 0
}

uninstall() {
  say "卸载节点"
  echo "  1. Reality"
  echo "  2. Hysteria2"
  echo "  3. CF 节点"
  echo "  4. 全部节点（SSH 设置、防火墙、swap 保留）"
  local c r=0 h=0 f=0 k
  c=$(ask "选择" "")
  case "$c" in
    1) r=1 ;;
    2) h=1 ;;
    3) f=1 ;;
    4) r=1; h=1; f=1 ;;
    *) info "已取消。"; return 0 ;;
  esac
  confirm_yes "确认卸载？" || { info "已取消。"; return 0; }

  if [ "$r" = 1 ]; then
    systemctl disable --now lu-reality >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/lu-reality.service "$LU_DIR/reality.json"
    if [ -n "$(state_get REALITY_PORT)" ]; then fw_delete "$(state_get REALITY_PORT)/tcp"; fi
    for k in REALITY_PORT REALITY_UUID REALITY_PRIV REALITY_PUB REALITY_SID REALITY_SNI; do state_del "$k"; done
    info "Reality 已卸载。"
  fi
  if [ "$h" = 1 ]; then
    systemctl disable --now hysteria-server >/dev/null 2>&1 || true
    bash -c "$(curl -fsSL https://get.hy2.sh/)" -- --remove >/dev/null 2>&1 || true
    if [ -n "$(state_get HY2_PORT)" ]; then fw_delete "$(state_get HY2_PORT)/udp"; fi
    rm -rf "$HY2_DIR"
    for k in HY2_PORT HY2_PASS HY2_SNI HY2_FP; do state_del "$k"; done
    info "Hysteria2 已卸载。"
  fi
  if [ "$f" = 1 ]; then
    systemctl disable --now lu-cf >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/lu-cf.service "$LU_DIR/cf.json"
    if [ -n "$(state_get CF_PORT)" ]; then fw_delete "$(state_get CF_PORT)/tcp"; fi
    for k in CF_PORT CF_UUID CF_PATH CF_DOMAIN; do state_del "$k"; done
    info "CF 节点已卸载（源证书保留在 $LU_DIR，可手动删除）。"
  fi
  systemctl daemon-reload
}

# ---------------------------------------------------------------------
# 安装快捷命令 / 更新脚本
# ---------------------------------------------------------------------
install_self() {
  mkdir -p "$LU_DIR"
  local src="${BASH_SOURCE[0]:-$0}"
  if [ -f "$src" ] && [ "$(readlink -f "$src")" != "$LU_DIR/lu.sh" ]; then
    install -m 700 "$src" "$LU_DIR/lu.sh"
  elif [ ! -f "$LU_DIR/lu.sh" ]; then
    case "$SCRIPT_URL" in
      *你的用户名*) return 0 ;;
    esac
    curl -fsSL "$SCRIPT_URL" -o "$LU_DIR/lu.sh.tmp" 2>/dev/null \
      && bash -n "$LU_DIR/lu.sh.tmp" \
      && install -m 700 "$LU_DIR/lu.sh.tmp" "$LU_DIR/lu.sh"
    rm -f "$LU_DIR/lu.sh.tmp"
  fi
  if [ -f "$LU_DIR/lu.sh" ]; then
    printf '#!/usr/bin/env bash\nexec bash %s "$@"\n' "$LU_DIR/lu.sh" > /usr/local/bin/lu
    chmod 755 /usr/local/bin/lu
  fi
}

update_self() {
  say "更新本脚本"
  case "$SCRIPT_URL" in
    *你的用户名*) die "脚本开头的 SCRIPT_URL 还没改成你自己的 GitHub 地址。" ;;
  esac
  local tmp
  tmp=$(mktemp)
  curl -fsSL "$SCRIPT_URL" -o "$tmp" || die "下载失败：$SCRIPT_URL"
  bash -n "$tmp" || die "下载的脚本有语法错误，没有替换。"
  install -m 700 "$tmp" "$LU_DIR/lu.sh"
  rm -f "$tmp"
  info "已更新，下次输入 lu 生效。"
}

# ---------------------------------------------------------------------
# 一键全部
# ---------------------------------------------------------------------
all_in_one() {
  setup_swap
  sys_update
  enable_bbr
  ssh_base
  install_reality
  install_hy2
  show_links
  cat <<EOF

${c_cyn}接下来：${c_off}
  1. 另开窗口测试新用户登录（上面有命令）。
  2. 客户端导入链接、测通节点。
  3. 都没问题后，输入 lu 选“收紧 SSH”。
  4. 服务商后台如果有防火墙（Lightsail、AWS 安全组等），记得放行节点端口。
EOF
  reboot_hint
}

# ---------------------------------------------------------------------
# 菜单
# ---------------------------------------------------------------------
# 在子 shell 里运行一个操作：出错立即停止该操作，回到菜单
run() {
  ( set -Eeuo pipefail
    trap 'err "第 $LINENO 行的命令出错，本项操作已停止。上面是出错信息。"' ERR
    "$@" )
}

menu() {
  while true; do
    clear 2>/dev/null || true
    cat <<EOF
${c_cyn}========== lu 节点脚本 v$VERSION ==========${c_off}
 1. 一键安装（swap + 系统更新 + SSH 加固 + BBR + Reality + Hy2）
 2. 系统初始化 + SSH 加固（单独执行）
 3. 安装 / 重装 Reality
 4. 安装 / 重装 Hysteria2
 5. 安装 / 重装 CF 节点（需要 Cloudflare 域名）
 6. 查看节点链接
 7. 修改节点端口
 8. 状态检查
 9. 收紧 SSH（新用户测通后再用）
10. 卸载节点
11. 加 swap + 开启 BBR
12. 更新本脚本
 0. 退出
EOF
    local c
    read -r -p "请输入选择 [0-12]: " c || exit 0
    case "$c" in
      1)  run all_in_one ;;
      2)  run ssh_base ;;
      3)  run install_reality && run show_links ;;
      4)  run install_hy2 && run show_links ;;
      5)  run install_cf && run show_links ;;
      6)  run show_links ;;
      7)  run change_port ;;
      8)  run status ;;
      9)  run ssh_lockdown ;;
      10) run uninstall ;;
      11) run setup_swap && run enable_bbr ;;
      12) run update_self ;;
      0)  exit 0 ;;
      *)  warn "没有这个选项。" ;;
    esac
    pause
  done
}

main() {
  need_root
  check_os
  install_self
  case "${1:-}" in
    links)  run show_links ;;
    status) run status ;;
    ""|menu) menu ;;
    *) echo "用法：lu [links|status]"; exit 1 ;;
  esac
}

main "$@"
