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
from datetime import datetime
from tabulate import tabulate
import tkinter as tk
from tkinter import ttk, messagebox, scrolledtext
import threading
import argparse
import webbrowser
from socket import AF_INET, SOCK_DGRAM, socket as Socket
from ssdpy import SSDPClient
import dns.resolver
import dns.message
import dns.rdatatype
from onvif import ONVIFCamera
from zeep.exceptions import Fault
import socket

# Configuración inicial
KNOWN_DEVICES_FILE = "known_devices.txt"
ONVIF_CREDENTIALS_FILE = "onvif_credentials.txt"
OUTPUT_DIR = "scan_results"
COMMON_PORTS = "22,80,443,445,3389,137,138,554,8080,8000"  # Incluye puertos ONVIF
SCAN_INTERVAL = 300  # Intervalo de escaneo automático en segundos (5 minutos)
MDNS_PORT = 5353  # Puerto para mDNS
ONVIF_PORTS = [80, 8000]  # Puertos comunes para ONVIF

def get_arguments():
    parser = argparse.ArgumentParser(description="Escanea la red local con soporte para dispositivos PLC y ONVIF.")
    parser.add_argument("-i", "--interface", dest="interface", required=True,
                        help="Interfaz de red (ej. eth0, wlan0)")
    parser.add_argument("-r", "--range", dest="ip_range", required=True,
                        help="Rango de IP a escanear (ej. 192.168.1.0/24)")
    parser.add_argument("--fast", action="store_true",
                        help="Modo rápido: omite nmap y ONVIF para escaneos más rápidos")
    return parser.parse_args()

def get_manufacturer(mac):
    try:
        response = requests.get(f"https://api.macvendors.com/{mac}", timeout=5)
        if response.status_code == 200 and response.text:
            return response.text
        return "Desconocido"
    except requests.RequestException:
        return "Desconocido (Error en API)"

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
        devices = client.m_search("ssdp:all", timeout=5)
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
        query = dns.message.make_query(f"{ip.replace('.', '-')}.local", dns.rdatatype.PTR)
        response = resolver.query(query, "IN")
        for rdata in response.answer:
            return str(rdata).split()[0]
        return "Desconocido"
    except:
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

def get_onvif_info(ip, fast_mode=False):
    if fast_mode:
        return "Omitido (modo rápido)"
    try:
        credentials = load_onvif_credentials()
        for user, password in credentials:
            for port in ONVIF_PORTS:
                try:
                    camera = ONVIFCamera(ip, port, user, password, timeout=2)
                    device_info = camera.devicemgmt.GetDeviceInformation()
                    services = camera.devicemgmt.GetServices(False)
                    profiles = []
                    for service in services:
                        if 'Profile' in service['Namespace']:
                            profiles.append(service['Namespace'].split(':')[-1])
                    return ", ".join(profiles) if profiles else "Soportado (sin perfiles específicos)"
                except (Fault, socket.timeout, ConnectionError):
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

def scan_network(ip_range, interface, output_widget=None, fast_mode=False):
    start_time = datetime.now()
    if output_widget:
        output_widget.insert(tk.END, f"[*] Escaneando red {ip_range} en interfaz {interface} (modo rápido: {fast_mode})...\n")
        output_widget.see(tk.END)
    
    # Escaneo pasivo
    if output_widget:
        output_widget.insert(tk.END, "[*] Realizando escaneo pasivo...\n")
    passive_devices = passive_scan(interface, timeout=10)
    
    # Escaneo ARP
    if output_widget:
        output_widget.insert(tk.END, "[*] Realizando escaneo ARP...\n")
    scapy.conf.iface = interface
    arp_request = scapy.ARP(pdst=ip_range)
    broadcast = scapy.Ether(dst="ff:ff:ff:ff:ff:ff")
    arp_request_broadcast = broadcast / arp_request
    answered_list = scapy.srp(arp_request_broadcast, timeout=5, retry=2, verbose=False)[0]
    
    # Escaneo UPnP/SSDP
    if output_widget:
        output_widget.insert(tk.END, "[*] Escaneando UPnP/SSDP...\n")
    upnp_info = get_upnp_ssdp_info()
    
    devices = []
    seen_ips = set()
    
    # Procesar dispositivos ARP
    for element in answered_list:
        ip = element[1].psrc
        mac = element[1].hwsrc
        if ip not in seen_ips:
            seen_ips.add(ip)
            manufacturer = get_manufacturer(mac)
            hostname = get_hostname(ip)
            netbios_name = get_netbios_name(ip)
            mdns_name = get_mdns_info(ip)
            ports, os_info = scan_ports_and_os(ip, fast_mode)
            upnp_details = upnp_info.get(ip, "Ninguno")
            onvif_info = get_onvif_info(ip, fast_mode)
            
            devices.append({
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
            })
    
    # Agregar dispositivos de escaneo pasivo
    for ip, mac in passive_devices.items():
        if ip not in seen_ips:
            seen_ips.add(ip)
            manufacturer = get_manufacturer(mac)
            hostname = get_hostname(ip)
            netbios_name = get_netbios_name(ip)
            mdns_name = get_mdns_info(ip)
            ports, os_info = scan_ports_and_os(ip, fast_mode)
            upnp_details = upnp_info.get(ip, "Ninguno")
            onvif_info = get_onvif_info(ip, fast_mode)
            
            devices.append({
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
            })
    
    end_time = datetime.now()
    if output_widget:
        output_widget.insert(tk.END, f"[*] Escaneo completado en {end_time - start_time}\n")
        output_widget.see(tk.END)
    
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

def display_table(devices, tree):
    for item in tree.get_children():
        tree.delete(item)
    
    for device in devices:
        tree.insert("", tk.END, values=(
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
        ))

class NetworkScannerApp:
    def __init__(self, root, interface, ip_range, fast_mode):
        self.root = root
        self.interface = interface
        self.ip_range = ip_range
        self.fast_mode = fast_mode
        self.root.title("Escáner de Red Avanzado (con soporte PLC y ONVIF)")
        self.root.geometry("1600x700")
        self.scanning = False
        self.auto_scan = False
        
        # Frame principal
        self.main_frame = ttk.Frame(self.root, padding="10")
        self.main_frame.grid(row=0, column=0, sticky=(tk.W, tk.E, tk.N, tk.S))
        
        # Botones
        self.scan_button = ttk.Button(self.main_frame, text="Iniciar Escaneo", command=self.start_scan)
        self.scan_button.grid(row=0, column=0, pady=5)
        
        self.auto_scan_var = tk.BooleanVar()
        self.auto_scan_check = ttk.Checkbutton(self.main_frame, text="Escaneo Continuo (cada 5 min)", variable=self.auto_scan_var, command=self.toggle_auto_scan)
        self.auto_scan_check.grid(row=0, column=1, pady=5)
        
        # Área de logs
        self.log_area = scrolledtext.ScrolledText(self.main_frame, height=10, width=100, wrap=tk.WORD)
        self.log_area.grid(row=1, column=0, columnspan=2, pady=5)
        
        # Tabla
        columns = ("IP", "MAC", "Fabricante", "Nombre de Host", "Nombre NetBIOS", "Nombre mDNS", "Puertos Abiertos", "Sistema Operativo", "Detalles UPnP", "Soporte ONVIF")
        self.tree = ttk.Treeview(self.main_frame, columns=columns, show="headings")
        for col in columns:
            self.tree.heading(col, text=col)
            self.tree.column(col, width=150)
        self.tree.grid(row=2, column=0, columnspan=2, pady=5)
        
        scrollbar = ttk.Scrollbar(self.main_frame, orient=tk.VERTICAL, command=self.tree.yview)
        self.tree.configure(yscrollcommand=scrollbar.set)
        scrollbar.grid(row=2, column=2, sticky=(tk.N, tk.S))
    
    def start_scan(self):
        if self.scanning:
            messagebox.showinfo("Info", "Un escaneo ya está en curso. Espere a que termine.")
            return
        
        self.scanning = True
        self.scan_button.config(state="disabled")
        self.log_area.insert(tk.END, f"[*] Iniciando nuevo escaneo...\n")
        self.log_area.see(tk.END)
        
        def scan_thread():
            try:
                devices = scan_network(self.ip_range, self.interface, self.log_area, self.fast_mode)
                display_table(devices, self.tree)
                
                csv_file, json_file, html_file = save_results(devices)
                self.log_area.insert(tk.END, f"[*] Resultados guardados en {csv_file}, {json_file}, {html_file}\n")
                
                intruders = check_intruders(devices)
                if intruders:
                    intruder_msg = "¡Dispositivos desconocidos detectados!\n"
                    for intruder in intruders:
                        intruder_msg += f"IP: {intruder['IP']}, MAC: {intruder['MAC']}, Fabricante: {intruder['Fabricante']}\n"
                    messagebox.showwarning("Alerta de Intrusos", intruder_msg)
                else:
                    self.log_area.insert(tk.END, "[*] No se detectaron intrusos.\n")
                
                webbrowser.open(f"file://{os.path.abspath(html_file)}")
            
            except Exception as e:
                messagebox.showerror("Error", f"Error durante el escaneo: {str(e)}")
            finally:
                self.scanning = False
                self.scan_button.config(state="normal")
                self.log_area.see(tk.END)
        
        threading.Thread(target=scan_thread, daemon=True).start()
    
    def toggle_auto_scan(self):
        self.auto_scan = self.auto_scan_var.get()
        if self.auto_scan:
            def auto_scan_thread():
                while self.auto_scan and not self.scanning:
                    self.start_scan()
                    time.sleep(SCAN_INTERVAL)
            threading.Thread(target=auto_scan_thread, daemon=True).start()

def main():
    if os.geteuid() != 0:
        print("[!] Este script debe ejecutarse con permisos de root (sudo).")
        sys.exit(1)
    
    args = get_arguments()
    root = tk.Tk()
    app = NetworkScannerApp(root, args.interface, args.ip_range, args.fast)
    root.mainloop()

if __name__ == "__main__":
    main()