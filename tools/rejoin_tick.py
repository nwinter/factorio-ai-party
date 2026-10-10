"""Keep a world ticking until player SLOT_INDEX (default 1) has rejoined: rejoin_tick.py WORLD RCON_PORT SECONDS [INDEX]"""
import sys, time, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import pog
world, port, secs = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
pw = open(os.path.expanduser(f'~/.config/pog/rcon-{world}.pw')).read().strip()
r = pog.Rcon('127.0.0.1', port, pw)
start = time.time()
while time.time() - start < secs:
    out = r.command('/silent-command game.tick_paused=false local p=game.get_player(' + str(int(sys.argv[4]) if len(sys.argv) > 4 else 1) + ') rcon.print(p.connected and p.character and "joined" or "waiting")')
    if out.strip() == 'joined':
        print('joined after', round(time.time() - start), 's'); sys.exit(0)
    time.sleep(0.15)
print('not joined'); sys.exit(1)
