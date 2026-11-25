-- Forever tells no flight's length. FlareUI's Flight Timer learns one per pair of ends, so
-- it goes stale when a newly learned flight point changes the route, and knows nothing for a
-- pair not flown yet. Here each flight is cut into legs at the moments the player passes
-- over the flight points on the way (closest approach on the taxi map), and a leg's time is
-- kept per role: take-off or pass-over at its start, landing or pass-over at its end. A
-- through-flight doesn't land at each point, so it is never timed as if it stopped.
-- Estimate for a route: the exact route flown before, else the sum of its legs (a role not
-- timed yet comes from the game's own flight paths, Data.lua, at the speed learned from the
-- player's flights, so Frequent Flier counts), else FlareUI's time for the two ends, else
-- straight-line distance at the speed learned on that map.

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
-- { name, faction bits, continent, world x, world y }
---@type table<integer, [string, integer, integer, number, number]>
local NODES = ns.TAXI_NODES or {}
local LEGS = ns.TAXI_LEGS or {}
local ROLE_INDEX = { tl = 1, tp = 2, pl = 3, pp = 4 }
-- learnable only by druids
local DRUID_ONLY = { [62] = true, [63] = true }
local MIN_SAVING = 60

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

-- the game's flight points by name; Alliance and Horde each have their own at shared towns
local idsByName = {}
for id, n in pairs(NODES) do
    idsByName[n[1]] = idsByName[n[1]] or {}
    table.insert(idsByName[n[1]], id)
end

local function Faction()
    local f = UnitFactionGroup("player")
    return f == "Alliance" and 1 or f == "Horde" and 2 or 3
end

local function NodeID(name)
    local list = name and idsByName[name]
    if not list then return end
    local mine = Faction()
    for _, id in ipairs(list) do
        if bit.band(NODES[id][2], mine) ~= 0 then return id end
    end
end
ns.NodeID = NodeID

-- learned time over built-in time, from whole flights; Frequent Flier makes it ~0.8
local function Scale() return db.scale or 1 end

local function BuiltLeg(a, b, role)
    local ia, ib = NodeID(a), NodeID(b)
    local rec = ia and ib and LEGS[ia] and LEGS[ia][ib]
    return rec and rec[ROLE_INDEX[role]] * Scale()
end

-- a leg's time in a role, and whether it was timed in exactly that role
local function LegTime(a, b, role, T, L)
    local fwd, rev = db.legs[EdgeKey(a, b)], db.legs[EdgeKey(b, a)]
    if fwd and fwd[role] then return fwd[role], true end
    local built = BuiltLeg(a, b, role)
    if built then
        -- timed in another role: the game's path tells what the role changes
        for r, s in pairs(fwd or {}) do return s + built - BuiltLeg(a, b, r), false end
        return built, false
    end
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
        local built = 0
        for i = 1, k do
            local ia, ib = NodeID(c.path[i]), NodeID(c.path[i + 1])
            local rec = ia and ib and LEGS[ia] and LEGS[ia][ib]
            if not rec then built = nil break end
            built = built + rec[ROLE_INDEX[Role(i, k)]]
        end
        if built and built > 0 then
            local ratio = math.max(0.5, math.min(1.5, (landAt - c.start) / built))
            db.scale = db.scale and db.scale * 0.5 + ratio * 0.5 or ratio
            db.scale = math.floor(db.scale * 1000 + 0.5) / 1000
        end
    end
end

-- set at PLAYER_ENTERING_WORLD: whether it was a /reload (GetTime and the flight carry on
-- unbroken) or a login (the time logged out is in GetTime but not in the flight)
local enteredAt, enteredByReload = 0, false

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
        cur.seen = t
        Track()
    elseif onTaxi and db.now then
        -- after a /reload mid-air: GetTime carries on, a client restart doesn't. After a relog
        -- the time logged out is no flight time: only legs done before it are learned, and
        -- the countdown picks up where it stopped.
        local r = db.now
        if r.start and r.start <= t and r.stamp and time() - r.stamp < RESUME then
            cur = r
            if not enteredByReload then
                local seen = r.seen or r.start
                cur.keep, cur.cut = false, math.min(cur.cut or seen, seen)
                if cur.est then cur.est = cur.est + t - seen end
                cur.best = nil
            end
            cur.seen = t
            FeedFlare()
            RefreshFlare()
        else
            db.now = nil
        end
    elseif db.now and not onTaxi and not pending and t - enteredAt > 10 then
        db.now = nil -- landed while logged out (or a flight never seen to end)
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

-- Detour hint: Forever's routes go round the houses while a flight point on the way is
-- unlearned. Shortest route in time over the points known plus one unlearned one, legs as
-- Estimate times them; the server's own routing is assumed to take the quickest.

local function Quickest(from, to, usable, T, L)
    local dist, prev, done = { [from] = 0 }, {}, {}
    while true do
        local u, du
        for id, d in pairs(dist) do
            if not done[id] and (not du or d < du) then u, du = id, d end
        end
        if not u or u == to then break end
        done[u] = true
        for v in pairs(LEGS[u] or {}) do
            if usable[v] and not done[v] then
                local role = (u == from and "t" or "p") .. (v == to and "l" or "p")
                local s = LegTime(NODES[u][1], NODES[v][1], role, T, L)
                if s and (not dist[v] or du + s < dist[v]) then dist[v], prev[v] = du + s, u end
            end
        end
    end
    return dist[to], prev
end

local function KnownIDs()
    local known = {}
    for i = 1, NumTaxiNodes and NumTaxiNodes() or 0 do
        local id = NodeID(TaxiNodeName(i))
        if id then known[id] = true end
    end
    return known
end

-- the unlearned point that makes info's route quickest: id, seconds with it, seconds saved
local function Detour(info)
    local from, to = NodeID(info.path[1]), NodeID(info.path[#info.path])
    if not (from and to and info.est) then return end
    local known = KnownIDs()
    known[from], known[to] = true, true
    local T, L = Offsets()
    local base = Quickest(from, to, known, T, L)
    base = math.min(base or info.est, info.est)
    local continent, mine = NODES[from][3], Faction()
    local druid = select(2, UnitClass("player")) == "DRUID"
    local bestID, bestTime
    for id, n in pairs(NODES) do
        if not known[id] and n[3] == continent and bit.band(n[2], mine) ~= 0
            and (druid or not DRUID_ONLY[id]) then
            known[id] = true
            local s, prev = Quickest(from, to, known, T, L)
            known[id] = nil
            local via, at = false, prev and prev[to]
            while at do
                if at == id then via = true break end
                at = prev[at]
            end
            if s and via and (not bestTime or s < bestTime) then bestID, bestTime = id, s end
        end
    end
    if bestID and base - bestTime >= MIN_SAVING and base - bestTime >= base * 0.1 then
        return bestID, bestTime, base - bestTime
    end
end
ns.Detour = Detour

-- tooltips on the flight map's pins and the old taxi frame's buttons

local function AddTooltipLine(slot)
    local info = slot and db and Lookup(slot)
    if not (info and info.est) or GameTooltip:IsForbidden() then return end
    local text = "Flight time: " .. (info.how == "flown" and "" or "~") .. Clock(info.est)
    if info.how == "rough" then text = text .. " |cff999999(rough: route not flown)|r"
    elseif info.how ~= "flown" then text = text .. " |cff999999(estimate)|r" end
    GameTooltip_AddNormalLine(GameTooltip, text)
    local id, with, saved = Detour(info)
    if id then
        local name = NODES[id][1]:gsub(", ", " (", 1)
        if name ~= NODES[id][1] then name = name .. ")" end
        -- 10 s steps: an estimate shouldn't look exact
        local function Near(s) return Clock(math.floor(s / 10 + 0.5) * 10) end
        GameTooltip_AddColoredLine(GameTooltip, ("Learn %s: ~%s, %s faster")
            :format(name, Near(with), Near(saved)), GREEN_FONT_COLOR)
    end
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
f:SetScript("OnEvent", function(self, event, name, isReload)
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
    if event == "PLAYER_ENTERING_WORLD" then
        enteredAt, enteredByReload = GetTime(), isReload and true or false
        C_Timer.After(10.5, Check)
    end
    C_Timer.After(0.2, Check)
end)
