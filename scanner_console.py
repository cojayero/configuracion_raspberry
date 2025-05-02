#!/usr/bin/env python3

import scapy.all as scapy
import requests
import nmap
import csv
import json
import os
import socket
import sys
import time
from datetime import datetime, timedelta
import sqlite3
from tabulate import tabulate
import argparse
from socket import AF_INET, SOCK_DGRAM, socket as Socket
from ssdpy import SSDPClient
import dns.resolver
import dns.name
import dns.rdatatype
from onvif import ONVIFCamera
from zeep.exceptions import Fault
import aiohttp
import webbrowser
import asyncio

# Configuración inicial
KNOWN_DEVICES_FILE = "known_devices.txt"
ONVIF_CREDENTIALS_FILE = "onvif_credentials.txt"
OUTPUT_DIR = "scan_results"
MAC_CACHE_DB = "mac_cache.db"
COMMON_PORTS = "22,80,443,445,3389,137,138,554,8080,8000"  # Incluye puertos ONVIF
MDNS_PORT = 5353  # Puerto para mDNS
ONVIF_PORTS = [80, 8000]  # Puertos comunes para ONVIF
CACHE_EXPIRY_DAYS = 30  # Días antes de actualizar la caché
ONVIF_TIMEOUT = 2  # Timeout en segundos para ONVIF

def init_mac_cache():
    """Inicializa la base de datos SQLite para la caché de MAC."""
    conn = sqlite3.connect(MAC_CACHE_DB)
    cursor = conn.cursor()
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS mac_vendors (
            mac_prefix TEXT PRIMARY KEY,
            vendor TEXT NOT NULL,
            last_updated TIMESTAMP NOT NULL
        )
    """)
    conn.commit()
    conn.close()

def get_manufacturer(mac):
    """Obtiene el fabricante de una dirección MAC, usando caché SQLite."""
    # Normalizar MAC y obtener prefijo (primeros 8 caracteres)
    mac_prefix = mac.replace(":", "").upper()[:8]
    
    # Conectar a la base de datos
    conn = sqlite3.connect(MAC_CACHE_DB)
    cursor = conn.cursor()
    
    # Buscar en la caché
    expiry_date = datetime.now() - timedelta(days=CACHE_EXPIRY_DAYS)
    cursor.execute("""
        SELECT vendor, last_updated FROM mac_vendors
        WHERE mac_prefix = ? AND last_updated >= ?
    """, (mac_prefix, expiry_date))
    result = cursor.fetchone()
    
    if result:
        # Usar valor en caché
        vendor = result[0]
        conn.close()
        return vendor
    
    # No hay caché válida, consultar API
    try:
        response = requests.get(f"https://api.macvendors.com/{mac}", timeout=5)
        if response.status_code == 200 and response.text:
            vendor = response.text
        else:
            vendor = "Desconocido"
    except requests.RequestException:
        vendor = "Desconocido (Error en API)"
    
    # Guardar en la caché
    cursor.execute("""
        INSERT OR REPLACE INTO mac_vendors (mac_prefix, vendor, last_updated)
        VALUES (?, ?, ?)
    """, (mac_prefix, vendor, datetime.now()))
    conn.commit()
    conn.close()
    
    return vendor

def get_arguments():
    parser = argparse.ArgumentParser(description="Escanea la red local con soporte para dispositivos PLC y ONVIF (versión de consola con caché SQLite).")
    parser.add_argument("-i", "--interface", dest="interface", required=True,
                        help="Interfaz de red (ej. eth0, wlan0)")
    parser.add_argument("-r", "--range", dest="ip_range", required=True,
                        help="Rango de IP a escanear (ej. 192.168.1.0/24)")
    parser.add_argument("--fast", action="store_true",
                        help="Modo rápido: omite nmap y ONVIF para escaneos más rápidos")
    return parser.parse_args()

def get_hostname(ip):
    try:
        return socket.gethostbyaddr(ip)[0]
    except socket.herror:
        return "Desconocido"

def get_netbios_name(ip):
    try:
        sock = Socket(AF_INET, SOCK_DGRAM)
        sock.settimeout(2)
        nb_packet = b"\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x20CKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\x00\x00\x20\x00\x01"
        sock.sendto(nb_packet, (ip, 137))
        data, _ = sock.recvfrom(1024)
        name = data[57:75].decode('ascii').strip()
        sock.close()
        return name if name else "Desconocido"
    except:
        return "Desconocido"

def scan_ports_and_os(ip, fast_mode=False):
    if fast_mode:
        return "Omitido (modo rápido)", "Omitido (modo rápido)"
    try:
        nm = nmap.PortScanner()
        nm.scan(ip, arguments=f"-p {COMMON_PORTS} -O --open -T4")
        ports = []
        os_info = "Desconocido"
        
        for host in nm.all_hosts():
            for proto in nm[host].all_protocols():
                lport = nm[host][proto].keys()
                for port in lport:
                    ports.append(port)
            if "osmatch" in nm[host]:
                for osmatch in nm[host]["osmatch"]:
                    os_info = osmatch["name"]
                    break
        
        ports_str = ", ".join(map(str, sorted(ports))) if ports else "Ninguno"
        return ports_str, os_info
    except Exception as e:
        return f"Error ({str(e)})", "Desconocido"

def get_upnp_ssdp_info():
    try:
        client = SSDPClient()
        devices = client.m_search("ssdp:all")
        upnp_info = {}
        for device in devices:
            ip = device.get("address", "Desconocido")
            headers = device.get("headers", {})
            details = []
            if "server" in headers:
                details.append(f"Servidor: {headers['server']}")
            if "location" in headers:
                details.append(f"URL: {headers['location']}")
            if "st" in headers:
                details.append(f"Tipo: {headers['st']}")
            upnp_info[ip] = ", ".join(details) if details else "Ninguno"
        return upnp_info
    except Exception as e:
        print(f"Error en UPnP/SSDP: {str(e)}")
        return {}

def get_mdns_info(ip):
    try:
        resolver = dns.resolver.Resolver()
        resolver.timeout = 2
        resolver.lifetime = 2
        mdns_name = dns.name.from_text(f"{ip.replace('.', '-')}.local")
        response = resolver.resolve(mdns_name, dns.rdatatype.PTR)
        for rdata in response:
            return str(rdata).split()[0]
        return "Desconocido"
    except (dns.resolver.NXDOMAIN, dns.resolver.Timeout, dns.resolver.NoAnswer):
        return "Desconocido"
    except Exception as e:
        print(f"Error en mDNS: {str(e)}")
        return "Desconocido"

def load_onvif_credentials():
    credentials = []
    if os.path.exists(ONVIF_CREDENTIALS_FILE):
        with open(ONVIF_CREDENTIALS_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    user, password = line.split(":")
                    credentials.append((user.strip(), password.strip()))
    # Añadir credenciales predeterminadas si no hay archivo
    credentials.append(("", ""))  # Sin credenciales
    credentials.append(("admin", "admin"))  # Predeterminadas
    return credentials

async def get_onvif_info(ip, fast_mode=False):
    if fast_mode:
        return "Omitido (modo rápido)"
    try:
        credentials = load_onvif_credentials()
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=ONVIF_TIMEOUT)) as session:
            for user, password in credentials:
                for port in ONVIF_PORTS:
                    try:
                        camera = ONVIFCamera(ip, port, user, password, wsdl='/usr/share/wsdl/onvif/wsdl/devicemgmt.wsdl')
                        camera.session = session
                        device_info = await camera.devicemgmt.GetDeviceInformation()
                        services = await camera.devicemgmt.GetServices(False)
                        profiles = []
                        for service in services:
                            if 'Profile' in service['Namespace']:
                                profiles.append(service['Namespace'].split(':')[-1])
                        return ", ".join(profiles) if profiles else "Soportado (sin perfiles específicos)"
                    except (Fault, socket.timeout, ConnectionError, aiohttp.ClientError):
                        continue
            return "No soportado"
    except Exception as e:
        return f"No soportado ({str(e)})"

def passive_scan(interface, timeout=10):
    devices = {}
    def packet_handler(packet):
        if packet.haslayer(scapy.IP) and packet.haslayer(scapy.Ether):
            ip = packet[scapy.IP].src
            mac = packet[scapy.Ether].src
            devices[ip] = mac
    try:
        scapy.sniff(iface=interface, prn=packet_handler, timeout=timeout, store=0)
    except Exception as e:
        print(f"Error en escaneo pasivo: {str(e)}")
        return {}
    return devices

def load_known_devices():
    known_devices = {}
    if os.path.exists(KNOWN_DEVICES_FILE):
        with open(KNOWN_DEVICES_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    mac, *comment = line.split("#")
                    known_devices[mac.strip().lower()] = comment[0].strip() if comment else "Dispositivo conocido"
    return known_devices

def check_intruders(devices):
    known_devices = load_known_devices()
    intruders = []
    for device in devices:
        mac = device["MAC"].lower()
        if mac not in known_devices:
            intruders.append(device)
    return intruders

async def scan_network(ip_range, interface, fast_mode=False):
    start_time = datetime.now()
    print(f"[*] Escaneando red {ip_range} en interfaz {interface} (modo rápido: {fast_mode})...")

    # Escaneo pasivo
    print("[*] Realizando escaneo pasivo...")
    passive_devices = passive_scan(interface, timeout=10)
    
    # Escaneo ARP
    print("[*] Realizando escaneo ARP...")
    scapy.conf.iface = interface
    arp_request = scapy.ARP(pdst=ip_range)
    broadcast = scapy.Ether(dst="ff:ff:ff:ff:ff:ff")
    arp_request_broadcast = broadcast / arp_request
    answered_list = scapy.srp(arp_request_broadcast, timeout=5, retry=2, verbose=False)[0]
    
    # Escaneo UPnP/SSDP
    print("[*] Escaneando UPnP/SSDP...")
    upnp_info = get_upnp_ssdp_info()
    
    devices = []
    seen_ips = set()
    
    # Encabezados para la tabla
    headers = ["IP", "MAC", "Fabricante", "Nombre de Host", "Nombre NetBIOS", "Nombre mDNS", "Puertos Abiertos", "Sistema Operativo", "Detalles UPnP", "Soporte ONVIF"]
    
    # Procesar dispositivos ARP
    for element in answered_list:
        ip = element[1].psrc
        mac = element[1].hwsrc
        if ip not in seen_ips:
            seen_ips.add(ip)
            print(f"[*] Procesando dispositivo: IP={ip}, MAC={mac}")
            manufacturer = get_manufacturer(mac)
            hostname = get_hostname(ip)
            netbios_name = get_netbios_name(ip)
            mdns_name = get_mdns_info(ip)
            ports, os_info = scan_ports_and_os(ip, fast_mode)
            upnp_details = upnp_info.get(ip, "Ninguno")
            onvif_info = await get_onvif_info(ip, fast_mode)
            
            device = {
                "IP": ip,
                "MAC": mac,
                "Fabricante": manufacturer,
                "Nombre de Host": hostname,
                "Nombre NetBIOS": netbios_name,
                "Nombre mDNS": mdns_name,
                "Puertos Abiertos": ports,
                "Sistema Operativo": os_info,
                "Detalles UPnP": upnp_details,
                "Soporte ONVIF": onvif_info
            }
            devices.append(device)
            
            # Mostrar dispositivo en la consola
            print(tabulate([[
                device["IP"],
                device["MAC"],
                device["Fabricante"],
                device["Nombre de Host"],
                device["Nombre NetBIOS"],
                device["Nombre mDNS"],
                device["Puertos Abiertos"],
                device["Sistema Operativo"],
                device["Detalles UPnP"],
                device["Soporte ONVIF"]
            ]], headers=headers, tablefmt="grid"))
    
    # Agregar dispositivos de escaneo pasivo
    for ip, mac in passive_devices.items():
        if ip not in seen_ips:
            seen_ips.add(ip)
            print(f"[*] Procesando dispositivo (pasivo): IP={ip}, MAC={mac}")
            manufacturer = get_manufacturer(mac)
            hostname = get_hostname(ip)
            netbios_name = get_netbios_name(ip)
            mdns_name = get_mdns_info(ip)
            ports, os_info = scan_ports_and_os(ip, fast_mode)
            upnp_details = upnp_info.get(ip, "Ninguno")
            onvif_info = await get_onvif_info(ip, fast_mode)
            
            device = {
                "IP": ip,
                "MAC": mac,
                "Fabricante": manufacturer,
                "Nombre de Host": hostname,
                "Nombre NetBIOS": netbios_name,
                "Nombre mDNS": mdns_name,
                "Puertos Abiertos": ports,
                "Sistema Operativo": os_info,
                "Detalles UPnP": upnp_details,
                "Soporte ONVIF": onvif_info
            }
            devices.append(device)
            
            # Mostrar dispositivo en la consola
            print(tabulate([[
                device["IP"],
                device["MAC"],
                device["Fabricante"],
                device["Nombre de Host"],
                device["Nombre NetBIOS"],
                device["Nombre mDNS"],
                device["Puertos Abiertos"],
                device["Sistema Operativo"],
                device["Detalles UPnP"],
                device["Soporte ONVIF"]
            ]], headers=headers, tablefmt="grid"))
    
    end_time = datetime.now()
    print(f"[*] Escaneo completado en {end_time - start_time}")
    
    return devices

def save_results(devices):
    if not os.path.exists(OUTPUT_DIR):
        os.makedirs(OUTPUT_DIR)
    
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    fields = ["IP", "MAC", "Fabricante", "Nombre de Host", "Nombre NetBIOS", "Nombre mDNS", "Puertos Abiertos", "Sistema Operativo", "Detalles UPnP", "Soporte ONVIF"]
    
    # Guardar en CSV
    csv_file = os.path.join(OUTPUT_DIR, f"scan_{timestamp}.csv")
    with open(csv_file, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for device in devices:
            writer.writerow(device)
    
    # Guardar en JSON
    json_file = os.path.join(OUTPUT_DIR, f"scan_{timestamp}.json")
    with open(json_file, "w") as f:
        json.dump(devices, f, indent=4, ensure_ascii=False)
    
    # Guardar en HTML
    html_file = os.path.join(OUTPUT_DIR, f"scan_{timestamp}.html")
    with open(html_file, "w") as f:
        f.write("<html><head><title>Informe de Escaneo de Red</title>")
        f.write("<style>table {border-collapse: collapse; width: 100%;} th, td {border: 1px solid black; padding: 8px; text-align: left;} th {background-color: #f2f2f2;}</style>")
        f.write("</head><body><h2>Informe de Escaneo de Red</h2>")
        f.write(f"<p>Fecha: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>")
        f.write("<table><tr>")
        for field in fields:
            f.write(f"<th>{field}</th>")
        f.write("</tr>")
        for device in devices:
            f.write("<tr>")
            for field in fields:
                f.write(f"<td>{device[field]}</td>")
            f.write("</tr>")
        f.write("</table></body></html>")
    
    return csv_file, json_file, html_file

async def main():
    if os.geteuid() != 0:
        print("[!] Este script debe ejecutarse con permisos de root (sudo).")
        sys.exit(1)
    
    # Inicializar la caché de MAC
    init_mac_cache()
    
    args = get_arguments()
    try:
        devices = await scan_network(args.ip_range, args.interface, args.fast)
        
        # Guardar resultados
        csv_file, json_file, html_file = save_results(devices)
        print(f"[*] Resultados guardados en {csv_file}, {json_file}, {html_file}")
        
        # Verificar intrusos
        intruders = check_intruders(devices)
        if intruders:
            print("\n[!] ¡Dispositivos desconocidos detectados!")
            for intruder in intruders:
                print(f"  IP: {intruder['IP']}, MAC: {intruder['MAC']}, Fabricante: {intruder['Fabricante']}")
        else:
            print("[*] No se detectaron intrusos.")
        
        # Abrir informe HTML (si hay un navegador disponible)
        if os.name == "posix" and os.environ.get("DISPLAY"):
            webbrowser.open(f"file://{os.path.abspath(html_file)}")
    
    except Exception as e:
        print(f"[!] Error durante el escaneo: {str(e)}")
        sys.exit(1)

if __name__ == "__main__":
    asyncio.run(main())
