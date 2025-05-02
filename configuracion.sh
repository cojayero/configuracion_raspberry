#!/bin/bash

LOG_FILE="/home/pi/Documents/configuracion/instalacion.log"
exec > >(tee -a $LOG_FILE) 2>&1

# Colores para los mensajes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}[INFO] Actualizando el sistema...${NC}"
sudo apt-get update
sudo apt-get upgrade -y

echo -e "${GREEN}[INFO] Instalando NGINX...${NC}"
sudo apt-get install -y nginx
sudo systemctl enable nginx

echo -e "${GREEN}[INFO] Instalando Docker...${NC}"
# Desinstalar versiones antiguas si existen
sudo apt-get remove -y docker docker-engine docker-ce docker.io containerd runc

# Instalar docker.io y docker-compose
sudo apt-get update
sudo apt-get install -y docker.io docker-compose

echo -e "${GREEN}[INFO] Configurando grupo docker...${NC}"
sudo groupadd docker || true
sudo usermod -aG docker $USER

echo -e "${GREEN}[INFO] Habilitando el servicio Docker...${NC}"
sudo systemctl enable --now docker

echo -e "${GREEN}[INFO] Creando archivo docker-compose.yml...${NC}"
cat > docker-compose.yml << 'EOL'
version: '3.8'

services:
  zabbix-mysql:
    image: arm64v8/mysql:8.0
    container_name: zabbix_mysql
    command: 
      - mysqld
      - --character-set-server=utf8
      - --collation-server=utf8_bin
      - --log-bin-trust-function-creators=1
    environment:
      MYSQL_DATABASE: zabbix
      MYSQL_USER: zabbix
      MYSQL_PASSWORD: zabbix_pwd
      MYSQL_ROOT_PASSWORD: root_pwd
    volumes:
      - zabbix-mysql-data:/var/lib/mysql
    restart: always
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p$$MYSQL_ROOT_PASSWORD"]
      interval: 10s
      timeout: 5s
      retries: 3
    networks:
      - app_network

  zabbix-server:
    image: zabbix/zabbix-server-mysql:alpine-6.4-latest
    container_name: zabbix
    ports:
      - "10051:10051"
    environment:
      DB_SERVER_HOST: zabbix_mysql
      MYSQL_DATABASE: zabbix
      MYSQL_USER: zabbix
      MYSQL_PASSWORD: zabbix_pwd
      ZBX_DBTLSCONNECT: "required"
    depends_on:
      zabbix-mysql:
        condition: service_healthy
    restart: always
    networks:
      - app_network

  zabbix-web:
    image: zabbix/zabbix-web-nginx-mysql:alpine-6.4-latest
    container_name: zabbix-web
    ports:
      - "8080:8080"
    environment:
      DB_SERVER_HOST: zabbix_mysql
      MYSQL_DATABASE: zabbix
      MYSQL_USER: zabbix
      MYSQL_PASSWORD: zabbix_pwd
      ZBX_SERVER_HOST: zabbix-server
      PHP_TZ: UTC
    depends_on:
      - zabbix-server
    restart: always
    networks:
      - app_network

  postgres:
    image: postgres:15-alpine
    container_name: postgres
    environment:
      POSTGRES_DB: netbox
      POSTGRES_USER: netbox
      POSTGRES_PASSWORD: netbox_pwd
      POSTGRES_HOST_AUTH_METHOD: md5
      POSTGRES_INITDB_ARGS: "--auth-host=md5"
    volumes:
      - netbox-postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U netbox -d netbox"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 30s
    restart: always
    networks:
      - app_network

  redis:
    image: redis:7-alpine
    container_name: netbox_redis
    command: --appendonly yes
    volumes:
      - netbox-redis-data:/data
    restart: always
    networks:
      - app_network

  netbox:
    image: netboxcommunity/netbox:latest
    container_name: netbox
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
    ports:
      - "8000:8080"
    environment:
      DB_NAME: netbox
      DB_USER: netbox
      DB_PASSWORD: netbox_pwd
      DB_HOST: postgres
      DB_PORT: 5432
      REDIS_HOST: redis
      REDIS_PORT: 6379
      REDIS_DB: 0
      REDIS_PASSWORD: ""
      REDIS_SSL: "false"
      SUPERUSER_NAME: admin
      SUPERUSER_EMAIL: admin@example.com
      SUPERUSER_PASSWORD: admin
      ALLOWED_HOSTS: "*"
      SECRET_KEY: "BHgBj1ZEzgEmU-lhbz4Duaodjfgarfdz8L0q4jQEkbQZYr36J9VKD1o5kEMefO7qR2Z3IwiUMUJ4heHG"
      SKIP_STARTUP_SCRIPTS: "false"
      SKIP_SUPERUSER: "false"
      DB_WAIT_DEBUG: "true"
      DB_WAIT_TIME: 60
      DJANGO_DEBUG: "true"
      PYTHONUNBUFFERED: 1
      LOG_LEVEL: DEBUG
    volumes:
      - netbox-media-files:/opt/netbox/netbox/media
    restart: always
    networks:
      - app_network

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    volumes:
      - grafana-data:/var/lib/grafana
    restart: always
    networks:
      - app_network

networks:
  app_network:
    driver: bridge

volumes:
  zabbix-mysql-data:
  netbox-postgres-data:
  netbox-redis-data:
  netbox-media-files:
  grafana-data:
EOL

echo -e "${GREEN}[INFO] Configurando NGINX como proxy inverso...${NC}"
sudo mkdir -p /home/pi/Documents/configuracion/configuraciones
sudo cp /etc/nginx/sites-available/default /home/pi/Documents/configuracion/configuraciones/nginx_default_back.conf

# Crear nueva configuración de NGINX
sudo cat > /home/pi/Documents/configuracion/configuraciones/nginx_default.conf << 'EOL'
server {
    listen 80;
    server_name _;

    location /zabbix/ {
        proxy_pass http://localhost:8080/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /netbox/ {
        proxy_pass http://localhost:8000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /grafana/ {
        proxy_pass http://localhost:3000/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOL

# Aplicar configuración de NGINX
sudo cp /home/pi/Documents/configuracion/configuraciones/nginx_default.conf /etc/nginx/sites-available/default
sudo nginx -t && sudo systemctl restart nginx

echo -e "${GREEN}[INFO] Iniciando servicios Docker...${NC}"
# Asegurarse que Docker está corriendo
sudo systemctl start docker
sudo systemctl enable docker

# Crear red de Docker si no existe
docker network create app_network || true

# Detener y eliminar contenedores existentes si los hay
sudo docker-compose down -v

# Levantar servicios
sudo docker-compose up -d

# Esperar a que los servicios estén disponibles
echo -e "${YELLOW}[INFO] Esperando a que los servicios estén disponibles...${NC}"
sleep 30

echo -e "${GREEN}[INFO] Instalación y configuración completadas. Accede a los servicios en las siguientes URLs:${NC}"
echo -e "${GREEN}Zabbix: http://<IP_Raspberry>/zabbix${NC}"
echo -e "${GREEN}NetBox: http://<IP_Raspberry>/netbox${NC}"
echo -e "   Usuario: admin"
echo -e "   Contraseña: admin"
echo -e "${GREEN}Grafana: http://<IP_Raspberry>/grafana${NC}"