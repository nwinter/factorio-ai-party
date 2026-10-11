"""Minimal obs-websocket v5 client, stdlib only (serve.py has no third-party dependencies; tools/obs.py uses
obsws_python from tools/.venv). Requests only, no event subscriptions. Thread-safe: one request at a time."""
import base64, hashlib, json, os, socket, struct, threading, uuid


class OBSError(RuntimeError):
    pass


class OBS:
    def __init__(self, host="127.0.0.1", port=4455, password=None, timeout=5.0):
        self.host, self.port, self.timeout = host, port, timeout
        if password is None:
            path = os.path.expanduser("~/.config/pog/obs.pw")
            password = open(path).read().strip() if os.path.exists(path) else ""
        self.password = password
        self.sock = None
        self.lock = threading.Lock()

    # ---- websocket framing ---------------------------------------------------------------------------------------
    def _connect(self):
        s = socket.create_connection((self.host, self.port), timeout=self.timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        s.sendall((f"GET / HTTP/1.1\r\nHost: {self.host}:{self.port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                   f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
                   f"Sec-WebSocket-Protocol: obswebsocket.json\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = s.recv(4096)
            if not chunk:
                raise OBSError("connection closed during handshake")
            head += chunk
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise OBSError("websocket upgrade refused: " + head.split(b"\r\n", 1)[0].decode(errors="replace"))
        self.sock, self.buf = s, head.split(b"\r\n\r\n", 1)[1]
        hello = self._recv()
        if hello.get("op") != 0:
            raise OBSError(f"expected Hello, got {hello}")
        ident = {"rpcVersion": 1, "eventSubscriptions": 0}
        auth = hello["d"].get("authentication")
        if auth:
            secret = base64.b64encode(hashlib.sha256((self.password + auth["salt"]).encode()).digest())
            ident["authentication"] = base64.b64encode(hashlib.sha256(secret + auth["challenge"].encode()).digest()).decode()
        self._send({"op": 1, "d": ident})
        if self._recv().get("op") != 2:
            raise OBSError("identify failed (wrong password?)")

    def _send(self, obj):
        data = json.dumps(obj).encode()
        n = len(data)
        head = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n)
                                 if n < 65536 else bytes([0x80 | 127]) + struct.pack(">Q", n))
        mask = os.urandom(4)
        self.sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise OBSError("connection closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _recv(self):
        while True:
            b1, b2 = self._read(2)
            n = b2 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if b2 & 0x80 else None
            data = self._read(n)
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            op = b1 & 0x0F
            if op == 8:
                raise OBSError("closed by OBS: " + data[2:].decode(errors="replace"))
            if op == 9:  # ping -> pong
                self.sock.sendall(bytes([0x8A, 0x80]) + os.urandom(4))
                continue
            if op in (1, 2):
                return json.loads(data)

    # ---- requests ------------------------------------------------------------------------------------------------
    def call(self, request, data=None):
        """Send one request; returns responseData ({} when none). Reconnects once on a dropped connection."""
        with self.lock:
            for attempt in (0, 1):
                try:
                    if self.sock is None:
                        self._connect()
                    rid = uuid.uuid4().hex
                    self._send({"op": 6, "d": {"requestType": request, "requestId": rid, "requestData": data or {}}})
                    while True:
                        msg = self._recv()
                        if msg.get("op") == 7 and msg["d"].get("requestId") == rid:
                            break
                    st = msg["d"]["requestStatus"]
                    if not st.get("result"):
                        raise OBSError(f"{request}: {st.get('code')} {st.get('comment', '')}".strip())
                    return msg["d"].get("responseData") or {}
                except (OSError, OBSError) as e:
                    self.close()
                    if attempt or (isinstance(e, OBSError) and not str(e).startswith(("connection", "closed"))):
                        raise

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None
