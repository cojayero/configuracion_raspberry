#!/bin/bash

LOG_FILE="/home/pi/Documents/configuracion/troubleshooting_monitorizacion.log"
exec > >(tee -a $LOG_FILE) 2>&1

# Definir colores para la salida
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # Sin color

# Verificar estado de los servicios

# Verificar NGINX
echo -e "${YELLOW}[INFO] Verificando estado de NGINX...${NC}"
if systemctl is-active --quiet nginx; then
    echo -e "${GREEN}NGINX: Activo${NC}"
else
    echo -e "${RED}NGINX: Inactivo${NC}"
fi

# Verificar Docker
echo -e "${YELLOW}[INFO] Verificando estado de Docker...${NC}"
if systemctl is-active --quiet docker; then
    echo -e "${GREEN}Docker: Activo${NC}"
else
    echo -e "${RED}Docker: Inactivo${NC}"
fi

# Verificar contenedores Docker
echo -e "${YELLOW}[INFO] Verificando contenedores Docker...${NC}"
containers=("zabbix" "netbox" "grafana")
for container in "${containers[@]}"; do
    if sudo docker ps --filter "name=$container" --filter "status=running" | grep -q "$container"; then
        echo -e "${GREEN}$container: Activo${NC}"
    else
        echo -e "${RED}$container: Inactivo${NC}"
    fi
done

# Verificar accesibilidad interna y externa de los servicios
echo -e "${YELLOW}[INFO] Verificando accesibilidad interna y externa de los servicios...${NC}"
services=("zabbix" "netbox" "grafana")
ports=("8080" "8000" "3000")
paths=("/zabbix" "/netbox" "/grafana")
for i in "${!services[@]}"; do
    service="${services[$i]}"
    port="${ports[$i]}"
    path="${paths[$i]}"

    # Verificación interna
    echo -e "${YELLOW}[INFO] Verificando accesibilidad interna para $service en: http://localhost:$port${NC}"
    if curl -s --head "http://localhost:$port" | grep -q "200 OK"; then
        echo -e "${GREEN}$service: Internamente accesible en http://localhost:$port${NC}"
    else
        echo -e "${RED}$service: No accesible internamente en http://localhost:$port${NC}"
    fi

    # Verificación externa
    echo -e "${YELLOW}[INFO] Verificando accesibilidad externa para $service en: http://localhost$path${NC}"
    if curl -s --head "http://localhost$path" | grep -q "200 OK"; then
        echo -e "${GREEN}$service: Externamente accesible en http://localhost$path${NC}"
    else
        echo -e "${RED}$service: No accesible externamente en http://localhost$path${NC}"
    fi
done

# Resumen final
echo -e "${YELLOW}[INFO] Verificación completada.${NC}"