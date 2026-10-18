#!/usr/bin/env python3
"""Windows-side port forwarder: 0.0.0.0:18080 -> WSL localhost:18080
Uses socat inside WSL to avoid sing-box TUN interfering with direct TCP to WSL IP.
Strategy: forward via WSL's own socat which connects to localhost:18080 inside WSL."""
import socket
import subprocess
import threading
import time
import sys

LISTEN_PORT = 18080

def handle_client(client_sock):
    """Handle a single client by piping through wsl.exe socat."""
    try:
        # Use wsl.exe to run socat inside WSL, connecting to localhost:18080
        # This avoids sing-box TUN interfering with direct TCP to WSL IP
        proc = subprocess.Popen(
            ["wsl.exe", "-d", "Ubuntu-24.04", "-u", "louis", "--",
             "socat", "-", "TCP:127.0.0.1:18080"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL
        )
        
        def pipe_to_wsl():
            try:
                while True:
                    data = client_sock.recv(65536)
                    if not data:
                        break
                    proc.stdin.write(data)
                    proc.stdin.flush()
            except:
                pass
            finally:
                try: proc.stdin.close()
                except: pass
        
        def pipe_from_wsl():
            try:
                while True:
                    data = proc.stdout.read(65536)
                    if not data:
                        break
                    client_sock.sendall(data)
            except:
                pass
            finally:
                try: client_sock.close()
                except: pass
        
        t1 = threading.Thread(target=pipe_to_wsl, daemon=True)
        t2 = threading.Thread(target=pipe_from_wsl, daemon=True)
        t1.start()
        t2.start()
        t1.join(timeout=120)
        proc.terminate()
    except Exception as e:
        print(f"  Error: {e}", flush=True)
    finally:
        try: client_sock.close()
        except: pass

print(f"=== WSL Port Forwarder (socat mode) ===", flush=True)
print(f"Listening on 0.0.0.0:{LISTEN_PORT} -> WSL localhost:18080", flush=True)

# Check socat is installed in WSL
r = subprocess.run(["wsl.exe", "-d", "Ubuntu-24.04", "-u", "louis", "--", "which", "socat"],
                   capture_output=True, text=True, timeout=10)
if r.returncode != 0:
    print("Installing socat in WSL...", flush=True)
    subprocess.run(["wsl.exe", "-d", "Ubuntu-24.04", "-u", "root", "--",
                    "apt-get", "install", "-y", "-qq", "socat"],
                   capture_output=True, timeout=60)

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("0.0.0.0", LISTEN_PORT))
server.listen(128)
print(f"Ready!", flush=True)

while True:
    try:
        client_sock, addr = server.accept()
        print(f"  Connection from {addr[0]}:{addr[1]}", flush=True)
        threading.Thread(target=handle_client, args=(client_sock,), daemon=True).start()
    except KeyboardInterrupt:
        print("\nShutting down...", flush=True)
        break
    except Exception as e:
        print(f"Accept error: {e}", flush=True)
        time.sleep(1)

server.close()
