# Regression suite and contribution sources

Run from the repository root with Python 3.13 and Git:

```sh
python -m pip install -r tests/requirements.txt
python tests/run_tests.py
```

`lupa.lua51` supplies a real Lua 5.1 runtime; WoW APIs are mocked. The reference implementation is read from upstream commit `d3f1e871d3df6cf33b151f5f465a5b9bcf33cd4e` using Git. A source file can be supplied with `--baseline PATH`, or a different Git revision with `--baseline-ref REV`.

## Coverage

- Compile every Lua file; verify TOC paths/load order and actual locale fallback for all included locales.
- Compare upstream and new full-order results across six quality requirements, no pricing provider, fully supplied orders and unknown recipes. Check prices, profit, chosen materials, quality state and concentration estimates.
- Compare 400 randomized lowest-fill cases to the original exhaustive objective, including missing prices and unmarketable materials.
- Verify a 1,200-entry cooperative sort and budgeted deep search.
- Exercise atomic list snapshots, cached preparations, selective item invalidation, stale pricing/profession results, hidden panes, errors and final-step cancellation.
- Verify that a 5,000-event burst creates one initial timer, with correct trailing delay/cancellation.
- Check lightweight detail-warning preparation, optional reagent item tracking, failed item loads, and successful empty requests versus timeout/new-session retries.
- Exercise the actual pricing/export code: quality-aware inventory, repeated/changed orders, owned-only selections, failed exports, persistent-name collisions, tracking reset, temporary lists and optional API failures.
- Cover merge/New List/cancel popup paths, provider changes, deleted lists, Don't Buy exclusions, no-provider errors, Auctioneer Snatch and filtered bulk selection.
- Abort incomplete Auctionator exports before list creation when item names or search conversion are unavailable.

The test reports simulated native work using a fixed per-call cost. Those figures demonstrate scheduling behavior in this fixture; they are not an in-game benchmark. The 2 ms worker target is cooperative and cannot preempt a single expensive native API call. In-game validation of the combined branch, real Auctionator/Auctioneer integration, and the added Filter-menu control is still required.

## Reviewed upstream contributions

All five existing public forks and their non-main branches were reviewed on 2026-10-18. Original authors are retained on the cherry-picked commits.

| Source | Included contribution |
| --- | --- |
| [tay-j-kohn / PR #6](https://github.com/foodmuffin/CraftingOrders-/pull/6) | `C_Item.GetItemInfo` compatibility and the Retail 12.1.5 interface update. The PR credits the original CurseForge commenter as well. |
| [cohenjw / PR #7](https://github.com/foodmuffin/CraftingOrders-/pull/7) | Optional temporary Auctionator lists, default off, with guarded access to the optional list manager. |
| [ottomansky / PR #5](https://github.com/foodmuffin/CraftingOrders-/pull/5) | Filter-menu Select All/Deselect All, session list tracking and merge/new-list choice. Integration extends this with per-order quantities, atomic tracking, current inventory accounting and preservation of persistent lists. |
| [beleczkia / commit 570ac4b](https://github.com/beleczkia/CraftingOrders-/commit/570ac4bfead04cf4a3d4aba471f6cce32ae251f7) | Adapted the successful-empty-request and failed-item-load guards. The broader EUI restyle is not included because upstream deliberately uses Blizzard styling. |
| [astavitsky](https://github.com/astavitsky/CraftingOrders-) | No commits ahead of upstream at review time. |

Additional preparation scheduling, warning/cache/event improvements, safe merge integration and offline tests are contributed by Merryfett. Existing full material/quality/concentration planning and Blizzard-native detail controls are retained.
