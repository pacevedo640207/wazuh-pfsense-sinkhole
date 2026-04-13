# Wazuh → pfSense DNS Sinkhole + pfBlockerNG

Integración automatizada de DNS sinkhole entre **Wazuh Active Response** y **pfSense**, con bloqueo persistente mediante **pfBlockerNG DNSBL**.

Cuando Wazuh detecta un dominio malicioso, lo redirige inmediatamente a `127.0.0.1` a través de un host override en pfSense. Un cron horario promueve esos overrides a un feed DNSBL de pfBlockerNG para bloqueo persistente y limpia los overrides temporales.

---

## Arquitectura

```
Evento de red detectado
        │
        ▼
┌─────────────────┐
│  Wazuh Manager  │  Regla dispara active-response
│                 │──────────────────────────────────┐
└─────────────────┘                                  │
                                                     ▼
                                       ┌─────────────────────────┐
                                       │  pfsense_dns_sinkhole.py│
                                       │  (ejecuta en el manager)│
                                       └────────────┬────────────┘
                                                    │ API REST
                                                    ▼
                                       ┌─────────────────────────┐
                                       │  pfSense API v2         │
                                       │  Host override temporal  │
                                       │  dominio → 127.0.0.1    │
                                       └────────────┬────────────┘
                                                    │ cron horario
                                                    ▼
                                       ┌─────────────────────────┐
                                       │  wazuh_pfblockerng_cron │
                                       │  pre → feed → post      │
                                       └────────────┬────────────┘
                                                    │
                                         ┌──────────┴──────────┐
                                         ▼                     ▼
                              ┌──────────────────┐  ┌──────────────────┐
                              │  pfBlockerNG     │  │  Host overrides  │
                              │  Feed DNSBL      │  │  limpiados       │
                              │  (persistente)   │  │  (eran temporales│
                              └──────────────────┘  └──────────────────┘
```

## Flujo completo

| Paso | Componente | Acción |
|------|-----------|--------|
| 1 | Wazuh | Detecta dominio malicioso, dispara active-response |
| 2 | `pfsense_dns_sinkhole.py` | Llama a la API REST de pfSense y crea host override temporal |
| 3 | Unbound / pfSense | El dominio resuelve a `127.0.0.1` de forma inmediata |
| 4 | Cron (cada hora) | Ejecuta `wazuh_pfblockerng_cron.sh` |
| 5 | `pre_process.sh` | Lee `config.xml` y acumula FQDNs en el feed DNSBL |
| 6 | pfBlockerNG | Carga el feed y aplica bloqueo persistente |
| 7 | `post_process.sh` | Elimina host overrides ya cubiertos por el feed |

---

## Estructura del repositorio

```
wazuh-pfsense-sinkhole/
├── README.md                        ← Este archivo
├── wazuh/
│   ├── README.md                    ← Instalación y configuración en Wazuh
│   ├── ossec.conf.snippet.xml       ← Fragmento de configuración active-response
│   ├── local_rules.xml              ← Ejemplos de reglas de detección
│   └── pfsense_dns_sinkhole.py      ← Script de active-response (ejecuta en manager)
├── pfsense/
│   ├── README.md                    ← Instalación API REST y pfBlockerNG
│   └── pfblockerng_dnsbl_group.md   ← Configuración del grupo DNSBL
└── scripts/
    ├── README.md                    ← Despliegue y uso de los scripts
    ├── pfblockerng_pre_process.sh   ← Genera y acumula el feed DNSBL
    ├── pfblockerng_post_process.sh  ← Limpia host overrides ya en el feed
    └── wazuh_pfblockerng_cron.sh    ← Orquestador principal (cron horario)
```

---

## Requisitos

### Wazuh Manager
- Wazuh Manager 4.x o superior
- Python 3.6+
- Librería `requests` — `pip install requests`
- Acceso de red al puerto de la API de pfSense (por defecto: 8444)

### pfSense
- pfSense 2.7+ o pfSense Plus
- Paquete **pfSense-pkg-API** instalado y configurado
- Paquete **pfBlockerNG-devel** instalado
- `xmllint` disponible (incluido en pfSense base)
- `php` disponible (incluido en pfSense base)

---

## Inicio rápido

```bash
# 1. Clonar el repositorio
git clone https://github.com/tuusuario/wazuh-pfsense-sinkhole.git

# 2. Seguir la guía de Wazuh
# Ver wazuh/README.md

# 3. Seguir la guía de pfSense
# Ver pfsense/README.md

# 4. Desplegar los scripts en pfSense
# Ver scripts/README.md
```

---

## Variables de entorno requeridas

Deben estar disponibles para el proceso del Wazuh Manager:

| Variable | Descripción | Ejemplo |
|----------|-------------|---------|
| `PFSENSE_API_URL` | URL completa al endpoint de host override | `https://192.168.4.1:8444/api/v2/services/dns_resolver/host_override` |
| `PFSENSE_API_KEY` | API Key generada en pfSense | *(definir via systemd — nunca hardcodear)* |
| `PFSENSE_SINKHOLE_IP` | IP a la que redirigir los dominios bloqueados | `127.0.0.1` |
| `PFSENSE_CA_CERT` | Ruta al certificado CA (opcional) | `/etc/ssl/certs/pfsense-ca.pem` |
| `PFSENSE_TIMEOUT` | Timeout HTTP en segundos (defecto: 5) | `5` |
| `PFSENSE_RETRIES` | Reintentos ante fallos de red (defecto: 3) | `3` |

---

## Licencia

MIT — libre para uso personal y comercial con atribución.
