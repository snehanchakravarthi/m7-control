#!/usr/bin/env python3
"""Check whether a Samsung smart monitor or TV supports IP Control (port 1516), before building the app.

Needs "IP Remote" switched on in the display's network expert settings.

  M7_IP=192.168.1.20 python3 ipcontrol_probe.py pair        one-time pairing: choose Allow on the display's popup
  M7_IP=192.168.1.20 python3 ipcontrol_probe.py read        read-only: states, backlight, volume, picture settings
  M7_IP=192.168.1.20 python3 ipcontrol_probe.py backlight   visible test: change the real backlight for 4 s, then restore
  M7_IP=192.168.1.20 python3 ipcontrol_probe.py set-backlight N     set the backlight to N (0-50)

The token the display issues is saved to ~/.config/m7ctl/ipcontrol.json (owner-only) together with
the display's certificate fingerprint, which is checked on every later connection. The token is never
printed. M7 Control adopts this pairing on first launch. Standard library only.
"""
from __future__ import annotations

import hashlib
import http.client
import json
import os
import ssl
import sys
import time
from pathlib import Path

IP = os.environ.get("M7_IP", "")
PORT = 1516
STORE = Path.home() / ".config" / "m7ctl" / "ipcontrol.json"

# Methods other people have confirmed on Samsung smart monitors.
KNOWN_READS = ["getTVStates", "getDeviceInformation", "backlightControl", "directVolumeControl", "muteControl", "inputSourceControl", "powerControl"]
# Names taken from Samsung's published command list; a given display may reject some of them.
CANDIDATE_READS = [
    "getVideoStates", "pictureModeControl", "contrastControl", "brightnessControl", "sharpnessControl",
    "colorControl", "tintControl", "colorToneControl", "soundModeControl", "pictureSizeControl",
]


class IPControl:
    def __init__(self) -> None:
        saved = json.loads(STORE.read_text()) if STORE.exists() else {}
        self.token: str = saved.get("token", "")
        self.fingerprint: str = saved.get("fingerprint", "")
        self.last_fingerprint = ""
        self._id = 0

    def call(self, method: str, params: dict | None = None, timeout: float = 8, with_token: bool = True) -> dict:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE  # self-signed; pinned by fingerprint below instead
        conn = http.client.HTTPSConnection(IP, PORT, timeout=timeout, context=context)
        conn.connect()
        seen = hashlib.sha256(conn.sock.getpeercert(binary_form=True)).hexdigest()
        if self.fingerprint and seen != self.fingerprint:
            conn.close()
            raise ConnectionError("The display's certificate changed since pairing; refusing to send the token.")
        self.last_fingerprint = seen
        self._id += 1
        body: dict = {"jsonrpc": "2.0", "id": str(self._id), "method": method}
        merged = dict(params or {})
        if with_token:
            merged = {"AccessToken": self.token, **merged}
        if merged:
            body["params"] = merged
        conn.request("POST", "/", body=json.dumps(body), headers={"Accept": "application/json", "Content-Type": "application/json"})
        raw = conn.getresponse().read().decode(errors="replace")
        conn.close()
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return {"unparsed": raw[:300]}

    def save(self, token: str) -> None:
        STORE.parent.mkdir(parents=True, exist_ok=True)
        STORE.write_text(json.dumps({"host": IP, "token": token, "fingerprint": self.last_fingerprint}))
        STORE.chmod(0o600)
        self.token, self.fingerprint = token, self.last_fingerprint


def shown(reply: dict) -> str:
    """Compact reply text with any token value hidden."""
    def scrub(value: object) -> object:
        if isinstance(value, dict):
            return {k: ("<hidden>" if "token" in k.lower() else scrub(v)) for k, v in value.items()}
        return value
    if "result" in reply:
        return "OK   " + json.dumps(scrub(reply["result"]))
    return "FAIL " + json.dumps(scrub(reply.get("error", reply)))


def pair(client: IPControl) -> int:
    print("Asking the display for access. Choose ALLOW on its popup (about 60 s).")
    print("The computer's picture must be showing, not the Samsung home screen or a settings menu.")
    reply = client.call("createAccessToken", timeout=75, with_token=False)
    token = reply.get("result", {}).get("AccessToken") if isinstance(reply.get("result"), dict) else None
    if not token:
        print("Pairing did not complete:", shown(reply))
        return 1
    client.save(token)
    print(f"Paired. Token and certificate fingerprint saved to {STORE}")
    return 0


def read_all(client: IPControl) -> int:
    print("Confirmed methods (read-only):")
    for method in KNOWN_READS:
        print(f"  {method:<24} {shown(client.call(method))}")
        time.sleep(0.3)
    print("\nPicture and sound methods (read-only, some may not exist on this display):")
    for method in CANDIDATE_READS:
        try:
            print(f"  {method:<24} {shown(client.call(method))}")
        except OSError as error:
            print(f"  {method:<24} connection error: {error}")
            time.sleep(3)
        time.sleep(0.4)
    return 0


def current_backlight(client: IPControl) -> int | None:
    result = client.call("backlightControl").get("result")
    return int(result["backlight"]) if isinstance(result, dict) and "backlight" in result else None


def backlight_test(client: IPControl) -> int:
    before = current_backlight(client)
    if before is None:
        print("Could not read the backlight:", shown(client.call("backlightControl")))
        return 1
    target = before - 20 if before >= 20 else min(50, before + 20)
    print(f"backlight now {before}/50. Changing to {target} for 4 s: the panel should get visibly {'darker' if target < before else 'brighter'}.")
    started = time.time()
    print("  set  ->", shown(client.call("backlightControl", {"backlight": target})), f"({(time.time() - started) * 1000:.0f} ms)")
    time.sleep(0.5)
    print("  read ->", current_backlight(client))
    time.sleep(4)
    print("  restore ->", shown(client.call("backlightControl", {"backlight": before})))
    time.sleep(0.5)
    print(f"backlight back to {current_backlight(client)}/50")
    return 0


def main() -> int:
    if not IP:
        print("Set M7_IP to the display's address, for example:  M7_IP=192.168.1.20 python3 ipcontrol_probe.py read")
        return 1
    command = sys.argv[1] if len(sys.argv) > 1 else "read"
    client = IPControl()
    if command == "pair":
        return pair(client)
    if not client.token:
        print("Not paired yet. Run the 'pair' command first.")
        return 1
    if command == "read":
        return read_all(client)
    if command == "backlight":
        return backlight_test(client)
    if command == "set-backlight" and len(sys.argv) > 2:
        level = max(0, min(50, int(sys.argv[2])))
        print(shown(client.call("backlightControl", {"backlight": level})))
        return 0
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main())
