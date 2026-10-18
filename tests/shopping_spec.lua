local function equal(actual, expected, message)
	assert(actual == expected, (message or "mismatch") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end

local function fixture()
	local env = setmetatable({owned = {}, lists = {}, messages = {}, exports = {}, config = {}}, {__index = _G})
	env.Enum = {TradeskillSlotDataType = {ModifiedReagent = 1}}
	env.StaticPopupDialogs = {}
	env.CANCEL, env.UNKNOWN, env.NONE = "Cancel", "Unknown", "None"
	env.GetTime = function() return 100 end
	env.wipe = function(t) for k in pairs(t) do t[k] = nil end end
	env.StaticPopup_Show = function(key, name, count, data) env.popup = {key = key, name = name, count = count, data = data} end
	local ns = {
		CALLER_ID = "CraftingOrders++", DEFAULT_SORT_KEY = "profit",
		GetConfig = function(key) return env.config[key] end,
		GetDatabase = function() return env.config end,
		IsAddonLoaded = function(name) return env.loaded and env.loaded[name] end,
		Print = function(message) assert(message, "missing localized message"); env.messages[#env.messages + 1] = message end,
		Util = {
			GetItemLink = function(id) return "item:" .. tostring(id):match("(%d+)$") end,
			GetItemName = function() return env.itemName end,
			GetProfessionItemQuality = function(id) return tonumber(tostring(id):match("(%d+)$")) % 10 end,
			GetQualityAwareItemCounts = function(id) return env.owned[id] or 0 end,
			GetLocalTimeStamp = function() return "same-minute" end,
			FormatMoney = function(value) return tostring(value) end,
		},
	}
	local function load(source)
		local chunk, err = loadstring(source)
		assert(chunk, err); setfenv(chunk, env); chunk("CraftingOrders++", ns)
	end
	-- The real locale loader is exercised separately by run_tests.py.
	ns.AddLocale = function(_, strings) ns.L = strings end
	load(ENGLISH_SOURCE)
	load(PRICING_SOURCE)
	load(NEW_SOURCE)
	env.ns, env.p, env.pricing = ns, ns.BrowsePane, ns.Pricing
	env.pricing.initialized = true
	env.pricing.activeProvider = {key = "auctionator", name = "Auctionator"}
	local manager = {}
	function manager:GetIndexForName(name) return env.lists[name] and name end
	function manager:GetByIndex(index) return env.lists[index] end
	function manager:FireMetaChangeEvent() env.metaEvents = (env.metaEvents or 0) + 1 end
	env.Auctionator = {Shopping = {ListManager = manager}, API = {v1 = {
		ConvertToSearchString = function(_, term)
			if env.failConversion then error("conversion failure") end
			env.lastTerm = term
			return term.searchString .. ":" .. tostring(term.tier) .. ":" .. term.quantity
		end,
		CreateShoppingList = function(_, name, strings)
			if env.failExport then error("export failure") end
			env.exports[#env.exports + 1] = {name = name, strings = strings}
			env.lists[name] = {data = {}}
		end,
		GetAuctionPriceByItemID = function() return 15 end,
	}}}
	function env.p:IsDontBuyItem(id) return env.excluded and env.excluded[id] end
	return env
end

local function order(id, quantity, itemID)
	return {orderID = id, materialPlan = {entries = {{quantity = quantity, option = {
		itemID = itemID or 11, reagentQuality = (itemID or 11) % 10, name = "Reagent", unitPrice = 15,
	}}}}}
end

local function selectOrders(e, orders)
	e.p.orders, e.p.selectedOrderIDs = orders, {}
	for _, o in ipairs(orders) do e.p.selectedOrderIDs[o.orderID] = true end
end

local function export(e, mode, orders)
	selectOrders(e, orders)
	local entries, _, _, ids = e.p:CollectShoppingEntries(true)
	return e.p:FinalizeShoppingList(mode, entries, ids)
end

local e = fixture()
e.owned[11], e.owned[12] = 4, 100
assert(export(e, "new", {order(1, 10)}))
local name = e.p._lastSessionListName
equal(e.exports[1].strings[1], "Reagent:1:6", "selected quality ownership")
assert(export(e, "merge", {order(2, 10)}))
equal(e.exports[2].name, name)
equal(e.exports[2].strings[1], "Reagent:1:16", "inventory subtracted more than once")
assert(export(e, "merge", {order(2, 10)}))
equal(e.exports[3].strings[1], "Reagent:1:16", "repeat order doubled requirements")
assert(export(e, "merge", {order(2, 3, 13)}))
equal(#e.exports[4].strings, 2, "changed quality did not replace old material plan")
local quantities = {}
for _, entry in ipairs(e.p._FlattenSessionShoppingList(name)) do quantities[entry.itemID] = entry.quantity end
equal(quantities[11], 6); equal(quantities[13], 3)
equal(e.lists[name].data.isTemporary, nil, "temporary lists must default off")
print("PASS: list merges reserve selected-quality inventory once and replace repeated/changed orders")

local e = fixture()
e.owned[11] = 8
assert(export(e, "new", {order(1, 10)}))
-- A selection with no missing reagents on its own still consumes shared stock.
assert(export(e, "merge", {order(2, 5)}))
equal(e.exports[2].strings[1], "Reagent:1:7")
e.owned[11] = 12
assert(export(e, "merge", {order(2, 5)}))
equal(e.exports[3].strings[1], "Reagent:1:3", "current inventory not refreshed")
local previous = e.p._sessionShoppingLists[e.p._lastSessionListName]
e.failExport = true
equal(export(e, "merge", {order(3, 20)}), false)
equal(e.p._sessionShoppingLists[e.p._lastSessionListName], previous, "failed merge committed session data")
e.failExport = false
assert(export(e, "merge", {order(2, 5)}))
equal(e.exports[4].strings[1], "Reagent:1:3", "failed merge leaked requirements")
print("PASS: owned-only selections merge correctly; failed exports leave tracked lists untouched")

local e = fixture()
e.lists["Patron Orders same-minute"] = {data = {userList = true}}
assert(export(e, "new", {order(1, 10)}))
equal(e.p._lastSessionListName, "Patron Orders same-minute (2)")
e.p:ResetSessionShoppingLists()
assert(e.lists["Patron Orders same-minute"].data.userList, "reset deleted persistent list")
assert(export(e, "new", {order(2, 10)}))
equal(e.p._lastSessionListName, "Patron Orders same-minute (3)")
e.Auctionator.Shopping = nil
local a, b = e.p._GenerateNewSessionListName(), e.p._GenerateNewSessionListName()
assert(a ~= b, "fallback names collide")
print("PASS: new lists avoid existing names; resetting tracking preserves saved lists")

local e = fixture()
e.failExport = true
equal(export(e, "new", {order(1, 10)}), false)
equal(e.p._lastSessionListName, nil)
equal(next(e.p._sessionShoppingLists), nil)
e.failExport, e.config.temporaryShoppingLists = false, true
assert(export(e, "new", {order(1, 10)}))
equal(e.lists[e.p._lastSessionListName].data.isTemporary, true)
equal(e.metaEvents, 1)
e.Auctionator.Shopping.ListManager.GetByIndex = function() error("optional API unavailable") end
assert(export(e, "new", {order(2, 10)}), "optional temporary-list API failure broke export")
print("PASS: failed first exports create no tracking; optional temporary-list support is guarded")

local e = fixture()
assert(export(e, "new", {order(1, 10)}))
selectOrders(e, {order(2, 5)})
e.p:CreateShoppingList()
assert(e.popup, "missing merge prompt")
local dialog, data = e.StaticPopupDialogs[e.popup.key], e.popup.data
equal(dialog.noCancelOnEscape, true, "Blizzard Escape must not invoke the New List callback")
dialog.OnCancel(nil, data, "escape")
equal(#e.exports, 1, "escape exported a new list")
e.pricing.activeProvider = {key = "auctioneer"}
dialog.OnAccept(nil, data)
equal(#e.exports, 1, "provider changed underneath popup")
e.pricing.activeProvider = {key = "auctionator"}
e.lists[data.listName] = nil
dialog.OnAccept(nil, data)
equal(#e.exports, 1, "deleted list resurrected by stale popup")
equal(e.p._lastSessionListName, nil)
e.p:CreateShoppingList()
equal(#e.exports, 2)
e.p:CreateShoppingList()
dialog.OnCancel(nil, e.popup.data, "clicked")
equal(#e.exports, 3, "New List did not create a separate list")
assert(e.exports[2].name ~= e.exports[3].name)
print("PASS: merge prompt handles cancellation, provider changes, removed lists and New List")

local e = fixture()
selectOrders(e, {order(1, 10), order(2, 2, 12)})
e.excluded = {[11] = true}
local entries, selected, skipped = e.p:CollectShoppingEntries()
equal(#entries, 1); equal(selected, 2); equal(skipped, 1); equal(entries[1].itemID, 12)
e.pricing.activeProvider = nil
local ok = e.pricing:ExportShoppingList(entries)
equal(ok, false, "missing provider should return an error")
e.pricing.activeProvider = {key = "auctioneer"}
local snatches = {}
e.AucAdvanced = {API = {GetMarketValue = function() return 15 end}, Modules = {Util = {SearchUI = {Searchers = {
	Snatch = {Private = {frame = {}}, AddSnatch = function(link, limit) snatches[#snatches + 1] = {link, limit} end},
}}}}}
e.p:CreateShoppingList()
equal(#snatches, 1); equal(snatches[1][1], "item:12"); equal(snatches[1][2], 15)
equal(e.popup, nil, "Auctioneer should not prompt for named-list merging")
equal(next(e.p._sessionShoppingLists), nil)
print("PASS: Don't Buy exclusions, no-provider errors and Auctioneer Snatch behavior are preserved")

local e = fixture()
e.p.orders = {{orderID = 1}, {orderID = 2}}
e.p.selectedOrderIDs = {[99] = true} -- filtered-out selection must remain unchanged
e.p.rows = {{order = e.p.orders[1], checkbox = {SetChecked = function(_, value) e.checked = value end}}}
function e.p:UpdateScrollBox() end
function e.p:UpdateToolbar() end
e.p:ToggleSelectAll()
equal(e.p:AreAllVisibleOrdersSelected(), true); equal(e.checked, true)
e.p:ToggleSelectAll()
equal(e.p.selectedOrderIDs[1], nil); equal(e.p.selectedOrderIDs[99], true); equal(e.checked, false)
print("PASS: bulk selection updates visible checkboxes and respects filtered-out orders")

local e = fixture()
local entries = {{itemID = 11, name = "Reagent", quantity = 2}, {itemID = 12, quantity = 1}}
equal(e.pricing:CreateAuctionatorShoppingList(entries, "test"), false)
equal(#e.exports, 0, "uncached item silently created a partial list")
entries[2].name, e.failConversion = "Other", true
equal(e.pricing:CreateAuctionatorShoppingList(entries, "test"), false)
equal(#e.exports, 0, "failed conversion silently created a partial list")
print("PASS: item-name and search-conversion failures abort before changing an Auctionator list")
