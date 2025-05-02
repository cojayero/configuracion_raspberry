#!/bin/bash

# Definir colores para la salida
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # Sin color

LOG_FILE="/home/pi/Documents/configuracion/desinstalacion.log"
exec > >(tee -a $LOG_FILE) 2>&1

# Desinstalar NGINX
echo -e "${YELLOW}[INFO] Desinstalando NGINX...${NC}"
sudo systemctl stop nginx
sudo apt purge -y nginx nginx-common nginx-full
sudo apt autoremove -y

# Limpiar archivos de configuración de NGINX
echo -e "${YELLOW}[INFO] Limpiando archivos de configuración de NGINX...${NC}"
sudo rm -rf /etc/nginx
sudo rm -rf /var/log/nginx
sudo rm -rf /var/cache/nginx

# Desinstalar Docker
echo -e "${YELLOW}[INFO] Desinstalando Docker...${NC}"
sudo systemctl stop docker
sudo apt purge -y docker docker-engine docker.io containerd runc
echo -e "${YELLOW}[INFO] Eliminando dependencias de Docker...${NC}"
sudo apt autoremove -y

# Limpiar archivos de configuración de Docker
echo -e "${YELLOW}[INFO] Limpiando archivos de configuración de Docker...${NC}"
sudo rm -rf /var/lib/docker
sudo rm -rf /etc/docker
sudo rm -rf /var/lib/containerd
sudo rm -rf /var/run/docker.sock

# Limpiar redes y volúmenes de Docker
echo -e "${YELLOW}[INFO] Limpiando redes y volúmenes de Docker...${NC}"
sudo docker network prune -f
sudo docker volume prune -f

# Mensaje final
echo -e "${GREEN}[INFO] Desinstalación completada. Se han eliminado NGINX, Docker y sus configuraciones.${NC}"