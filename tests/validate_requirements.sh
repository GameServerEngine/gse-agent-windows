#!/usr/bin/env bash
# requirements.json says what this component needs (minimum OS and prerequisites).
# The GSE website reads it. This test keeps the file valid.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$root/requirements.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
need = ["schema", "component", "title", "minimum_os", "tested_on", "prerequisites", "unverified"]
missing = [k for k in need if k not in d]
assert not missing, "requirements.json is missing: " + ", ".join(missing)
assert d["schema"] == 1, "unknown schema"
assert d["minimum_os"], "minimum_os is empty"
assert d["prerequisites"], "prerequisites is empty"
for o in d["minimum_os"]:
    assert o.get("name"), "a minimum_os entry has no name"
    assert "minimum" in o, "a minimum_os entry has no minimum"
    # A missing minimum is allowed only when the file says it is not yet known.
    assert o["minimum"] or d["unverified"], "minimum is empty and unverified is empty"
for p in d["prerequisites"]:
    assert p.get("name") and p.get("note"), "a prerequisite needs a name and a note"
print("requirements.json OK")
PY
