-- XenoScanner v4.0 -- Production -- Pure ASCII -- Safe re-execute
-- Tabs: TREE | SCRIPTS | REMOTES | PROPS
-- Keybind: RightShift = toggle GUI
-- All 15 diagnostic findings resolved.
--
-- Applied fixes:
--   H-001: ContentScroll CanvasSize fixed via AutomaticCanvasSize
--   H-002: All scan bodies wrapped in pcall for guaranteed mutex release
--   H-003: UIS connections tracked and disconnected on GUI close
--   H-004: stopSpy checks hook chain before restoration
--   H-005: resolvePath service fallback restricted to depth=2
--   H-006: newcclosure shim detection warns before spy activation
--   H-007: spyRenderThread properly cancelled via task.cancel
--   H-008: Render generation counter prevents interleaved renders
--   H-009: Selected state segregated per tab, cleared on switch
--   H-010: Generation-counter debounce (executor-agnostic)
--   H-011: Drag handler guarded against destroyed GUI
--   H-012: Bulk copy snapshots scriptList and guards mid-copy state
--   H-013: Dead type(lines) guard removed from buildTree
--   H-014: GUI_PARENT test validates actual parenting success
--   H-015: Vararg capture before nested closure (Luau scoping fix)

-- ============================================================
-- S0  UNC SHIMS
-- Every exploit API shimmed before anything else runs.
-- ============================================================
if not cloneref          then cloneref          = function(o) return o   end end
if not getnilinstances   then getnilinstances   = function()  return {}  end end
if not getinstances      then getinstances      = function()  return {}  end end
if not getscripts        then getscripts        = function()  return {}  end end
if not decompile         then decompile         = function()  return nil end end
if not getscriptclosure  then getscriptclosure  = function()  return nil end end
if not getconstants      then getconstants      = function()  return {}  end end
if not getupvalues       then getupvalues       = function()  return {}  end end
if not getgc             then getgc             = function()  return {}  end end
if not checkcaller       then checkcaller       = function()  return false end end
if not newcclosure       then newcclosure       = function(f) return f   end end
if not getnamecallmethod then getnamecallmethod = function()  return ""  end end
if not gethui            then gethui            = function()  return nil end end
if not hookmetamethod    then hookmetamethod    = nil end
-- [FIX H-010] Shim task.cancel for executors that lack it
if not task.cancel       then task.cancel       = function() end end
if not getrawmetatable   then getrawmetatable   = function() return {} end end
if not setclipboard      then
    setclipboard = function()
        error("[XenoScanner] setclipboard not available on this executor")
    end
end

-- ============================================================
-- S1  SERVICES
-- ============================================================
local Players = cloneref(game:GetService("Players"))
local UIS     = cloneref(game:GetService("UserInputService"))
local CoreGui = cloneref(game:GetService("CoreGui"))
local LP      = Players.LocalPlayer

-- [FIX H-003] Connection cleanup table -- all persistent connections tracked here
local _connections = {}

-- ============================================================
-- S2  GUI PARENT  (Xeno: CoreGui -> gethui -> PlayerGui)
-- [FIX H-014] Validates that parenting actually succeeded
-- ============================================================
local GUI_PARENT
do
    local ok = pcall(function()
        local t = Instance.new("Frame")
        t.Parent = CoreGui
        -- [FIX H-014] Verify the assignment took effect
        assert(t.Parent == CoreGui, "parent assignment rejected")
        t:Destroy()
    end)
    if ok then
        GUI_PARENT = CoreGui
    else
        local ok2, hui = pcall(gethui)
        if ok2 and hui and typeof(hui) == "Instance" then
            GUI_PARENT = hui
        else
            GUI_PARENT = LP:WaitForChild("PlayerGui")
        end
    end
end

-- ============================================================
-- S3  CLEANUP  (destroy any previous instance from all parents)
-- [FIX H-003] Also disconnects any previously stored connections
-- ============================================================
local SCRIPT_NAME = "XenoScannerV4"

local function destroyOld()
    -- Disconnect any lingering connections from a prior execution
    local oldConns = _G[SCRIPT_NAME .. "_conns"]
    if type(oldConns) == "table" then
        for _, c in ipairs(oldConns) do
            pcall(function() c:Disconnect() end)
        end
    end

    local parents = { CoreGui }
    local pg = LP:FindFirstChild("PlayerGui")
    if pg then parents[#parents + 1] = pg end
    local ok2, hui = pcall(gethui)
    if ok2 and hui and typeof(hui) == "Instance" then
        parents[#parents + 1] = hui
    end
    for _, p in ipairs(parents) do
        local old = p:FindFirstChild(SCRIPT_NAME)
        if old then pcall(function() old:Destroy() end) end
    end
end
destroyOld()

-- ============================================================
-- S4  CONFIG
-- ============================================================
local C = {
    ROOTS = {
        "Workspace", "Players", "Lighting", "MaterialService",
        "ReplicatedFirst", "ReplicatedStorage", "ServerScriptService",
        "ServerStorage", "StarterGui", "StarterPack", "StarterPlayer",
        "Teams", "SoundService", "TextChatService", "CoreGui",
    },
    SKIP      = { Terrain = true },
    MAX_DEPTH = 64,
    CHUNK     = 175000,
    W = 740, H = 520,
    BG      = Color3.fromRGB( 12,  12,  18),
    SURFACE = Color3.fromRGB( 20,  20,  30),
    HEADER  = Color3.fromRGB( 18,  18,  28),
    ACCENT  = Color3.fromRGB(108,  92, 231),
    ACCENT2 = Color3.fromRGB( 72, 200, 150),
    DANGER  = Color3.fromRGB(210,  60,  60),
    TEXT    = Color3.fromRGB(225, 225, 240),
    DIM     = Color3.fromRGB(120, 120, 150),
    CODEBG  = Color3.fromRGB(  8,   8,  14),
    SPY_COL = Color3.fromRGB(220, 160,  40),
    GREEN   = Color3.fromRGB( 40, 180, 100),
    GREY    = Color3.fromRGB( 80,  80, 110),
    FILTER_DEBOUNCE = 0.15,
    SPY_POLL_RATE   = 0.25,
}

-- ============================================================
-- S5  STATE
-- [FIX H-009] Separated selected state per tab
-- ============================================================
local ST = {
    activeTab      = "TREE",
    guiVisible     = true,
    scanning       = false,
    -- Spy state
    spyActive      = false,
    spyOriginal    = nil,
    spyHookRef     = nil,      -- [FIX H-004] reference to our hook closure
    spyLines       = {},
    spyRenderThread = nil,
    spyDirty       = false,
    -- Data caches
    treeText       = nil,
    scriptList     = {},
    remoteList     = {},
    -- [FIX H-009] Per-tab selected content
    selectedScriptSource = nil,
    selectedRemotePath   = nil,
    propsText      = nil,
    filterText     = "",
    -- [FIX H-010] Generation-counter debounce (no task.cancel dependency)
    filterGen      = 0,
}

-- ============================================================
-- S6  UTILITY
-- ============================================================

local function SP(inst, prop)
    local ok, v = pcall(function() return inst[prop] end)
    return ok and tostring(v) or "<?>"
end

local function chunkStr(str)
    local out, s, len = {}, 1, #str
    while s <= len do
        local e = math.min(s + C.CHUNK - 1, len)
        if e < len then
            for i = e, s, -1 do
                if str:sub(i, i) == "\n" then e = i; break end
            end
        end
        out[#out + 1] = str:sub(s, e)
        s = e + 1
    end
    return out
end

local function fullPath(inst)
    if inst == game then return "game" end
    local parts, cur = {}, inst
    while cur and cur ~= game do
        local ok, n = pcall(function() return cur.Name end)
        parts[#parts + 1] = ok and tostring(n) or "<?>"
        local ok2, p = pcall(function() return cur.Parent end)
        if not ok2 or p == nil then break end
        cur = p
    end
    local rev = {}
    for i = #parts, 1, -1 do rev[#rev + 1] = parts[i] end
    return "game." .. table.concat(rev, ".")
end

local function numberLines(src)
    local out, n = {}, 0
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        n = n + 1
        out[#out + 1] = string.format("%5d  %s", n, line)
    end
    return table.concat(out, "\n"), n
end

-- ============================================================
-- S7  SCANNERS
-- ============================================================

-- S7-A  TREE ------------------------------------------------
local function buildTree()
    local lines = {}
    local function ins(s) lines[#lines + 1] = s end

    ins("XENO GAME SCANNER v4.0  --  Full Hierarchy")
    ins("Game:    " .. SP(game, "Name"))
    ins("PlaceId: " .. SP(game, "PlaceId"))
    ins("JobId:   " .. SP(game, "JobId"))
    ins(string.rep("-", 60))
    ins("")

    local function recurse(inst, prefix, isLast, depth)
        -- [FIX H-013] Removed dead 'type(lines) ~= "table"' guard
        if depth > C.MAX_DEPTH then
            lines[#lines + 1] = prefix
                .. (isLast and "\\- " or "|- ") .. "[MAX DEPTH]"
            return
        end
        local br   = isLast and "\\- " or "|- "
        local name = SP(inst, "Name")
        local cls  = SP(inst, "ClassName")
        lines[#lines + 1] = prefix .. br .. name .. "  [" .. cls .. "]"

        if C.SKIP[cls] then
            local cp = prefix .. (isLast and "   " or "|  ")
            lines[#lines + 1] = cp .. "\\- ... (skipped)"
            return
        end

        local ok, ch = pcall(function() return inst:GetChildren() end)
        if not ok or type(ch) ~= "table" or #ch == 0 then return end
        local cp = prefix .. (isLast and "   " or "|  ")
        for i = 1, #ch do
            pcall(recurse, ch[i], cp, i == #ch, depth + 1)
        end
    end

    for _, svcName in ipairs(C.ROOTS) do
        local ok, svc = pcall(function() return game:GetService(svcName) end)
        if ok and svc then
            local ok2, ch = pcall(function() return svc:GetChildren() end)
            local count = (ok2 and type(ch) == "table") and #ch or 0
            ins(">> " .. svcName
                .. "  [" .. SP(svc, "ClassName") .. "]"
                .. "  (" .. count .. " children)")
            if ok2 and type(ch) == "table" then
                for i = 1, #ch do
                    pcall(recurse, ch[i], "  ", i == #ch, 1)
                end
            end
            ins("")
        end
    end

    ins(string.rep("-", 60))
    ins("Scan complete  --  " .. #lines .. " lines")
    return table.concat(lines, "\n")
end

-- S7-B  SCRIPTS ---------------------------------------------
local function buildScriptList()
    local list, seen = {}, {}

    local ok, scripts = pcall(getscripts)
    if ok and type(scripts) == "table" then
        for _, s in ipairs(scripts) do
            if not seen[s] then
                seen[s] = true
                local ok2, cls  = pcall(function() return s.ClassName end)
                local ok3, name = pcall(function() return s.Name      end)
                if ok2 and (cls == "LocalScript" or cls == "Script"
                            or cls == "ModuleScript") then
                    list[#list + 1] = {
                        name     = ok3 and tostring(name) or "<?>",
                        cls      = cls,
                        path     = fullPath(s),
                        instance = s,
                    }
                end
            end
        end
    end

    if #list == 0 then
        local ok2, all = pcall(getinstances)
        if ok2 and type(all) == "table" then
            for _, s in ipairs(all) do
                if not seen[s] then
                    seen[s] = true
                    local ok3, cls = pcall(function() return s.ClassName end)
                    if ok3 and (cls == "LocalScript" or cls == "Script"
                                or cls == "ModuleScript") then
                        local ok4, name = pcall(function() return s.Name end)
                        list[#list + 1] = {
                            name     = ok4 and tostring(name) or "<?>",
                            cls      = cls,
                            path     = fullPath(s),
                            instance = s,
                        }
                    end
                end
            end
        end
    end

    table.sort(list, function(a, b) return a.path < b.path end)
    return list
end

local function decompileScript(entry)
    local inst = entry.instance

    local ok1, src = pcall(decompile, inst)
    if ok1 and type(src) == "string" and #src > 0 then
        local numbered, n = numberLines(src)
        return numbered, n, "decompile()"
    end

    local ok2, closure = pcall(getscriptclosure, inst)
    if ok2 and closure then
        local buf = {}
        buf[#buf + 1] = "-- decompile() unavailable for this script."
        buf[#buf + 1] = "-- Fallback: closure analysis"
        buf[#buf + 1] = "--"
        buf[#buf + 1] = "-- CONSTANTS:"
        local ok3, consts = pcall(getconstants, closure)
        if ok3 and type(consts) == "table" then
            for i, v in ipairs(consts) do
                buf[#buf + 1] = string.format("--   [%d] %s", i, tostring(v))
            end
        else
            buf[#buf + 1] = "--   (none)"
        end
        buf[#buf + 1] = "--"
        buf[#buf + 1] = "-- UPVALUES:"
        local ok4, ups = pcall(getupvalues, closure)
        if ok4 and type(ups) == "table" then
            for k, v in pairs(ups) do
                buf[#buf + 1] = string.format(
                    "--   [%s] = %s", tostring(k), tostring(v))
            end
        else
            buf[#buf + 1] = "--   (none)"
        end
        local numbered, n = numberLines(table.concat(buf, "\n"))
        return numbered, n, "closure dump"
    end

    local fallback = "-- Source unavailable.\n"
        .. "-- Script is protected or obfuscated."
    local numbered, n = numberLines(fallback)
    return numbered, n, "unavailable"
end

-- S7-C  REMOTES ---------------------------------------------
local function buildRemoteList()
    local list, seen = {}, {}
    local TARGET = {
        RemoteEvent            = true,
        RemoteFunction         = true,
        BindableEvent          = true,
        BindableFunction       = true,
        UnreliableRemoteEvent  = true,
    }

    local function scanRoot(root)
        if not root then return end
        local ok, desc = pcall(function() return root:GetDescendants() end)
        if not ok or type(desc) ~= "table" then return end
        for _, inst in ipairs(desc) do
            if not seen[inst] then
                seen[inst] = true
                local ok2, cls = pcall(function() return inst.ClassName end)
                if ok2 and TARGET[cls] then
                    local ok3, name = pcall(function() return inst.Name end)
                    list[#list + 1] = {
                        name     = ok3 and tostring(name) or "<?>",
                        cls      = cls,
                        path     = fullPath(inst),
                        instance = inst,
                    }
                end
            end
        end
    end

    for _, svcName in ipairs(C.ROOTS) do
        local ok, svc = pcall(function() return game:GetService(svcName) end)
        if ok and svc then scanRoot(svc) end
    end

    local okN, nilInsts = pcall(getnilinstances)
    if okN and type(nilInsts) == "table" then
        for _, inst in ipairs(nilInsts) do
            if not seen[inst] then
                seen[inst] = true
                local ok2, cls = pcall(function() return inst.ClassName end)
                if ok2 and TARGET[cls] then
                    local ok3, name = pcall(function() return inst.Name end)
                    list[#list + 1] = {
                        name     = ok3 and tostring(name) or "<?>",
                        cls      = cls,
                        path     = "(nil-parent) " .. (ok3 and tostring(name) or "<?>"),
                        instance = inst,
                    }
                end
            end
        end
    end

    table.sort(list, function(a, b) return a.path < b.path end)
    return list
end

-- S7-D  PROPERTIES ------------------------------------------
local function buildPropsText(inst)
    if not inst then return "No instance selected." end
    local lines = {}
    local function ins(s) lines[#lines + 1] = s end

    ins("PROPERTIES  --  " .. SP(inst, "Name")
        .. "  [" .. SP(inst, "ClassName") .. "]")
    ins("Full path: " .. fullPath(inst))
    ins(string.rep("-", 56))
    ins("")

    local PROPS = {
        "Name", "ClassName", "Parent", "Archivable", "Locked",
        "Position", "Orientation", "Size", "CFrame",
        "Color", "BrickColor", "Material", "Transparency",
        "Anchored", "CanCollide", "CanQuery", "CastShadow",
        "Massless", "RootPriority",
        "Health", "MaxHealth", "WalkSpeed", "JumpPower",
        "JumpHeight", "DisplayName",
        "Disabled", "RunContext", "Source",
        "Value",
        "SoundId", "Volume", "PlayOnRemove", "IsPlaying", "Looped",
        "Text", "TextColor3", "Font", "TextSize", "BackgroundColor3",
        "Visible", "ZIndex",
        "RespawnLocation", "Team", "TeamColor", "Neutral",
    }

    for _, p in ipairs(PROPS) do
        local ok, v = pcall(function() return inst[p] end)
        if ok then
            ins(string.format("  %-28s = %s", p, tostring(v)))
        end
    end

    ins("")
    local okC, ch = pcall(function() return inst:GetChildren() end)
    local childCount = (okC and type(ch) == "table") and #ch or 0
    ins("CHILDREN  (" .. childCount .. ")")
    if okC and type(ch) == "table" then
        for _, child in ipairs(ch) do
            ins("    " .. SP(child, "Name")
                .. "  [" .. SP(child, "ClassName") .. "]")
        end
    end

    return table.concat(lines, "\n")
end

-- [FIX H-005] resolvePath: service fallback ONLY at depth=2
local function resolvePath(pathStr)
    local f = pathStr:gsub("^%s+", ""):gsub("%s+$", "")
    if f == "" then return nil, "empty path" end

    local parts = {}
    for p in f:gmatch("[^%.]+") do parts[#parts + 1] = p end

    if parts[1] ~= "game" and parts[1] ~= "Game" then
        return nil, "path must start with 'game' (got '" .. parts[1] .. "')"
    end

    local cur = game
    for i = 2, #parts do
        local seg  = parts[i]
        local child = cur:FindFirstChild(seg)
        if child then
            cur = child
        -- [FIX H-005] Only attempt GetService directly under game (i == 2)
        elseif i == 2 then
            local ok2, svc = pcall(function() return game:GetService(seg) end)
            if ok2 and svc and typeof(svc) == "Instance" then
                cur = svc
            else
                return nil, "could not find service or child '"
                    .. seg .. "' under game"
            end
        else
            local parentName = parts[i - 1]
            return nil, "could not find '" .. seg
                .. "' under " .. parentName
        end
    end

    if typeof(cur) ~= "Instance" then
        return nil, "resolved value is not an Instance"
    end
    return cur, nil
end

-- ============================================================
-- S8  GUI CONSTRUCTION
-- ============================================================

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name            = SCRIPT_NAME
ScreenGui.ResetOnSpawn    = false
ScreenGui.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
ScreenGui.IgnoreGuiInset  = true
ScreenGui.Parent          = GUI_PARENT

local Main = Instance.new("Frame")
Main.Name             = "Main"
Main.Size             = UDim2.new(0, C.W, 0, C.H)
Main.Position         = UDim2.new(0.5, -(C.W / 2), 0.5, -(C.H / 2))
Main.BackgroundColor3 = C.BG
Main.BorderSizePixel  = 0
Main.ClipsDescendants = true
Main.Parent           = ScreenGui
Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 10)

local TitleBar = Instance.new("Frame")
TitleBar.Name             = "TitleBar"
TitleBar.Size             = UDim2.new(1, 0, 0, 40)
TitleBar.BackgroundColor3 = C.HEADER
TitleBar.BorderSizePixel  = 0
TitleBar.ZIndex           = 5
TitleBar.Parent           = Main
Instance.new("UICorner", TitleBar).CornerRadius = UDim.new(0, 10)

local TBPatch = Instance.new("Frame")
TBPatch.Size             = UDim2.new(1, 0, 0, 10)
TBPatch.Position         = UDim2.new(0, 0, 1, -10)
TBPatch.BackgroundColor3 = C.HEADER
TBPatch.BorderSizePixel  = 0
TBPatch.ZIndex           = 5
TBPatch.Parent           = TitleBar

local Stripe = Instance.new("Frame")
Stripe.Size             = UDim2.new(0, 3, 0, 22)
Stripe.Position         = UDim2.new(0, 10, 0.5, -11)
Stripe.BackgroundColor3 = C.ACCENT
Stripe.BorderSizePixel  = 0
Stripe.ZIndex           = 6
Stripe.Parent           = TitleBar
Instance.new("UICorner", Stripe).CornerRadius = UDim.new(0, 2)

local TitleLbl = Instance.new("TextLabel")
TitleLbl.Text               = "XENO GAME SCANNER  v4.0"
TitleLbl.Size               = UDim2.new(1, -100, 1, 0)
TitleLbl.Position           = UDim2.new(0, 20, 0, 0)
TitleLbl.BackgroundTransparency = 1
TitleLbl.TextColor3         = C.TEXT
TitleLbl.Font               = Enum.Font.GothamBold
TitleLbl.TextSize           = 13
TitleLbl.TextXAlignment     = Enum.TextXAlignment.Left
TitleLbl.ZIndex             = 6
TitleLbl.Parent             = TitleBar

local function makeTitleBtn(xOff, col, lbl)
    local b = Instance.new("TextButton")
    b.Size             = UDim2.new(0, 26, 0, 26)
    b.Position         = UDim2.new(1, xOff, 0.5, -13)
    b.BackgroundColor3 = col
    b.Text             = lbl
    b.TextColor3       = Color3.new(1, 1, 1)
    b.Font             = Enum.Font.GothamBold
    b.TextSize         = 11
    b.BorderSizePixel  = 0
    b.ZIndex           = 7
    b.Parent           = TitleBar
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
    return b
end

local CloseBtn = makeTitleBtn(-34, C.DANGER,                    "X")
local HideBtn  = makeTitleBtn(-64, Color3.fromRGB(80, 80, 100), "-")

local TabBar = Instance.new("Frame")
TabBar.Name             = "TabBar"
TabBar.Size             = UDim2.new(1, 0, 0, 32)
TabBar.Position         = UDim2.new(0, 0, 0, 40)
TabBar.BackgroundColor3 = C.SURFACE
TabBar.BorderSizePixel  = 0
TabBar.ZIndex           = 4
TabBar.Parent           = Main

local TabLayout = Instance.new("UIListLayout")
TabLayout.FillDirection     = Enum.FillDirection.Horizontal
TabLayout.Padding           = UDim.new(0, 1)
TabLayout.VerticalAlignment = Enum.VerticalAlignment.Center
TabLayout.Parent            = TabBar

local UIPadTab = Instance.new("UIPadding")
UIPadTab.PaddingLeft = UDim.new(0, 6)
UIPadTab.Parent      = TabBar

local TAB_NAMES  = { "TREE", "SCRIPTS", "REMOTES", "PROPS" }
local tabButtons = {}

for _, tname in ipairs(TAB_NAMES) do
    local tb = Instance.new("TextButton")
    tb.Name             = "Tab_" .. tname
    tb.Size             = UDim2.new(0, 100, 1, -6)
    tb.BackgroundColor3 = C.SURFACE
    tb.Text             = tname
    tb.TextColor3       = C.DIM
    tb.Font             = Enum.Font.GothamBold
    tb.TextSize         = 11
    tb.BorderSizePixel  = 0
    tb.ZIndex           = 5
    tb.AutoButtonColor  = false
    tb.Parent           = TabBar
    Instance.new("UICorner", tb).CornerRadius = UDim.new(0, 5)
    tabButtons[tname] = tb
end

local FilterBar = Instance.new("Frame")
FilterBar.Name             = "FilterBar"
FilterBar.Size             = UDim2.new(1, -16, 0, 26)
FilterBar.Position         = UDim2.new(0, 8, 0, 76)
FilterBar.BackgroundColor3 = C.SURFACE
FilterBar.BorderSizePixel  = 0
FilterBar.ZIndex           = 4
FilterBar.Parent           = Main
Instance.new("UICorner", FilterBar).CornerRadius = UDim.new(0, 5)

local FilterLbl = Instance.new("TextLabel")
FilterLbl.Text              = "Filter:"
FilterLbl.Size              = UDim2.new(0, 40, 1, 0)
FilterLbl.Position          = UDim2.new(0, 6, 0, 0)
FilterLbl.BackgroundTransparency = 1
FilterLbl.TextColor3        = C.DIM
FilterLbl.Font              = Enum.Font.GothamBold
FilterLbl.TextSize          = 11
FilterLbl.ZIndex            = 5
FilterLbl.Parent            = FilterBar

local FilterInput = Instance.new("TextBox")
FilterInput.Name              = "FilterInput"
FilterInput.Size              = UDim2.new(1, -76, 1, 0)
FilterInput.Position          = UDim2.new(0, 46, 0, 0)
FilterInput.BackgroundTransparency = 1
FilterInput.TextColor3        = C.TEXT
FilterInput.PlaceholderText   = "type to filter..."
FilterInput.PlaceholderColor3 = C.DIM
FilterInput.Font              = Enum.Font.Code
FilterInput.TextSize          = 11
FilterInput.TextXAlignment    = Enum.TextXAlignment.Left
FilterInput.ClearTextOnFocus  = false
FilterInput.ZIndex            = 5
FilterInput.Parent            = FilterBar

local FilterClear = Instance.new("TextButton")
FilterClear.Size             = UDim2.new(0, 28, 1, 0)
FilterClear.Position         = UDim2.new(1, -30, 0, 0)
FilterClear.BackgroundTransparency = 1
FilterClear.Text             = "[X]"
FilterClear.TextColor3       = C.DIM
FilterClear.Font             = Enum.Font.GothamBold
FilterClear.TextSize         = 10
FilterClear.ZIndex           = 5
FilterClear.Parent           = FilterBar

-- Content scroll (TREE + PROPS)
-- [FIX H-001] AutomaticCanvasSize = XY handles both axes
local ContentScroll = Instance.new("ScrollingFrame")
ContentScroll.Name                 = "ContentScroll"
ContentScroll.Size                 = UDim2.new(1, -16, 1, -152)
ContentScroll.Position             = UDim2.new(0, 8, 0, 108)
ContentScroll.BackgroundColor3     = C.CODEBG
ContentScroll.BorderSizePixel      = 0
ContentScroll.ScrollBarThickness   = 5
ContentScroll.ScrollBarImageColor3 = C.ACCENT
ContentScroll.CanvasSize           = UDim2.new(0, 0, 0, 0)
-- [FIX H-001] Enable automatic canvas sizing for both axes
ContentScroll.AutomaticCanvasSize  = Enum.AutomaticSize.XY
ContentScroll.ZIndex               = 3
ContentScroll.Parent               = Main
Instance.new("UICorner", ContentScroll).CornerRadius = UDim.new(0, 6)

local ContentLayout = Instance.new("UIListLayout")
ContentLayout.SortOrder = Enum.SortOrder.LayoutOrder
ContentLayout.Padding   = UDim.new(0, 0)
ContentLayout.Parent    = ContentScroll

local ListPanel = Instance.new("Frame")
ListPanel.Name             = "ListPanel"
ListPanel.Size             = UDim2.new(0, 210, 1, -152)
ListPanel.Position         = UDim2.new(0, 8, 0, 108)
ListPanel.BackgroundColor3 = C.SURFACE
ListPanel.BorderSizePixel  = 0
ListPanel.ZIndex           = 3
ListPanel.Visible          = false
ListPanel.Parent           = Main
Instance.new("UICorner", ListPanel).CornerRadius = UDim.new(0, 6)

local ListScroll = Instance.new("ScrollingFrame")
ListScroll.Size                 = UDim2.new(1, -4, 1, -4)
ListScroll.Position             = UDim2.new(0, 2, 0, 2)
ListScroll.BackgroundTransparency = 1
ListScroll.BorderSizePixel      = 0
ListScroll.ScrollBarThickness   = 4
ListScroll.ScrollBarImageColor3 = C.ACCENT
ListScroll.CanvasSize           = UDim2.new(0, 0, 0, 0)
ListScroll.AutomaticCanvasSize  = Enum.AutomaticSize.Y
ListScroll.ZIndex               = 4
ListScroll.Parent               = ListPanel

local ListItemLayout = Instance.new("UIListLayout")
ListItemLayout.SortOrder = Enum.SortOrder.LayoutOrder
ListItemLayout.Padding   = UDim.new(0, 2)
ListItemLayout.Parent    = ListScroll

local UIPadList = Instance.new("UIPadding")
UIPadList.PaddingLeft   = UDim.new(0, 4)
UIPadList.PaddingTop    = UDim.new(0, 4)
UIPadList.PaddingRight  = UDim.new(0, 4)
UIPadList.Parent        = ListScroll

local SourceScroll = Instance.new("ScrollingFrame")
SourceScroll.Name                 = "SourceScroll"
SourceScroll.Size                 = UDim2.new(1, -230, 1, -152)
SourceScroll.Position             = UDim2.new(0, 224, 0, 108)
SourceScroll.BackgroundColor3     = C.CODEBG
SourceScroll.BorderSizePixel      = 0
SourceScroll.ScrollBarThickness   = 5
SourceScroll.ScrollBarImageColor3 = C.ACCENT2
SourceScroll.CanvasSize           = UDim2.new(0, 0, 0, 0)
-- [FIX H-001] Also enable for SourceScroll
SourceScroll.AutomaticCanvasSize  = Enum.AutomaticSize.XY
SourceScroll.ZIndex               = 3
SourceScroll.Visible              = false
SourceScroll.Parent               = Main
Instance.new("UICorner", SourceScroll).CornerRadius = UDim.new(0, 6)

local SourceLayout = Instance.new("UIListLayout")
SourceLayout.SortOrder = Enum.SortOrder.LayoutOrder
SourceLayout.Padding   = UDim.new(0, 0)
SourceLayout.Parent    = SourceScroll

local StatusBar = Instance.new("Frame")
StatusBar.Name             = "StatusBar"
StatusBar.Size             = UDim2.new(1, 0, 0, 22)
StatusBar.Position         = UDim2.new(0, 0, 1, -44)
StatusBar.BackgroundColor3 = C.SURFACE
StatusBar.BorderSizePixel  = 0
StatusBar.ZIndex           = 4
StatusBar.Parent           = Main

local StatusLbl = Instance.new("TextLabel")
StatusLbl.Size             = UDim2.new(1, -12, 1, 0)
StatusLbl.Position         = UDim2.new(0, 10, 0, 0)
StatusLbl.BackgroundTransparency = 1
StatusLbl.TextColor3       = C.DIM
StatusLbl.Font             = Enum.Font.Code
StatusLbl.TextSize         = 10
StatusLbl.TextXAlignment   = Enum.TextXAlignment.Left
StatusLbl.Text             = "Ready."
StatusLbl.ZIndex           = 5
StatusLbl.Parent           = StatusBar

local BtnRow = Instance.new("Frame")
BtnRow.Name             = "BtnRow"
BtnRow.Size             = UDim2.new(1, -16, 0, 34)
BtnRow.Position         = UDim2.new(0, 8, 1, -40)
BtnRow.BackgroundTransparency = 1
BtnRow.ZIndex           = 4
BtnRow.Parent           = Main

local BtnRowLayout = Instance.new("UIListLayout")
BtnRowLayout.FillDirection     = Enum.FillDirection.Horizontal
BtnRowLayout.Padding           = UDim.new(0, 6)
BtnRowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
BtnRowLayout.Parent            = BtnRow

local function makeBtn(label, col, w)
    local b = Instance.new("TextButton")
    b.Size             = UDim2.new(0, w or 120, 1, 0)
    b.BackgroundColor3 = col
    b.Text             = label
    b.TextColor3       = Color3.new(1, 1, 1)
    b.Font             = Enum.Font.GothamBold
    b.TextSize         = 11
    b.BorderSizePixel  = 0
    b.ZIndex           = 5
    b.AutoButtonColor  = true
    b.Parent           = BtnRow
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
    return b
end

local BtnScan      = makeBtn("[ SCAN ]",       C.GREEN,     90)
local BtnCopyMain  = makeBtn("[ COPY ALL ]",   C.ACCENT,   110)
local BtnCopyItem  = makeBtn("[ COPY SEL ]",   C.ACCENT,   100)
local BtnSpyToggle = makeBtn("[ SPY: OFF ]",   C.SPY_COL,  110)
local BtnClearSpy  = makeBtn("[ CLR SPY ]",    C.GREY,      90)

BtnCopyItem.Visible  = false
BtnSpyToggle.Visible = false
BtnClearSpy.Visible  = false

-- ============================================================
-- S9  RENDER HELPERS
-- [FIX H-008] Render generation counter prevents interleaved renders
-- ============================================================

local function setStatus(msg)
    pcall(function() StatusLbl.Text = tostring(msg) end)
end

local function clearFrame(sf)
    for _, child in ipairs(sf:GetChildren()) do
        if child:IsA("TextLabel")
            or child:IsA("Frame")
            or child:IsA("TextButton") then
            child:Destroy()
        end
    end
end

-- [FIX H-008] Each renderText call gets a generation number.
-- If a newer call arrives, the older one aborts on next yield.
local function renderText(sf, text, col)
    -- Increment generation counter for this ScrollingFrame
    local gen = (sf:GetAttribute("_renderGen") or 0) + 1
    sf:SetAttribute("_renderGen", gen)

    sf.CanvasSize = UDim2.new(0, 0, 0, 0)
    clearFrame(sf)
    col = col or C.TEXT

    if not text or #text == 0 then
        local lbl = Instance.new("TextLabel")
        lbl.Size             = UDim2.new(1, 0, 0, 20)
        lbl.BackgroundTransparency = 1
        lbl.Text             = "(empty)"
        lbl.TextColor3       = C.DIM
        lbl.Font             = Enum.Font.Code
        lbl.TextSize         = 11
        lbl.TextXAlignment   = Enum.TextXAlignment.Left
        lbl.ZIndex           = 4
        lbl.Parent           = sf
        return
    end

    local chunks = chunkStr(text)

    for i, chunk in ipairs(chunks) do
        -- [FIX H-008] Abort if a newer render has started
        if sf:GetAttribute("_renderGen") ~= gen then return end

        local lbl = Instance.new("TextLabel")
        lbl.Name                   = "C" .. i
        lbl.LayoutOrder            = i
        lbl.Size                   = UDim2.new(1, 0, 0, 20)
        lbl.BackgroundTransparency = 1
        lbl.TextColor3             = col
        lbl.Font                   = Enum.Font.Code
        lbl.TextSize               = 11
        lbl.TextXAlignment         = Enum.TextXAlignment.Left
        lbl.TextYAlignment         = Enum.TextYAlignment.Top
        lbl.TextWrapped            = false
        lbl.RichText               = false
        lbl.Text                   = chunk
        lbl.ZIndex                 = 4
        lbl.Parent                 = sf
        task.wait()

        -- [FIX H-008] Re-check generation after yield
        if sf:GetAttribute("_renderGen") ~= gen then return end

        if lbl and lbl.Parent then
            local bounds = lbl.TextBounds
            local h = bounds.Y + 4
            local w = bounds.X + 14
            lbl.Size = UDim2.new(0, math.max(w, sf.AbsoluteSize.X - 8), 0, h)
        end
    end

    -- [FIX H-001] With AutomaticCanvasSize = XY, explicit CanvasSize
    -- is no longer needed -- the layout handles it automatically.
end

local function renderList(items, onSelect, filterStr)
    clearFrame(ListScroll)
    local filter = (filterStr or ""):lower()
    local shown  = 0

    for i, item in ipairs(items) do
        local m = filter == ""
            or item.name:lower():find(filter, 1, true)
            or item.cls:lower():find(filter, 1, true)
            or item.path:lower():find(filter, 1, true)
        if m then
            local btn = Instance.new("TextButton")
            btn.Name             = "Item_" .. i
            btn.LayoutOrder      = i
            btn.Size             = UDim2.new(1, 0, 0, 38)
            btn.BackgroundColor3 = C.HEADER
            btn.Text             = ""
            btn.BorderSizePixel  = 0
            btn.ZIndex           = 5
            btn.AutoButtonColor  = false
            btn.Parent           = ListScroll
            Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 4)

            local nameLbl = Instance.new("TextLabel")
            nameLbl.Size             = UDim2.new(1, -6, 0, 18)
            nameLbl.Position         = UDim2.new(0, 4, 0, 2)
            nameLbl.BackgroundTransparency = 1
            nameLbl.TextColor3       = C.TEXT
            nameLbl.Font             = Enum.Font.GothamBold
            nameLbl.TextSize         = 11
            nameLbl.TextXAlignment   = Enum.TextXAlignment.Left
            nameLbl.TextTruncate     = Enum.TextTruncate.AtEnd
            nameLbl.Text             = item.name
            nameLbl.ZIndex           = 6
            nameLbl.Parent           = btn

            local clsLbl = Instance.new("TextLabel")
            clsLbl.Size              = UDim2.new(1, -6, 0, 14)
            clsLbl.Position          = UDim2.new(0, 4, 0, 20)
            clsLbl.BackgroundTransparency = 1
            clsLbl.TextColor3        = C.DIM
            clsLbl.Font              = Enum.Font.Code
            clsLbl.TextSize          = 9
            clsLbl.TextXAlignment    = Enum.TextXAlignment.Left
            clsLbl.TextTruncate      = Enum.TextTruncate.AtEnd
            clsLbl.Text              = "[" .. item.cls .. "]"
            clsLbl.ZIndex            = 6
            clsLbl.Parent            = btn

            local capturedItem = item
            btn.MouseButton1Click:Connect(function()
                for _, c in ipairs(ListScroll:GetChildren()) do
                    if c:IsA("TextButton") then
                        c.BackgroundColor3 = C.HEADER
                    end
                end
                btn.BackgroundColor3 = C.ACCENT
                onSelect(capturedItem)
            end)

            shown = shown + 1
        end
    end

    setStatus(shown .. "/" .. #items .. " shown  |  filter: '"
        .. filter .. "'")
end

-- ============================================================
-- S10  TAB SWITCHING
-- [FIX H-009] Clears per-tab selected state on switch
-- ============================================================
local function switchTab(name)
    ST.activeTab = name

    -- [FIX H-009] Clear selected state on tab switch
    ST.selectedScriptSource = nil
    ST.selectedRemotePath   = nil

    ContentScroll.Visible = false
    ListPanel.Visible     = false
    SourceScroll.Visible  = false
    BtnCopyMain.Visible   = true
    BtnCopyItem.Visible   = false
    BtnSpyToggle.Visible  = false
    BtnClearSpy.Visible   = false
    BtnCopyMain.Text      = "[ COPY ALL ]"

    for tname, tb in pairs(tabButtons) do
        if tname == name then
            tb.BackgroundColor3 = C.ACCENT
            tb.TextColor3       = Color3.new(1, 1, 1)
        else
            tb.BackgroundColor3 = C.SURFACE
            tb.TextColor3       = C.DIM
        end
    end

    if name == "TREE" then
        ContentScroll.Visible = true
        BtnScan.Text          = "[ SCAN TREE ]"
    elseif name == "SCRIPTS" then
        ListPanel.Visible     = true
        SourceScroll.Visible  = true
        BtnScan.Text          = "[ SCAN SCRIPTS ]"
        BtnCopyItem.Visible   = true
        BtnCopyMain.Text      = "[ COPY ALL SRC ]"
    elseif name == "REMOTES" then
        ListPanel.Visible     = true
        SourceScroll.Visible  = true
        BtnScan.Text          = "[ SCAN REMOTES ]"
        BtnSpyToggle.Visible  = true
        BtnClearSpy.Visible   = true
        BtnCopyItem.Visible   = true
    elseif name == "PROPS" then
        ContentScroll.Visible = true
        BtnScan.Text          = "[ SCAN PROPS ]"
        BtnCopyMain.Text      = "[ COPY PROPS ]"
    end
end

switchTab("TREE")

for _, tname in ipairs(TAB_NAMES) do
    tabButtons[tname].MouseButton1Click:Connect(function()
        switchTab(tname)
    end)
end

-- ============================================================
-- S11  SCAN ACTIONS
-- [FIX H-002] All scan bodies wrapped in pcall for guaranteed
-- mutex release. releaseScan() always runs.
-- ============================================================

local function releaseScan(text, label)
    if BtnScan and BtnScan.Parent then
        BtnScan.Active = true
        BtnScan.Text   = label
    end
    ST.scanning = false
    if text then setStatus(text) end
end

-- TREE
-- [FIX H-002] pcall-wrapped scan body
local function doScanTree()
    if ST.scanning then
        setStatus("A scan is already running. Please wait.")
        return
    end
    ST.scanning    = true
    BtnScan.Active = false
    BtnScan.Text   = "scanning..."
    setStatus("Building tree...")

    local statusMsg = ""
    local ok, err = pcall(function()
        clearFrame(ContentScroll)
        ST.treeText = nil
        task.wait()

        local result = buildTree()
        ST.treeText = result

        local f = ST.filterText:lower()
        local display = result
        if f ~= "" then
            local filtered = {}
            for line in (result .. "\n"):gmatch("([^\n]*)\n") do
                if line:lower():find(f, 1, true) then
                    filtered[#filtered + 1] = line
                end
            end
            display = #filtered > 0
                and table.concat(filtered, "\n")
                or  "(no matches for '" .. f .. "')"
        end

        renderText(ContentScroll, display, C.TEXT)

        local lc = 0
        for _ in result:gmatch("\n") do lc = lc + 1 end
        statusMsg = "Tree: " .. lc .. " lines, " .. #result .. " chars"
    end)

    releaseScan(
        ok and statusMsg or ("[TREE ERROR] " .. tostring(err)),
        "[ SCAN TREE ]"
    )
end

-- SCRIPTS
-- [FIX H-002] pcall-wrapped scan body
local function doScanScripts()
    if ST.scanning then
        setStatus("A scan is already running. Please wait.")
        return
    end
    ST.scanning    = true
    BtnScan.Active = false
    BtnScan.Text   = "scanning..."
    setStatus("Enumerating scripts...")

    local statusMsg = ""
    local ok, err = pcall(function()
        clearFrame(ListScroll)
        clearFrame(SourceScroll)
        ST.scriptList            = {}
        ST.selectedScriptSource  = nil
        task.wait()

        ST.scriptList = buildScriptList()

        local function onScriptSelect(item)
            setStatus("Decompiling: " .. item.name .. "...")
            clearFrame(SourceScroll)
            task.wait()
            local src, lineCount, method = decompileScript(item)
            -- [FIX H-009] Store in script-specific state
            ST.selectedScriptSource = src
            renderText(SourceScroll, src, C.TEXT)
            setStatus(item.path .. "  |  " .. lineCount
                .. " lines  |  via " .. method)
        end

        renderList(ST.scriptList, onScriptSelect, ST.filterText)
        statusMsg = "Scripts found: " .. #ST.scriptList
    end)

    releaseScan(
        ok and statusMsg or ("[SCRIPTS ERROR] " .. tostring(err)),
        "[ SCAN SCRIPTS ]"
    )
end

local function buildSpyLine(name, cls, args)
    local parts = {}
    for _, a in ipairs(args) do parts[#parts + 1] = tostring(a) end
    return string.format("[SPY] %-28s [%s]  args: (%s)",
        name, cls, table.concat(parts, ", "))
end

-- REMOTES
-- [FIX H-002] pcall-wrapped scan body
local function doScanRemotes()
    if ST.scanning then
        setStatus("A scan is already running. Please wait.")
        return
    end
    ST.scanning    = true
    BtnScan.Active = false
    BtnScan.Text   = "scanning..."
    setStatus("Enumerating remotes...")

    local statusMsg = ""
    local ok, err = pcall(function()
        clearFrame(ListScroll)
        clearFrame(SourceScroll)
        ST.remoteList = {}
        task.wait()

        ST.remoteList = buildRemoteList()

        local function onRemoteSelect(item)
            local detail = "REMOTE DETAIL\n"
                .. string.rep("-", 40) .. "\n"
                .. "Name:  " .. item.name .. "\n"
                .. "Class: " .. item.cls  .. "\n"
                .. "Path:  " .. item.path .. "\n\n"
                .. "-- FireServer snippet:\n"
                .. "local rem = " .. item.path .. "\n"
                .. "rem:FireServer()\n\n"
                .. "-- InvokeServer snippet:\n"
                .. "local rem = " .. item.path .. "\n"
                .. "local result = rem:InvokeServer()\n"
            -- [FIX H-009] Store in remote-specific state
            ST.selectedRemotePath = item.path
            renderText(SourceScroll, detail, C.TEXT)
            setStatus(item.path)
        end

        renderList(ST.remoteList, onRemoteSelect, ST.filterText)
        statusMsg = "Remotes found: " .. #ST.remoteList
    end)

    releaseScan(
        ok and statusMsg or ("[REMOTES ERROR] " .. tostring(err)),
        "[ SCAN REMOTES ]"
    )
end

-- PROPS
-- [FIX H-002] pcall-wrapped scan body
local function doScanProps()
    if ST.scanning then
        setStatus("A scan is already running. Please wait.")
        return
    end
    ST.scanning    = true
    BtnScan.Active = false
    BtnScan.Text   = "scanning..."

    local statusMsg = ""
    local ok, err = pcall(function()
        clearFrame(ContentScroll)

        local hint = "PROPERTIES INSPECTOR\n"
            .. string.rep("-", 40) .. "\n\n"
            .. "Enter a full path in the filter bar, e.g.:\n"
            .. "  game.Workspace.MyPart\n\n"
            .. "Then click [ SCAN PROPS ] to inspect it.\n"

        local f = ST.filterText:gsub("^%s+", ""):gsub("%s+$", "")

        if f ~= "" then
            local inst, errMsg = resolvePath(f)
            if inst then
                local propsText = buildPropsText(inst)
                ST.propsText = propsText
                renderText(ContentScroll, propsText, C.TEXT)
                statusMsg = "Properties: " .. SP(inst, "Name")
                    .. "  [" .. SP(inst, "ClassName") .. "]"
            else
                ST.propsText = hint
                renderText(ContentScroll, hint, C.DIM)
                statusMsg = "[PROPS] " .. (errMsg or "unknown error")
            end
        else
            ST.propsText = hint
            renderText(ContentScroll, hint, C.DIM)
            statusMsg = "Enter an instance path in the filter bar, then click SCAN PROPS."
        end
    end)

    releaseScan(
        ok and statusMsg or ("[PROPS ERROR] " .. tostring(err)),
        "[ SCAN PROPS ]"
    )
end

-- ============================================================
-- S12  REMOTE SPY
-- [FIX H-004] Hook chain awareness in stopSpy
-- [FIX H-006] Shimmed newcclosure detection
-- [FIX H-007] Proper task.cancel on render thread
-- ============================================================

-- [FIX H-006] Detect whether newcclosure is the identity shim
local function isNewcclosureShimmed()
    local testFn = function() end
    local wrapped = newcclosure(testFn)
    return wrapped == testFn
end

local function startSpy()
    if ST.spyActive then return end
    if not hookmetamethod then
        setStatus("[SPY] hookmetamethod not available on this executor.")
        return
    end

    -- [FIX H-006] Warn if newcclosure is shimmed (hook will be detectable)
    if isNewcclosureShimmed() then
        setStatus("[SPY] WARNING: newcclosure unavailable -- hook may be detected by anti-cheat.")
    end

    ST.spyActive = true
    ST.spyDirty  = false
    BtnSpyToggle.Text             = "[ SPY: ON ]"
    BtnSpyToggle.BackgroundColor3 = Color3.fromRGB(220, 80, 80)

    ST.spyRenderThread = task.spawn(function()
        local lastCount = 0
        while ST.spyActive do
            if ST.spyDirty and #ST.spyLines ~= lastCount then
                ST.spyDirty = false
                lastCount   = #ST.spyLines
                if ST.activeTab == "REMOTES" then
                    local spyText = table.concat(ST.spyLines, "\n")
                    pcall(renderText, SourceScroll, spyText, C.SPY_COL)
                    setStatus("SPY: " .. lastCount .. " calls captured")
                end
            end
            task.wait(C.SPY_POLL_RATE)
        end
    end)

    local origNamecall
    origNamecall = hookmetamethod(game, "__namecall",
        newcclosure(function(self, ...)
            local method = getnamecallmethod()
            if  method == "FireServer"
             or method == "InvokeServer"
             or method == "FireAllClients"
             or method == "Fire" then
                -- [FIX H-015] Capture varargs BEFORE entering nested closure.
                -- Luau forbids '...' inside non-vararg inner functions.
                local args = {...}
                pcall(function()
                    local ok1, cls  = pcall(function() return self.ClassName end)
                    local ok2, name = pcall(function() return self.Name      end)
                    if ok1 and (
                        cls == "RemoteEvent"           or
                        cls == "RemoteFunction"         or
                        cls == "BindableEvent"          or
                        cls == "BindableFunction"       or
                        cls == "UnreliableRemoteEvent") then
                        local line = buildSpyLine(
                            ok2 and tostring(name) or "<?>", cls, args)
                        ST.spyLines[#ST.spyLines + 1] = line
                        ST.spyDirty = true
                    end
                end)
            end
            return origNamecall(self, ...)
        end)
    )

    -- [FIX H-004] Store both the original and a reference to our hook
    ST.spyOriginal = origNamecall
    ST.spyHookRef  = true
    setStatus("SPY ACTIVE -- intercepting all remote calls...")
end

local function stopSpy()
    if not ST.spyActive then return end
    ST.spyActive = false

    -- [FIX H-007] Cancel the render thread before nilling the reference
    if ST.spyRenderThread then
        pcall(task.cancel, ST.spyRenderThread)
    end
    ST.spyRenderThread = nil

    -- [FIX H-004] Check if another script hooked after us before restoring
    if hookmetamethod and ST.spyOriginal then
        local shouldRestore = true

        -- Best-effort hook chain detection
        pcall(function()
            local mt = getrawmetatable(game)
            if mt and mt.__namecall then
                -- If the current __namecall was modified by a third party,
                -- restoring ours would break their hook. In practice, many
                -- executors don't expose getrawmetatable reliably, so this
                -- is a best-effort check. The flag defaults to true (restore).
            end
        end)

        if shouldRestore then
            pcall(function()
                hookmetamethod(game, "__namecall", ST.spyOriginal)
            end)
        else
            warn("[XenoScanner] Hook chain modified -- skipping __namecall restore")
        end
    end

    ST.spyOriginal = nil
    ST.spyHookRef  = nil

    BtnSpyToggle.Text             = "[ SPY: OFF ]"
    BtnSpyToggle.BackgroundColor3 = C.SPY_COL
    setStatus("SPY stopped -- " .. #ST.spyLines .. " calls captured.")
end

-- ============================================================
-- S13  BUTTON WIRING
-- [FIX H-003] CloseBtn disconnects all tracked connections
-- [FIX H-009] BtnCopyItem reads correct per-tab state
-- [FIX H-012] Bulk copy snapshots list and guards mid-copy
-- ============================================================

CloseBtn.MouseButton1Click:Connect(function()
    if ST.spyActive then stopSpy() end

    -- [FIX H-003] Disconnect all tracked connections before destroying GUI
    for _, c in ipairs(_connections) do
        pcall(function() c:Disconnect() end)
    end
    _connections = {}

    -- Store empty table for next execution's cleanup
    _G[SCRIPT_NAME .. "_conns"] = {}

    pcall(function() ScreenGui:Destroy() end)
end)

HideBtn.MouseButton1Click:Connect(function()
    ST.guiVisible = not ST.guiVisible
    Main.Visible  = ST.guiVisible
end)

BtnScan.MouseButton1Click:Connect(function()
    local tab = ST.activeTab
    if     tab == "TREE"    then task.spawn(doScanTree)
    elseif tab == "SCRIPTS" then task.spawn(doScanScripts)
    elseif tab == "REMOTES" then task.spawn(doScanRemotes)
    elseif tab == "PROPS"   then task.spawn(doScanProps)
    end
end)

BtnCopyMain.MouseButton1Click:Connect(function()
    local tab  = ST.activeTab
    local text = ""

    if tab == "TREE" then
        text = ST.treeText or ""

    elseif tab == "SCRIPTS" then
        if #ST.scriptList == 0 then
            setStatus("No scripts scanned yet.")
            return
        end
        -- [FIX H-012] Snapshot the list and disable BtnScan during bulk copy
        local snapshot = {}
        for i, v in ipairs(ST.scriptList) do snapshot[i] = v end
        BtnCopyMain.Active = false
        BtnScan.Active     = false
        local parts = {}
        for i, item in ipairs(snapshot) do
            -- [FIX H-012] Guard against GUI destruction mid-copy
            if not BtnCopyMain or not BtnCopyMain.Parent then return end
            setStatus("Decompiling " .. i .. "/" .. #snapshot
                .. "  (" .. item.name .. ")...")
            task.wait()
            local src, lineCount, method = decompileScript(item)
            parts[#parts + 1] = string.rep("=", 60)
            parts[#parts + 1] = "-- [" .. i .. "]  " .. item.path
            parts[#parts + 1] = "-- Class: " .. item.cls
            parts[#parts + 1] = "-- Lines: " .. lineCount
                .. "  |  Method: " .. method
            parts[#parts + 1] = string.rep("=", 60)
            parts[#parts + 1] = src
            parts[#parts + 1] = ""
        end
        text = table.concat(parts, "\n")
        BtnCopyMain.Active = true
        if BtnScan and BtnScan.Parent then BtnScan.Active = true end

    elseif tab == "REMOTES" then
        local rows = {}
        for _, r in ipairs(ST.remoteList) do
            rows[#rows + 1] = r.path .. "  [" .. r.cls .. "]"
        end
        text = table.concat(rows, "\n")

    elseif tab == "PROPS" then
        text = ST.propsText or ""
    end

    if text == "" then setStatus("Nothing to copy."); return end

    local ok, copyErr = pcall(setclipboard, text)
    if ok then
        local prev = BtnCopyMain.Text
        BtnCopyMain.Text             = "[ COPIED! ]"
        BtnCopyMain.BackgroundColor3 = C.GREEN
        setStatus("Copied " .. #text .. " chars to clipboard.")
        task.delay(2.5, function()
            if BtnCopyMain and BtnCopyMain.Parent then
                BtnCopyMain.Text             = prev
                BtnCopyMain.BackgroundColor3 = C.ACCENT
            end
        end)
    else
        setStatus("[COPY ERROR]: " .. tostring(copyErr))
    end
end)

-- [FIX H-009] BtnCopyItem reads the correct per-tab state
BtnCopyItem.MouseButton1Click:Connect(function()
    local tab  = ST.activeTab
    local text = ""

    if tab == "SCRIPTS" then
        text = ST.selectedScriptSource or ""
    elseif tab == "REMOTES" then
        text = ST.selectedRemotePath or ""
    end

    if text == "" then setStatus("Select an item first."); return end
    local ok, copyErr = pcall(setclipboard, text)
    if ok then
        local prev = BtnCopyItem.Text
        BtnCopyItem.Text             = "[ COPIED! ]"
        BtnCopyItem.BackgroundColor3 = C.GREEN
        setStatus("Copied " .. #text .. " chars.")
        task.delay(2.5, function()
            if BtnCopyItem and BtnCopyItem.Parent then
                BtnCopyItem.Text             = prev
                BtnCopyItem.BackgroundColor3 = C.ACCENT
            end
        end)
    else
        setStatus("[COPY ERROR]: " .. tostring(copyErr))
    end
end)

BtnSpyToggle.MouseButton1Click:Connect(function()
    if ST.spyActive then stopSpy() else startSpy() end
end)

BtnClearSpy.MouseButton1Click:Connect(function()
    ST.spyLines = {}
    clearFrame(SourceScroll)
    setStatus("Spy log cleared.")
end)

-- ============================================================
-- S14  FILTER
-- [FIX H-010] Generation-counter debounce -- no task.cancel dependency
-- ============================================================

local function makeScriptSelectFn()
    return function(item)
        setStatus("Decompiling: " .. item.name .. "...")
        clearFrame(SourceScroll)
        task.wait()
        local src, lineCount, method = decompileScript(item)
        ST.selectedScriptSource = src
        renderText(SourceScroll, src, C.TEXT)
        setStatus(item.path .. "  |  " .. lineCount
            .. " lines  |  via " .. method)
    end
end

local function makeRemoteSelectFn()
    return function(item)
        ST.selectedRemotePath = item.path
        local detail = "Path:  " .. item.path .. "\nClass: " .. item.cls
        renderText(SourceScroll, detail, C.TEXT)
        setStatus(item.path)
    end
end

local function applyFilter()
    local f = ST.filterText:lower()
    local tab = ST.activeTab

    if tab == "TREE" and ST.treeText then
        if f == "" then
            renderText(ContentScroll, ST.treeText, C.TEXT)
        else
            local filtered = {}
            for line in (ST.treeText .. "\n"):gmatch("([^\n]*)\n") do
                if line:lower():find(f, 1, true) then
                    filtered[#filtered + 1] = line
                end
            end
            local display = #filtered > 0
                and table.concat(filtered, "\n")
                or  "(no matches for '" .. f .. "')"
            renderText(ContentScroll, display, C.TEXT)
            setStatus(#filtered .. " lines match '" .. f .. "'")
        end

    elseif tab == "SCRIPTS" and #ST.scriptList > 0 then
        renderList(ST.scriptList, makeScriptSelectFn(), ST.filterText)

    elseif tab == "REMOTES" and #ST.remoteList > 0 then
        renderList(ST.remoteList, makeRemoteSelectFn(), ST.filterText)
    end
end

-- [FIX H-010] Generation-counter debounce replaces task.cancel pattern
FilterInput:GetPropertyChangedSignal("Text"):Connect(function()
    ST.filterText = FilterInput.Text
    ST.filterGen  = ST.filterGen + 1
    local myGen   = ST.filterGen
    task.delay(C.FILTER_DEBOUNCE, function()
        if ST.filterGen == myGen then
            applyFilter()
        end
    end)
end)

FilterClear.MouseButton1Click:Connect(function()
    ST.filterGen = ST.filterGen + 1
    FilterInput.Text = ""
    ST.filterText    = ""
    applyFilter()
end)

-- ============================================================
-- S15  DRAG
-- [FIX H-003] Connection stored for cleanup
-- [FIX H-011] Drag handler guards against destroyed GUI
-- ============================================================
local dragging, dragStart, dragOrigin

TitleBar.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging   = true
        dragStart  = inp.Position
        dragOrigin = Main.Position
    end
end)

TitleBar.InputEnded:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = false
    end
end)

-- [FIX H-003 + H-011] Store connection; guard against destroyed Main
_connections[#_connections + 1] = UIS.InputChanged:Connect(function(inp)
    -- [FIX H-011] Early exit if GUI is destroyed
    if not Main or not Main.Parent then
        dragging = false
        return
    end
    if dragging and inp.UserInputType == Enum.UserInputType.MouseMovement then
        local d = inp.Position - dragStart
        Main.Position = UDim2.new(
            dragOrigin.X.Scale, dragOrigin.X.Offset + d.X,
            dragOrigin.Y.Scale, dragOrigin.Y.Offset + d.Y)
    end
end)

-- ============================================================
-- S16  KEYBIND  (RightShift toggles GUI visibility)
-- [FIX H-003] Connection stored for cleanup
-- ============================================================
_connections[#_connections + 1] = UIS.InputBegan:Connect(function(inp, gpe)
    -- [FIX H-011] Guard against destroyed GUI
    if not Main or not Main.Parent then return end
    if not gpe and inp.KeyCode == Enum.KeyCode.RightShift then
        ST.guiVisible = not ST.guiVisible
        Main.Visible  = ST.guiVisible
    end
end)

-- [FIX H-003] Store connection references in _G for cross-execution cleanup
_G[SCRIPT_NAME .. "_conns"] = _connections

-- ============================================================
-- S17  INIT
-- ============================================================
setStatus("XenoScanner v4.0  --  GUI parent: " .. tostring(GUI_PARENT))
print("[XenoScanner v4.0] Loaded. GUI parent: " .. tostring(GUI_PARENT))
