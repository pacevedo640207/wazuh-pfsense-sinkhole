#!/bin/sh
# Orquestador Wazuh + pfBlockerNG
# Ubicación recomendada en pfSense: /usr/local/etc/pfblockerng/wazuh_cron.sh
# Cron sugerido: 5 * * * * root /usr/local/etc/pfblockerng/wazuh_cron.sh
#
# Flujo:
#   1. Genera el feed desde host overrides de Wazuh
#   2. Fuerza recarga de pfBlockerNG para que cargue el feed nuevo
#   3. Espera a que pfBlockerNG termine
#   4. Limpia los host overrides ya cubiertos por el feed

LOG_FILE="/var/log/pfblockerng_wazuh.log"
PRE_SCRIPT="/usr/local/etc/pfblockerng/wazuh_pre_process.sh"
POST_SCRIPT="/usr/local/etc/pfblockerng/wazuh_post_process.sh"
TIMESTAMP=$(date "+%Y/%m/%d %H:%M:%S")
PFB_LOCK="/var/db/pfblockerng/pfblockerng.lock"
WAIT_TIMEOUT=120   # segundos máximos esperando que pfBlockerNG libere el lock

log() {
    echo "${TIMESTAMP} [cron] $1" >> "$LOG_FILE"
}

# ---------- Verificar scripts ----------
for script in "$PRE_SCRIPT" "$POST_SCRIPT"; do
    if [ ! -x "$script" ]; then
        log "ERROR: $script no existe o no tiene permisos de ejecución"
        exit 1
    fi
done

log "=== Ciclo Wazuh-pfBlockerNG iniciado ==="

# ---------- PASO 1: Generar el feed ----------
log "Ejecutando pre-process (generación de feed)..."
sh "$PRE_SCRIPT"
PRE_EXIT=$?
if [ $PRE_EXIT -ne 0 ]; then
    log "ERROR: pre-process terminó con código $PRE_EXIT — abortando ciclo"
    exit 1
fi

# ---------- PASO 2: Forzar recarga de pfBlockerNG ----------
# Usamos el comando nativo de pfSense para que pfBlockerNG
# recargue todos sus feeds (incluido el feed de Wazuh recién generado)
log "Forzando recarga de pfBlockerNG..."
/usr/local/sbin/pfblockerng update cron 2>> "$LOG_FILE"
PFB_EXIT=$?
if [ $PFB_EXIT -ne 0 ]; then
    log "WARN: pfblockerng update salió con código $PFB_EXIT — continuando de todas formas"
fi

# ---------- PASO 3: Esperar a que pfBlockerNG termine ----------
# pfBlockerNG crea un lockfile mientras procesa; esperamos a que desaparezca
log "Esperando que pfBlockerNG libere el lock..."
WAITED=0
while [ -f "$PFBLOCK_LOCK" ] && [ $WAITED -lt $WAIT_TIMEOUT ]; do
    sleep 5
    WAITED=$((WAITED + 5))
done

if [ -f "$PFBLOCK_LOCK" ]; then
    log "WARN: pfBlockerNG sigue bloqueado tras ${WAIT_TIMEOUT}s — continuando de todas formas"
else
    log "pfBlockerNG liberó el lock tras ${WAITED}s"
fi

# Pausa adicional de seguridad para que Unbound aplique los cambios
sleep 10

# ---------- PASO 4: Limpiar host overrides ----------
log "Ejecutando post-process (limpieza de overrides)..."
sh "$POST_SCRIPT"
POST_EXIT=$?
if [ $POST_EXIT -ne 0 ]; then
    log "ERROR: post-process terminó con código $POST_EXIT"
    exit 1
fi

log "=== Ciclo completado correctamente ==="
exit 0
