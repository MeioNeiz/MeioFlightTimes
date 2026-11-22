-- Forever tells no flight's length. FlareUI's Flight Timer learns one per pair of ends, so
-- it goes stale when a newly learned flight point changes the route, and knows nothing for a
-- pair not flown yet. Here each flight is cut into legs at the moments the player passes
-- over the flight points on the way (closest approach on the taxi map), and a leg's time is
-- kept per role: take-off or pass-over at its start, landing or pass-over at its end. A
-- through-flight doesn't land at each point, so it is never timed as if it stopped.
-- Estimate for a route: the exact route flown before, else the sum of its legs (a role not
-- timed yet is converted with the learned take-off and landing costs), else FlareUI's time
-- for the two ends, else straight-line distance at the speed learned on that map.

local ADDON, ns = ...
local PREFIX = "|cffb090ffMeioFlightTimes:|r "
local MIN_FLIGHT = 10
local MIN_LEG = 3
local CATCH = 15
local RESUME = 3600
local PASS_YARDS = 200
local AWAY_YARDS = 40
local TICK = 0.25
-- a continent's rough size, for a client without C_Map.GetMapWorldSize
local FALLBACK_MAP_YARDS = 40000

local db
local pending, cur

local function Say(msg) DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg) end

local function Clock(s)
    s = math.max(0, math.floor(s + 0.5))
    return ("%d:%02d"):format(math.floor(s / 60), s % 60)
end
ns.Clock = Clock

local function Round(s) return math.floor(s * 10 + 0.5) / 10 end
local function EdgeKey(a, b) return a .. " > " .. b end
local function PathKey(path) return table.concat(path, " > ") end

-- role of leg i of k: "t"ake-off or "p"ass at its start, "l"anding or "p"ass at its end
local function Role(i, k) return (i == 1 and "t" or "p") .. (i == k and "l" or "p") end
local FLIP = { t = "l", l = "t", p = "p" }
local function ReverseRole(r) return FLIP[r:sub(2, 2)] .. FLIP[r:sub(1, 1)] end
local function Ends(r)
    return r:sub(1, 1) == "t" and 1 or 0, r:sub(2, 2) == "l" and 1 or 0
end

-- extra seconds a take-off adds to a leg against passing over its start (T), and a landing
-- against passing over its end (L), averaged over legs timed both ways
local function Offsets()
    local t, tn, l, ln = 0, 0, 0, 0
    for _, rec in pairs(db.legs) do
        for _, e in ipairs({ "l", "p" }) do
            if rec["t" .. e] and rec["p" .. e] then
                t, tn = t + rec["t" .. e] - rec["p" .. e], tn + 1
            end
        end
        for _, s in ipairs({ "t", "p" }) do
            if rec[s .. "l"] and rec[s .. "p"] then
                l, ln = l + rec[s .. "l"] - rec[s .. "p"], ln + 1
            end
        end
    end
    return tn > 0 and t / tn or 0, ln > 0 and l / ln or 0
end

local function Adjust(from, to, T, L)
    local ft, fl = Ends(from)
    local tt, tl = Ends(to)
    return (tt - ft) * T + (tl - fl) * L
end

local function FlareTimes()
    local g = FlareUI2_DB and FlareUI2_DB.global
    return g and g.flightTimes
end

-- a leg's time in a role, and whether it was timed in exactly that role
local function LegTime(a, b, role, T, L)
    local fwd, rev = db.legs[EdgeKey(a, b)], db.legs[EdgeKey(b, a)]
    if fwd and fwd[role] then return fwd[role], true end
    local best, bestDiff
    local function consider(s, asRole, penalty)
        local ft, fl = Ends(asRole)
        local tt, tl = Ends(role)
        local diff = math.abs(ft - tt) + math.abs(fl - tl) + penalty
        if not bestDiff or diff < bestDiff then
            best, bestDiff = s + Adjust(asRole, role, T, L), diff
        end
    end
    for r, s in pairs(fwd or {}) do consider(s, r, 0) end
    -- the way back usually mirrors the way out, but not always
    for r, s in pairs(rev or {}) do consider(s, ReverseRole(r), 0.5) end
    if best then return best, false end
    -- FlareUI's time for two neighbouring points is their direct flight
    local flare = FlareTimes()
    local s = flare and (flare[EdgeKey(a, b)] or flare[EdgeKey(b, a)])
    if s then return s + Adjust("tl", role, T, L), false end
end

local function MapYards(map)
    local w, h
    if C_Map.GetMapWorldSize then w, h = C_Map.GetMapWorldSize(map) end
    if not (w and w > 0 and h and h > 0) then
        return FALLBACK_MAP_YARDS, FALLBACK_MAP_YARDS
    end
    return w, h
end

local function Distance(map, ax, ay, bx, by)
    local w, h = MapYards(map)
    local dx, dy = (ax - bx) * w, (ay - by) * h
    return math.sqrt(dx * dx + dy * dy)
end

-- straight-line yards per second over the legs timed on this map, pass-over to pass-over
local function Speed(map, pos, T, L)
    local yards, secs = 0, 0
    for key, rec in pairs(db.legs) do
        local a, b = key:match("^(.-) > (.+)$")
        local pa, pb = pos[a], pos[b]
        if pa and pb then
            for r, s in pairs(rec) do
                local cruise = s + Adjust(r, "pp", T, L)
                if cruise > 0 then
                    yards = yards + Distance(map, pa.x, pa.y, pb.x, pb.y)
                    secs = secs + cruise
                end
            end
        end
    end
    return secs > 0 and yards / secs or nil
end

-- seconds for a route { from, ..., to } and how it was found: "flown" (this exact route),
-- "legs", "ends" (FlareUI's time for the two ends) or "rough" (some leg by distance).
-- pos: name -> { x, y } on map, for the distance fallback; may be nil
local function Estimate(path, map, pos)
    local exact = db.paths[PathKey(path)]
    if exact then return exact, "flown" end
    local T, L = Offsets()
    local k, total, missing = #path - 1, 0, {}
    for i = 1, k do
        local s = LegTime(path[i], path[i + 1], Role(i, k), T, L)
        if s then total = total + s else missing[#missing + 1] = i end
    end
    if #missing == 0 then return total, "legs" end
    local flare = FlareTimes()
    local ends = flare and flare[EdgeKey(path[1], path[#path])]
    if ends then return ends, "ends" end
    local speed = pos and map and Speed(map, pos, T, L)
    if not speed then return nil end
    for _, i in ipairs(missing) do
        local pa, pb = pos[path[i]], pos[path[i + 1]]
        if not (pa and pb) then return nil end
        local cruise = Distance(map, pa.x, pa.y, pb.x, pb.y) / speed
        total = total + cruise + Adjust("pp", Role(i, k), T, L)
    end
    return total, "rough"
end
ns.Estimate = Estimate

-- seconds left from passing path[j] to landing, from legs alone; nil if a leg is unknown
local function Remaining(path, j)
    local T, L = Offsets()
    local k, total = #path - 1, 0
    for i = j, k do
        local s = LegTime(path[i], path[i + 1], Role(i, k), T, L)
        if not s then return nil end
        total = total + s
    end
    return total
end

-- the open taxi map

local function TaxiMapID()
    local fm = _G.FlightMapFrame
    if fm and fm:IsShown() and fm.GetMapID then return fm:GetMapID() end
    local map = C_Map.GetBestMapForUnit("player")
    for _ = 1, 10 do
        local info = map and C_Map.GetMapInfo(map)
        if not info then return map end
        if info.mapType <= Enum.UIMapType.Continent or not info.parentMapID
            or info.parentMapID == 0 then
            return map
        end
        map = info.parentMapID
    end
    return map
end

-- slot -> { name, x, y } and name -> the same, for the nodes on map
local function Nodes(map)
    local bySlot, byName = {}, {}
    local ok, list = pcall(C_TaxiMap.GetAllTaxiNodes, map)
    for _, n in ipairs(ok and list or {}) do
        local p = n.position
        if n.slotIndex and p and p.x then
            local node = { name = n.name, x = p.x, y = p.y }
            bySlot[n.slotIndex] = node
            if n.name then byName[n.name] = node end
        end
    end
    return bySlot, byName
end

-- the route to a slot: names and slots from here, via every point on the way
local function Route(slot)
    if not (NumTaxiNodes and GetNumRoutes and TaxiGetNodeSlot) then return end
    local here
    for i = 1, NumTaxiNodes() do
        if TaxiNodeGetType(i) == "CURRENT" then here = i break end
    end
    local hops = GetNumRoutes(slot) or 0
    if not here or here == slot or hops < 1 then return end
    local slots = { here }
    for i = 1, hops do slots[#slots + 1] = TaxiGetNodeSlot(slot, i, false) end
    if slots[#slots] ~= slot then return end
    local path = {}
    for i, s in ipairs(slots) do
        path[i] = TaxiNodeName(s)
        if not path[i] then return end
    end
    return path, slots
end

local function Lookup(slot)
    local path, slots = Route(slot)
    if not path then return end
    local map = TaxiMapID()
    local bySlot, byName = {}, {}
    if map and C_TaxiMap and C_TaxiMap.GetAllTaxiNodes then bySlot, byName = Nodes(map) end
    local seconds, how = Estimate(path, map, byName)
    return { path = path, slots = slots, map = map, bySlot = bySlot, est = seconds,
             how = how }
end

-- FlareUI's Flight Timer bar

local function Flare()
    return FlareUI and FlareUI.ResourceBars and FlareUI.ResourceBars.Flight
end

local function FeedFlare()
    local F, c = Flare(), cur or pending
    local now = F and F.now
    if not (now and c and c.est) then return end
    if now.dest and now.dest ~= c.path[#c.path] then return end
    now.total = c.est
end

local function RefreshFlare()
    local F, bar = Flare(), _G.FlareUI_Resource_flight
    if F and F.now and bar and bar:IsShown() then F.Update(bar) end
end

local function HookFlare()
    local F = Flare()
    if not F or F.flightTimesHooked then return end
    F.flightTimesHooked = true
    -- our own tooltip line replaces FlareUI's, which knows only the two ends
    F.TimeTo = function() return nil end
    local update = F.Update
    F.Update = function(holder, ...)
        FeedFlare()
        return update(holder, ...)
    end
end

-- our own timer bar, when FlareUI's Flight Timer isn't there: the breath bar's look, at the
-- place Edit Mode gives the timer bars (none run on a flight path)

local bar

local function FlareBarOn()
    local F = Flare()
    return F and F.initialized and _G.FlareUI_Resource_flight and true or false
end

local function ShortName(name) return name:match("^([^,]+)") or name end

local function BarTick(self, elapsed)
    local c = cur
    if not c then return end
    local flown = GetTime() - c.start
    local known = c.est and c.est > 0
    self.Bar:SetValue(known and math.min(flown / c.est, 1) or 0)
    self.tick = self.tick + elapsed
    if self.tick < 0.2 then return end
    self.tick = 0
    local text = "|cffffd100" .. ShortName(c.path[#c.path]) .. "|r  "
    if known then
        text = text .. Clock(c.est - flown)
    else
        text = text .. Clock(flown) .. " |cff999999(new route)|r"
    end
    self.Text:SetText(text)
end

local function BuildBar()
    bar = CreateFrame("Frame", "MeioFlightTimesBar", UIParent)
    bar:SetSize(206, 32)
    bar:SetFrameStrata("MEDIUM")
    local timers = _G.MirrorTimerContainer
    if timers then
        bar:SetPoint("TOP", timers, "TOP")
    else
        bar:SetPoint("TOP", UIParent, "TOP", 0, -100)
    end
    local sb = CreateFrame("StatusBar", nil, bar)
    sb:SetSize(195, 13)
    sb:SetPoint("TOP", 0, -2)
    sb:SetMinMaxValues(0, 1)
    local fill = sb:CreateTexture(nil, "ARTWORK")
    fill:SetAtlas("ui-castingbar-filling-applyingcrafting")
    sb:SetStatusBarTexture(fill)
    bar.Bar = sb
    local box = bar:CreateTexture(nil, "BACKGROUND", nil, 0)
    box:SetAtlas("ui-castingbar-textbox")
    box:SetPoint("TOPLEFT", sb, "TOPLEFT")
    box:SetPoint("BOTTOMRIGHT", sb, "BOTTOMRIGHT", 0, -14)
    local bg = bar:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetAtlas("ui-castingbar-background")
    bg:SetPoint("TOPLEFT", sb, "TOPLEFT", -1, 1)
    bg:SetPoint("BOTTOMRIGHT", sb, "BOTTOMRIGHT", 1, -1)
    local border = sb:CreateTexture(nil, "OVERLAY")
    border:SetAtlas("ui-castingbar-frame")
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetPoint("BOTTOMRIGHT", 2, -2)
    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", sb, "BOTTOMLEFT")
    text:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", 0, 2)
    bar.Text = text
    bar.tick = 0
    bar:SetScript("OnUpdate", BarTick)
end

local function ShowBar()
    local want = cur and not FlareBarOn()
    if want and not bar then BuildBar() end
    if not bar then return end
    if want and not bar:IsShown() then bar.tick = 1 end
    bar:SetShown(want and true or false)
    if want then BarTick(bar, 0) end
end

-- a flight under way

local function Track()
    local c = cur
    if not (c and c.map and c.track) or c.next > #c.path - 1 then return end
    local p = C_Map.GetPlayerMapPosition(c.map, "player")
    if not (p and p.x) then return end
    local node = c.pos[c.next]
    if not node then
        c.next, c.best = c.next + 1, nil
        return
    end
    local d, t = Distance(c.map, p.x, p.y, node.x, node.y), GetTime()
    if not c.best or d < c.best then c.best, c.bestAt = d, t end
    if c.best <= PASS_YARDS and d > c.best + AWAY_YARDS then
        c.passed[c.next] = c.bestAt
        c.next, c.best = c.next + 1, nil
        if c.how ~= "flown" then
            local left = Remaining(c.path, c.next - 1)
            if left then
                c.est = c.passed[c.next - 1] - c.start + left
                FeedFlare()
                RefreshFlare()
            end
        end
        return
    end
    -- never came close: already nearer the point after it
    local after = c.pos[c.next + 1]
    if after and Distance(c.map, p.x, p.y, after.x, after.y) < PASS_YARDS then
        c.next, c.best = c.next + 1, nil
    end
end

local function Learn(c, landAt)
    local k = #c.path - 1
    local times = { c.start }
    for i = 2, k do times[i] = c.passed[i] end
    if c.keep then times[k + 1] = landAt end
    for i = 1, k do
        local s, e = times[i], times[i + 1]
        if s and e and e - s >= MIN_LEG and (not c.cut or e <= c.cut) then
            local key = EdgeKey(c.path[i], c.path[i + 1])
            db.legs[key] = db.legs[key] or {}
            db.legs[key][Role(i, k)] = Round(e - s)
        end
    end
    if c.keep and landAt - c.start >= MIN_FLIGHT then
        db.paths[PathKey(c.path)] = Round(landAt - c.start)
    end
end

local ticker
local function Check()
    local onTaxi = UnitOnTaxi("player")
    local t = GetTime()
    if pending and not cur then
        if onTaxi then
            local p = pending
            pending = nil
            cur = { path = p.path, map = p.map, pos = {}, passed = {}, next = 2, start = t,
                    keep = true, est = p.est, how = p.how, stamp = time() }
            for i, s in ipairs(p.slots) do cur.pos[i] = p.bySlot[s] end
            cur.track = cur.map and #cur.path > 2 and C_Map.GetPlayerMapPosition and true
            db.now = cur
            FeedFlare()
            RefreshFlare()
        elseif t - pending.at > CATCH then
            pending = nil
        end
    elseif cur and not onTaxi then
        local c = cur
        cur, db.now = nil, nil
        Learn(c, t)
    elseif cur then
        Track()
    elseif onTaxi and db.now then
        -- after a /reload mid-air: GetTime carries on, a client restart doesn't
        local r = db.now
        if r.start and r.start <= t and r.stamp and time() - r.stamp < RESUME then
            cur = r
            FeedFlare()
            RefreshFlare()
        else
            db.now = nil
        end
    end
    ShowBar()
    local busy = pending or cur
    if busy and not ticker then
        ticker = C_Timer.NewTicker(TICK, Check)
    elseif not busy and ticker then
        ticker:Cancel()
        ticker = nil
    end
end

-- tooltips on the flight map's pins and the old taxi frame's buttons

local function AddTooltipLine(slot)
    local info = slot and db and Lookup(slot)
    if not (info and info.est) or GameTooltip:IsForbidden() then return end
    local text = "Flight time: " .. (info.how == "flown" and "" or "~") .. Clock(info.est)
    if info.how == "rough" then text = text .. " |cff999999(rough: route not flown)|r"
    elseif info.how ~= "flown" then text = text .. " |cff999999(estimate)|r" end
    GameTooltip_AddNormalLine(GameTooltip, text)
    GameTooltip:Show()
end

local function OnTake(slot)
    if not db then return end
    pending = Lookup(slot)
    if pending then
        pending.at = GetTime()
        Check()
    end
end

local function HookTaxi()
    if TakeTaxiNode then hooksecurefunc("TakeTaxiNode", OnTake) end
    if TaxiRequestEarlyLanding then
        hooksecurefunc("TaxiRequestEarlyLanding", function()
            if cur then cur.keep, cur.cut = false, GetTime() end
        end)
    end
    if TaxiNodeOnButtonEnter then
        hooksecurefunc("TaxiNodeOnButtonEnter", function(button)
            if button and TaxiNodeGetType(button:GetID()) == "REACHABLE" then
                AddTooltipLine(button:GetID())
            end
        end)
    end
    EventUtil.ContinueOnAddOnLoaded("Blizzard_FlightMap", function()
        local mixin = _G.FlightMap_FlightPointPinMixin
        if mixin and mixin.OnMouseEnter then
            hooksecurefunc(mixin, "OnMouseEnter", function(pin)
                local data = pin.taxiNodeData
                if data and data.state == Enum.FlightPathState.Reachable then
                    AddTooltipLine(data.slotIndex)
                end
            end)
        end
    end)
end

-- slash

local function Cmd(text) return "|cffffd100" .. text .. "|r" end

local function Help()
    Say("flight times learned per leg, so a route you haven't flown is still timed")
    for _, l in ipairs({
        Cmd("/meioflighttimes stats") .. " - what has been learned so far",
        Cmd("/meioflighttimes forget") .. " - forget every learned time",
    }) do
        DEFAULT_CHAT_FRAME:AddMessage("  " .. l)
    end
end

local function Stats()
    local paths, legs = 0, 0
    for _ in pairs(db.paths) do paths = paths + 1 end
    for _, rec in pairs(db.legs) do for _ in pairs(rec) do legs = legs + 1 end end
    local T, L = Offsets()
    Say(("%d routes flown, %d legs timed; take-off adds %.1fs, landing %.1fs")
        :format(paths, legs, T, L))
end

SLASH_MEIOFLIGHTTIMES1 = "/meioflighttimes"
SLASH_MEIOFLIGHTTIMES2 = "/flighttimes"
SlashCmdList.MEIOFLIGHTTIMES = function(msg)
    local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(%S*)")
    if cmd == "" or cmd == "help" or cmd == "?" then
        Help()
    elseif cmd == "stats" then
        Stats()
    elseif cmd == "forget" then
        if arg == "confirm" then
            db.paths, db.legs, db.now = {}, {}, nil
            Say("every learned time forgotten")
        else
            Say("this forgets every learned time: " .. Cmd("/meioflighttimes forget confirm"))
        end
    else
        Say(("unknown command \"%s\""):format(cmd))
        Help()
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" then
        if name ~= ADDON then return end
        MeioFlightTimesDB = MeioFlightTimesDB or {}
        db = MeioFlightTimesDB
        db.paths = db.paths or {}
        db.legs = db.legs or {}
        ns.db = db
        self:UnregisterEvent("ADDON_LOADED")
        return
    end
    if event == "PLAYER_LOGIN" then
        HookFlare()
        HookTaxi()
        for _, e in ipairs({ "PLAYER_CONTROL_LOST", "PLAYER_CONTROL_GAINED",
            "PLAYER_ENTERING_WORLD", "TAXIMAP_CLOSED" }) do
            pcall(self.RegisterEvent, self, e)
        end
    end
    C_Timer.After(0.2, Check)
end)
