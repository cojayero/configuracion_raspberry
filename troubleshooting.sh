#!/bin/bash

LOG_FILE="/home/pi/Documents/configuracion/troubleshooting.log"
exec > >(tee -a $LOG_FILE) 2>&1

# Definir colores para la salida
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # Sin color

# Información del sistema
echo -e "${GREEN}[INFO] Información del sistema:${NC}" > $LOG_FILE
uname -a >> $LOG_FILE
cat /etc/os-release >> $LOG_FILE

# Mostrar en pantalla el paso que se está ejecutando
echo -e "${YELLOW}[INFO] Ejecutando paso: Verificar conectividad a internet...${NC}"
# Verificar conectividad a internet
echo -e "${GREEN}[INFO] Verificando conectividad a internet...${NC}" >> $LOG_FILE
ping -c 4 google.com >> $LOG_FILE 2>&1 || {
    echo -e "${RED}[ERROR] No hay conectividad a internet. Verifica la conexión de red.${NC}" >> $LOG_FILE;
    exit 1;
}

# Mostrar en pantalla el paso que se está ejecutando
echo -e "${YELLOW}[INFO] Ejecutando paso: Verificar repositorios configurados...${NC}"
# Verificar repositorios configurados
echo -e "${GREEN}[INFO] Verificando repositorios configurados...${NC}" >> $LOG_FILE
cat /etc/apt/sources.list >> $LOG_FILE
ls /etc/apt/sources.list.d/ >> $LOG_FILE

# Mostrar en pantalla el paso que se está ejecutando
echo -e "${YELLOW}[INFO] Ejecutando paso: Verificar claves GPG...${NC}"
# Verificar claves GPG
echo -e "${GREEN}[INFO] Verificando claves GPG...${NC}" >> $LOG_FILE
ls -l /etc/apt/keyrings/ >> $LOG_FILE

# Mostrar en pantalla el paso que se está ejecutando
echo -e "${YELLOW}[INFO] Ejecutando paso: Verificar paquetes instalados...${NC}"
# Verificar paquetes instalados
echo -e "${GREEN}[INFO] Verificando paquetes instalados...${NC}" >> $LOG_FILE
dpkg -l | grep -E "docker|nginx|ca-certificates|curl|gnupg|lsb-release" >> $LOG_FILE

# Mostrar en pantalla el paso que se está ejecutando
echo -e "${YELLOW}[INFO] Ejecutando paso: Verificar estado de servicios...${NC}"
# Verificar estado de servicios
echo -e "${GREEN}[INFO] Verificando estado de servicios...${NC}" >> $LOG_FILE
systemctl status nginx >> $LOG_FILE 2>&1 || echo -e "${RED}[ERROR] NGINX no está corriendo.${NC}" >> $LOG_FILE
systemctl status docker >> $LOG_FILE 2>&1 || echo -e "${RED}[ERROR] Docker no está corriendo.${NC}" >> $LOG_FILE

# Mostrar en pantalla el paso que se está ejecutando
echo -e "${YELLOW}[INFO] Ejecutando paso: Verificar configuración de NGINX...${NC}"
# Verificar configuración de NGINX
echo -e "${GREEN}[INFO] Verificando configuración de NGINX...${NC}" >> $LOG_FILE
sudo nginx -t >> $LOG_FILE 2>&1 || echo -e "${RED}[ERROR] Error en la configuración de NGINX.${NC}" >> $LOG_FILE

# Verificar errores en la configuración de NGINX
echo -e "${YELLOW}[INFO] Verificando errores en la configuración de NGINX...${NC}" >> $LOG_FILE
sudo nginx -t 2>&1 | grep -i 'error' >> $LOG_FILE

# Mostrar en pantalla el paso que se está ejecutando
echo -e "${YELLOW}[INFO] Ejecutando paso: Verificar logs de Docker...${NC}"
# Verificar logs de Docker
echo -e "${GREEN}[INFO] Verificando logs de Docker...${NC}" >> $LOG_FILE
sudo journalctl -u docker --no-pager >> $LOG_FILE 2>&1 || echo -e "${RED}[ERROR] No se pudieron obtener los logs de Docker.${NC}" >> $LOG_FILE

# Mostrar en pantalla el paso que se está ejecutando
echo -e "${YELLOW}[INFO] Ejecutando paso: Verificar interfaces de red...${NC}"
# Verificar interfaces de red
echo -e "${GREEN}[INFO] Verificando interfaces de red...${NC}" >> $LOG_FILE
ip addr show >> $LOG_FILE

# Mostrar en pantalla el paso que se está ejecutando
echo -e "${YELLOW}[INFO] Ejecutando paso: Verificar redes de Docker...${NC}"
# Verificar redes de Docker
echo -e "${GREEN}[INFO] Verificando redes de Docker...${NC}" >> $LOG_FILE
sudo docker network ls >> $LOG_FILE
sudo docker network inspect bridge >> $LOG_FILE

# Verificar problemas en redes de Docker
echo -e "${YELLOW}[INFO] Verificando problemas en redes de Docker...${NC}" >> $LOG_FILE
sudo ls -l /var/lib/docker/network/files >> $LOG_FILE

# Mostrar en pantalla el paso que se está ejecutando
echo -e "${YELLOW}[INFO] Ejecutando paso: Verificar contenedores Docker...${NC}"
# Verificar contenedores Docker
echo -e "${GREEN}[INFO] Verificando contenedores Docker...${NC}" >> $LOG_FILE
sudo docker ps -a >> $LOG_FILE

# Verificar estado de contenedores Docker
echo -e "${YELLOW}[INFO] Verificando estado de contenedores Docker...${NC}" >> $LOG_FILE
sudo docker ps -a >> $LOG_FILE

# Mostrar en pantalla el paso que se está ejecutando
echo -e "${YELLOW}[INFO] Ejecutando paso: Verificar conectividad de los contenedores a la red personalizada...${NC}"
# Verificar conectividad de los contenedores a la red personalizada
echo -e "${GREEN}[INFO] Verificando conectividad de los contenedores a la red personalizada...${NC}" >> $LOG_FILE
sudo docker network inspect app_network >> $LOG_FILE
containers=("zabbix" "netbox" "grafana")
for container in "${containers[@]}"; do
    if sudo docker network inspect app_network | grep -q "$container"; then
        echo -e "${GREEN}$container: Conectado a la red app_network${NC}" >> $LOG_FILE
    else
        echo -e "${RED}$container: No conectado a la red app_network${NC}" >> $LOG_FILE
    fi
done

# Mostrar en pantalla el paso que se está ejecutando
echo -e "${YELLOW}[INFO] Ejecutando paso: Verificar conectividad HTTP de los servicios...${NC}"
# Verificar conectividad HTTP de los servicios
echo -e "${GREEN}[INFO] Verificando conectividad HTTP de los servicios...${NC}" >> $LOG_FILE
services=("zabbix" "netbox" "grafana")
ports=("/zabbix" "/netbox" "/grafana")
for i in "${!services[@]}"; do
    service="${services[$i]}"
    port="${ports[$i]}"
    if curl -s --head "http://localhost$port" | grep -q "200 OK"; then
        echo -e "${GREEN}$service: Accesible por HTTP${NC}" >> $LOG_FILE
    else
        echo -e "${RED}$service: No accesible por HTTP${NC}" >> $LOG_FILE
    fi
done

# Mostrar en pantalla el paso que se está ejecutando
echo -e "${YELLOW}[INFO] Ejecutando paso: Buscar histórico de salida a consola...${NC}"
# Buscar histórico de salida a consola
echo -e "${YELLOW}[INFO] Buscando histórico de salida a consola...${NC}" >> $LOG_FILE
sudo journalctl --no-pager >> $LOG_FILE

# Mostrar en pantalla el paso que se está ejecutando
echo -e "${YELLOW}[INFO] Ejecutando paso: Buscar ficheros de errores del sistema operativo...${NC}"
# Buscar ficheros de errores del sistema operativo
echo -e "${YELLOW}[INFO] Buscando ficheros de errores del sistema operativo...${NC}" >> $LOG_FILE
sudo dmesg >> $LOG_FILE

# Mostrar en pantalla el paso que se está ejecutando
echo -e "${YELLOW}[INFO] Ejecutando paso: Verificar reglas de iptables...${NC}"
# Verificar reglas de iptables
echo -e "${YELLOW}[INFO] Verificando reglas de iptables...${NC}" >> $LOG_FILE
sudo iptables -L -v -n >> $LOG_FILE

# Mostrar en pantalla el paso que se está ejecutando
echo -e "${YELLOW}[INFO] Ejecutando paso: Verificar logs del sistema para problemas de red...${NC}"
# Verificar logs del sistema para problemas de red
echo -e "${YELLOW}[INFO] Verificando logs del sistema para problemas de red...${NC}" >> $LOG_FILE
sudo dmesg | grep -i 'network' >> $LOG_FILE
sudo journalctl -u network --no-pager >> $LOG_FILE