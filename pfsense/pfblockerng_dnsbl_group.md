# Configuración del grupo DNSBL en pfBlockerNG

Referencia de los valores exactos a introducir en la UI de pfBlockerNG para el grupo `Wazuh_Sinkhole`.

---

## Datos del grupo

Ir a **Firewall → pfBlockerNG → DNSBL → DNSBL Groups → Add**

### Configuración general

| Campo | Valor |
|-------|-------|
| **Name** | `Wazuh_Sinkhole` |
| **Description** | Feed de amenazas dinámico generado por Wazuh Active Response. Los dominios se añaden automáticamente cuando se dispara una regla de seguridad y se eliminan una vez que pfBlockerNG asume el bloqueo persistente. |
| **Action** | `Unbound` |
| **State** | `Enabled` |

### Fuente del feed (DNSBL Sources)

| Campo | Valor |
|-------|-------|
| **Source** | `file:///var/db/pfblockerng/wazuh_dnsbl_feed.txt` |
| **Header/Label** | `WAZUH-SINKHOLE-FEED` |
| **State** | `ON` |
| **Format** | `Auto` |
| **Update Frequency** | `1 Hour` |

---

## Verificar que pfBlockerNG cargó el feed

Tras la primera actualización manual (**Update → Run**), verificar en los logs:

```sh
# Log principal de pfBlockerNG
cat /var/log/pfblockerng/pfblockerng.log | grep WAZUH

# Verificar en Unbound que los dominios están bloqueados
unbound-control list_local_data | grep globalchat
```

Resultado esperado:

```
www.globalchat.site. 60 IN A 0.0.0.0
```

---

## Notas importantes

- El archivo `wazuh_dnsbl_feed.txt` debe existir antes de que pfBlockerNG intente cargarlo. Si no existe, pfBlockerNG registrará un error pero continuará sin interrumpirse.
- El **Header/Label** `WAZUH-SINKHOLE-FEED` aparece en los logs de Unbound — facilita correlacionar bloqueos con alertas de Wazuh.
- El feed es **acumulativo**: los dominios no se eliminan aunque el host override haya sido limpiado, garantizando bloqueo persistente.
