# Configuración de Wazuh

Guía completa para instalar y configurar el active-response de DNS Sinkhole en el **Wazuh Manager**.

---

## Requisitos previos

```bash
# Verificar versión de Python
python3 --version   # >= 3.6 requerido

# Instalar la librería requests
pip3 install requests --break-system-packages

# Verificar que está disponible para root
sudo python3 -c "import requests; print('OK')"
```

---

## 1. Instalar el script de active-response

```bash
# Copiar el script al directorio de active-response de Wazuh
cp pfsense_dns_sinkhole.py /var/ossec/active-response/bin/

# Asignar propietario y permisos correctos
chmod 750 /var/ossec/active-response/bin/pfsense_dns_sinkhole.py
chown root:wazuh /var/ossec/active-response/bin/pfsense_dns_sinkhole.py
```

---

## 2. Configurar variables de entorno

El script **nunca acepta credenciales hardcodeadas**. Las lee exclusivamente de variables de entorno del proceso Wazuh Manager.

Crea un override de systemd para el servicio:

```bash
mkdir -p /etc/systemd/system/wazuh-manager.service.d/

cat > /etc/systemd/system/wazuh-manager.service.d/override.conf << 'EOF'
[Service]
Environment="PFSENSE_API_URL=https://192.168.4.1:8444/api/v2/services/dns_resolver/host_override"
Environment="PFSENSE_API_KEY=TU_API_KEY_AQUI"
Environment="PFSENSE_SINKHOLE_IP=127.0.0.1"
Environment="PFSENSE_TIMEOUT=5"
Environment="PFSENSE_RETRIES=3"
EOF

# Aplicar cambios
systemctl daemon-reload
systemctl restart wazuh-manager
```

> **Seguridad:** El archivo `override.conf` debe ser propiedad de root con permisos 600:
> ```bash
> chmod 600 /etc/systemd/system/wazuh-manager.service.d/override.conf
> ```

---

## 3. Registrar el comando en ossec.conf

Añade el siguiente bloque dentro de `<ossec_config>` en `/var/ossec/etc/ossec.conf`:

```xml
<!-- Comando: DNS Sinkhole vía pfSense API REST -->
<command>
  <n>domain_sinkhole</n>
  <executable>pfsense_dns_sinkhole.py</executable>
  <timeout_allowed>yes</timeout_allowed>
</command>

<!-- Active Response: ejecuta en el propio Manager, no en agentes -->
<active-response>
  <command>domain_sinkhole</command>
  <location>server</location>
  <rules_id>100200</rules_id>
  <timeout>3600</timeout>
</active-response>
```

| Parámetro | Valor | Descripción |
|-----------|-------|-------------|
| `location` | `server` | Ejecuta el script en el Wazuh Manager, no en agentes |
| `rules_id` | `100200` | ID de la regla que dispara el sinkhole (ajustar al tuyo) |
| `timeout` | `3600` | Segundos antes de que Wazuh envíe el comando `delete` para revertir |

---

## 4. Configurar las reglas de detección

Crea o edita `/var/ossec/etc/rules/local_rules.xml`. Ver el archivo `local_rules.xml` de esta carpeta para ejemplos completos.

### Estructura del JSON que llega al script

El script extrae el dominio del campo `value` dentro del alert. El JSON que Wazuh envía al active-response tiene esta estructura:

```json
{
  "command": "add",
  "parameters": {
    "alert": {
      "action": "sinkhole",
      "value": "www.dominio-malicioso.com"
    }
  }
}
```

---

## 5. Verificar el funcionamiento

### Prueba manual del script

Simula exactamente el JSON que envía Wazuh:

```bash
export PFSENSE_API_KEY="tu_key_aqui"
export PFSENSE_API_URL="https://192.168.4.1:8444/api/v2/services/dns_resolver/host_override"

echo '{"command":"add","arguments":[],"parameters":{"alert":{"action":"sinkhole","value":"www.test-malicioso.com"}}}' \
  | sudo -E python3 /var/ossec/active-response/bin/pfsense_dns_sinkhole.py
```

### Revisar el log de active-response

```bash
tail -f /var/ossec/logs/active-responses.log
```

Salida esperada tras una ejecución exitosa:

```json
{"timestamp": "2026/04/10 10:00:01", "active_response": "domain_sinkhole_api", "message": {"status": "Started"}}
{"timestamp": "2026/04/10 10:00:01", "active_response": "domain_sinkhole_api", "message": "Sinkhole aplicado: www.test-malicioso.com -> 127.0.0.1"}
{"timestamp": "2026/04/10 10:00:01", "active_response": "domain_sinkhole_api", "message": "Ended"}
```

### Verificar en pfSense

```bash
# Desde pfSense via SSH
grep -A5 "Wazuh Active Response" /cf/conf/config.xml
```

---

## 6. Solución de problemas

| Síntoma | Causa probable | Solución |
|---------|---------------|----------|
| Log vacío tras disparo de regla | `location` incorrecto en ossec.conf | Cambiar a `server` |
| `PFSENSE_API_KEY no definida` | Variable de entorno no cargada | Verificar override de systemd y reiniciar wazuh-manager |
| `HTTP 401` en el log | API Key incorrecta o expirada | Regenerar key en pfSense → System → API |
| `HTTP 403` | Key sin permisos suficientes | Revisar permisos del usuario API en pfSense |
| `Timeout` | pfSense no accesible desde el Manager | Verificar firewall y ruta de red entre ambos |
| Script no ejecuta | Permisos incorrectos | `chmod 750` y `chown root:wazuh` |
