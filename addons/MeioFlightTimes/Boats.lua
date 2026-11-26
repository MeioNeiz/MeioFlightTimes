-- Boats and zeppelins: when each leaves each dock. A vessel runs a fixed cycle (BoatData.lua,
-- from Nauticus's measurements); only where in the cycle it is now has to be learned. The
-- player is carried when their position moves while they aren't moving themselves; the
-- moment a ride starts at a dock (or stops at one) pins that route's cycle. Anchors are kept
-- in server time, so they hold across relogs, reboots and characters.
-- Cycle maths after NauticusClassicResurrected (MIT; README credits).

local ADDON, ns = ...
local PREFIX = "|cffb090ffMeioFlightTimes:|r "
local BOATS = ns.BOATS or {}
local TICK = 0.5
local NEAR = 150
-- a pier holds the recorded point within a vessel's length; two piers at one town lie 64+
-- yards apart
local AT_PIER = 40
local CARRIED_SPEED = 3
local MAX_SPEED = 80
local STILL_SPEED = 0.5
local RIDE_MIN = 8
local ARRIVE_AFTER = 30
local RIDE_LOST = 60
local SOON = 30
local WIDTH = 250
local GREEN, GOLD, MUTED, RED = "|cff80ff80", "|cffffd100", "|cff999999", "|cffff8080"

local canaccess = canaccessvalue or function() return true end

local db
local panel, broker
local rows = {}

local function Say(msg) DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg) end
local function Clock(s) return ns.Clock(s) end

-- server time with GetTime's resolution: GetServerTime ticks once a second, so the offset
-- is set again at each tick until one has been seen
local offset, offsetExact, lastServer
local function Now()
    local server = GetServerTime()
    if not offsetExact then
        if lastServer and server ~= lastServer then
            offset, offsetExact = server - GetTime(), true
        elseif not offset then
            offset = server - GetTime()
        end
        lastServer = server
    end
    return GetTime() + offset
end
ns.BoatNow = Now

local function Dock(id, i)
    local d = BOATS[id][4][i]
    return { place = d[1], zone = d[2], cont = d[3], x = d[4], y = d[5], arrive = d[6],
        leave = d[7] }
end

local function Kind(id) return BOATS[id][1] == "Zeppelin" and "zeppelin" or "boat" end

local function NextDock(id, i)
    local list = BOATS[id][4]
    return i % #list + 1
end

local function Mine(id)
    local f = BOATS[id][2]
    return f == "Neutral" or f == UnitFactionGroup("player")
end

-- seconds into the cycle, or nil while not learned
local function Cycle(id)
    local rec = db.boats[id]
    if not (rec and rec.at) then return end
    return (Now() - rec.at) % BOATS[id][3]
end

-- for dock i of route id: docked (true/false), seconds until it leaves, seconds until it
-- arrives (0 when docked)
local function DockState(id, i)
    local c = Cycle(id)
    if not c then return end
    local d, rtt = BOATS[id][4][i], BOATS[id][3]
    local arrive, leave = d[6], d[7]
    if c >= arrive and c < leave then return true, leave - c, 0 end
    return false, (leave - c) % rtt, (arrive - c) % rtt
end
ns.DockState = DockState

local function Anchor(id, at, src)
    local rec = db.boats[id] or {}
    local rtt = BOATS[id][3]
    if rec.at and rec.src ~= "nauticus" then
        rec.drift = ((at - rec.at + rtt / 2) % rtt) - rtt / 2
    end
    rec.at, rec.src, rec.n = at, src, (rec.n or 0) + 1
    db.boats[id] = rec
end
ns.BoatAnchor = Anchor

-- Nauticus keeps "since" in GetTime of its last session, with that session's GetTime and
-- clock time saved together: enough to find the clock time of cycle 0
local function ImportNauticus()
    local g = NauticusClassic5DB and NauticusClassic5DB.global
    local known = g and g.knownCycles
    if not (known and g.uptime and g.timestamp) then return 0 end
    local skew = GetServerTime() - time()
    local n = 0
    for id, k in pairs(known) do
        local rec = db.boats[id]
        if BOATS[id] and k.since and (not rec or rec.src == "nauticus") then
            Anchor(id, g.timestamp - g.uptime + k.since + skew, "nauticus")
            n = n + 1
        end
    end
    return n
end
ns.ImportNauticus = ImportNauticus

-- the pier the player stands at: nearest recorded point within AT_PIER on this continent
local function Pier(x, y, cont, only)
    local best, bid, bi
    for id, r in pairs(BOATS) do
        if not only or only == id then
            for i, d in ipairs(r[4]) do
                if d[3] == cont then
                    local dist = math.sqrt((x - d[4]) ^ 2 + (y - d[5]) ^ 2)
                    if dist < AT_PIER and (not best or dist < best) then best, bid, bi = dist, id, i end
                end
            end
        end
    end
    return bid, bi
end

-- docks within NEAR of the player on routes for their faction, nearest first
local function NearDocks(x, y, cont)
    local out = {}
    for id, r in pairs(BOATS) do
        if Mine(id) then
            for i, d in ipairs(r[4]) do
                if d[3] == cont then
                    local dist = math.sqrt((x - d[4]) ^ 2 + (y - d[5]) ^ 2)
                    if dist < NEAR then out[#out + 1] = { id = id, i = i, dist = dist } end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

-- riding

local last, still, ride
local stillAt -- { id, i } of the pier the player stood still at

local function ResetTrack() last = nil end

local function Carried(speed)
    return speed > CARRIED_SPEED and speed < MAX_SPEED and not IsPlayerMoving()
        and not IsFalling() and not IsSwimming() and not UnitOnTaxi("player")
end

local function Track()
    -- UnitPosition gives world X first, as BoatData keeps them
    local x, y, _, cont = UnitPosition("player")
    if not x then ResetTrack() return end
    local t = GetTime()
    local prev = last
    last = { x = x, y = y, cont = cont, t = t }
    if not prev or prev.cont ~= cont or t - prev.t > 3 * TICK then return x, y, cont end
    local speed = math.sqrt((x - prev.x) ^ 2 + (y - prev.y) ^ 2) / (t - prev.t)
    if Carried(speed) then
        still = nil
        if not ride then
            ride = { start = prev.t, from = stillAt }
        end
        ride.moved = t
        local r = ride
        if r.from and not r.left and t - r.start >= RIDE_MIN then
            r.left = true
            local d = Dock(r.from.id, r.from.i)
            Anchor(r.from.id, r.start + offset - d.leave, "ride")
        end
    elseif speed < STILL_SPEED then
        still = still or prev.t
        local id, i = Pier(x, y, cont, ride and ride.from and ride.from.id)
        if not id and ride then id, i = Pier(x, y, cont) end
        if ride and t - still >= 2 * TICK then
            if id and ride.moved - ride.start >= ARRIVE_AFTER then
                Anchor(id, still + offset - Dock(id, i).arrive, "ride")
            end
            ride = nil
        end
        stillAt = id and { id = id, i = i } or nil
    else
        -- walking about: not waiting on a deck; on a ride, walking the deck (or a loading
        -- screen mid-crossing) doesn't end it
        still, stillAt = nil, nil
        if ride and t - ride.moved > RIDE_LOST then ride = nil end
    end
    return x, y, cont
end

-- dock panel: a bar per route leaving the pier the player is near

local function Text(id, i)
    local to = Dock(id, NextDock(id, i)).place
    local head = GOLD .. to .. "|r  "
    local docked, leaves, arrives = DockState(id, i)
    if docked == nil then return head .. MUTED .. "not timed yet: ride it once|r", 0 end
    ---@cast leaves number
    ---@cast arrives number
    local dwell = BOATS[id][4][i][7] - BOATS[id][4][i][6]
    if docked then
        local col = leaves <= SOON and RED or GREEN
        return head .. col .. Kind(id) .. " leaves in " .. Clock(leaves) .. "|r", leaves / dwell
    end
    return head .. Kind(id) .. " due " .. Clock(arrives) .. MUTED .. ", leaves "
        .. Clock(leaves) .. "|r", 1 - arrives / (BOATS[id][3] - dwell)
end

local function Row(n)
    if rows[n] then return rows[n] end
    local row = CreateFrame("Frame", nil, panel)
    row:SetSize(WIDTH + 11, 30)
    row:SetPoint("TOP", panel, "TOP", 0, -(n - 1) * 30)
    local sb = CreateFrame("StatusBar", nil, row)
    sb:SetSize(WIDTH, 13)
    sb:SetPoint("TOP", 0, -2)
    sb:SetMinMaxValues(0, 1)
    local fill = sb:CreateTexture(nil, "ARTWORK")
    fill:SetAtlas("ui-castingbar-filling-standard")
    sb:SetStatusBarTexture(fill)
    row.Bar, row.Fill = sb, fill
    local box = row:CreateTexture(nil, "BACKGROUND", nil, 0)
    box:SetAtlas("ui-castingbar-textbox")
    box:SetPoint("TOPLEFT", sb, "TOPLEFT")
    box:SetPoint("BOTTOMRIGHT", sb, "BOTTOMRIGHT", 0, -14)
    local bg = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetAtlas("ui-castingbar-background")
    bg:SetPoint("TOPLEFT", sb, "TOPLEFT", -1, 1)
    bg:SetPoint("BOTTOMRIGHT", sb, "BOTTOMRIGHT", 1, -1)
    local border = sb:CreateTexture(nil, "OVERLAY")
    border:SetAtlas("ui-castingbar-frame")
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetPoint("BOTTOMRIGHT", 2, -2)
    local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", sb, "BOTTOMLEFT")
    text:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", 0, 2)
    row.Text = text
    rows[n] = row
    return row
end

local function Place()
    panel:ClearAllPoints()
    local p = db.boatPos
    if p then
        local point = p[1] --[[@as FramePoint]]
        panel:SetPoint(point, UIParent, point, p[2] --[[@as number]], p[3] --[[@as number]])
    else
        panel:SetPoint("TOP", UIParent, "TOP", 0, -150)
    end
end

local function BuildPanel()
    panel = CreateFrame("Frame", "MeioFlightTimesDock", UIParent)
    panel:SetSize(WIDTH + 11, 30)
    panel:SetFrameStrata("MEDIUM")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetClampedToScreen(true)
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        db.boatPos = { point, math.floor(x + 0.5), math.floor(y + 0.5) }
    end)
    Place()
    panel:Hide()
end

local function ShowPanel(list)
    if db.boatPanel == false or not list or #list == 0 or UnitOnTaxi("player") then
        if panel then panel:Hide() end
        return
    end
    if not panel then BuildPanel() end
    -- the routes leaving the nearest town's piers
    local seen, n = {}, 0
    for _, e in ipairs(list) do
        if not seen[e.id] then
            seen[e.id] = true
            n = n + 1
            local row = Row(n)
            local text, value = Text(e.id, e.i)
            row.Text:SetText(text)
            row.Bar:SetValue(value)
            local docked, leaves = DockState(e.id, e.i)
            -- green while boarding, red in the last half minute, gold while away
            row.Fill:SetAtlas(docked and "ui-castingbar-filling-channel"
                or "ui-castingbar-filling-standard")
            if docked and leaves <= SOON then
                row.Fill:SetVertexColor(1, 0.35, 0.35)
            else
                row.Fill:SetVertexColor(1, 1, 1)
            end
            row:Show()
        end
    end
    for k = n + 1, #rows do rows[k]:Hide() end
    panel:SetHeight(n * 30)
    panel:Show()
end

-- timetable: one line per dock, soonest first

local function Lines(all)
    local out = {}
    local _, _, _, cont = UnitPosition("player")
    for id in pairs(BOATS) do
        if Mine(id) then
            for i in ipairs(BOATS[id][4]) do
                local d = Dock(id, i)
                if all or d.cont == cont then
                    local docked, leaves = DockState(id, i)
                    out[#out + 1] = { label = d.place .. " > " .. Dock(id, NextDock(id, i)).place,
                        docked = docked, leaves = leaves }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if (a.leaves ~= nil) ~= (b.leaves ~= nil) then return a.leaves ~= nil end
        if a.leaves and a.leaves ~= b.leaves then return a.leaves < b.leaves end
        return a.label < b.label
    end)
    return out
end

local function When(l)
    if l.leaves == nil then return MUTED .. "ride once to time it|r" end
    if l.docked then return (l.leaves <= SOON and RED or GREEN) .. "in port, leaves " .. Clock(l.leaves) .. "|r" end
    return "leaves in " .. Clock(l.leaves)
end

local function Tooltip(tt)
    local all = IsShiftKeyDown()
    tt:AddLine("Boats and zeppelins", 1, 1, 1)
    local lines = Lines(all)
    for _, l in ipairs(lines) do
        tt:AddDoubleLine(l.label, When(l), NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g,
            NORMAL_FONT_COLOR.b, 1, 1, 1)
    end
    if #lines == 0 then tt:AddLine(MUTED .. "none on this continent|r") end
    if not all then tt:AddLine(MUTED .. "Shift: every dock|r") end
end
ns.BoatTooltip = Tooltip

local function PrintTimetable()
    Say("boats and zeppelins for you, soonest first")
    for _, l in ipairs(Lines(true)) do
        DEFAULT_CHAT_FRAME:AddMessage("  " .. l.label .. " - " .. When(l))
    end
end

local function BrokerText(list)
    if not broker then return end
    local e = list and list[1]
    local text = "Boats"
    if e then
        local docked, leaves = DockState(e.id, e.i)
        local to = Dock(e.id, NextDock(e.id, e.i)).place
        if leaves then text = to .. " " .. (docked and GREEN or "") .. Clock(leaves) .. "|r" end
    end
    broker.text = text
end

local function Tick()
    Now()
    local x, y, cont = Track()
    local list = x and NearDocks(x, y, cont)
    ShowPanel(list)
    BrokerText(list)
end
ns.BoatTick = Tick

-- dockmasters on Zephras Isle and in Dalaran call each arrival
local CALLS = {
    { sender = "Windshapers Dockmaster", word = "Skycutter", id = 12, i = 1 },
    { sender = "High Order Dockmaster", word = "just arrived", id = 13, i = 1 },
    { sender = "Arcanist Laurain", word = "just arrived", id = 13, i = 2 },
}

local function OnCall(msg, sender)
    if not (canaccess(msg) and canaccess(sender)) then return end
    if type(msg) ~= "string" or type(sender) ~= "string" then return end
    for _, c in ipairs(CALLS) do
        if sender == c.sender and msg:find(c.word, 1, true) and BOATS[c.id] then
            Anchor(c.id, Now() - Dock(c.id, c.i).arrive, "call")
            return
        end
    end
end

local function RegisterBroker()
    local ldb = LibStub and LibStub("LibDataBroker-1.1", true)
    if not ldb or ldb:GetDataObjectByName("MeioFlightTimes Boats") then return end
    broker = ldb:NewDataObject("MeioFlightTimes Boats", {
        type = "data source",
        label = "Boats",
        text = "Boats",
        icon = "Interface\\Icons\\INV_Misc_Spyglass_03",
        OnClick = PrintTimetable,
        OnTooltipShow = Tooltip,
    })
    local icon = LibStub("LibDBIcon-1.0", true)
    if icon then
        db.boatIcon = db.boatIcon or {}
        icon:Register("MeioFlightTimes Boats", broker, db.boatIcon)
    end
end

-- slash: /meioflighttimes boats [on|off|reset]
function ns.BoatsSlash(arg)
    if arg == "on" or arg == "off" then
        if arg == "on" then db.boatPanel = nil else db.boatPanel = false end
        Say("dock timers near a pier " .. (arg == "on" and GREEN .. "on|r" or RED .. "off|r"))
        Tick()
    elseif arg == "reset" then
        db.boatPos = nil
        if panel then Place() end
        Say("dock timers back in their place")
    else
        PrintTimetable()
    end
end
function ns.BoatPanelOn() return db.boatPanel ~= false end

-- Blizzard's addon button by the minimap
function MeioFlightTimes_OnAddonCompartmentClick() PrintTimetable() end
function MeioFlightTimes_OnAddonCompartmentEnter(_, button)
    GameTooltip:SetOwner(button or UIParent, "ANCHOR_LEFT")
    Tooltip(GameTooltip)
    GameTooltip:Show()
end
function MeioFlightTimes_OnAddonCompartmentLeave() GameTooltip:Hide() end

-- for MeioMap: state of dock i of route id (see DockState) and the route table
MeioFlightTimes_API = MeioFlightTimes_API or {}
MeioFlightTimes_API.Boats = BOATS
MeioFlightTimes_API.BoatDock = DockState

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        db = ns.db
        db.boats = db.boats or {}
        Now()
        ImportNauticus()
        local ok, err = pcall(RegisterBroker)
        if not ok then geterrorhandler()(err) end
        for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "CHAT_MSG_MONSTER_SAY",
            "CHAT_MSG_MONSTER_YELL" }) do
            pcall(self.RegisterEvent, self, e)
        end
        C_Timer.NewTicker(TICK, Tick)
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- a loading screen mid-crossing: the ride goes on, the position jumps
        ResetTrack()
    else
        pcall(OnCall, ...)
    end
end)
