#!/bin/sh
# pfBlockerNG Post-Process Script
# Elimina de host overrides los dominios que ya están gestionados por pfBlockerNG
# Ubicación en pfSense: configurar en pfBlockerNG -> DNSBL -> Post-Process Script
#
# Flujo:
#   1. Lee el feed generado por el pre-process (ya cargado por pfBlockerNG)
#   2. Para cada FQDN del feed, elimina el host override correspondiente de config.xml
#   3. Recarga Unbound solo si hubo cambios (evita recargas innecesarias)
#   4. Loguea cada eliminación y el resultado final

CONFIG="/cf/conf/config.xml"
FEED_FILE="/var/db/pfblockerng/wazuh_dnsbl_feed.txt"
LOG_FILE="/var/log/pfblockerng_wazuh.log"
TMP_CONFIG="/tmp/config_wazuh_clean.xml"
DESCR="Added by Wazuh Active Response sinkhole"
TIMESTAMP=$(date "+%Y/%m/%d %H:%M:%S")

log() {
    echo "${TIMESTAMP} [post-process] $1" >> "$LOG_FILE"
}

# Verificar dependencias
if ! command -v xmllint > /dev/null 2>&1; then
    log "ERROR: xmllint no disponible"
    exit 1
fi
if ! command -v php > /dev/null 2>&1; then
    log "ERROR: php no disponible (necesario para pfSense_config_save)"
    exit 1
fi

# Verificar que el feed existe y tiene contenido
if [ ! -f "$FEED_FILE" ] || [ ! -s "$FEED_FILE" ]; then
    log "Feed vacío o inexistente — nada que limpiar"
    exit 0
fi

# Verificar que config.xml es legible
if [ ! -r "$CONFIG" ]; then
    log "ERROR: No se puede leer $CONFIG"
    exit 1
fi

# Contar overrides de Wazuh actualmente en config.xml
TOTAL_OVERRIDES=$(xmllint --xpath \
    "count(//unbound/hosts[normalize-space(descr)='${DESCR}'])" \
    "$CONFIG" 2>/dev/null || echo 0)

if [ "$TOTAL_OVERRIDES" -eq 0 ]; then
    log "No hay host overrides de Wazuh en config.xml — nada que limpiar"
    exit 0
fi

log "Iniciando limpieza: ${TOTAL_OVERRIDES} overrides de Wazuh encontrados"

# Construir script PHP para eliminar overrides de forma segura
# Usamos PHP porque es el método nativo de pfSense para modificar config.xml
# sin riesgo de corrupción (maneja locks y escritura atómica)
PHP_SCRIPT=$(cat << 'PHPEOF'
<?php
require_once("config.inc");
require_once("util.inc");

$descr  = "Added by Wazuh Active Response sinkhole";
$feed   = "/var/db/pfblockerng/wazuh_dnsbl_feed.txt";
$log    = "/var/log/pfblockerng_wazuh.log";
$ts     = date("Y/m/d H:i:s");

function wlog($msg) {
    global $log, $ts;
    file_put_contents($log, "{$ts} [post-process] {$msg}\n", FILE_APPEND);
}

// Leer FQDNs del feed
$feed_domains = [];
if (file_exists($feed)) {
    foreach (file($feed, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        $line = trim($line);
        if ($line !== '' && $line[0] !== '#') {
            $feed_domains[$line] = true;
        }
    }
}

if (empty($feed_domains)) {
    wlog("Feed sin dominios — saliendo");
    exit(0);
}

// Eliminar overrides de Wazuh que están en el feed
$removed = 0;
$skipped = 0;

if (isset($config['unbound']['hosts']) && is_array($config['unbound']['hosts'])) {
    $new_hosts = [];
    foreach ($config['unbound']['hosts'] as $entry) {
        $entry_descr = isset($entry['descr']) ? trim($entry['descr']) : '';
        if ($entry_descr !== $descr) {
            // No es de Wazuh — conservar siempre
            $new_hosts[] = $entry;
            continue;
        }
        $host   = isset($entry['host'])   ? trim($entry['host'])   : '';
        $domain = isset($entry['domain']) ? trim($entry['domain']) : '';
        $fqdn   = ($host !== '') ? "{$host}.{$domain}" : $domain;

        if (isset($feed_domains[$fqdn])) {
            // Está en el feed — pfBlockerNG ya lo bloquea — eliminar override
            wlog("Eliminado override: {$fqdn}");
            $removed++;
        } else {
            // Es de Wazuh pero aún no está en el feed — conservar
            wlog("Conservado (no en feed todavía): {$fqdn}");
            $skipped++;
            $new_hosts[] = $entry;
        }
    }
    $config['unbound']['hosts'] = $new_hosts;
}

if ($removed > 0) {
    write_config("Wazuh post-process: eliminados {$removed} overrides ya en pfBlockerNG");
    wlog("Config guardada: {$removed} eliminados, {$skipped} conservados");
    // Recargar Unbound para que los overrides eliminados dejen de tener efecto
    // (pfBlockerNG ya los bloquea desde el feed, así que no hay ventana sin cobertura)
    exec("/usr/local/sbin/unbound-control reload 2>&1", $out, $rc);
    if ($rc !== 0) {
        wlog("WARN: unbound-control reload salió con código {$rc}: " . implode(" ", $out));
    } else {
        wlog("Unbound recargado correctamente");
    }
} else {
    wlog("Ningún override eliminado (0 coincidencias feed/overrides)");
}

exit(0);
PHPEOF
)

# Ejecutar el script PHP con el entorno de pfSense
echo "$PHP_SCRIPT" | php -q
PHP_EXIT=$?

if [ $PHP_EXIT -ne 0 ]; then
    log "ERROR: El script PHP terminó con código $PHP_EXIT"
    exit 1
fi

log "Post-process completado"
exit 0
