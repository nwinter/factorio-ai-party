#!/usr/bin/env python3
"""mt308: pog.connect tries the host's IPv4 addresses first, falls back to the name, and makes every connection through
socket.create_connection (tools/test_live_guard.py stubs only that). On chonk imac.local resolved to two IPv6
addresses before its IPv4 one; Factorio's RCON listens on IPv4 only, so connecting by name cost ~1.2 s each time."""
import os, socket, sys
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pog  # noqa: E402

calls = []
def fake_create(addr, timeout=None):
    calls.append(addr)
    if addr[0] == '192.0.2.9':
        raise ConnectionRefusedError('refused')
    return 'sock:' + addr[0]
def fake_getaddrinfo(host, port, family=0, kind=0, *a):
    assert family == socket.AF_INET, family   # only IPv4 is asked for
    return [(socket.AF_INET, socket.SOCK_STREAM, 6, '', ('192.0.2.7', port)), (socket.AF_INET, socket.SOCK_STREAM, 6, '', ('192.0.2.7', port))]

with mock.patch.object(socket, 'create_connection', fake_create), mock.patch.object(socket, 'getaddrinfo', fake_getaddrinfo):
    assert pog.connect('imac.local', 27475, 5) == 'sock:192.0.2.7', calls
    assert calls == [('192.0.2.7', 27475)], calls   # the IPv4 address, once (duplicates dropped), never the name

calls.clear()
with mock.patch.object(socket, 'create_connection', fake_create), \
     mock.patch.object(socket, 'getaddrinfo', lambda *a, **k: [(socket.AF_INET, socket.SOCK_STREAM, 6, '', ('192.0.2.9', 1))]):
    assert pog.connect('somehost', 1, 5) == 'sock:somehost'
    assert calls == [('192.0.2.9', 1), ('somehost', 1)], calls   # a refused IPv4 address falls back to the name

calls.clear()
def no_ipv4(*a, **k):
    raise socket.gaierror('no IPv4')
with mock.patch.object(socket, 'create_connection', fake_create), mock.patch.object(socket, 'getaddrinfo', no_ipv4):
    assert pog.connect('v6only', 2, 5) == 'sock:v6only' and calls == [('v6only', 2)], calls
print('pog connect: ok')
