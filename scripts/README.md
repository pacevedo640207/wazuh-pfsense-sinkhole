# Scripts de pfSense

Scripts que se ejecutan directamente en **pfSense** para sincronizar los host overrides de Wazuh con pfBlockerNG DNSBL.

---

## Descripción de los scripts

| Script | Dónde se ejecuta | Cuándo |
|--------|-----------------|--------|
| `pfblockerng_pre_process.sh` | pfSense | Antes de que pfBlockerNG cargue los feeds |
| `pfblockerng_post_process.sh` | pfSense | Después de que pfBlockerNG aplica los feeds |
| `wazuh_pfblockerng_cron.sh` | pfSense | Cron horario — orquesta los dos anteriores |

---

## Flujo de ejecución

```
Cron (minuto 5 de cada hora)
        │
        ▼
wazuh_pfblockerng_cron.sh
        │
        ├─ 1. pre_process.sh
        │      Lee config.xml
        │      Extrae FQDNs de los overrides de Wazuh
        │      Acumula en wazuh_dnsbl_feed.txt (nunca sobreescribe)
        │
        ├─ 2. pfblockerng update cron
        │      pfBlockerNG recarga todos sus feeds
        │      Unbound aplica los bloqueos DNSBL
        │
        ├─ 3. Espera a que pfBlockerNG libere el lock
        │
        └─ 4. post_process.sh (PHP nativo de pfSense)
               Para cada FQDN del feed:
                 Si el override existe → eliminarlo de config.xml
                 Si aún no está en el feed → conservarlo
               Si hubo cambios → write_config() + unbound-control reload
```

---

## Instalación en pfSense

### 1. Copiar los scripts

Conectar a pfSense por SSH y ejecutar:

```sh
# Crear el directorio si no existe
mkdir -p /usr/local/etc/pfblockerng/

# Copiar los scripts desde una máquina con acceso al repositorio
scp scripts/pfblockerng_pre_process.sh  admin@192.168.4.1:/usr/local/etc/pfblockerng/wazuh_pre_process.sh
scp scripts/pfblockerng_post_process.sh admin@192.168.4.1:/usr/local/etc/pfblockerng/wazuh_post_process.sh
scp scripts/wazuh_pfblockerng_cron.sh   admin@192.168.4.1:/usr/local/etc/pfblockerng/wazuh_cron.sh
```

### 2. Asignar permisos

```sh
chmod 750 /usr/local/etc/pfblockerng/wazuh_pre_process.sh
chmod 750 /usr/local/etc/pfblockerng/wazuh_post_process.sh
chmod 750 /usr/local/etc/pfblockerng/wazuh_cron.sh
```

### 3. Crear el directorio del feed

```sh
mkdir -p /var/db/pfblockerng/
touch /var/db/pfblockerng/wazuh_dnsbl_feed.txt
```

### 4. Configurar el cron

```sh
# Añadir al cron de pfSense (se ejecuta al minuto 5 de cada hora)
echo "5 * * * * root /usr/local/etc/pfblockerng/wazuh_cron.sh" \
  >> /etc/cron.d/wazuh_pfblockerng
```

También puede configurarse desde la UI en **Services → Cron → Add**:

| Campo | Valor |
|-------|-------|
| Minute | `5` |
| Hour | `*` |
| Day of month | `*` |
| Month | `*` |
| Day of week | `*` |
| User | `root` |
| Command | `/usr/local/etc/pfblockerng/wazuh_cron.sh` |

---

## Prueba manual

```sh
# Ejecutar el ciclo completo manualmente
sh /usr/local/etc/pfblockerng/wazuh_cron.sh

# Ver el log en tiempo real
tail -f /var/log/pfblockerng_wazuh.log
```

Salida esperada en el log:

```
2026/04/10 10:05:01 [cron] === Ciclo Wazuh-pfBlockerNG iniciado ===
2026/04/10 10:05:01 [pre-process] Feed actualizado: 3 dominios (+1 nuevos desde overrides)
2026/04/10 10:05:18 [cron] pfBlockerNG liberó el lock tras 15s
2026/04/10 10:05:28 [post-process] Eliminado override: www.globalchat.site
2026/04/10 10:05:28 [post-process] Config guardada: 1 eliminados, 0 conservados
2026/04/10 10:05:28 [post-process] Unbound recargado correctamente
2026/04/10 10:05:28 [cron] === Ciclo completado correctamente ===
```

---

## Archivo del feed

El feed se guarda en:

```
/var/db/pfblockerng/wazuh_dnsbl_feed.txt
```

Formato — un FQDN por línea, sin comentarios:

```
malware-c2.example.com
phishing-site.net
www.globalchat.site
```

Para limpiar el feed manualmente:

```sh
> /var/db/pfblockerng/wazuh_dnsbl_feed.txt
```

---

## Solución de problemas

| Síntoma | Causa | Solución |
|---------|-------|----------|
| Log vacío | El script no tiene permisos de ejecución | `chmod 750 wazuh_cron.sh` |
| `xmllint no disponible` | Paquete no instalado | `pkg install libxml2` |
| Feed vacío tras pre-process | No hay overrides de Wazuh en config.xml | Verificar que el active-response creó overrides |
| Post-process no elimina nada | FQDNs en overrides no coinciden con el feed | Revisar formato en `config.xml` vs `feed.txt` |
| `pfblockerng update` falla | pfBlockerNG no instalado o desactivado | Verificar en Firewall → pfBlockerNG |
| Cron no persiste tras reinicio | pfSense no persiste `/etc/cron.d` | Configurar via UI en Services → Cron |
