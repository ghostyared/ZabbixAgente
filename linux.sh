#!/usr/bin/env bash
#
# Instalación de Zabbix Agent 2 (7.0 LTS) en Linux.
# Detecta la distribución, elige el paquete de repositorio correcto,
# instala, configura de forma idempotente y verifica el servicio.
#
# Uso:  sudo ./install-zabbix-agent2.sh [-n HOSTNAME] [-s SERVERS] [-a SERVERACTIVE] [-t TIMEOUT] [-p] [-l]
#   -n  Hostname del agente (por defecto pregunta; Enter = hostname actual)
#   -s  Servidores Zabbix (separados por coma)
#   -a  ServerActive (por defecto = -s; usa "-" para no configurarlo)
#   -t  Timeout del agente en segundos (por defecto 30)
#   -p  Instalar también los plugins (mongodb, mssql, postgresql)
#   -l  Solo listar las distribuciones soportadas y salir
#
set -euo pipefail

# ----------------------------- Configuración -----------------------------
ZBX_MAJOR="7.0"
ZBX_SERVERS="192.168.100.200,192.168.100.205,172.16.0.205"
ZBX_ACTIVE=""            # vacío = igual que ZBX_SERVERS
ZBX_TIMEOUT="30"
ZBX_PORT="10050"
INSTALL_PLUGINS="no"
ZBX_HOSTNAME=""
CONF="/etc/zabbix/zabbix_agent2.conf"
SERVICE="zabbix-agent2"
BASE="https://repo.zabbix.com/zabbix/${ZBX_MAJOR}"

# --------------------- Base de conocimiento de paquetes ---------------------
# Clave: <ID>-<VERSION>  (ubuntu/debian: versión completa; familia RHEL: versión mayor)
# Valor: URL del paquete zabbix-release
declare -A RELEASE_URL=(
  # Ubuntu / Debian (.deb)
  ["ubuntu-26.04"]="${BASE}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${ZBX_MAJOR}+ubuntu24.04_all.deb"
  ["ubuntu-24.04"]="${BASE}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${ZBX_MAJOR}+ubuntu24.04_all.deb"
  ["ubuntu-22.04"]="${BASE}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${ZBX_MAJOR}+ubuntu22.04_all.deb"
  ["debian-12"]="${BASE}/debian/pool/main/z/zabbix-release/zabbix-release_latest_${ZBX_MAJOR}+debian12_all.deb"
  # Rocky / RHEL / CentOS (.rpm) - @ARCH@ se reemplaza por x86_64 o aarch64
  ["rocky-9"]="${BASE}/rocky/9/@ARCH@/zabbix-release-latest-${ZBX_MAJOR}.el9.noarch.rpm"
  ["rocky-8"]="${BASE}/rocky/8/@ARCH@/zabbix-release-latest-${ZBX_MAJOR}.el8.noarch.rpm"
  ["rhel-9"]="${BASE}/rhel/9/@ARCH@/zabbix-release-latest-${ZBX_MAJOR}.el9.noarch.rpm"
  ["rhel-8"]="${BASE}/rhel/8/@ARCH@/zabbix-release-latest-${ZBX_MAJOR}.el8.noarch.rpm"
  ["rhel-7"]="${BASE}/rhel/7/@ARCH@/zabbix-release-latest-${ZBX_MAJOR}.el7.noarch.rpm"
  ["centos-7"]="${BASE}/rhel/7/@ARCH@/zabbix-release-latest-${ZBX_MAJOR}.el7.noarch.rpm"
)

# ------------------------------- Utilidades -------------------------------
log()  { printf '%s [INFO]  %s\n'  "$(date '+%F %T')" "$*"; }
warn() { printf '%s [WARN]  %s\n'  "$(date '+%F %T')" "$*" >&2; }
die()  { printf '%s [ERROR] %s\n'  "$(date '+%F %T')" "$*" >&2; exit 1; }

list_supported() {
  echo "Distribuciones soportadas:"
  printf '  %s\n' "${!RELEASE_URL[@]}" | sort
}

# ------------------------------- Argumentos -------------------------------
while getopts ":n:s:a:t:plh" opt; do
  case "$opt" in
    n) ZBX_HOSTNAME="$OPTARG" ;;
    s) ZBX_SERVERS="$OPTARG" ;;
    a) ZBX_ACTIVE="$OPTARG" ;;
    t) ZBX_TIMEOUT="$OPTARG" ;;
    p) INSTALL_PLUGINS="yes" ;;
    l) list_supported; exit 0 ;;
    h) sed -n '2,15p' "$0"; exit 0 ;;
    *) die "Opción inválida: -$OPTARG" ;;
  esac
done
[[ -z "$ZBX_ACTIVE" ]] && ZBX_ACTIVE="$ZBX_SERVERS"

[[ $EUID -eq 0 ]] || die "Ejecuta este script como root (sudo)."

# ---------------------------- Detección de la distro ----------------------------
[[ -r /etc/os-release ]] || die "No se encontró /etc/os-release."
# shellcheck disable=SC1091
. /etc/os-release

OS_ID="${ID,,}"
case "$OS_ID" in
  ubuntu|debian) OS_KEY="${OS_ID}-${VERSION_ID}" ;;
  *)             OS_KEY="${OS_ID}-${VERSION_ID%%.*}" ;;
esac

ARCH="$(uname -m)"
log "Sistema detectado: ${PRETTY_NAME:-$OS_ID $VERSION_ID} (${ARCH}) -> clave '${OS_KEY}'"

RELEASE="${RELEASE_URL[$OS_KEY]:-}"
if [[ -z "$RELEASE" ]]; then
  warn "Distribución no incluida en la base de conocimiento: ${OS_KEY}"
  list_supported >&2
  die "Agrega la URL de zabbix-release de esta distro a RELEASE_URL."
fi
RELEASE="${RELEASE//@ARCH@/$ARCH}"

# Verifica que la URL exista antes de intentar instalar (evita errores 404 a mitad de camino)
if command -v curl >/dev/null 2>&1; then
  curl -fsIL --max-time 20 "$RELEASE" >/dev/null || die "El paquete no está disponible (404/red): $RELEASE"
fi
log "Paquete de repositorio: $RELEASE"

# ------------------------------ Hostname del agente ------------------------------
if [[ -z "$ZBX_HOSTNAME" ]]; then
  CURRENT_HOST="$(hostname)"
  if [[ -t 0 ]]; then
    read -r -p "Nombre de HOST [${CURRENT_HOST}]: " ZBX_HOSTNAME
  fi
  ZBX_HOSTNAME="${ZBX_HOSTNAME:-$CURRENT_HOST}"
fi
if [[ "$ZBX_HOSTNAME" != "$(hostname)" ]]; then
  log "Cambiando hostname del sistema a '$ZBX_HOSTNAME'"
  hostnamectl set-hostname "$ZBX_HOSTNAME"
fi

# --------------------------------- Instalación ---------------------------------
PLUGIN_PKGS=(zabbix-agent2-plugin-mongodb zabbix-agent2-plugin-mssql zabbix-agent2-plugin-postgresql)

install_deb() {
  local tmp; tmp="$(mktemp --suffix=.deb)"
  if command -v wget >/dev/null 2>&1; then wget -q -O "$tmp" "$RELEASE"; else curl -fsSL -o "$tmp" "$RELEASE"; fi
  dpkg -i "$tmp"; rm -f "$tmp"
  apt-get update -qq
  local pkgs=(zabbix-agent2)
  [[ "$INSTALL_PLUGINS" == "yes" ]] && pkgs+=("${PLUGIN_PKGS[@]}")
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
}

install_rpm() {
  local pm="yum"; command -v dnf >/dev/null 2>&1 && pm="dnf"
  rpm -q zabbix-release >/dev/null 2>&1 || rpm -Uvh "$RELEASE"
  "$pm" clean all
  local pkgs=(zabbix-agent2)
  [[ "$INSTALL_PLUGINS" == "yes" ]] && pkgs+=("${PLUGIN_PKGS[@]}")
  "$pm" install -y "${pkgs[@]}"
}

if [[ -f "$CONF" ]] && command -v zabbix_agent2 >/dev/null 2>&1; then
  log "Zabbix Agent 2 ya está instalado; se omite la instalación."
else
  log "Instalando Zabbix Agent 2..."
  if [[ "$RELEASE" == *.deb ]]; then install_deb; else install_rpm; fi
fi
[[ -f "$CONF" ]] || die "No existe $CONF después de instalar."

# ---------------------------------- Configuración ----------------------------------
# Reemplaza la línea activa; si no existe, la comentada; si tampoco, la agrega al final.
set_param() {
  local key="$1" val="$2"
  if grep -qE "^[[:space:]]*${key}=" "$CONF"; then
    sed -i -E "s|^[[:space:]]*${key}=.*|${key}=${val}|" "$CONF"
  elif grep -qE "^[[:space:]]*#[[:space:]]*${key}=" "$CONF"; then
    sed -i -E "0,/^[[:space:]]*#[[:space:]]*${key}=/{s|^[[:space:]]*#[[:space:]]*${key}=.*|${key}=${val}|}" "$CONF"
  else
    printf '%s=%s\n' "$key" "$val" >> "$CONF"
  fi
}

cp -n "$CONF" "${CONF}.orig" 2>/dev/null || true
set_param Hostname "$ZBX_HOSTNAME"
set_param Server   "$ZBX_SERVERS"
if [[ "$ZBX_ACTIVE" != "-" ]]; then set_param ServerActive "$ZBX_ACTIVE"; fi
set_param Timeout  "$ZBX_TIMEOUT"
log "Configuración aplicada en $CONF"

# ------------------------------------ Firewall ------------------------------------
# Solo TCP (el agente no usa UDP) y solo desde los servidores Zabbix.
IFS=',' read -r -a SRV_LIST <<< "$ZBX_SERVERS"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  for ip in "${SRV_LIST[@]}"; do
    ufw allow from "$ip" to any port "$ZBX_PORT" proto tcp comment 'Zabbix agent' >/dev/null
  done
  log "Reglas ufw creadas para: ${ZBX_SERVERS}"
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  for ip in "${SRV_LIST[@]}"; do
    firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${ip} port port=${ZBX_PORT} protocol=tcp accept" >/dev/null
  done
  firewall-cmd --reload >/dev/null
  log "Reglas firewalld creadas para: ${ZBX_SERVERS}"
else
  log "No hay firewall activo (ufw/firewalld); no se crean reglas."
fi

# --------------------------- Servicio: reinicio automático ---------------------------
mkdir -p "/etc/systemd/system/${SERVICE}.service.d"
cat > "/etc/systemd/system/${SERVICE}.service.d/override.conf" <<'EOF'
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=30
EOF
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1
systemctl restart "$SERVICE"

# --------------------------------- Verificación ---------------------------------
sleep 3
if systemctl is-active --quiet "$SERVICE"; then
  log "Servicio ${SERVICE}: activo"
else
  warn "El servicio no quedó activo. Últimas líneas del journal:"
  journalctl -u "$SERVICE" -n 30 --no-pager || true
  exit 1
fi

if ss -ltn 2>/dev/null | grep -q ":${ZBX_PORT}\b"; then
  log "El agente escucha en el puerto ${ZBX_PORT}."
else
  warn "El puerto ${ZBX_PORT} no aparece en escucha."
fi

log "Configuración efectiva:"
grep -E '^(Hostname|Server|ServerActive|Timeout)=' "$CONF" | sed 's/^/    /'
log "Despliegue completado en $(hostname)."
