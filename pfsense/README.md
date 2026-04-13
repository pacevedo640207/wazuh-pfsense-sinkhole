# Configuración de pfSense

Guía para instalar y configurar la **API REST** y **pfBlockerNG** en pfSense.

---

## 1. Instalar la API REST de pfSense

### Instalación del paquete

1. Ir a **System → Package Manager → Available Packages**
2. Buscar `pfSense-pkg-API`
3. Hacer clic en **Install** y confirmar

### Configuración inicial

Ir a **System → API → Settings**:

| Campo | Valor recomendado |
|-------|------------------|
| Enable | ✅ Activado |
| Allowed IPs | IP del Wazuh Manager (ej: `192.168.4.10`) |
| Authentication mode | API Key |
| HTTPS only | ✅ Activado |
| Port | `8444` |

### Crear la API Key

1. Ir a **System → API → Keys**
2. Hacer clic en **Add**
3. Seleccionar el usuario (recomendado: crear un usuario dedicado `wazuh-api`)
4. Copiar la key generada — **se muestra una sola vez**
5. Guardarla en la variable de entorno `PFSENSE_API_KEY` del Wazuh Manager

### Permisos mínimos necesarios para el usuario API

El usuario `wazuh-api` solo necesita acceso a:

- `GET /api/v2/services/dns_resolver/host_override` — listar overrides
- `POST /api/v2/services/dns_resolver/host_override` — crear override
- `DELETE /api/v2/services/dns_resolver/host_override/{id}` — eliminar override

---

## 2. Verificar que la API responde

Desde el Wazuh Manager, probar conectividad:

```bash
# Listar host overrides actuales (debe devolver HTTP 200)
curl -sk \
  -H "X-API-KEY: TU_API_KEY_AQUI" \
  "https://192.168.4.1:8444/api/v2/services/dns_resolver/host_override"
```

Respuesta esperada:

```json
{
  "status": "ok",
  "code": 200,
  "data": []
}
```

---

## 3. Instalar pfBlockerNG

### Instalación del paquete

1. Ir a **System → Package Manager → Available Packages**
2. Buscar `pfBlockerNG-devel`
3. Instalar y esperar a que complete

> Se recomienda **pfBlockerNG-devel** sobre la versión estable para compatibilidad con las versiones recientes de pfSense.

### Configuración inicial

Al acceder por primera vez a **Firewall → pfBlockerNG**, aparecerá el asistente de configuración. Completarlo con los valores de tu red y activar **DNSBL**.

---

## 4. Crear el grupo DNSBL para Wazuh

### Datos del grupo

Ir a **Firewall → pfBlockerNG → DNSBL → DNSBL Groups → Add**:

| Campo | Valor |
|-------|-------|
| **Name** | `Wazuh_Sinkhole` |
| **Description** | Feed de amenazas dinámico generado por Wazuh Active Response. Los dominios se añaden automáticamente cuando se dispara una regla de seguridad y se eliminan una vez que pfBlockerNG asume el bloqueo persistente. |
| **Header/Label** | `WAZUH-SINKHOLE-FEED` |
| **Action** | `Unbound` |
| **Update Frequency** | `1 Hour` |
| **State** | `Enabled` |

### Configurar la fuente del feed

En la sección **DNSBL Sources** del grupo:

| Campo | Valor |
|-------|-------|
| **Source** | `file:///var/db/pfblockerng/wazuh_dnsbl_feed.txt` |
| **Header/Label** | `WAZUH-SINKHOLE-FEED` |
| **State** | `ON` |
| **Format** | `Auto` |

> El archivo `wazuh_dnsbl_feed.txt` es generado automáticamente por `pfblockerng_pre_process.sh`. En la primera ejecución puede estar vacío — pfBlockerNG lo ignorará sin errores.

---

## 5. Certificado TLS (opcional pero recomendado)

### Opción A — Certificado autofirmado con CA propia

```bash
# En pfSense: System → Certificate Manager → CAs → Add
# Exportar el certificado CA y copiarlo al Wazuh Manager:
scp admin@192.168.4.1:/tmp/pfsense-ca.crt /etc/ssl/certs/pfsense-ca.pem

# Añadir al override de systemd del Wazuh Manager:
Environment="PFSENSE_CA_CERT=/etc/ssl/certs/pfsense-ca.pem"
```

### Opción B — Aceptar riesgo en red interna aislada

Si la red entre Wazuh y pfSense está aislada, puede dejarse sin verificación. El script lo registrará en el log como advertencia:

```
TLS: verificación de certificado desactivada (riesgo aceptado en red interna)
```

---

## 6. Solución de problemas

| Síntoma | Causa probable | Solución |
|---------|---------------|----------|
| API devuelve 404 | Paquete no instalado o URL incorrecta | Verificar instalación y URL |
| API devuelve 401 | API Key inválida | Regenerar key en System → API → Keys |
| Unbound no resuelve al sinkhole | Override creado pero Unbound no recargó | El script usa `"apply": true` — verificar logs de Unbound |
| pfBlockerNG no carga el feed | El archivo del feed no existe aún | Ejecutar `wazuh_pfblockerng_cron.sh` manualmente una vez |
| Feed cargado pero sin bloqueos | Formato de dominio incorrecto | Revisar contenido de `wazuh_dnsbl_feed.txt` |
