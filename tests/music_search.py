"""Offline Openverse contract checks: combine title, all instruments and creator."""
import os
import re
import sys
import tempfile
from pathlib import Path
from unittest.mock import Mock, patch

from fastapi.testclient import TestClient

with tempfile.TemporaryDirectory(prefix="atmovio-music-") as tmp:
    os.environ["ATMOVIO_DIR"] = tmp
    os.environ["ATMOVIO_ADMIN_PASSWORD"] = "fixture-music-only"
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src" / "atmovio"))
    import app as a

    a.db_init()
    cfg = a.load_config()
    response = Mock(status_code=200, ok=True)
    response.json.return_value = {"results": [{
        "id": "fixture", "title": "Run", "creator": "Test Artist", "duration": 120000,
        "url": "https://example.org/run.mp3", "license": "by", "license_version": "4.0",
        "genres": ["classical"], "tags": [{"name": "piano"}, {"name": "orchestra"}],
        "foreign_landing_url": "https://example.org/run", "attribution": "Test credit",
    }, {"id": "no-playable-url"}]}
    with patch.object(a, "openverse_headers", return_value={}) as auth, \
         patch.object(a.requests, "get", return_value=response) as remote, patch.object(a.time, "sleep") as pause:
        client = TestClient(a.app)
        assert client.get("/studio/music/search?q=run", follow_redirects=False).status_code == 303
        token = re.search(r'name="csrf_token" value="([^"]+)"', client.get("/login").text)[1]
        client.post("/login", data={"password": os.environ["ATMOVIO_ADMIN_PASSWORD"], "csrf_token": token}, follow_redirects=False)
        remote.reset_mock()
        data = client.get("/studio/music/search", params={
            "q": "run", "search_in": "title", "instruments": "piano,orchestra,piano",
            "creator": "Test Artist", "length": "medium", "license": "by", "extension": "mp3",
        }).json()
        sent = remote.call_args.kwargs["params"]
        assert "q" not in sent, "Openverse would ignore all field filters when q is present"
        assert sent["title"] == '"run"'
        assert sent["tags"] == '"piano" +"orchestra"', "Both instruments must be required, not ORed"
        assert sent["creator"] == '"Test" +"Artist"'
        assert sent["length"] == "medium" and sent["license"] == "by" and sent["extension"] == "mp3"
        assert sent["category"] == "music" and sent["mature"] == "false"
        assert len(data["items"]) == 1 and data["items"][0]["duration_h"] == "2:00"
        assert data["items"][0]["attribution"] == "Test credit" and not data["error"]

        for filters, expected in [
            ({"instruments": "piano,orchestra", "search_in": "title"}, {"tags": '"piano" +"orchestra"'}),
            ({"creator": "Test Artist"}, {"creator": '"Test" +"Artist"'}),
            ({"q": "calm ambient", "search_in": "tags", "instruments": "piano"}, {"tags": '"calm" +"ambient" +"piano"'}),
            ({"q": "run", "creator": "Test Artist"}, {"title": '"run"', "creator": '"Test" +"Artist"'}),
            ({"q": "calm piano"}, {"q": "calm piano"}),  # Existing API callers keep general search.
        ]:
            assert not client.get("/studio/music/search", params=filters).json()["error"]
            sent = remote.call_args.kwargs["params"]
            assert {k: v for k, v in sent.items() if k in ("q", "title", "tags", "creator")} == expected

        for filters in [{}, {"q": "r"}, {"instruments": "unknown"}, {"q": "run", "search_in": "unknown"},
                        {"q": "++", "search_in": "title"}, {"creator": "--"}]:
            remote.reset_mock()
            assert client.get("/studio/music/search", params=filters).json()["error"]
            remote.assert_not_called()

        a.music_search(cfg, 'run" -piano', instruments="piano", search_in="title", license="by-nc", extension="exe")
        sent = remote.call_args.kwargs["params"]
        assert sent["title"] == '"run" +"piano"' and sent["tags"] == '"piano"'
        assert sent["license"] == "cc0,by" and "extension" not in sent
        response.json.return_value = {"results": []}
        assert "Žádná skladba" in a.music_search(cfg, "run", instruments="piano,orchestra")["error"]
        response.json.return_value = {"results": [{"id": "recovered", "url": "https://example.org/run.mp3", "title": "Run"}]}
        for failure in [a.requests.ReadTimeout("raw exception must stay hidden"), a.requests.ConnectTimeout("fixture"),
                        a.requests.ConnectionError("fixture"), Mock(status_code=502, ok=False),
                        Mock(status_code=503, ok=False), Mock(status_code=504, ok=False)]:
            remote.reset_mock(); pause.reset_mock(); auth.reset_mock()
            remote.side_effect = [failure, response]
            recovered = a.music_search(cfg, "run", instruments="piano,orchestra", creator="Test Artist", license="by")
            assert remote.call_count == 2 and pause.call_count == 1 and auth.call_count == 1
            first, second = [call.kwargs for call in remote.call_args_list]
            assert first == second  # Retry never relaxes filters or license.
            assert first["timeout"] == (5, 30)
            assert first["params"]["title"] == '"run"' and first["params"]["tags"] == '"piano" +"orchestra"'
            assert not recovered["error"] and not recovered.get("retryable") and recovered["items"][0]["title"] == "Run"

        for failure, expected in [(a.requests.ReadTimeout("raw exception must stay hidden"), "neodpovědělo včas"),
                                  (a.requests.ConnectionError("fixture"), "DNS"),
                                  (Mock(status_code=503, ok=False), "HTTP 503")]:
            remote.reset_mock(); pause.reset_mock()
            remote.side_effect = [failure, failure]
            failed = a.music_search(cfg, "run")
            assert remote.call_count == 2 and pause.call_count == 1
            assert failed["retryable"] and expected in failed["error"] and not failed["items"]
            assert "raw exception" not in failed["error"] and "fixture" not in failed["error"]

        for code in [400, 401, 403, 429]:
            remote.reset_mock(); pause.reset_mock()
            remote.side_effect = None; remote.return_value = Mock(status_code=code, ok=False)
            failed = a.music_search(cfg, "run")
            assert failed["error"] and not failed.get("retryable")
            assert remote.call_count == 1 and pause.call_count == 0
            if code == 429:
                assert "Vyšší limit" in failed["error"]
                auth.return_value = {"Authorization": "Bearer fixture"}
                assert "registrací" not in a.music_search(cfg, "run")["error"]
                auth.return_value = {}

        remote.reset_mock(); pause.reset_mock()
        remote.side_effect = a.requests.exceptions.SSLError("fixture")
        assert "certifikáty" in a.music_search(cfg, "run")["error"]
        assert remote.call_count == 1 and pause.call_count == 0
        remote.side_effect = None; remote.return_value = response
        for body in [None, [], {"results": None}, {"results": "invalid"}]:
            response.json.return_value = body
            assert "neplatnou odpověď" in a.music_search(cfg, "run")["error"]
        response.json.side_effect = ValueError("invalid JSON")
        failed = client.get("/studio/music/search?q=run").json()
        assert failed["retryable"] and "neplatnou odpověď" in failed["error"]

    # Render the actual Studio page to cover its instrument list and labels.
    eid = a.record_export(cfg, "fixture", None, "east", "Fixture", 0, 1000)
    source = Path(tmp) / "fixture.mp4"
    source.write_bytes(b"fixture")
    with patch.object(a, "frigate_exports", return_value={"fixture": {"video_path": str(source)}}), \
         patch.object(a, "frigate_media_path", return_value=source), \
         patch.object(a, "ffprobe_info", return_value={"duration": 1000}), \
         patch.object(a, "disk_health_warning", return_value=("", "")), \
         patch.object(a.requests, "get", side_effect=AssertionError("Unexpected network")):
        page = client.get(f"/studio/new/{eid}")
        assert page.status_code == 200
        for key, label in a.MUSIC_INSTRUMENTS:
            assert f'value="{key}" x-model="instruments">{label}' in page.text
        assert 'for="music-query"' in page.text and "Autor / interpret" in page.text
        assert 'type="button" class="chip"' in page.text
        assert "Zkusit hledání znovu" in page.text

print("PASS: combined filters, bounded retry/recovery, timeout/connection/HTTP/JSON errors, auth and Studio form")
