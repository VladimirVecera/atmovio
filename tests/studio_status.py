"""Studio queue and missing-file regression through the real gallery/detail routes."""
import contextlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

base = Path(tempfile.mkdtemp(prefix="atmovio-studio-status-"))
os.environ["ATMOVIO_DIR"] = str(base)
os.environ["ATMOVIO_ADMIN_PASSWORD"] = "studio-status-fixture"
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src/atmovio"))
import app as a
from fastapi.testclient import TestClient

try:
    a.db_init()
    cfg = a.load_config()
    cfg.update(snapshot_dir=str(base / "snapshots"), recordings_path=str(base / "recordings"),
               frigate_config_path=str(base / "frigate.yml"))
    a.save_config(cfg)
    eid = a.record_export(cfg, "source", None, "camera", "Source clip", 0, 600)
    output = base / "finished.mp4"
    with a.db() as con:
        sid = con.execute(
            "INSERT INTO studio_videos(export_id,camera,name,speed,title,description,status,file,created) "
            "VALUES(?,'camera','Fixture',120,'Saved title','Saved description','ready',?,datetime('now'))",
            (eid, str(output)),
        ).lastrowid

    with contextlib.ExitStack() as stack:
        stack.enter_context(patch("requests.sessions.Session.request", side_effect=AssertionError("Unexpected network call")))
        stack.enter_context(patch("subprocess.run", return_value=subprocess.CompletedProcess([], 1, "", "Offline fixture")))
        stack.enter_context(patch("subprocess.Popen", side_effect=AssertionError("Unexpected process launch")))
        stack.enter_context(patch.object(a, "yt_linked", return_value=True))
        kick = stack.enter_context(patch.object(a, "studio_kick"))
        client = TestClient(a.app)
        login = client.get("/login")
        token = re.search(r'name="csrf_token" value="([^"]+)"', login.text)[1]
        response = client.post("/login", data={"password": os.environ["ATMOVIO_ADMIN_PASSWORD"], "csrf_token": token}, follow_redirects=False)
        assert response.status_code == 303

        def pages():
            result = [client.get("/youtube"), client.get(f"/studio/v/{sid}")]
            assert all(r.status_code == 200 for r in result)
            return [re.search(r"<main\b[^>]*>(.*?)</main>", r.text, re.S)[1] for r in result]

        # Missing paths, an unset path and a directory must never look like queued work.
        for path in (str(output), None, "", str(base)):
            with a.db() as con:
                con.execute("UPDATE studio_videos SET file=? WHERE id=?", (path, sid))
            gallery, detail = pages()
            for html in (gallery, detail):
                assert "Video není dostupné" in html
                assert "Soubor hotového videa se nepodařilo najít" in html
                assert 'href="/storage"' in html
                assert f'href="/studio/new/{eid}?again={sid}"' in html
                assert "Čeká na vytvoření videa" not in html and "Čeká ve frontě" not in html
                assert 'class="spin"' not in html and 'x-data="autorefresh(' not in html
                assert f'/studio/v/{sid}/download' not in html
            assert "K nahrání je potřeba dostupný soubor videa" in detail
            assert "Až bude video hotové" not in detail
            assert f'action="/studio/v/{sid}/youtube"' not in detail

        # Checking availability never rewrites the stored job or starts a new render.
        with a.db() as con:
            job = dict(con.execute("SELECT * FROM studio_videos WHERE id=?", (sid,)).fetchone())
        assert (job["status"], job["title"], job["description"]) == ("ready", "Saved title", "Saved description")
        kick.assert_not_called()

        # A returned disk/file immediately restores playback, download and upload controls.
        output.write_bytes(b"fixture video")
        with a.db() as con:
            con.execute("UPDATE studio_videos SET file=? WHERE id=?", (str(output), sid))
        gallery, detail = pages()
        assert "Video není dostupné" not in gallery + detail
        assert f'/studio/v/{sid}/download' in gallery and f'/studio/v/{sid}/play.mp4' in detail
        assert f'action="/studio/v/{sid}/youtube"' in detail

        for status, label in (("queued", "Čeká na vytvoření videa"), ("rendering", "Vytváří se…"),
                              ("failed", "nepodařilo se"), ("unknown", "Video není dostupné")):
            with a.db() as con:
                con.execute("UPDATE studio_videos SET status=?,file=NULL,message='Fixture failure' WHERE id=?", (status, sid))
            gallery, detail = pages()
            assert label.lower() in gallery.lower() and label in detail
            assert ('x-data="autorefresh(' in gallery) == (status in ("queued", "rendering"))
            assert ('x-data="autorefresh(' in detail) == (status in ("queued", "rendering"))
            assert ('class="spin"' in detail) == (status in ("queued", "rendering"))
            if status == "queued":
                assert "Ve frontě na zpracování v Raspberry Pi" in detail
                assert "hotovo asi v" in detail
            else:
                assert "Čeká na vytvoření videa" not in gallery + detail
            if status == "failed":
                assert "Fixture failure" in gallery + detail
            if status == "unknown":
                assert "Stav videa se nepodařilo rozpoznat" in detail

        # A published YouTube link remains usable even if the local output disappears.
        with a.db() as con:
            con.execute("UPDATE studio_videos SET status='ready',yt_status='done',yt_url='https://youtu.be/fixture' WHERE id=?", (sid,))
        gallery, detail = pages()
        assert "Video není dostupné" in gallery + detail
        assert 'href="https://youtu.be/fixture"' in gallery and 'href="https://youtu.be/fixture"' in detail
        kick.assert_not_called()

    assert not a.watcher.is_alive()
    print("PASS: missing/unset/directory file, restored file, queued/rendering/failed/unknown states, recovery links, no implicit render or data changes, retained YouTube link")
finally:
    shutil.rmtree(base)
