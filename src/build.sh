#!/usr/bin/env bash
# Sestaví install.sh a update-skywatch.sh ze šablon + skywatch/app.py
set -euo pipefail
cd "$(dirname "$0")"
"${PYTHON:-python3}" - "$@" <<'PY'
import ast
import sys
from pathlib import Path
app = Path("skywatch/app.py").read_text(encoding="utf-8").rstrip("\n")
requirements = Path("skywatch/requirements.txt").read_text(encoding="utf-8").rstrip("\n")
storage = Path("skywatch/storage_guard.py").read_text(encoding="utf-8").rstrip("\n")
css = Path("skywatch/static/skywatch.css").read_text(encoding="utf-8").rstrip("\n")
js = Path("skywatch/static/skywatch.js").read_text(encoding="utf-8").rstrip("\n")
for name, text in (("skywatch.css", css), ("skywatch.js", js)):
    if "SKYWATCH_CSS_EOF" in text or "SKYWATCH_JS_EOF" in text:
        raise SystemExit(f"Kolize heredoc značky v {name}.")
ast.parse(storage)
ast.parse(app)
if "SKYWATCH_APP_EOF" in app or "SKYWATCH_REQUIREMENTS_EOF" in requirements or "SKYWATCH_STORAGE_EOF" in storage:
    raise SystemExit("Kolize heredoc značky ve zdrojích.")
check = "--check" in sys.argv[1:]
for tpl, out in (("install.template.sh", "../install.sh"), ("update.template.sh", "../update-skywatch.sh")):
    txt = Path(tpl).read_text(encoding="utf-8")
    for marker, value in (("__SKYWATCH_APP__", app), ("__SKYWATCH_REQUIREMENTS__", requirements), ("__SKYWATCH_STORAGE__", storage),
                          ("__SKYWATCH_CSS__", css), ("__SKYWATCH_JS__", js)):
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
