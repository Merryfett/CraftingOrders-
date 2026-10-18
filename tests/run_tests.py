"""Run offline regression tests using lupa's Lua 5.1 runtime.

Usage: python -m pip install -r tests/requirements.txt
       python tests/run_tests.py
The test environment mocks WoW APIs; this never loads the addon in the game.
"""
import argparse
import subprocess
from pathlib import Path
from lupa.lua51 import LuaRuntime

parser = argparse.ArgumentParser()
parser.add_argument("--baseline", type=Path)
parser.add_argument("--baseline-ref", default="d3f1e871d3df6cf33b151f5f465a5b9bcf33cd4e")
args = parser.parse_args()
addon = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
compile_lua = lua.eval("function(s,n) local f,e=loadstring(s,n); return f~=nil,e end")
files = list(addon.rglob("*.lua"))
for path in files:
    ok, error = compile_lua(path.read_text(encoding="utf-8-sig"), "@" + str(path))
    if not ok:
        raise SystemExit(error)
print(f"PASS: {len(files)} Lua files compile under Lua 5.1", flush=True)
if args.baseline:
    baseline = args.baseline.read_text(encoding="utf-8-sig")
else:
    baseline = subprocess.check_output(
        ["git", "show", args.baseline_ref + ":BrowsePane.lua"], cwd=addon
    ).decode("utf-8-sig")
lua.globals().OLD_SOURCE = baseline
lua.globals().NEW_SOURCE = (addon / "BrowsePane.lua").read_text(encoding="utf-8-sig")
lua.globals().WORK_SOURCE = (addon / "WorkQueue.lua").read_text(encoding="utf-8-sig")
lua.execute((addon / "tests" / "performance_spec.lua").read_text(encoding="utf-8"))
shopping = addon / "tests" / "shopping_spec.lua"
if shopping.exists():
    lua.globals().PRICING_SOURCE = (addon / "Pricing.lua").read_text(encoding="utf-8-sig")
    lua.execute(shopping.read_text(encoding="utf-8"))
