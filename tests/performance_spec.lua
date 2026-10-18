local function equal(a, b, message)
	assert(a == b, (message or "mismatch") .. ": " .. tostring(a) .. " ~= " .. tostring(b))
end

local function fixture(source, worker)
	local env = setmetatable({now = 0, operations = 0, errors = {}, frames = {}, timers = {}}, {__index = _G})
	env.Enum = {TradeskillSlotDataType = {ModifiedReagent = 1}, RecipeRequirementType = {}}
	env.NORMAL_FONT_COLOR = {r = 1, g = 1, b = 1}
	env.DISABLED_FONT_COLOR = {r = .5, g = .5, b = .5}
	env.UNKNOWN = "unknown"
	env.CANCEL = "Cancel"
	env.StaticPopupDialogs = {}
	env.strtrim = function(s) return s:match("^%s*(.-)%s*$") end
	env.GetTime = function() return env.now / 1000 end
	env.debugprofilestop = function() return env.now end
	env.geterrorhandler = function() return function(e) env.errors[#env.errors + 1] = e end end
	env.CreateFrame = function()
		local frame = {scripts = {}}
		function frame:SetScript(name, fn) self.scripts[name] = fn end
		env.frames[#env.frames + 1] = frame
		return frame
	end
	env.C_Timer = {After = function(delay, fn)
		env.timers[#env.timers + 1] = {at = env.now + delay * 1000, fn = fn}
	end}
	env.securecall = function(fn, ...) return fn(...) end
	env.C_Item = {
		GetItemInfo = function() return "Reagent", nil, 2 end,
		GetItemInfoInstant = function(id) return id, "", "", "", 123 end,
		IsItemDataCachedByID = function(id) return not (env.missing and env.missing[id]) end,
	}
	env.GetItemInfo = env.C_Item.GetItemInfo -- historical upstream baseline only
	env.C_Spell = {GetSpellName = function() return "Product" end, GetSpellTexture = function() return 123 end}
	env.C_StringUtil = {StripHyperlinks = function(s) return s end}
	env.C_Texture = {GetAtlasInfo = function() return {width = 16, height = 16} end}
	env.CreateAtlasMarkup = function() return "" end
	env.C_CurrencyInfo = {GetCurrencyInfo = function() return {quantity = 100} end}
	env.recipe = {recipeID = 1, skillLineAbilityID = 1, learned = true, qualityIDs = {1, 2, 3}}
	env.schematic = {reagentSlotSchematics = {}}
	local function operation(_, reagents)
		env.operations = env.operations + 1
		env.now = env.now + .2 -- a simulated native API cost, in milliseconds
		local score = 0
		for _, r in ipairs(reagents or {}) do score = score + (r.itemID % 10) * r.quantity end
		return {craftingQuality = math.min(3, 1 + math.floor(score / 10)), concentrationCost = 100 - score, concentrationCurrencyID = 1}
	end
	env.C_TradeSkillUI = {
		GetRecipeInfoForSkillLineAbility = function() return env.recipe end,
		GetRecipeInfo = function() return env.recipe end,
		GetRecipeSchematic = function() return env.schematic end,
		GetRecipeOutputItemData = function() return {itemID = 99} end,
		GetCraftingOperationInfoForOrder = operation,
		GetCraftingOperationInfo = operation,
	}
	local callbacks = {}
	local ns = {
		L = setmetatable({}, {__index = function(_, k) return k end}),
		DEFAULT_SORT_KEY = "profit", ORDER_TYPE_NPC = 3,
		RegisterEvent = function(name, fn) callbacks[name] = fn end,
		GetConfig = function() return nil end,
		Util = {
			GetItemLink = function(id) return "item:" .. id end,
			GetItemName = function() return "Reagent" end,
			GetProfessionItemQuality = function(item) return (tonumber(tostring(item):match("(%d+)$")) or 0) % 10 end,
			GetQualityAwareItemCounts = function() return 9, 0, 9 end,
			GetItemCount = function() return 9 end,
		},
		Pricing = {GetPriceInfo = function(_, item, count)
			local price = (tonumber(tostring(item):match("(%d+)$")) or 1) % 10 * 10
			return {unitPrice = price, totalPrice = price * (count or 1), state = "priced", isMarketable = true}
		end},
	}
	local function load(text)
		local chunk, err = loadstring(text)
		assert(chunk, err)
		setfenv(chunk, env)
		chunk("CraftingOrders++", ns)
	end
	if worker then load(WORK_SOURCE) end
	load(source .. [[
ns.test = {PrepareOrder = PrepareOrder, variants = BuildSlotFillVariants,
 lowest = BuildLowestMaterialPlan, compare = CompareMaterialPlanPreference,
 fingerprint = BuildOrderFingerprint}
]])
	env.ns, env.callbacks = ns, callbacks
	function env:step()
		local start = self.now
		for _, frame in ipairs(self.frames) do
			if frame.scripts.OnUpdate then frame.scripts.OnUpdate(frame, .016) end
		end
		self.maxSlice = math.max(self.maxSlice or 0, self.now - start)
	end
	function env:drain()
		local frames = 0
		while self.ns.PreparationWork.job do
			self:step(); frames = frames + 1
			assert(frames < 20000, "work never completed")
		end
		equal(#self.errors, 0, "worker error: " .. tostring(self.errors[1]))
		return frames
	end
	return env
end

local function slot(index, quantity)
	return {slotIndex = index, dataSlotIndex = index, dataSlotType = 1, required = true,
		quantityRequired = quantity, reagents = {{itemID = index * 10 + 1}, {itemID = index * 10 + 2}, {itemID = index * 10 + 3}}}
end

local function summary(data)
	local parts = {tostring(data.profitValue), tostring(data.materialCost), tostring(data.materialCostKnown),
		tostring(data.materialCostComplete), tostring(data.qualityRequirement.state), tostring(data.concentration and data.concentration.currentCost)}
	local entries = {}
	for _, entry in ipairs(data.materialPlan.entries) do entries[#entries + 1] = entry.option.itemID .. ":" .. entry.quantity end
	table.sort(entries)
	return table.concat(parts, "|") .. "|" .. table.concat(entries, ",")
end

-- Full order calculations must retain their prices, chosen materials, quality
-- state and concentration estimates while yielding through deep searches.
for _, required in ipairs({0, 1, 2, 3, 4, 6}) do
	local old, new = fixture(OLD_SOURCE), fixture(NEW_SOURCE, true)
	old.schematic.reagentSlotSchematics = {slot(1, 4), slot(2, 4)}
	new.schematic.reagentSlotSchematics = {slot(1, 4), slot(2, 4)}
	local raw = {orderID = 10, skillLineAbilityID = 1, minQuality = required, tipAmount = 5000}
	local expected = old.ns.test.PrepareOrder(raw)
	local actual
	new.ns.PreparationWork:Start(function() return new.ns.test.PrepareOrder(raw) end,
		function() return true end, function(result) actual = result end)
	local frames = new:drain()
	assert(actual, "missing order result")
	equal(summary(actual), summary(expected), "order result for quality " .. required)
	equal(actual.unknownRecipeTooltip, nil, "known recipes should not build unknown-recipe tooltips")
	assert(new.maxSlice <= 2.21, "simulated API slice exceeded budget")
	if required == 6 then
		assert(frames > 10, "deep search did not yield")
		print(string.format("Simulated deep-search native work: original %.1f ms in one call; patched largest frame slice %.1f ms across %d frames", old.now, new.maxSlice, frames))
	end
end
print("PASS: full order results match original across six quality cases; deep search yields within budget")

-- Exhaustively compare the new linear lowest-fill shortcut to the original
-- combinatorial solver across mixed qualities, unknown prices and exclusions.
math.randomseed(8241)
local old, new = fixture(OLD_SOURCE), fixture(NEW_SOURCE, true)
for trial = 1, 400 do
	local options = {}
	for n = 1, math.random(1, 4) do
		local state = ({"priced", "no_data", "not_marketable"})[math.random(1, 3)]
		options[n] = {itemID = n, reagentQuality = math.random(0, 3), score = math.random(-10, 10),
			priceState = state, unitPrice = state == "priced" and math.random(1, 30) or nil}
	end
	local s = {options = options, quantityRequired = math.random(1, 6), dataSlotType = 1, dataSlotIndex = 1, required = true}
	local variants = old.ns.test.variants(s, false)
	local result = new.ns.test.lowest({mutableSlots = {s}, operationReagents = {}})
	assert(not old.ns.test.compare(variants[1], result) and not old.ns.test.compare(result, variants[1]), "lowest-fill objective changed")
end
print("PASS: 400 randomized lowest-fill cases match original exhaustive objective")

local e = fixture(NEW_SOURCE, true)
local work = e.ns.PreparationWork
local data = {}
for n = 1, 1200 do data[n] = {value = (n * 37) % 1201} end
work:Start(function() work:Sort(data, function(a,b) return a.value < b.value end); return data end,
	function() return true end, function() end)
assert(e:drain() > 10, "sort did not yield")
for n = 2, #data do assert(data[n-1].value <= data[n].value, "sort order broken") end
print("PASS: large variant sorting is cooperative and correctly ordered")

local e = fixture(NEW_SOURCE, true)
e.schematic.reagentSlotSchematics = {slot(1, 4), slot(2, 4)}
local p = e.ns.BrowsePane
local raw = {orderID = 10, skillLineAbilityID = 1, minQuality = 6}
local warnings = p:RefreshDetailWarningOrderData(raw)
assert(warnings and warnings.slotMap[1].options[1], "warning slot options missing")
equal(e.operations, 0, "price warnings must not simulate crafting")
equal(p:RefreshDetailWarningOrderData(raw), warnings, "warning cache reuse")
p:InitializeEvents()
p.detailWarningDataDirty = nil
e.callbacks.ITEM_DATA_LOAD_RESULT(nil, 99999)
equal(p.detailWarningDataDirty, nil, "unrelated item invalidated warnings")
warnings.unresolvedItemIDs[11] = true
function p:IsDetailWarningVisible() return false end
e.callbacks.ITEM_DATA_LOAD_RESULT(nil, 11)
equal(p.detailWarningDataDirty, true, "relevant item did not invalidate warnings")
print("PASS: warning refreshes skip quality searches and ignore unrelated item events")

local e = fixture(NEW_SOURCE, true)
local optional = slot(3, 1)
optional.required = false
e.schematic.reagentSlotSchematics = {optional}
e.missing = {[31] = true}
local warnings = e.ns.BrowsePane:RefreshDetailWarningOrderData({orderID = 10, skillLineAbilityID = 1})
equal(warnings.unresolvedItemIDs[31], true, "uncached optional reagent was not tracked")
equal(e.operations, 0)
print("PASS: warnings track uncached optional reagents without quality simulation")

-- Exercise actual pane scheduling with cheap synthetic orders and expensive
-- preparation. Expose the local PrepareOrder upvalue only inside this test VM.
local function paneFixture()
	local e = fixture(NEW_SOURCE, true)
	local p = e.ns.BrowsePane
	p.root = {shown = true, IsShown = function(self) return self.shown end}
	e.profession, e.prepared, e.renders = 1, 0, 0
	e.raw = {{orderID = 1}, {orderID = 2}}
	function p:GetCurrentProfessionID() return e.profession end
	function p:GetVisibleRawOrders() return e.raw end
	function p:UpdateEmptyState() end
	function p:HideAllRows() end
	function p:MaybeRequestOrders() end
	function p:UpdateHeaderArrow() end
	function p:UpdateToolbar() end
	function p:RenderRows() e.renders = e.renders + 1 end
	for index = 1, 40 do
		local name = debug.getupvalue(p.RebuildPreparedOrders, index)
		if not name then break end
		if name == "PrepareOrder" then
			debug.setupvalue(p.RebuildPreparedOrders, index, function(raw)
				e.prepared = e.prepared + 1
				for n = 1, 100 do e.ns.PreparationWork:Checkpoint() end
				return {orderID = raw.orderID, product = {plainLabel = tostring(raw.orderID)},
					unresolvedItemIDs = {}, hasUnresolvedItemData = false}
			end)
		end
	end
	return e, p
end

local e, p = paneFixture()
p.needsRebuild = true
p:ProcessPendingRefresh()
equal(#p.allOrders, 0, "partial rows committed")
e:step()
equal(#p.allOrders, 0, "suspended rows committed")
e:drain()
equal(#p.allOrders, 2, "completed snapshot missing")
p:ProcessPendingRefresh()
equal(e.renders, 1, "completed snapshot not rendered")
equal(e.prepared, 2)
p.needsRebuild = true; p:ProcessPendingRefresh(); e:drain()
equal(e.prepared, 2, "unchanged orders recalculated")
p.preparedOrderCache[1].hasUnresolvedItemData = true
p.hasUnresolvedItemData = true
p:MarkDirty("item-data"); p:ProcessPendingRefresh(); e:drain()
equal(e.prepared, 3, "item arrival should recalculate only unresolved order")
print("PASS: pane commits complete snapshots, reuses cache and selectively refreshes item data")

local e, p = paneFixture()
p.needsRebuild = true; p:ProcessPendingRefresh(); e:step()
p:MarkDirty("pricing-db")
equal(e.ns.PreparationWork.job, nil, "invalidated work still scheduled")
equal(#p.allOrders, 0, "invalidated snapshot committed")
p:ProcessPendingRefresh(); e:drain(); equal(#p.allOrders, 2)
p.needsRebuild = true; p:ProcessPendingRefresh(); e.profession = 2; e:step()
equal(p.preparationPending, nil, "profession switch left stuck worker")
equal(p.ordersProfession, 1, "stale profession result committed")
p:ProcessPendingRefresh(); e:drain(); equal(p.ordersProfession, 2)
p.needsRebuild = true; p:ProcessPendingRefresh(); p.root.shown = false; e:step()
equal(p.preparationPending, nil, "hidden pane left stuck worker")
equal(e.ns.PreparationWork.job, nil)
print("PASS: pricing changes, profession switches and hidden panels discard stale work")

local e = fixture(NEW_SOURCE, true)
local p = e.ns.BrowsePane
local fired = 0
function p:MarkDirty() fired = fired + 1 end
for n = 1, 5000 do p:ScheduleTrailingDirty("item-data", .75) end
equal(#e.timers, 1, "event burst created thousands of timers")
e.now = 750; e.timers[1].fn(); equal(fired, 1)
p:ScheduleTrailingDirty("item-data", .75)
e.now = 1000; p:ScheduleTrailingDirty("item-data", .75)
e.now = 1500; e.timers[2].fn(); equal(fired, 1)
e.now = 1750; e.timers[3].fn(); equal(fired, 2)
p:ScheduleTrailingDirty("item-data", .75)
p.trailingDirtyTokens = nil; e.now = 2500; e.timers[4].fn(); equal(fired, 2)
print("PASS: 5,000-event burst coalesces into one timer; trailing delay and cancellation work")

local e = fixture(NEW_SOURCE, true)
local completed, failed = false, false
e.ns.PreparationWork:Start(function() error("expected fixture failure") end,
	function() return true end, function() completed = true end, function() failed = true end)
e:step()
equal(e.ns.PreparationWork.job, nil); equal(completed, false); equal(failed, true); equal(#e.errors, 1)
print("PASS: worker errors are reported, stopped and never committed")

local e = fixture(NEW_SOURCE, true)
local valid, invalidated, completed = true, false, false
e.ns.PreparationWork:Start(function() valid = false; return {} end,
	function() return valid end, function() completed = true end, function(stale) invalidated = stale end)
e:step()
equal(completed, false); equal(invalidated, true); equal(e.ns.PreparationWork.job, nil)
print("PASS: invalidation during the final calculation cannot leave a pending worker")
