"""Run offline regression tests using lupa's Lua 5.1 runtime.

Usage: python -m pip install -r tests/requirements.txt
       python tests/run_tests.py
The test environment mocks WoW APIs; this never loads the addon in the game.
"""
import argparse
import re
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

# Check package load order and exercise actual English fallback for each locale.
toc = (addon / "CraftingOrders++_Mainline.toc").read_text(encoding="utf-8-sig")
load_order = [line.strip().replace("\\", "/") for line in toc.splitlines()
              if line.strip() and not line.startswith("#")]
for relative in load_order:
    assert (addon / relative).is_file(), f"TOC refers to a missing file: {relative}"
assert load_order.index("WorkQueue.lua") < load_order.index("BrowsePane.lua")
for locale in (addon / "Locales").glob("*.lua"):
    vm = LuaRuntime(unpack_returned_tuples=True)
    vm.globals().GetLocale = lambda: locale.stem
    ns = vm.table()
    for relative in load_order:
        if relative == "Locale.lua" or relative.startswith("Locales/"):
            vm.execute((addon / relative).read_text(encoding="utf-8-sig"), "CraftingOrders++", ns)
    for path in (addon / name for name in load_order if not name.startswith("Locales/")):
        source = path.read_text(encoding="utf-8-sig")
        keys = set(re.findall(r'\bL\.([A-Z][A-Z_0-9]+)', source))
        keys.update(re.findall(r'\bLF\("([A-Z][A-Z_0-9]+)"', source))
        for key in keys:
            assert ns._localeDefaults[key] is not None, f"Missing English string {key}"
            assert ns.L[key] is not None, f"Missing locale fallback {locale.stem}/{key}"
print("PASS: TOC file order and all locale fallbacks/reference keys", flush=True)
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
    lua.globals().ENGLISH_SOURCE = (addon / "Locales" / "enUS.lua").read_text(encoding="utf-8-sig")
    lua.execute(shopping.read_text(encoding="utf-8"))
