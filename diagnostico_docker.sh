#!/bin/bash

LOG_FILE="/home/pi/Documents/configuracion/diagnostico_docker.log"
exec > >(tee -a $LOG_FILE) 2>&1

# Colores para los mensajes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}[$(date)] Iniciando diagnóstico de contenedores Docker${NC}"

echo -e "\n${GREEN}=== Estado de los contenedores ===${NC}"
docker ps -a

echo -e "\n${GREEN}=== Uso de recursos de los contenedores ===${NC}"
docker stats --no-stream

echo -e "\n${GREEN}=== Redes Docker ===${NC}"
docker network ls
docker network inspect app_network

echo -e "\n${GREEN}=== Logs de Zabbix MySQL ===${NC}"
docker logs zabbix_mysql --tail 100

echo -e "\n${GREEN}=== Logs de Zabbix Server ===${NC}"
docker logs zabbix --tail 100

echo -e "\n${GREEN}=== Logs de NetBox ===${NC}"
docker logs netbox --tail 100

echo -e "\n${GREEN}=== Comprobando resolución DNS entre contenedores ===${NC}"
docker exec zabbix ping -c 2 zabbix_mysql
docker exec zabbix ping -c 2 netbox

echo -e "\n${GREEN}=== Verificando conexión a la base de datos de Zabbix ===${NC}"
docker exec zabbix_mysql mysqladmin -uzabbix -pzabbix_pwd ping

echo -e "\n${GREEN}=== Verificando variables de entorno de Zabbix ===${NC}"
docker exec zabbix env | grep -E "MYSQL|DB"

echo -e "\n${GREEN}=== Verificando puertos en escucha ===${NC}"
docker exec zabbix netstat -tulpn
docker exec netbox netstat -tulpn

echo -e "\n${GREEN}=== Verificando espacio en disco ===${NC}"
df -h

echo -e "\n${GREEN}=== Verificando memoria disponible ===${NC}"
free -h

echo -e "${YELLOW}[$(date)] Diagnóstico completado. Revisa el archivo $LOG_FILE para más detalles${NC}"