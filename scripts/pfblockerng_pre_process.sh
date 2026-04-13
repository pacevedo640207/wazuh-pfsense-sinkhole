#!/bin/sh
# pfBlockerNG Pre-Process Script
# Extrae dominios de host overrides de Wazuh y los ACUMULA en el feed.
# No sobreescribe — añade los nuevos y conserva los anteriores.

CONFIG="/cf/conf/config.xml"
FEED_FILE="/var/db/pfblockerng/wazuh_dnsbl_feed.txt"
TMP_FEED="/tmp/wazuh_dnsbl_feed.tmp"
LOG_FILE="/var/log/pfblockerng_wazuh.log"
DESCR="Added by Wazuh Active Response sinkhole"
TIMESTAMP=$(date "+%Y/%m/%d %H:%M:%S")

log() {
    echo "${TIMESTAMP} [pre-process] $1" >> "$LOG_FILE"
}

if [ ! -r "$CONFIG" ]; then
    log "ERROR: No se puede leer $CONFIG"
    exit 1
fi

if ! command -v xmllint > /dev/null 2>&1; then
    log "ERROR: xmllint no disponible"
    exit 1
fi

FEED_DIR=$(dirname "$FEED_FILE")
if [ ! -d "$FEED_DIR" ]; then
    log "ERROR: Directorio $FEED_DIR no existe"
    exit 1
fi

# Extraer dominios nuevos desde los overrides actuales de Wazuh
XPATH_HOST="//unbound/hosts[normalize-space(descr)='${DESCR}']/host/text()"
XPATH_DOMAIN="//unbound/hosts[normalize-space(descr)='${DESCR}']/domain/text()"

xmllint --xpath "${XPATH_HOST} | ${XPATH_DOMAIN}" "$CONFIG" 2>/dev/null \
    | paste -d '.' - - \
    | grep -E '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$' \
    > "$TMP_FEED"

NEW_FROM_OVERRIDES=$(wc -l < "$TMP_FEED" | tr -d ' ')

# Combinar: feed existente + dominios nuevos extraídos → deduplicar → guardar
# De esta forma los dominios que ya no están en overrides (porque el post-process
# los limpió) se conservan en el feed para que pfBlockerNG siga bloqueándolos.
{
    # Contenido actual del feed (si existe), excluyendo comentarios
    if [ -f "$FEED_FILE" ]; then
        grep -v '^#' "$FEED_FILE"
    fi
    # Dominios recién extraídos de los overrides
    cat "$TMP_FEED"
} | sort -u > "${TMP_FEED}.merged"

PREV_COUNT=$([ -f "$FEED_FILE" ] && grep -c '^[^#]' "$FEED_FILE" 2>/dev/null || echo 0)
NEW_COUNT=$(wc -l < "${TMP_FEED}.merged" | tr -d ' ')
ADDED=$((NEW_COUNT - PREV_COUNT))

# Actualización atómica
mv "${TMP_FEED}.merged" "$FEED_FILE"
if [ $? -ne 0 ]; then
    log "ERROR: No se pudo actualizar $FEED_FILE"
    rm -f "$TMP_FEED" "${TMP_FEED}.merged"
    exit 1
fi

rm -f "$TMP_FEED"

if [ "$ADDED" -gt 0 ]; then
    log "Feed actualizado: ${NEW_COUNT} dominios (+${ADDED} nuevos desde overrides)"
elif [ "$ADDED" -lt 0 ]; then
    log "Feed actualizado: ${NEW_COUNT} dominios (${ADDED} duplicados eliminados)"
else
    log "Feed sin cambios: ${NEW_COUNT} dominios (${NEW_FROM_OVERRIDES} leídos desde overrides)"
fi

exit 0
