#!/usr/bin/python3
# Active Response para Wazuh Manager -> Sinkhole DNS en pfSense vía API REST
# Ubicación: /var/ossec/active-response/bin/pfsense_dns_sinkhole.py

import datetime
import json
import os
import re
import sys
import requests
from requests.exceptions import RequestException

LOG_FILE = "/var/ossec/logs/active-responses.log"

# ==========================
# Variables de entorno
# ==========================
PFSENSE_API_URL = os.environ.get(
    "PFSENSE_API_URL",
    "https://192.168.4.1:8444/api/v2/services/dns_resolver/host_override"
)
# Sin fallback hardcodeado — si no está definida, el script aborta limpiamente
API_KEY     = os.environ.get("PFSENSE_API_KEY")
SINKHOLE_IP = os.environ.get("PFSENSE_SINKHOLE_IP", "127.0.0.1")
CA_CERT     = os.environ.get("PFSENSE_CA_CERT")
TIMEOUT     = int(os.environ.get("PFSENSE_TIMEOUT", "5"))
MAX_RETRIES = int(os.environ.get("PFSENSE_RETRIES", "3"))

COMMANDS   = {"add": 0, "delete": 1, "continue": 2, "abort": 3}
OS_SUCCESS = 0
OS_INVALID = -1


# ============================================================
# LOGGING
# ============================================================

def write_debug_file(ar_name, msg):
    """Escribe una entrada de log en formato JSON estructurado."""
    with open(LOG_FILE, mode="a") as log_file:
        log_entry = {
            "timestamp": datetime.datetime.now().strftime("%Y/%m/%d %H:%M:%S"),
            "active_response": "domain_sinkhole_api",
            "message": (
                json.loads(msg)
                if isinstance(msg, str) and msg.strip().startswith("{")
                else msg
            ),
        }
        log_file.write(json.dumps(log_entry) + "\n")


# ============================================================
# PROTOCOLO WAZUH
# ============================================================

class Message:
    def __init__(self, alert="", command=0):
        self.alert = alert
        self.command = command


def setup_and_check_message(argv):
    """Lee y valida el mensaje de stdin enviado por Wazuh."""
    input_str = next(sys.stdin, "")
    write_debug_file(argv[0], input_str)
    try:
        data = json.loads(input_str)
    except ValueError:
        write_debug_file(argv[0], "Decoding JSON has failed, invalid input format")
        return Message(command=OS_INVALID)
    command = COMMANDS.get(data.get("command"), OS_INVALID)
    if command == OS_INVALID:
        write_debug_file(argv[0], f"Comando no válido: {data.get('command')}")
    return Message(alert=data, command=command)


def extract_alert_info(msg, argv):
    """
    Extrae acción y dominio del mensaje de Wazuh.

    Formato estándar que llega desde el manager:
      {
        "command": "add",
        "parameters": {
          "alert": {
            "action": "sinkhole",
            "value": "www.globalchat.site"
          }
        }
      }
    """
    try:
        alert  = msg.alert["parameters"]["alert"]
        action = alert.get("action", "sinkhole")
        domain = alert.get("value")
        if not domain:
            write_debug_file(argv[0], "No se especificó dominio en la alerta")
            sys.exit(OS_INVALID)
    except KeyError as e:
        write_debug_file(argv[0], f"Clave faltante en el mensaje: {e}")
        sys.exit(OS_INVALID)
    return action, domain


# ============================================================
# VALIDACIÓN DE DOMINIO
# ============================================================

def is_valid_domain(domain):
    """Valida FQDN. Acepta subdomains de un carácter y normaliza wildcards."""
    if not domain:
        return False
    domain = domain.rstrip(".").lstrip("*.")
    pattern = (
        r"^(?:[a-zA-Z0-9]"
        r"(?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+"
        r"[a-zA-Z]{2,}$"
    )
    return bool(re.match(pattern, domain))


def split_host_domain(fqdn):
    """
    Divide un FQDN en (host, dominio_base).
    Ejemplo: 'www.globalchat.site' -> ('www', 'globalchat.site')
    """
    parts = fqdn.split(".")
    if len(parts) < 2:
        return None, None
    return parts[0], ".".join(parts[1:])


# ============================================================
# CLIENTE REST PARA PFSENSE
# ============================================================

def api_request(method, url, payload=None):
    """
    Cliente HTTP genérico con reintentos.

    Retorna (True, body) en éxito, (False, mensaje_error) en fallo.
    Solo reintenta en errores de red/timeout, no en errores HTTP 4xx/5xx.
    """
    if not API_KEY:
        return False, "PFSENSE_API_KEY no definida en el entorno"

    headers = {
        "Content-Type": "application/json",
        "X-API-KEY": API_KEY,
    }
    verify = CA_CERT if CA_CERT else False

    for attempt in range(1, MAX_RETRIES + 1):
        try:
            response = requests.request(
                method=method,
                url=url,
                headers=headers,
                json=payload,
                timeout=TIMEOUT,
                verify=verify,
            )
            if response.status_code in (200, 201, 204):
                return True, response.text
            # Error HTTP definitivo — no reintentar
            return False, f"HTTP {response.status_code}: {response.text}"
        except RequestException as e:
            if attempt == MAX_RETRIES:
                return False, f"Fallo tras {MAX_RETRIES} intentos: {e}"
            # Continúa al siguiente intento solo si es error de red


def get_host_override_id(host, domain):
    """
    Busca el ID de un host_override existente en pfSense.
    Necesario para construir la URL correcta al hacer DELETE.
    Retorna el ID (str) si existe, None si no.
    """
    ok, body = api_request("GET", PFSENSE_API_URL)
    if not ok:
        return None
    try:
        data = json.loads(body)
        for item in data.get("data", []):
            if item.get("host") == host and item.get("domain") == domain:
                return str(item.get("id"))
    except (json.JSONDecodeError, AttributeError):
        pass
    return None


def sinkhole_domain_api(domain):
    """
    Crea un host_override en pfSense para redirigir el dominio al sinkhole.
    Idempotente: si ya existe, omite la inserción.
    """
    host, base_domain = split_host_domain(domain)
    if not host or not base_domain:
        return f"Formato de dominio inválido: {domain}"

    # Verificar duplicado antes de insertar
    if get_host_override_id(host, base_domain):
        return f"Host override ya existe para {domain}, omitiendo"

    payload = {
        "enabled": True,
        "host": host,
        "domain": base_domain,
        "ip": [SINKHOLE_IP],
        "descr": "Added by Wazuh Active Response sinkhole",
        "apply": True,
    }
    ok, msg = api_request("POST", PFSENSE_API_URL, payload)
    if ok:
        return f"Sinkhole aplicado: {domain} -> {SINKHOLE_IP}"
    return f"Fallo al aplicar sinkhole en {domain}: {msg}"


def remove_sinkholed_domain_api(domain):
    """
    Elimina el host_override de pfSense buscando primero el ID real.
    Evita construir URLs con el FQDN, que no es lo que espera la API.
    """
    host, base_domain = split_host_domain(domain)
    if not host or not base_domain:
        return f"Formato de dominio inválido: {domain}"

    override_id = get_host_override_id(host, base_domain)
    if not override_id:
        return f"No existe host_override para {domain}, nada que eliminar"

    delete_url = f"{PFSENSE_API_URL}/{override_id}"
    ok, msg = api_request("DELETE", delete_url)
    if ok:
        return f"Sinkhole eliminado: {domain}"
    return f"Fallo al eliminar sinkhole de {domain}: {msg}"


# ============================================================
# MAIN
# ============================================================

def main(argv):
    write_debug_file(argv[0], {"status": "Started"})

    if not API_KEY:
        write_debug_file(argv[0], "ERROR: PFSENSE_API_KEY no definida en el entorno")
        sys.exit(OS_INVALID)

    msg = setup_and_check_message(argv)
    if msg.command < 0:
        sys.exit(OS_INVALID)

    if msg.command == COMMANDS["add"]:
        action, domain = extract_alert_info(msg, argv)

        domain = domain.rstrip(".")

        if not is_valid_domain(domain):
            write_debug_file(argv[0], {"status": "failed", "message": f"Dominio inválido: {domain}"})
            sys.exit(OS_INVALID)

        if action == "sinkhole":
            result = sinkhole_domain_api(domain)
            write_debug_file(argv[0], result)

        elif action == "remove_sinkhole":
            result = remove_sinkholed_domain_api(domain)
            write_debug_file(argv[0], result)

        else:
            write_debug_file(argv[0], f"Acción desconocida: {action}")

    elif msg.command == COMMANDS["delete"]:
        # Wazuh puede enviar "delete" para revertir un "add" previo
        action, domain = extract_alert_info(msg, argv)
        domain = domain.rstrip(".")
        result = remove_sinkholed_domain_api(domain)
        write_debug_file(argv[0], result)

    write_debug_file(argv[0], "Ended")
    sys.exit(OS_SUCCESS)


if __name__ == "__main__":
    main(sys.argv)
