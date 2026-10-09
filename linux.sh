#!/usr/bin/env bash
#
# Instalación de Zabbix Agent (2 ó 1) en Linux.
# Detecta la distribución, elige el paquete de repositorio correcto,
# instala, configura de forma idempotente y verifica el servicio.
#
# Si la distro no tiene paquete publicado en repo.zabbix.com (ej. una
# versión de Ubuntu/Debian/RHEL muy nueva), cae automáticamente al
# binario estático genérico de Zabbix Agent 1 (zabbix_agentd, C) que
# Zabbix publica para linux amd64/i386. Ver NOTA_AGENTE_GENERICO abajo.
#
# IMPORTANTE: este script NUNCA modifica el hostname del sistema.
# El nombre indicado con -n solo se escribe en el parámetro Hostname= del agente.
#
# Uso:  sudo ./linux.sh [-n HOSTNAME] [-s SERVERS] [-a SERVERACTIVE] [-t TIMEOUT] [-p] [-g] [-l]
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
ZBX_SERVERS="192.168.100.200"
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
# @ARCH@ se reemplaza por x86_64 o aarch64
EL7="${BASE}/rhel/7/@ARCH@/zabbix-release-latest-${ZBX_MAJOR}.el7.noarch.rpm"
EL8="${BASE}/rhel/8/@ARCH@/zabbix-release-latest-${ZBX_MAJOR}.el8.noarch.rpm"
EL9="${BASE}/rhel/9/@ARCH@/zabbix-release-latest-${ZBX_MAJOR}.el9.noarch.rpm"
EL10="${BASE}/rhel/10/@ARCH@/zabbix-release-latest-${ZBX_MAJOR}.el10.noarch.rpm"

declare -A RELEASE_URL=(
  # Ubuntu / Debian (.deb)
  ["ubuntu-26.04"]="${BASE}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${ZBX_MAJOR}+ubuntu26.04_all.deb"
  ["ubuntu-24.04"]="${BASE}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${ZBX_MAJOR}+ubuntu24.04_all.deb"
  ["ubuntu-22.04"]="${BASE}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${ZBX_MAJOR}+ubuntu22.04_all.deb"
  ["debian-12"]="${BASE}/debian/pool/main/z/zabbix-release/zabbix-release_latest_${ZBX_MAJOR}+debian12_all.deb"
  # Oracle Linux (usa el repo rhel de Zabbix)
  ["ol-7"]="$EL7"
  ["ol-8"]="$EL8"
  ["ol-9"]="$EL9"
  ["ol-10"]="$EL10"
  # RHEL
  ["rhel-7"]="$EL7"
  ["rhel-8"]="$EL8"
  ["rhel-9"]="$EL9"
  ["rhel-10"]="$EL10"
  # Rocky
  ["rocky-8"]="$EL8"
  ["rocky-9"]="$EL9"
  ["rocky-10"]="$EL10"
  # AlmaLinux
  ["almalinux-8"]="$EL8"
  ["almalinux-9"]="$EL9"
  ["almalinux-10"]="$EL10"
  # CentOS / CentOS Stream
  ["centos-7"]="$EL7"
  ["centos-8"]="$EL8"
  ["centos-9"]="$EL9"
  ["centos-10"]="$EL10"
)

# ------------------------------- Utilidades -------------------------------
log()  { printf '%s [INFO]  %s\n'  "$(date '+%F %T')" "$*"; }
warn() { printf '%s [WARN]  %s\n'  "$(date '+%F %T')" "$*" >&2; }
die()  { printf '%s [ERROR] %s\n'  "$(date '+%F %T')" "$*" >&2; exit 1; }

list_supported() {
  echo "Distribuciones con paquete conocido (Agent 2 vía repo.zabbix.com):"
  printf '  %s\n' "${!RELEASE_URL[@]}" | sort
  echo "Clones de RHEL no listados (ID_LIKE=rhel) se resuelven como rhel-<versión mayor>."
  echo "Cualquier otra distro cae al binario estático genérico (Agent 1, solo linux amd64/i386)."
}

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
    h) sed -n '2,/^set -/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    :) die "La opción -$OPTARG requiere un valor." ;;
    *) die "Opción inválida: -$OPTARG" ;;
  esac
done
if [[ -z "$ZBX_ACTIVE" ]]; then ZBX_ACTIVE="$ZBX_SERVERS"; fi

[[ $EUID -eq 0 ]] || die "Ejecuta este script como root (sudo)."

# ---------------------------- Detección de la distro ----------------------------
[[ -r /etc/os-release ]] || die "No se encontró /etc/os-release."
# shellcheck disable=SC1091
. /etc/os-release

VERSION_ID="${VERSION_ID:-0}"
OS_ID="${ID,,}"
case "$OS_ID" in
  ubuntu|debian) OS_KEY="${OS_ID}-${VERSION_ID}" ;;
  *)             OS_KEY="${OS_ID}-${VERSION_ID%%.*}" ;;
esac

ARCH="$(uname -m)"
log "Sistema detectado: ${PRETTY_NAME:-$OS_ID $VERSION_ID} (${ARCH}) -> clave '${OS_KEY}'"

RELEASE="${RELEASE_URL[$OS_KEY]:-}"

# Fallback para clones de RHEL no listados (ID_LIKE contiene "rhel")
if [[ -z "$RELEASE" && " ${ID_LIKE:-} " == *" rhel "* ]]; then
  ALT_KEY="rhel-${VERSION_ID%%.*}"
  RELEASE="${RELEASE_URL[$ALT_KEY]:-}"
  if [[ -n "$RELEASE" ]]; then
    log "Distro derivada de RHEL; se usa la clave '${ALT_KEY}'."
    OS_KEY="$ALT_KEY"
  fi
fi

USE_GENERIC="no"
if [[ "$FORCE_GENERIC" == "yes" || -z "$RELEASE" ]]; then
  USE_GENERIC="yes"
  if [[ -z "$RELEASE" ]]; then warn "No hay paquete conocido para '${OS_KEY}' en la base de conocimiento."; fi
  log "Se usará el binario estático genérico de Zabbix Agent 1 (ver NOTA_AGENTE_GENERICO)."
else
  RELEASE="${RELEASE//@ARCH@/$ARCH}"
  # En arm64 Zabbix publica los .deb de Ubuntu en un árbol aparte (ubuntu-arm64).
  if [[ "$RELEASE" == *.deb && ( "$ARCH" == "aarch64" || "$ARCH" == "arm64" ) ]]; then
    RELEASE="${RELEASE/\/zabbix\/${ZBX_MAJOR}\/ubuntu\//\/zabbix\/${ZBX_MAJOR}\/ubuntu-arm64\/}"
  fi
  # Verifica que la URL exista antes de instalar (evita errores 404 a mitad de camino)
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsIL --max-time 20 "$RELEASE" >/dev/null; then
      warn "El paquete no está disponible (404/red): $RELEASE"
      warn "Se usará el binario estático genérico como respaldo."
      USE_GENERIC="yes"
    fi
  fi
  if [[ "$USE_GENERIC" == "no" ]]; then log "Paquete de repositorio: $RELEASE"; fi
fi

# ------------------------------ Hostname del agente ------------------------------
# Solo define el valor de Hostname= en el .conf del agente. NO toca el hostname del sistema.
if [[ -z "$ZBX_HOSTNAME" ]]; then
  ZBX_HOSTNAME="$(hostname)"
  if [[ -t 0 ]]; then
    INPUT_HOST=""
    read -r -p "Nombre de HOST [${ZBX_HOSTNAME}]: " INPUT_HOST || true
    ZBX_HOSTNAME="${INPUT_HOST:-$ZBX_HOSTNAME}"
  fi
fi
log "Hostname del agente: '${ZBX_HOSTNAME}' (el hostname del sistema no se modifica)."

# --------------------------------- Instalación (paquete = Agent 2) ---------------------------------
PLUGIN_PKGS=(zabbix-agent2-plugin-mongodb zabbix-agent2-plugin-mssql zabbix-agent2-plugin-postgresql)

install_deb() {
  local tmp; tmp="$(mktemp --suffix=.deb)"
  if command -v wget >/dev/null 2>&1; then wget -q -O "$tmp" "$RELEASE"; else curl -fsSL -o "$tmp" "$RELEASE"; fi
  dpkg -i "$tmp"; rm -f "$tmp"
  # Ubuntu/Debian traen su propio paquete zabbix* (universe) que puede ganar por número de
  # versión. Se prioriza el repo oficial para quedar en el 7.0 LTS vigente.
  cat > /etc/apt/preferences.d/zabbix-official <<'EOF'
Package: zabbix*
Pin: origin repo.zabbix.com
Pin-Priority: 1001
EOF
  # AllowReleaseInfoChange evita que apt-get update falle por cambios de metadatos
  # (p. ej. 'Label') en repos de terceros que no tienen nada que ver con Zabbix.
  apt-get update -qq -o Acquire::AllowReleaseInfoChange=true
  local pkgs=(zabbix-agent2)
  if [[ "$INSTALL_PLUGINS" == "yes" ]]; then pkgs+=("${PLUGIN_PKGS[@]}"); fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
}

# En Oracle Linux (y RHEL en general) EPEL también publica paquetes zabbix*.
# Se excluyen para que no reemplacen a los del repo oficial de Zabbix.
exclude_zabbix_from_epel() {
  local f
  for f in /etc/yum.repos.d/*[Ee][Pp][Ee][Ll]*.repo; do
    [[ -f "$f" ]] || continue
    if grep -qE '^excludepkgs=.*zabbix' "$f"; then continue; fi
    if grep -qE '^excludepkgs=' "$f"; then
      warn "$f ya tiene excludepkgs; agrega 'zabbix*' manualmente si EPEL está habilitado."
      continue
    fi
    sed -i -E '/^\[.*\]/a excludepkgs=zabbix*' "$f"
    log "Excluido zabbix* en $f"
  done
}

install_rpm() {
  local pm="yum"; if command -v dnf >/dev/null 2>&1; then pm="dnf"; fi
  if ! rpm -q zabbix-release >/dev/null 2>&1; then rpm -Uvh "$RELEASE"; fi
  exclude_zabbix_from_epel
  "$pm" clean all
  local pkgs=(zabbix-agent2)
  if [[ "$INSTALL_PLUGINS" == "yes" ]]; then pkgs+=("${PLUGIN_PKGS[@]}"); fi
  "$pm" install -y "${pkgs[@]}"
}

# --------------------------- Instalación (genérico = Agent 1 estático) ---------------------------
# NOTA_AGENTE_GENERICO:
#   Zabbix solo publica binarios ESTÁTICOS para Linux del agente CLÁSICO
#   (zabbix_agentd, en C), no de Agent 2 (Go). Este agente 1 soporta los mismos
#   parámetros básicos (Server, ServerActive, Hostname, Timeout) y checks
#   pasivos/activos, pero NO tiene el sistema de plugins de Agent 2
#   (no sirve -p en este modo). Úsalo como puente hasta que Zabbix publique
#   paquete para tu distro, y luego migra a Agent 2 reinstalando sin -g.
#   Solo hay binario estático para linux amd64 e i386 (no arm64).
GENERIC_BIN="/usr/sbin/zabbix_agentd"

install_generic() {
  local GARCH
  case "$ARCH" in
    x86_64)    GARCH="amd64" ;;
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

  # El tar trae bin/ sbin/ conf/ en la raíz (o dentro de un único directorio): se soportan ambos casos.
  mkdir -p "$tmp/x"
  tar -xzf "$tmp/agent.tar.gz" -C "$tmp/x"
  local bin dist_conf
  bin="$(find "$tmp/x" -type f -name zabbix_agentd -print -quit)"
  dist_conf="$(find "$tmp/x" -type f -name zabbix_agentd.conf -print -quit)"
  [[ -n "$bin" ]] || die "No se encontró zabbix_agentd en el paquete descargado."

  mkdir -p /etc/zabbix /var/log/zabbix
  install -m 0755 "$bin" "$GENERIC_BIN"
  if [[ ! -f "$CONF" ]]; then
    [[ -n "$dist_conf" ]] || die "No se encontró zabbix_agentd.conf en el paquete descargado."
    cp "$dist_conf" "$CONF"
  fi

  if ! id zabbix >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin zabbix
  fi
  chown -R zabbix:zabbix /var/log/zabbix

  set_param LogFile "/var/log/zabbix/zabbix_agentd.log"
  set_param PidFile "/run/zabbix/zabbix_agentd.pid"

  # RuntimeDirectory recrea /run/zabbix (tmpfs) en cada arranque con el dueño correcto.
  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=Zabbix Agent (binario estático genérico)
After=network.target

[Service]
Type=forking
User=zabbix
Group=zabbix
RuntimeDirectory=zabbix
PIDFile=/run/zabbix/zabbix_agentd.pid
ExecStart=${GENERIC_BIN} -c ${CONF}
Restart=always
RestartSec=30
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
EOF

  rm -rf "$tmp"
  systemctl daemon-reload
  if [[ "$INSTALL_PLUGINS" == "yes" ]]; then
    warn "El binario genérico es Agent 1 (C): no soporta plugins de Agent 2; se ignora -p."
  fi
  return 0
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
cp -n "$CONF" "${CONF}.orig" 2>/dev/null || true
set_param Hostname "$ZBX_HOSTNAME"
set_param Server   "$ZBX_SERVERS"
if [[ "$ZBX_ACTIVE" != "-" ]]; then set_param ServerActive "$ZBX_ACTIVE"; fi
set_param Timeout  "$ZBX_TIMEOUT"
log "Configuración aplicada en $CONF"

# ------------------------------------ Firewall ------------------------------------
# Solo TCP (el agente no usa UDP) y solo desde los servidores Zabbix.
# En OCI recuerda permitir también TCP ${ZBX_PORT} en la Security List / NSG.
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
grep -E '^(Hostname|Server|ServerActive|Timeout)=' "$CONF" | sed 's/^/    /' || true
if [[ "$USE_GENERIC" == "yes" ]]; then
  log "Instalado con el binario estático genérico (Agent 1). Migra a Agent 2 cuando Zabbix publique paquete para '${OS_KEY}'."
fi
log "Despliegue completado en $(hostname)."
