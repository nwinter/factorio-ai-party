#!/usr/bin/env python3
"""Screenshot the `stream` scene as OBS composes it, then put the program scene back.

  tools/.venv/bin/python tools/stream/obs_shot.py OUT.png [--wait 4] [--back co-op]

Browser sources only render while their scene is live, so this switches the program scene to `stream` for a few
seconds. It refuses while a recording is running so it never changes what is being recorded.
"""
import argparse, base64, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.dont_write_bytecode = True
import obs  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--scene", default="stream")
    ap.add_argument("--back", default="co-op")
    ap.add_argument("--wait", type=float, default=4.0)
    ap.add_argument("--reload", action="store_true", help="reload the overlay page first (after editing it)")
    a = ap.parse_args()
    c = obs.client()
    if c.get_record_status().output_active:
        sys.exit("recording is active: not switching scenes")
    c.set_current_program_scene(a.scene)
    try:
        if a.reload:
            c.press_input_properties_button("stream overlay", "refreshnocache")
        time.sleep(a.wait)
        img = c.get_source_screenshot(a.scene, "png", 1920, 1080, -1).image_data
        open(a.out, "wb").write(base64.b64decode(img.split(",", 1)[1]))
    finally:
        c.set_current_program_scene(a.back)
    print(a.out)


if __name__ == "__main__":
    main()
