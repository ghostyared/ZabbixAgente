#!/usr/bin/env bash
#
# Instalación de Zabbix Agent (2 ó 1) en Linux.
# Detecta la distribución, elige el paquete de repositorio correcto,
# instala, configura de forma idempotente y verifica el servicio.
#
# Si la distro no tiene paquete publicado en repo.zabbix.com (ej. una
# versión de Ubuntu/Debian/RHEL muy nueva), cae automáticamente al
# binario estático genérico de Zabbix Agent 1 (zabbix_agent, C) que
# Zabbix publica para linux amd64/i386. Ver NOTA_AGENTE_GENERICO abajo.
#
# Uso:  sudo ./install-zabbix-agent2.sh [-n HOSTNAME] [-s SERVERS] [-a SERVERACTIVE] [-t TIMEOUT] [-p] [-g] [-l]
#   -n  Hostname del agente (por defecto pregunta; Enter = hostname actual)
#   -s  Servidores Zabbix (separados por coma)
#   -a  ServerActive (por defecto = -s; usa "-" para no configurarlo)
#   -t  Timeout del agente en segundos (por defecto 30)
#   -p  Instalar también los plugins de Agent 2 (mongodb, mssql, postgresql)
#   -g  Forzar el binario estático genérico aunque exista paquete para la distro
#   -l  Solo listar las distribuciones con paquete conocido y salir
#
set -euo pipefail

# ----------------------------- Configuración -----------------------------
ZBX_MAJOR="7.0"
ZBX_SERVERS="192.168.100.200,192.168.100.205,172.16.0.205"
ZBX_ACTIVE=""            # vacío = igual que ZBX_SERVERS
ZBX_TIMEOUT="30"
ZBX_PORT="10050"
INSTALL_PLUGINS="no"
FORCE_GENERIC="no"
ZBX_HOSTNAME=""
BASE="https://repo.zabbix.com/zabbix/${ZBX_MAJOR}"
CDN="https://cdn.zabbix.com/zabbix/binaries/stable/${ZBX_MAJOR}/latest"

# Se fijan según la ruta de instalación elegida (paquete = Agent 2 / genérico = Agent 1)
CONF=""
SERVICE=""

# --------------------- Base de conocimiento de paquetes ---------------------
# Clave: <ID>-<VERSION>  (ubuntu/debian: versión completa; familia RHEL: versión mayor)
# Valor: URL del paquete zabbix-release (instala Zabbix Agent 2 vía apt/dnf/yum)
declare -A RELEASE_URL=(
  # Ubuntu / Debian (.deb)
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
  echo "Distribuciones con paquete conocido (Agent 2 vía repo.zabbix.com):"
  printf '  %s\n' "${!RELEASE_URL[@]}" | sort
  echo "Cualquier otra distro cae al binario estático genérico (Agent 1, solo linux amd64/i386)."
}

# ------------------------------- Argumentos -------------------------------
while getopts ":n:s:a:t:pglh" opt; do
  case "$opt" in
    n) ZBX_HOSTNAME="$OPTARG" ;;
    s) ZBX_SERVERS="$OPTARG" ;;
    a) ZBX_ACTIVE="$OPTARG" ;;
    t) ZBX_TIMEOUT="$OPTARG" ;;
    p) INSTALL_PLUGINS="yes" ;;
    g) FORCE_GENERIC="yes" ;;
    l) list_supported; exit 0 ;;
    h) sed -n '2,20p' "$0"; exit 0 ;;
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
USE_GENERIC="no"
if [[ "$FORCE_GENERIC" == "yes" || -z "$RELEASE" ]]; then
  USE_GENERIC="yes"
  [[ -z "$RELEASE" ]] && warn "No hay paquete conocido para '${OS_KEY}' en la base de conocimiento."
  log "Se usará el binario estático genérico de Zabbix Agent 1 (NOTA_AGENTE_GENERICO más abajo)."
else
  RELEASE="${RELEASE//@ARCH@/$ARCH}"
  # Verifica que la URL exista antes de intentar instalar (evita errores 404 a mitad de camino)
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsIL --max-time 20 "$RELEASE" >/dev/null; then
      warn "El paquete no está disponible (404/red): $RELEASE"
      warn "Se usará el binario estático genérico como respaldo."
      USE_GENERIC="yes"
    fi
  fi
  [[ "$USE_GENERIC" == "no" ]] && log "Paquete de repositorio: $RELEASE"
fi

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

# --------------------------------- Instalación (paquete = Agent 2) ---------------------------------
PLUGIN_PKGS=(zabbix-agent2-plugin-mongodb zabbix-agent2-plugin-mssql zabbix-agent2-plugin-postgresql)

install_deb() {
  local tmp; tmp="$(mktemp --suffix=.deb)"
  if command -v wget >/dev/null 2>&1; then wget -q -O "$tmp" "$RELEASE"; else curl -fsSL -o "$tmp" "$RELEASE"; fi
  dpkg -i "$tmp"; rm -f "$tmp"
  # -o Acquire::AllowReleaseInfoChange=true evita que apt-get update falle por cambios
  # de metadatos (p. ej. 'Label') en repos de terceros que no tienen nada que ver con Zabbix.
  apt-get update -qq -o Acquire::AllowReleaseInfoChange=true
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

# --------------------------- Instalación (genérico = Agent 1 estático) ---------------------------
# NOTA_AGENTE_GENERICO:
#   Zabbix solo publica binarios ESTÁTICOS para Linux del agente CLÁSICO
#   (zabbix_agent, en C), no de Agent 2 (Go). Este agente 1 soporta los mismos
#   parámetros básicos (Server, ServerActive, Hostname, Timeout) y checks
#   pasivos/activos, pero NO tiene el sistema de plugins de Agent 2
#   (no sirve -p en este modo). Úsalo como puente hasta que Zabbix publique
#   paquete para tu distro, y luego migra a Agent 2 reinstalando sin -g.
#   Solo hay binario estático para linux amd64 e i386 (no arm64).
GENERIC_PREFIX="/opt/zabbix-agent"
GENERIC_BIN="/usr/sbin/zabbix_agentd"

install_generic() {
  case "$ARCH" in
    x86_64) GARCH="amd64" ;;
    i386|i686) GARCH="i386" ;;
    *) die "No hay binario estático de Zabbix para arquitectura '${ARCH}' (solo amd64/i386). Instala manualmente." ;;
  esac
  local url="${CDN}/zabbix_agent-${ZBX_MAJOR}-latest-linux-3.0-${GARCH}-static.tar.gz"
  local tmp; tmp="$(mktemp -d)"
  log "Descargando binario estático genérico: $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmp/agent.tar.gz" "$url" || die "No se pudo descargar $url"
  else
    wget -q -O "$tmp/agent.tar.gz" "$url" || die "No se pudo descargar $url"
  fi
  tar -xzf "$tmp/agent.tar.gz" -C "$tmp"
  local srcdir; srcdir="$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -n1)"
  [[ -n "$srcdir" ]] || die "No se pudo extraer el paquete descargado."

  mkdir -p "$GENERIC_PREFIX" /etc/zabbix /var/log/zabbix /var/run/zabbix
  cp -a "$srcdir"/. "$GENERIC_PREFIX"/
  install -m 0755 "$GENERIC_PREFIX/sbin/zabbix_agentd" "$GENERIC_BIN" 2>/dev/null \
    || install -m 0755 "$GENERIC_PREFIX/bin/zabbix_agentd" "$GENERIC_BIN"
  [[ -f "$CONF" ]] || cp "$GENERIC_PREFIX/etc/zabbix_agentd.conf" "$CONF" 2>/dev/null \
    || cp "$GENERIC_PREFIX"/conf/zabbix_agentd.conf "$CONF"

  id zabbix >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin zabbix
  chown -R zabbix:zabbix /var/log/zabbix /var/run/zabbix

  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=Zabbix Agent (binario estático genérico)
After=network.target

[Service]
Type=forking
User=zabbix
Group=zabbix
ExecStart=${GENERIC_BIN} -c ${CONF}
ExecStop=/bin/kill -TERM \$MAINPID
PIDFile=/var/run/zabbix/zabbix_agentd.pid
Restart=always
RestartSec=30
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
EOF
  # El .conf de fábrica trae PidFile relativo; nos aseguramos de que coincida con el unit.
  grep -q '^PidFile=' "$CONF" && sed -i "s|^PidFile=.*|PidFile=/var/run/zabbix/zabbix_agentd.pid|" "$CONF" \
    || echo 'PidFile=/var/run/zabbix/zabbix_agentd.pid' >> "$CONF"

  rm -rf "$tmp"
  systemctl daemon-reload
  [[ "$INSTALL_PLUGINS" == "yes" ]] && warn "El binario genérico es Agent 1 (C): no soporta plugins de Agent 2; se ignora -p."
}

# ------------------------------------ Elegir ruta e instalar ------------------------------------
if [[ "$USE_GENERIC" == "yes" ]]; then
  CONF="/etc/zabbix/zabbix_agentd.conf"
  SERVICE="zabbix-agent"
  if [[ -x "$GENERIC_BIN" && -f "$CONF" ]]; then
    log "Zabbix Agent (genérico) ya está instalado; se omite la descarga."
  else
    log "Instalando Zabbix Agent (binario estático genérico)..."
    install_generic
  fi
else
  CONF="/etc/zabbix/zabbix_agent2.conf"
  SERVICE="zabbix-agent2"
  if [[ -f "$CONF" ]] && command -v zabbix_agent2 >/dev/null 2>&1; then
    log "Zabbix Agent 2 ya está instalado; se omite la instalación."
  else
    log "Instalando Zabbix Agent 2..."
    if [[ "$RELEASE" == *.deb ]]; then install_deb; else install_rpm; fi
  fi
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
if [[ "$USE_GENERIC" == "no" ]]; then
  # El paquete ya trae su propia unidad systemd; solo agregamos un override de recuperación.
  mkdir -p "/etc/systemd/system/${SERVICE}.service.d"
  cat > "/etc/systemd/system/${SERVICE}.service.d/override.conf" <<'EOF'
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=30
EOF
  systemctl daemon-reload
fi
# En modo genérico la unidad ya se creó completa (con Restart=always) dentro de install_generic().

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
[[ "$USE_GENERIC" == "yes" ]] && log "Instalado con el binario estático genérico (Agent 1). Migra a Agent 2 cuando Zabbix publique paquete para '${OS_KEY}'."
log "Despliegue completado en $(hostname)."
