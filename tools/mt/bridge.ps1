# One spectator UDP socket -> framed TCP -> reverse SSH -> Mac -> iMac UDP.
# Run in the foreground of an owned SSH child. TCP EOF exits this process.
param([int]$Port = 34478)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Collections.Generic;
public class MtDatagrams {
  public static void Run(int port) {
    using (var tcp = new TcpClient("127.0.0.1", port))
    using (var udp = new UdpClient(new IPEndPoint(IPAddress.Loopback, port))) {
      tcp.NoDelay = true;
      tcp.SendTimeout = 10000;
      var stream = tcp.GetStream();
      var buf = new List<byte>();
      var bytes = new byte[65536];
      IPEndPoint peer = null;
      while (true) {
        if (udp.Client.Poll(1000, SelectMode.SelectRead)) {
          var from = new IPEndPoint(IPAddress.Any, 0);
          var data = udp.Receive(ref from);
          if (peer == null) peer = from;
          if (!peer.Equals(from)) continue;
          var frame = new byte[data.Length + 2];
          frame[0] = (byte)(data.Length >> 8); frame[1] = (byte)data.Length;
          Array.Copy(data, 0, frame, 2, data.Length);
          stream.Write(frame, 0, frame.Length);
        }
        if (tcp.Client.Poll(1000, SelectMode.SelectRead)) {
          int count = stream.Read(bytes, 0, bytes.Length);
          if (count == 0) return;
          for (int i = 0; i < count; i++) buf.Add(bytes[i]);
          while (buf.Count >= 2) {
            int size = (buf[0] << 8) | buf[1];
            if (buf.Count < size + 2) break;
            if (peer != null) udp.Send(buf.GetRange(2, size).ToArray(), size, peer);
            buf.RemoveRange(0, size + 2);
          }
        }
      }
    }
  }
}
'@
[MtDatagrams]::Run($Port)
