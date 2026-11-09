"""One-client UDP over a reverse SSH TCP forward (stdlib, no listening LAN ports).

Mac accepts framed datagrams on loopback TCP; each connection owns a UDP socket to
imac.local:34475. pogwin's bridge.ps1 supplies the other end. TCP_NODELAY avoids
coalescing game packets. This is for one spectator, never the agents' RCON path.
"""
import select
import socket
import socketserver
import struct
import threading


def frames(buffer):
    out = []
    while len(buffer) >= 2:
        size = struct.unpack('!H', buffer[:2])[0]
        if len(buffer) < size + 2:
            break
        out.append(buffer[2:size + 2])
        buffer = buffer[size + 2:]
    return out, buffer


def pump(tcp, target):
    tcp.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    tcp.settimeout(10)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        udp.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 262144)
        udp.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 262144)
        udp.connect(target)
        buf = b''
        while True:
            ready, _, _ = select.select([tcp, udp], [], [], 1)
            if tcp in ready:
                chunk = tcp.recv(65536)
                if not chunk:
                    return
                packets, buf = frames(buf + chunk)
                for packet in packets:
                    udp.send(packet)
            if udp in ready:
                try:
                    packet = udp.recv(65535)
                except ConnectionRefusedError:  # server not up yet
                    continue
                tcp.sendall(struct.pack('!H', len(packet)) + packet)


class Bridge(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, port=34478, target=('imac.local', 34475)):
        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                try:
                    pump(self.request, target)
                except (OSError, ValueError):
                    pass
        super().__init__(('127.0.0.1', port), Handler)

    def start(self):
        threading.Thread(target=self.serve_forever, daemon=True).start()

