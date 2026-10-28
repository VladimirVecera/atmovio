"""Older installations discover releases and run only checksum-verified updates."""
import hashlib
import os
from pathlib import Path
import shutil
import sys
import tempfile
from unittest.mock import Mock, patch

base = Path(tempfile.mkdtemp(prefix="atmovio-release-test-"))
os.environ["ATMOVIO_DIR"] = str(base)
os.environ["ATMOVIO_ADMIN_PASSWORD"] = "release-test-only"
root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "src/atmovio"))
import app as a

try:
    script = (root / "update-atmovio.sh").read_bytes()
    version = a.APP_VERSION
    script_url = f"https://github.com/VladimirVecera/atmovio/releases/download/v{version}/update-atmovio.sh"
    sums_url = script_url.rsplit("/", 1)[0] + "/SHA256SUMS"
    release = Mock(status_code=200)
    release.json.return_value = dict(tag_name="v" + version, assets=[
        dict(name="update-atmovio.sh", browser_download_url=script_url),
        dict(name="SHA256SUMS", browser_download_url=sums_url)])
    for installed in ("5.3.21", "6.0.0", "6.0.1", version):
        with patch.object(a, "APP_VERSION", installed), patch.object(a.requests, "get", return_value=release):
            state = a.check_for_update()
            assert state["available"] == (installed != version)
            assert state["script_url"] == script_url and state["sums_url"] == sums_url
    body = Mock(content=script)
    checksum = Mock(text=hashlib.sha256(script).hexdigest() + "  update-atmovio.sh\n")
    with patch.object(a, "APP_VERSION", "5.3.21"), patch.object(a, "update_running", return_value=False), patch.object(a, "run", return_value=(0, "")) as run:
        with patch.object(a.requests, "get", side_effect=[body, Mock(text="0" * 64 + "  update-atmovio.sh\n")]):
            assert "Kontrolní součet" in a.start_update()
            run.assert_not_called()
        with patch.object(a.requests, "get", side_effect=[body, checksum]):
            assert a.start_update() == ""
            assert (base / ".update-dl/update-atmovio.sh").read_bytes() == script
            assert any(call.args[0][0] == "systemd-run" for call in run.call_args_list)
    print("PASS: older installations discover the current release, current release is not reinstalled, bad checksum blocks execution, verified updater runs independently of the web service")
finally:
    shutil.rmtree(base)
