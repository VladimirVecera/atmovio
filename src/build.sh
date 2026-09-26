#!/usr/bin/env bash
# Sestaví install.sh a update-atmovio.sh ze šablon + atmovio/app.py
set -euo pipefail
cd "$(dirname "$0")"
"${PYTHON:-python3}" - "$@" <<'PY'
import ast
import sys
from pathlib import Path
app = Path("atmovio/app.py").read_text(encoding="utf-8").rstrip("\n")
requirements = Path("atmovio/requirements.txt").read_text(encoding="utf-8").rstrip("\n")
storage = Path("atmovio/storage_guard.py").read_text(encoding="utf-8").rstrip("\n")
css = Path("atmovio/static/atmovio.css").read_text(encoding="utf-8").rstrip("\n")
js = Path("atmovio/static/atmovio.js").read_text(encoding="utf-8").rstrip("\n")
for name, text in (("atmovio.css", css), ("atmovio.js", js)):
    if "ATMOVIO_CSS_EOF" in text or "ATMOVIO_JS_EOF" in text:
        raise SystemExit(f"Kolize heredoc značky v {name}.")
metrics = Path("atmovio/metrics.py").read_text(encoding="utf-8").rstrip("\n")
ast.parse(metrics)
if "ATMOVIO_METRICS_EOF" in metrics: raise SystemExit("Kolize metrics heredoc")
ast.parse(storage)
ast.parse(app)
if "ATMOVIO_APP_EOF" in app or "ATMOVIO_REQUIREMENTS_EOF" in requirements or "ATMOVIO_STORAGE_EOF" in storage:
    raise SystemExit("Kolize heredoc značky ve zdrojích.")
check = "--check" in sys.argv[1:]
for tpl, out in (("install.template.sh", "../install.sh"), ("update.template.sh", "../update-atmovio.sh")):
    txt = Path(tpl).read_text(encoding="utf-8")
    for marker, value in (("__ATMOVIO_APP__", app), ("__ATMOVIO_REQUIREMENTS__", requirements), ("__ATMOVIO_STORAGE__", storage),
                          ("__ATMOVIO_METRICS__", metrics), ("__ATMOVIO_CSS__", css), ("__ATMOVIO_JS__", js)):
        if txt.count(marker) != 1:
            raise SystemExit(f"{tpl}: značka {marker} musí být právě jednou.")
        txt = txt.replace(marker, value)
    if check:
        if not Path(out).exists() or Path(out).read_text(encoding="utf-8") != txt:
            raise SystemExit(f"{out} neodpovídá zdrojům. Spusť bash src/build.sh.")
    else:
        Path(out).write_text(txt, encoding="utf-8")
        Path(out).chmod(0o755)
    print("OK ->", Path(out).resolve(), len(txt.splitlines()), "řádků")
PY
