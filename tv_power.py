"""Turn the Hisense TV on/off together with the PC.

Usage:
    python tv_power.py on
    python tv_power.py off
"""
import logging
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _load_env(path: Path) -> None:
    """Minimal .env reader (KEY=value lines); real env vars take precedence."""
    if not path.exists():
        return
    # utf-8-sig: Windows PowerShell 5.1 writes a BOM.
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip("\"'"))


_load_env(HERE / ".env")
# Input id as shown by `tv source list`. Unset: never switch input, and turn off
# whatever is showing.
PC_INPUT = os.environ.get("TV_INPUT", "").strip() or None
CONNECT_RETRIES = int(os.environ.get("TV_WOL_RETRIES", 12))  # x5 s for the TV to boot after WoL
SOURCE_RETRIES = int(os.environ.get("TV_SOURCE_RETRIES", 6))  # x~2.5 s for the input switch
# The TV's real MAC, for Wake-on-LAN only. Popped so vidaa doesn't apply it to the
# config's `mac`, which is the pairing identity the tokens were issued for.
TV_MAC = os.environ.pop("TV_MAC", "").strip() or None


# vidaa reads config.yaml and tokens.json from the working directory,
# and scheduled/shutdown tasks start elsewhere (often System32).
os.chdir(HERE)

from vidaa.cli import create_tv_client, get_default_tv  # noqa: E402
from vidaa.topics import TOPIC_SET_SOURCE, get_topic  # noqa: E402
from vidaa.wol import wake_tv  # noqa: E402

logging.basicConfig(
    filename=HERE / "tv_power.log",
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("tv_power")


def _norm(value) -> str:
    return str(value or "").replace(" ", "").lower()


def switch_to_pc(tv, attempts: int = SOURCE_RETRIES) -> bool:
    """Switch to PC_INPUT and confirm it via the state broadcast.

    Not using tv.set_source(): it maps "hdmi4" to the legacy id "6", while
    this TV reports sources by name ("HDMI4"). Send the TV's own sourcelist
    entry instead. A freshly woken TV can ignore the first few requests.
    """
    target = {"sourceid": PC_INPUT, "sourcename": PC_INPUT}
    sources = tv.get_sources(timeout=3)
    if isinstance(sources, list):
        for src in sources:
            if _norm(PC_INPUT) in (_norm(src.get("sourceid")), _norm(src.get("sourcename"))):
                target = src
                break
        else:
            log.warning("%s not in source list: %s", PC_INPUT, sources)

    topic = get_topic(TOPIC_SET_SOURCE, tv.client_id)
    for attempt in range(1, attempts + 1):
        state = tv.get_state(timeout=2) or {}
        if state.get("sourceid") == PC_INPUT:
            log.info("Input is %s (attempt %d)", PC_INPUT, attempt)
            return True
        tv._publish(topic, target)
        time.sleep(2)

    log.warning("Could not confirm switch to %s, sent %s", PC_INPUT, target)
    return False


def _power_on_and_switch(tv) -> None:
    try:
        tv.power_on()  # no-op if already on, wakes it from fake standby otherwise
        if PC_INPUT:
            switch_to_pc(tv)
    finally:
        tv.disconnect()


def turn_on() -> int:
    cfg = get_default_tv()
    mac = TV_MAC or cfg.get("mac") or cfg.get("device_id")
    subnet = cfg["host"].rsplit(".", 1)[0]  # also broadcast to 192.168.0.255
    tv = create_tv_client()
    if tv.connect(timeout=3):
        state = tv.get_state(timeout=3) or {}
        if state and state.get("statetype") != "fake_sleep_0":
            # Someone is already using the TV; mirror turn_off and leave it be.
            log.info("TV already on (%s), leaving input alone", state.get("sourceid"))
            tv.disconnect()
            return 0
        log.info("TV in standby, waking")
        _power_on_and_switch(tv)
        return 0

    for attempt in range(1, CONNECT_RETRIES + 1):
        wake_tv(mac, subnet)
        time.sleep(5)
        tv = create_tv_client()
        if tv.connect(timeout=3):
            log.info("TV on after %d WoL attempt(s)", attempt)
            _power_on_and_switch(tv)
            return 0

    log.error("TV did not respond to WoL")
    return 1


def turn_off(connect_timeout: float = 5, state_timeout: float = 3) -> int:
    tv = create_tv_client()
    if not tv.connect(timeout=connect_timeout):
        log.info("TV not reachable, assuming it's already off")
        return 0
    try:
        state = tv.get_state(timeout=state_timeout) or {}
        if state.get("statetype") == "fake_sleep_0":
            log.info("TV already off")
        elif PC_INPUT and state.get("sourceid") != PC_INPUT:
            log.info("TV is on %s, not %s - leaving it on", state.get("sourceid"), PC_INPUT)
        else:
            tv.send_key("KEY_POWER")
            time.sleep(0.5)  # let the publish flush before the PC goes down
            log.info("Power off sent")
    finally:
        tv.disconnect()
    return 0


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        if action == "on":
            sys.exit(turn_on())
        if action == "off":
            sys.exit(turn_off())
        print(__doc__)
        sys.exit(2)
    except Exception:
        log.exception("tv_power %s failed", action)
        sys.exit(1)
