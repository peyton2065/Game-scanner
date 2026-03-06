--[[
╔═══════════════════════════════════════════════════════════════════╗
║              XENO GAME SCANNER  v3.0  — Production               ║
║  Tabs: Tree · Scripts · Remotes · Properties                      ║
║  Author: ENI  |  Safe re-execute  |  Full UNC compatibility       ║
╚═══════════════════════════════════════════════════════════════════╝

  TABS
  ────
  [TREE]       Full game hierarchy, filterable, collapsible roots
  [SCRIPTS]    All scripts in memory via getscripts() + decompile()
               line-by-line source viewer with line numbers
  [REMOTES]    All RemoteEvent / RemoteFunction / Bindable instances
               + live __namecall spy
  [PROPS]      Click any instance path → inspect all properties

  KEYBINDS
  ────────
  RightShift   Toggle GUI visibility
]]

-- ══════════════════════════════════════════════════════════════════
--  §0  UNC SHIMS  (ensure APIs exist regardless of executor)
-- ══════════════════════════════════════════════════════════════════
if not cloneref         then cloneref         = function(o) return o end end
if not getnilinstances  then getnilinstances  = function()  return {} end end
if not getinstances     then getinstances     = function()  return {} end end
if not getscripts       then getscripts       = function()  return {} end end
if not decompile        then decompile        = function()  return nil end end
if not getscriptclosure then getscriptclosure = function()  return nil end end
if not getconstants     then getconstants     = function()  return {} end end
if not getupvalues      then getupvalues      = function()  return {} end end
if not getgc            then getgc            = function()  return {} end end
if not setclipboard     then
    setclipboard = function() error("setclipboard unavailable") end
end
if not hookmetamethod   then hookmetamethod   = nil end  -- spy optional

-- ══════════════════════════════════════════════════════════════════
--  §1  SERVICES
-- ══════════════════════════════════════════════════════════════════
local Players          = cloneref(game:GetService("Players"))
local TweenService     = cloneref(game:GetService("TweenService"))
local UIS              = cloneref(game:GetService("UserInputService"))
local RunService       = cloneref(game:GetService("RunService"))

local LP               = Players.LocalPlayer
local PlayerGui        = LP:WaitForChild("PlayerGui")

-- ══════════════════════════════════════════════════════════════════
--  §2  CLEANUP — safe to re-execute
-- ══════════════════════════════════════════════════════════════════
local OLD = PlayerGui:FindFirstChild("XenoScannerV3")
if OLD then OLD:Destroy() end

-- ══════════════════════════════════════════════════════════════════
--  §3  CONFIG
-- ══════════════════════════════════════════════════════════════════
local C = {
    -- Roots scanned in Tree tab
    ROOTS = {
        "Workspace","Players","Lighting","MaterialService",
        "ReplicatedFirst","ReplicatedStorage","ServerScriptService",
        "ServerStorage","StarterGui","StarterPack","StarterPlayer",
        "Teams","SoundService","TextChatService","CoreGui",
    },
    -- Classes whose children are skipped (performance)
    SKIP  = { Terrain=true },
    -- Max recursion depth for tree
    MAX_DEPTH = 64,
    -- TextLabel hard cap — stay well under 200 000
    CHUNK = 175000,
    -- GUI geometry
    W = 740, H = 520,
    -- Palette
    BG       = Color3.fromRGB( 12,  12,  18),
    SURFACE  = Color3.fromRGB( 20,  20,  30),
    HEADER   = Color3.fromRGB( 18,  18,  28),
    ACCENT   = Color3.fromRGB(108,  92, 231),
    ACCENT2  = Color3.fromRGB( 72, 200, 150),
    DANGER   = Color3.fromRGB(210,  60,  60),
    TEXT     = Color3.fromRGB(225, 225, 240),
    DIM      = Color3.fromRGB(120, 120, 150),
    CODEBG   = Color3.fromRGB(  8,   8,  14),
    LINENO   = Color3.fromRGB( 80,  80, 110),
    SPY_ON   = Color3.fromRGB(220, 160,  40),
}

-- ══════════════════════════════════════════════════════════════════
--  §4  STATE
-- ══════════════════════════════════════════════════════════════════
local ST = {
    activeTab     = "TREE",   -- "TREE" | "SCRIPTS" | "REMOTES" | "PROPS"
    guiVisible    = true,
    spyActive     = false,
    spyHook       = nil,      -- the namecall hook connection
    spyLines      = {},       -- accumulated spy log lines
    treeText      = nil,      -- full raw tree string
    scriptList    = {},       -- array of {name,path,class,instance}
    remoteList    = {},       -- array of {name,path,class,instance}
    selectedScript= nil,      -- currently viewed script source text
    propsText     = nil,      -- currently viewed properties text
    filterText    = "",
    scrollX       = { TREE=0, SCRIPTS=0, REMOTES=0, PROPS=0 },
}

-- ══════════════════════════════════════════════════════════════════
--  §5  UTILITY
-- ══════════════════════════════════════════════════════════════════

-- Safe property read
local function SP(inst, prop)
    local ok, v = pcall(function() return inst[prop] end)
    return ok and tostring(v) or "<locked>"
end

-- Chunk a long string into pieces ≤ CHUNK_SIZE, splitting on \n
local function chunkStr(str)
    local out, s, len = {}, 1, #str
    while s <= len do
        local e = math.min(s + C.CHUNK - 1, len)
        if e < len then
            for i = e, s, -1 do
                if str:sub(i,i) == "\n" then e = i; break end
            end
        end
        out[#out+1] = str:sub(s, e)
        s = e + 1
    end
    return out
end

-- Get full DataModel path of an instance as a string
local function fullPath(inst)
    if inst == game then return "game" end
    local parts = {}
    local cur = inst
    while cur and cur ~= game do
        local ok, n = pcall(function() return cur.Name end)
        parts[#parts+1] = ok and n or "<?>"
        local ok2, p = pcall(function() return cur.Parent end)
        if not ok2 then break end
        cur = p
    end
    -- reverse
    local rev = {}
    for i = #parts, 1, -1 do rev[#rev+1] = parts[i] end
    return "game." .. table.concat(rev, ".")
end

-- Add line numbers to a source string
local function numberLines(src)
    local lines = {}
    local n = 0
    for line in (src.."\n"):gmatch("([^\n]*)\n") do
        n += 1
        lines[#lines+1] = string.format("%5d  %s", n, line)
    end
    return table.concat(lines, "\n"), n
end

-- ══════════════════════════════════════════════════════════════════
--  §6  SCANNER MODULES
-- ══════════════════════════════════════════════════════════════════

----------  6-A  TREE  -----------------------------------------------
local function buildTree()
    local lines = {}
    local function ins(s) lines[#lines+1] = s end

    ins("XENO GAME SCANNER v3.0 — Full Hierarchy")
    ins("Game:    " .. SP(game,"Name"))
    ins("PlaceId: " .. SP(game,"PlaceId"))
    ins("JobId:   " .. SP(game,"JobId"))
    ins(string.rep("─", 60))
    ins("")

    local function recurse(inst, prefix, isLast, depth)
        if type(lines) ~= "table" then return end
        if depth > C.MAX_DEPTH then
            lines[#lines+1] = prefix .. (isLast and "└─ " or "├─ ") .. "[MAX DEPTH]"
            return
        end
        local br   = isLast and "└─ " or "├─ "
        local name = SP(inst, "Name")
        local cls  = SP(inst, "ClassName")
        lines[#lines+1] = prefix .. br .. name .. "  [" .. cls .. "]"

        if C.SKIP[cls] then
            local cp = prefix .. (isLast and "   " or "│  ")
            lines[#lines+1] = cp .. "└─ ... (skipped)"
            return
        end

        local ok, ch = pcall(function() return inst:GetChildren() end)
        if not ok or type(ch)~="table" or #ch==0 then return end

        local cp = prefix .. (isLast and "   " or "│  ")
        for i,child in ipairs(ch) do
            pcall(recurse, child, cp, i==#ch, depth+1)
        end
    end

    for _, svcName in ipairs(C.ROOTS) do
        local ok, svc = pcall(function() return game:GetService(svcName) end)
        if ok and svc then
            local ok2, ch = pcall(function() return svc:GetChildren() end)
            local count   = (ok2 and type(ch)=="table") and #ch or 0
            ins("▸ " .. svcName .. "  [" .. SP(svc,"ClassName") .. "]"
                .. "  (" .. count .. " children)")
            if ok2 and type(ch)=="table" then
                for i,child in ipairs(ch) do
                    pcall(recurse, child, "  ", i==#ch, 1)
                end
            end
            ins("")
        end
    end

    ins(string.rep("─", 60))
    ins("Tree scan complete — " .. #lines .. " lines")
    return table.concat(lines, "\n")
end

----------  6-B  SCRIPTS  --------------------------------------------
local function buildScriptList()
    local list = {}
    local seen = {}

    -- Primary: getscripts()
    local ok, scripts = pcall(getscripts)
    if ok and type(scripts)=="table" then
        for _, s in ipairs(scripts) do
            if not seen[s] then
                seen[s] = true
                local ok2, cls  = pcall(function() return s.ClassName end)
                local ok3, name = pcall(function() return s.Name      end)
                if ok2 and (cls=="LocalScript" or cls=="Script" or cls=="ModuleScript") then
                    list[#list+1] = {
                        name     = ok3 and name or "<?>",
                        cls      = cls,
                        path     = fullPath(s),
                        instance = s,
                    }
                end
            end
        end
    end

    -- Fallback: getinstances() scan
    if #list == 0 then
        local ok2, all = pcall(getinstances)
        if ok2 and type(all)=="table" then
            for _, s in ipairs(all) do
                if not seen[s] then
                    seen[s] = true
                    local ok3, cls = pcall(function() return s.ClassName end)
                    if ok3 and (cls=="LocalScript" or cls=="Script" or cls=="ModuleScript") then
                        local ok4, name = pcall(function() return s.Name end)
                        list[#list+1] = {
                            name     = ok4 and name or "<?>",
                            cls      = cls,
                            path     = fullPath(s),
                            instance = s,
                        }
                    end
                end
            end
        end
    end

    table.sort(list, function(a,b) return a.path < b.path end)
    return list
end

-- Decompile one script — returns (source, lineCount, method)
local function decompileScript(entry)
    local inst = entry.instance

    -- Attempt 1: decompile()
    local ok1, src = pcall(decompile, inst)
    if ok1 and type(src)=="string" and #src > 0 then
        local numbered, n = numberLines(src)
        return numbered, n, "decompile()"
    end

    -- Attempt 2: getscriptclosure → getconstants + getupvalues dump
    local ok2, closure = pcall(getscriptclosure, inst)
    if ok2 and closure then
        local lines = {}
        lines[#lines+1] = "-- decompile() unavailable for this script."
        lines[#lines+1] = "-- Showing closure analysis instead."
        lines[#lines+1] = "--"
        lines[#lines+1] = "-- CONSTANTS:"
        local ok3, consts = pcall(getconstants, closure)
        if ok3 and type(consts)=="table" then
            for i, v in ipairs(consts) do
                lines[#lines+1] = string.format("--   [%d] %s", i, tostring(v))
            end
        else
            lines[#lines+1] = "--   (none)"
        end
        lines[#lines+1] = "--"
        lines[#lines+1] = "-- UPVALUES:"
        local ok4, ups = pcall(getupvalues, closure)
        if ok4 and type(ups)=="table" then
            for k, v in pairs(ups) do
                lines[#lines+1] = string.format("--   [%s] = %s", tostring(k), tostring(v))
            end
        else
            lines[#lines+1] = "--   (none)"
        end
        local src2 = table.concat(lines, "\n")
        local numbered, n = numberLines(src2)
        return numbered, n, "closure dump"
    end

    -- Attempt 3: just say so
    local fallback = "-- Source unavailable.\n-- Script may be protected or obfuscated."
    local numbered, n = numberLines(fallback)
    return numbered, n, "unavailable"
end

----------  6-C  REMOTES  --------------------------------------------
local function buildRemoteList()
    local list = {}
    local seen = {}
    local TARGET = {
        RemoteEvent=true, RemoteFunction=true,
        BindableEvent=true, BindableFunction=true,
        UnreliableRemoteEvent=true,
    }

    local function scan(root)
        if not root then return end
        local ok, desc = pcall(function() return root:GetDescendants() end)
        if not ok or type(desc)~="table" then return end
        for _, inst in ipairs(desc) do
            if not seen[inst] then
                seen[inst] = true
                local ok2, cls = pcall(function() return inst.ClassName end)
                if ok2 and TARGET[cls] then
                    local ok3, name = pcall(function() return inst.Name end)
                    list[#list+1] = {
                        name     = ok3 and name or "<?>",
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
        if ok and svc then scan(svc) end
    end

    -- Also scan nil instances (hidden remotes)
    local ok5, nilInsts = pcall(getnilinstances)
    if ok5 and type(nilInsts)=="table" then
        for _, inst in ipairs(nilInsts) do
            if not seen[inst] then
                seen[inst] = true
                local ok2, cls = pcall(function() return inst.ClassName end)
                if ok2 and TARGET[cls] then
                    local ok3, name = pcall(function() return inst.Name end)
                    list[#list+1] = {
                        name     = ok3 and name or "<?>",
                        cls      = cls,
                        path     = "(nil) " .. (ok3 and name or "<?>"),
                        instance = inst,
                    }
                end
            end
        end
    end

    table.sort(list, function(a,b) return a.path < b.path end)
    return list
end

----------  6-D  PROPERTIES  -----------------------------------------
local function buildPropsText(inst)
    if not inst then return "No instance selected." end

    local lines = {}
    local function ins(s) lines[#lines+1] = s end

    local cls  = SP(inst, "ClassName")
    local name = SP(inst, "Name")
    ins("PROPERTIES — " .. name .. "  [" .. cls .. "]")
    ins("Full path: " .. fullPath(inst))
    ins(string.rep("─", 56))
    ins("")

    -- Read a broad set of common properties with pcall guards
    local PROPS = {
        -- Identity
        "Name","ClassName","Parent",
        -- Common
        "Archivable","Locked",
        -- Parts
        "Position","Orientation","Size","CFrame",
        "Color","BrickColor","Material","Transparency",
        "Anchored","CanCollide","CanQuery","CastShadow",
        "Massless","RootPriority",
        -- Humanoid
        "Health","MaxHealth","WalkSpeed","JumpPower",
        "JumpHeight","DisplayName",
        -- Scripts
        "Disabled","RunContext","Source",
        -- Values
        "Value",
        -- Sounds
        "SoundId","Volume","PlayOnRemove","IsPlaying","Looped",
        -- UI
        "Text","TextColor3","Font","TextSize","BackgroundColor3",
        "Size","Position","Visible","ZIndex",
        -- Misc
        "RespawnLocation","Team","TeamColor","Neutral",
    }

    for _, p in ipairs(PROPS) do
        local ok, v = pcall(function() return inst[p] end)
        if ok then
            ins(string.format("  %-28s = %s", p, tostring(v)))
        end
    end

    ins("")
    ins("CHILDREN  (" .. (function()
        local ok, ch = pcall(function() return inst:GetChildren() end)
        return (ok and type(ch)=="table") and tostring(#ch) or "?" end)() .. ")")
    local ok, ch = pcall(function() return inst:GetChildren() end)
    if ok and type(ch)=="table" then
        for _, child in ipairs(ch) do
            local cn = SP(child,"ClassName")
            local nm = SP(child,"Name")
            ins("    " .. nm .. "  [" .. cn .. "]")
        end
    end

    return table.concat(lines, "\n")
end

-- ══════════════════════════════════════════════════════════════════
--  §7  GUI  CONSTRUCTION
-- ══════════════════════════════════════════════════════════════════

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name           = "XenoScannerV3"
ScreenGui.ResetOnSpawn   = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.IgnoreGuiInset = true
ScreenGui.Parent         = PlayerGui

----  Main window  ----------------------------------------------------
local Main = Instance.new("Frame")
Main.Name             = "Main"
Main.Size             = UDim2.new(0, C.W, 0, C.H)
Main.Position         = UDim2.new(0.5, -C.W/2, 0.5, -C.H/2)
Main.BackgroundColor3 = C.BG
Main.BorderSizePixel  = 0
Main.ClipsDescendants = true
Main.Parent           = ScreenGui
Instance.new("UICorner", Main).CornerRadius = UDim.new(0,10)

-- Outer glow / shadow
local Glow = Instance.new("ImageLabel")
Glow.Name                  = "Glow"
Glow.Size                  = UDim2.new(1, 40, 1, 40)
Glow.Position              = UDim2.new(0,-20,0,-20)
Glow.BackgroundTransparency= 1
Glow.Image                 = "rbxassetid://5028857084"
Glow.ImageColor3           = C.ACCENT
Glow.ImageTransparency     = 0.82
Glow.ScaleType             = Enum.ScaleType.Slice
Glow.SliceCenter           = Rect.new(24,24,276,276)
Glow.ZIndex                = 0
Glow.Parent                = Main

----  Title bar  -------------------------------------------------------
local TitleBar = Instance.new("Frame")
TitleBar.Name             = "TitleBar"
TitleBar.Size             = UDim2.new(1,0,0,40)
TitleBar.BackgroundColor3 = C.HEADER
TitleBar.BorderSizePixel  = 0
TitleBar.ZIndex           = 5
TitleBar.Parent           = Main
Instance.new("UICorner", TitleBar).CornerRadius = UDim.new(0,10)

-- Patch lower-round corners of TitleBar
local TBPatch = Instance.new("Frame")
TBPatch.Size             = UDim2.new(1,0,0,10)
TBPatch.Position         = UDim2.new(0,0,1,-10)
TBPatch.BackgroundColor3 = C.HEADER
TBPatch.BorderSizePixel  = 0
TBPatch.ZIndex           = 5
TBPatch.Parent           = TitleBar

local Stripe = Instance.new("Frame")
Stripe.Size             = UDim2.new(0,3,0,22)
Stripe.Position         = UDim2.new(0,10,0.5,-11)
Stripe.BackgroundColor3 = C.ACCENT
Stripe.BorderSizePixel  = 0
Stripe.ZIndex           = 6
Stripe.Parent           = TitleBar
Instance.new("UICorner",Stripe).CornerRadius=UDim.new(0,2)

local TitleLbl = Instance.new("TextLabel")
TitleLbl.Text              = "XENO GAME SCANNER   v3.0"
TitleLbl.Size              = UDim2.new(1,-110,1,0)
TitleLbl.Position          = UDim2.new(0,20,0,0)
TitleLbl.BackgroundTransparency = 1
TitleLbl.TextColor3        = C.TEXT
TitleLbl.Font              = Enum.Font.GothamBold
TitleLbl.TextSize          = 13
TitleLbl.TextXAlignment    = Enum.TextXAlignment.Left
TitleLbl.ZIndex            = 6
TitleLbl.Parent            = TitleBar

-- Title bar buttons (close, minimise)
local function makeTitleBtn(xOff, col, lbl)
    local b = Instance.new("TextButton")
    b.Size             = UDim2.new(0,26,0,26)
    b.Position         = UDim2.new(1,xOff,0.5,-13)
    b.BackgroundColor3 = col
    b.Text             = lbl
    b.TextColor3       = Color3.new(1,1,1)
    b.Font             = Enum.Font.GothamBold
    b.TextSize         = 11
    b.BorderSizePixel  = 0
    b.ZIndex           = 7
    b.Parent           = TitleBar
    Instance.new("UICorner",b).CornerRadius=UDim.new(0,5)
    return b
end
local CloseBtn = makeTitleBtn(-34, C.DANGER,      "✕")
local HideBtn  = makeTitleBtn(-64, Color3.fromRGB(80,80,100), "−")

----  Tab bar  ---------------------------------------------------------
local TabBar = Instance.new("Frame")
TabBar.Name             = "TabBar"
TabBar.Size             = UDim2.new(1,0,0,32)
TabBar.Position         = UDim2.new(0,0,0,40)
TabBar.BackgroundColor3 = C.SURFACE
TabBar.BorderSizePixel  = 0
TabBar.ZIndex           = 4
TabBar.Parent           = Main

local TabLayout = Instance.new("UIListLayout")
TabLayout.FillDirection  = Enum.FillDirection.Horizontal
TabLayout.Padding        = UDim.new(0,1)
TabLayout.VerticalAlignment = Enum.VerticalAlignment.Center
TabLayout.Parent         = TabBar

local UIPadTabBar = Instance.new("UIPadding")
UIPadTabBar.PaddingLeft = UDim.new(0,6)
UIPadTabBar.Parent      = TabBar

local TAB_NAMES = {"TREE","SCRIPTS","REMOTES","PROPS"}
local tabButtons = {}

for _, tname in ipairs(TAB_NAMES) do
    local tb = Instance.new("TextButton")
    tb.Name             = "Tab_"..tname
    tb.Size             = UDim2.new(0,100,1,-6)
    tb.BackgroundColor3 = C.SURFACE
    tb.Text             = tname
    tb.TextColor3       = C.DIM
    tb.Font             = Enum.Font.GothamBold
    tb.TextSize         = 11
    tb.BorderSizePixel  = 0
    tb.ZIndex           = 5
    tb.AutoButtonColor  = false
    tb.Parent           = TabBar
    Instance.new("UICorner",tb).CornerRadius=UDim.new(0,5)
    tabButtons[tname] = tb
end

----  Filter bar  ------------------------------------------------------
local FilterBar = Instance.new("Frame")
FilterBar.Name             = "FilterBar"
FilterBar.Size             = UDim2.new(1,-16,0,26)
FilterBar.Position         = UDim2.new(0,8,0,76)
FilterBar.BackgroundColor3 = C.SURFACE
FilterBar.BorderSizePixel  = 0
FilterBar.ZIndex           = 4
FilterBar.Parent           = Main
Instance.new("UICorner",FilterBar).CornerRadius=UDim.new(0,5)

local FilterIcon = Instance.new("TextLabel")
FilterIcon.Text              = "⌕"
FilterIcon.Size              = UDim2.new(0,24,1,0)
FilterIcon.Position          = UDim2.new(0,4,0,0)
FilterIcon.BackgroundTransparency = 1
FilterIcon.TextColor3        = C.DIM
FilterIcon.Font              = Enum.Font.GothamBold
FilterIcon.TextSize          = 14
FilterIcon.ZIndex            = 5
FilterIcon.Parent            = FilterBar

local FilterInput = Instance.new("TextBox")
FilterInput.Name              = "FilterInput"
FilterInput.Size              = UDim2.new(1,-36,1,0)
FilterInput.Position          = UDim2.new(0,28,0,0)
FilterInput.BackgroundTransparency = 1
FilterInput.TextColor3        = C.TEXT
FilterInput.PlaceholderText   = "Filter by name or class..."
FilterInput.PlaceholderColor3 = C.DIM
FilterInput.Font              = Enum.Font.Code
FilterInput.TextSize          = 11
FilterInput.TextXAlignment    = Enum.TextXAlignment.Left
FilterInput.ClearTextOnFocus  = false
FilterInput.ZIndex            = 5
FilterInput.Parent            = FilterBar

local FilterClear = Instance.new("TextButton")
FilterClear.Size             = UDim2.new(0,24,1,0)
FilterClear.Position         = UDim2.new(1,-26,0,0)
FilterClear.BackgroundTransparency = 1
FilterClear.Text             = "✕"
FilterClear.TextColor3       = C.DIM
FilterClear.Font             = Enum.Font.GothamBold
FilterClear.TextSize         = 11
FilterClear.ZIndex           = 5
FilterClear.Parent           = FilterBar

----  Main content scroll  --------------------------------------------
-- Shared scroll frame used by all tabs for primary text output
local ContentScroll = Instance.new("ScrollingFrame")
ContentScroll.Name                 = "ContentScroll"
ContentScroll.Size                 = UDim2.new(1,-16,1,-152)
ContentScroll.Position             = UDim2.new(0,8,0,108)
ContentScroll.BackgroundColor3     = C.CODEBG
ContentScroll.BorderSizePixel      = 0
ContentScroll.ScrollBarThickness   = 5
ContentScroll.ScrollBarImageColor3 = C.ACCENT
ContentScroll.CanvasSize           = UDim2.new(0,0,0,0)
ContentScroll.AutomaticCanvasSize  = Enum.AutomaticSize.Y
ContentScroll.ZIndex               = 3
ContentScroll.Parent               = Main
Instance.new("UICorner",ContentScroll).CornerRadius=UDim.new(0,6)

local ContentLayout = Instance.new("UIListLayout")
ContentLayout.SortOrder = Enum.SortOrder.LayoutOrder
ContentLayout.Padding   = UDim.new(0,0)
ContentLayout.Parent    = ContentScroll

-- Script/Remote list panel (left side of split view for SCRIPTS/REMOTES)
local ListPanel = Instance.new("Frame")
ListPanel.Name             = "ListPanel"
ListPanel.Size             = UDim2.new(0,210,1,-152)
ListPanel.Position         = UDim2.new(0,8,0,108)
ListPanel.BackgroundColor3 = C.SURFACE
ListPanel.BorderSizePixel  = 0
ListPanel.ZIndex           = 3
ListPanel.Visible          = false
ListPanel.Parent           = Main
Instance.new("UICorner",ListPanel).CornerRadius=UDim.new(0,6)

local ListScroll = Instance.new("ScrollingFrame")
ListScroll.Size               = UDim2.new(1,-4,1,-4)
ListScroll.Position           = UDim2.new(0,2,0,2)
ListScroll.BackgroundTransparency = 1
ListScroll.BorderSizePixel    = 0
ListScroll.ScrollBarThickness = 4
ListScroll.ScrollBarImageColor3 = C.ACCENT
ListScroll.CanvasSize         = UDim2.new(0,0,0,0)
ListScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
ListScroll.ZIndex             = 4
ListScroll.Parent             = ListPanel

local ListItemLayout = Instance.new("UIListLayout")
ListItemLayout.SortOrder = Enum.SortOrder.LayoutOrder
ListItemLayout.Padding   = UDim.new(0,2)
ListItemLayout.Parent    = ListScroll

local UIPadList = Instance.new("UIPadding")
UIPadList.PaddingLeft   = UDim.new(0,4)
UIPadList.PaddingTop    = UDim.new(0,4)
UIPadList.PaddingRight  = UDim.new(0,4)
UIPadList.Parent        = ListScroll

-- Source/detail panel (right side of split view)
local SourceScroll = Instance.new("ScrollingFrame")
SourceScroll.Name                 = "SourceScroll"
SourceScroll.Size                 = UDim2.new(1,-230,1,-152)
SourceScroll.Position             = UDim2.new(0,224,0,108)
SourceScroll.BackgroundColor3     = C.CODEBG
SourceScroll.BorderSizePixel      = 0
SourceScroll.ScrollBarThickness   = 5
SourceScroll.ScrollBarImageColor3 = C.ACCENT2
SourceScroll.CanvasSize           = UDim2.new(0,0,0,0)
SourceScroll.AutomaticCanvasSize  = Enum.AutomaticSize.Y
SourceScroll.ZIndex               = 3
SourceScroll.Visible              = false
SourceScroll.Parent               = Main
Instance.new("UICorner",SourceScroll).CornerRadius=UDim.new(0,6)

local SourceLayout = Instance.new("UIListLayout")
SourceLayout.SortOrder = Enum.SortOrder.LayoutOrder
SourceLayout.Padding   = UDim.new(0,0)
SourceLayout.Parent    = SourceScroll

----  Status bar  ------------------------------------------------------
local StatusBar = Instance.new("Frame")
StatusBar.Name             = "StatusBar"
StatusBar.Size             = UDim2.new(1,0,0,22)
StatusBar.Position         = UDim2.new(0,0,1,-44)
StatusBar.BackgroundColor3 = C.SURFACE
StatusBar.BorderSizePixel  = 0
StatusBar.ZIndex           = 4
StatusBar.Parent           = Main

local StatusLbl = Instance.new("TextLabel")
StatusLbl.Size             = UDim2.new(1,-12,1,0)
StatusLbl.Position         = UDim2.new(0,10,0,0)
StatusLbl.BackgroundTransparency = 1
StatusLbl.TextColor3       = C.DIM
StatusLbl.Font             = Enum.Font.Code
StatusLbl.TextSize         = 10
StatusLbl.TextXAlignment   = Enum.TextXAlignment.Left
StatusLbl.Text             = "Ready."
StatusLbl.ZIndex           = 5
StatusLbl.Parent           = StatusBar

----  Bottom button row  -----------------------------------------------
local BtnRow = Instance.new("Frame")
BtnRow.Name             = "BtnRow"
BtnRow.Size             = UDim2.new(1,-16,0,34)
BtnRow.Position         = UDim2.new(0,8,1,-40)
BtnRow.BackgroundTransparency = 1
BtnRow.ZIndex           = 4
BtnRow.Parent           = Main

local BtnRowLayout = Instance.new("UIListLayout")
BtnRowLayout.FillDirection     = Enum.FillDirection.Horizontal
BtnRowLayout.Padding           = UDim.new(0,6)
BtnRowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
BtnRowLayout.Parent            = BtnRow

local function makeBtn(label, col, w)
    local b = Instance.new("TextButton")
    b.Size             = UDim2.new(0, w or 120, 1, 0)
    b.BackgroundColor3 = col
    b.Text             = label
    b.TextColor3       = Color3.new(1,1,1)
    b.Font             = Enum.Font.GothamBold
    b.TextSize         = 11
    b.BorderSizePixel  = 0
    b.ZIndex           = 5
    b.AutoButtonColor  = true
    b.Parent           = BtnRow
    Instance.new("UICorner",b).CornerRadius=UDim.new(0,6)
    return b
end

local BtnScan      = makeBtn("▶  SCAN",              Color3.fromRGB(40,180,100), 100)
local BtnCopyMain  = makeBtn("⎘  COPY ALL",           C.ACCENT,                  110)
local BtnCopyItem  = makeBtn("⎘  COPY SELECTED",      C.ACCENT,                  130)
local BtnSpyToggle = makeBtn("◉  SPY: OFF",           C.SPY_ON,                  110)
local BtnClearSpy  = makeBtn("⌫  CLEAR SPY",          Color3.fromRGB(80,80,110), 100)

-- Only certain buttons visible per tab — managed in switchTab()
BtnCopyItem.Visible  = false
BtnSpyToggle.Visible = false
BtnClearSpy.Visible  = false

-- ══════════════════════════════════════════════════════════════════
--  §8  RENDER HELPERS
-- ══════════════════════════════════════════════════════════════════

local function setStatus(msg)
    StatusLbl.Text = msg
end

-- Clear a scroll frame (remove all TextLabels/Frames children)
local function clearFrame(sf)
    for _, c in ipairs(sf:GetChildren()) do
        if c:IsA("TextLabel") or c:IsA("Frame") or c:IsA("TextButton") then
            c:Destroy()
        end
    end
end

-- Render a long string into chunked TextLabels inside a scroll frame
local function renderText(sf, layout, text, color)
    clearFrame(sf)
    color = color or C.TEXT
    if not text or #text == 0 then
        local lbl = Instance.new("TextLabel")
        lbl.Size             = UDim2.new(1,0,0,20)
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
    local maxW   = sf.AbsoluteSize.X

    for i, chunk in ipairs(chunks) do
        local lbl = Instance.new("TextLabel")
        lbl.Name                   = "C"..i
        lbl.LayoutOrder            = i
        lbl.Size                   = UDim2.new(1,0,0,10)
        lbl.AutomaticSize          = Enum.AutomaticSize.Y
        lbl.BackgroundTransparency = 1
        lbl.TextColor3             = color
        lbl.Font                   = Enum.Font.Code
        lbl.TextSize               = 11
        lbl.TextXAlignment         = Enum.TextXAlignment.Left
        lbl.TextYAlignment         = Enum.TextYAlignment.Top
        lbl.TextWrapped            = false
        lbl.RichText               = false
        lbl.Text                   = chunk
        lbl.ZIndex                 = 4
        lbl.Parent                 = sf
        task.wait()   -- yield each chunk so Roblox can breathe
        local w = lbl.TextBounds.X + 14
        if w > maxW then maxW = w end
    end

    -- X axis: AutomaticCanvasSize only handles Y; set X manually
    sf.CanvasSize = UDim2.new(0, maxW, 0, 0)
end

-- Render a list of {name, cls, path} items as clickable buttons
local function renderList(items, onSelect, filterStr)
    clearFrame(ListScroll)
    local filter = (filterStr or ""):lower()
    local shown  = 0

    for i, item in ipairs(items) do
        if filter == "" or
           item.name:lower():find(filter, 1, true) or
           item.cls:lower():find(filter, 1, true)  or
           item.path:lower():find(filter, 1, true) then

            local btn = Instance.new("TextButton")
            btn.Name             = "Item_"..i
            btn.LayoutOrder      = i
            btn.Size             = UDim2.new(1,0,0,38)
            btn.BackgroundColor3 = C.HEADER
            btn.Text             = ""
            btn.BorderSizePixel  = 0
            btn.ZIndex           = 5
            btn.AutoButtonColor  = false
            btn.Parent           = ListScroll
            Instance.new("UICorner",btn).CornerRadius=UDim.new(0,4)

            local nameLbl = Instance.new("TextLabel")
            nameLbl.Size             = UDim2.new(1,-6,0,18)
            nameLbl.Position         = UDim2.new(0,4,0,2)
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
            clsLbl.Size              = UDim2.new(1,-6,0,14)
            clsLbl.Position          = UDim2.new(0,4,0,20)
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
                -- Highlight selected
                for _, c in ipairs(ListScroll:GetChildren()) do
                    if c:IsA("TextButton") then
                        c.BackgroundColor3 = C.HEADER
                    end
                end
                btn.BackgroundColor3 = C.ACCENT
                onSelect(capturedItem)
            end)

            shown += 1
        end
    end

    setStatus(shown .. " / " .. #items .. " items shown  |  filter: '" .. filter .. "'")
end

-- ══════════════════════════════════════════════════════════════════
--  §9  TAB SWITCHING
-- ══════════════════════════════════════════════════════════════════

local function switchTab(name)
    ST.activeTab = name

    -- Reset layout visibility
    ContentScroll.Visible = false
    ListPanel.Visible     = false
    SourceScroll.Visible  = false
    BtnCopyMain.Visible   = true
    BtnCopyItem.Visible   = false
    BtnSpyToggle.Visible  = false
    BtnClearSpy.Visible   = false
    BtnScan.Visible       = true

    -- Tab button highlight
    for tname, tb in pairs(tabButtons) do
        if tname == name then
            tb.BackgroundColor3 = C.ACCENT
            tb.TextColor3       = Color3.new(1,1,1)
        else
            tb.BackgroundColor3 = C.SURFACE
            tb.TextColor3       = C.DIM
        end
    end

    if name == "TREE" then
        ContentScroll.Visible = true
        BtnScan.Text          = "▶  SCAN TREE"

    elseif name == "SCRIPTS" then
        ListPanel.Visible     = true
        SourceScroll.Visible  = true
        BtnScan.Text          = "▶  SCAN SCRIPTS"
        BtnCopyItem.Visible   = true
        BtnCopyMain.Text      = "⎘  COPY ALL SRC"

    elseif name == "REMOTES" then
        ListPanel.Visible     = true
        SourceScroll.Visible  = true
        BtnScan.Text          = "▶  SCAN REMOTES"
        BtnSpyToggle.Visible  = true
        BtnClearSpy.Visible   = true
        BtnCopyItem.Visible   = true
        BtnCopyMain.Text      = "⎘  COPY ALL"

    elseif name == "PROPS" then
        ContentScroll.Visible = true
        BtnScan.Text          = "▶  SCAN PROPS"
        BtnCopyMain.Text      = "⎘  COPY PROPS"
    end
end

switchTab("TREE")

for _, tname in ipairs(TAB_NAMES) do
    tabButtons[tname].MouseButton1Click:Connect(function()
        switchTab(tname)
    end)
end

-- ══════════════════════════════════════════════════════════════════
--  §10  SCAN ACTIONS
-- ══════════════════════════════════════════════════════════════════

----  TREE  -----------------------------------------------------------
local function doScanTree()
    BtnScan.Active = false
    BtnScan.Text   = "SCANNING..."
    setStatus("Building tree...")
    clearFrame(ContentScroll)
    ST.treeText = nil
    task.wait()

    local ok, result = pcall(buildTree)
    if not ok then result = "[TREE ERROR]: " .. tostring(result) end
    ST.treeText = result

    -- Apply filter
    local f = ST.filterText:lower()
    local display = result
    if f ~= "" then
        local filtered = {}
        for line in (result.."\n"):gmatch("([^\n]*)\n") do
            if line:lower():find(f,1,true) then
                filtered[#filtered+1] = line
            end
        end
        display = table.concat(filtered, "\n")
        if #filtered == 0 then display = "(no matches for '" .. f .. "')" end
    end

    renderText(ContentScroll, ContentLayout, display, C.TEXT)

    local lc = 0
    for _ in result:gmatch("\n") do lc+=1 end
    setStatus("Tree: " .. lc .. " lines, " .. #result .. " chars")
    BtnScan.Active = true
    BtnScan.Text   = "▶  SCAN TREE"
end

----  SCRIPTS  --------------------------------------------------------
local function doScanScripts()
    BtnScan.Active = false
    BtnScan.Text   = "SCANNING..."
    setStatus("Enumerating scripts...")
    clearFrame(ListScroll)
    clearFrame(SourceScroll)
    ST.scriptList      = {}
    ST.selectedScript  = nil
    task.wait()

    ST.scriptList = buildScriptList()

    renderList(ST.scriptList, function(item)
        -- On click: decompile and show source
        setStatus("Decompiling: " .. item.name .. "...")
        clearFrame(SourceScroll)
        task.wait()

        local src, lineCount, method = decompileScript(item)
        ST.selectedScript = src

        renderText(SourceScroll, SourceLayout, src, C.TEXT)
        setStatus(item.path .. "  |  " .. lineCount .. " lines  |  via " .. method)
    end, ST.filterText)

    setStatus("Scripts found: " .. #ST.scriptList)
    BtnScan.Active = true
    BtnScan.Text   = "▶  SCAN SCRIPTS"
end

----  REMOTES  --------------------------------------------------------
local function buildSpyLine(name, cls, args)
    local argStrs = {}
    for _, a in ipairs(args) do
        argStrs[#argStrs+1] = tostring(a)
    end
    return string.format("[SPY] %-28s [%s]  args: (%s)",
        name, cls, table.concat(argStrs, ", "))
end

local function doScanRemotes()
    BtnScan.Active = false
    BtnScan.Text   = "SCANNING..."
    setStatus("Enumerating remotes...")
    clearFrame(ListScroll)
    clearFrame(SourceScroll)
    ST.remoteList = {}
    task.wait()

    ST.remoteList = buildRemoteList()

    renderList(ST.remoteList, function(item)
        -- Show full path + class + copy hint in source panel
        local detail = "REMOTE DETAIL\n"
            .. string.rep("─",40) .. "\n"
            .. "Name:  " .. item.name .. "\n"
            .. "Class: " .. item.cls  .. "\n"
            .. "Path:  " .. item.path .. "\n\n"
            .. "-- FireServer snippet:\n"
            .. "local rem = " .. item.path .. "\n"
            .. "rem:FireServer(  )\n\n"
            .. "-- InvokeServer snippet:\n"
            .. "local rem = " .. item.path .. "\n"
            .. "local result = rem:InvokeServer(  )\n"
        ST.selectedScript = item.path  -- for copy-selected
        renderText(SourceScroll, SourceLayout, detail, C.TEXT)
        setStatus(item.path)
    end, ST.filterText)

    setStatus("Remotes found: " .. #ST.remoteList)
    BtnScan.Active = true
    BtnScan.Text   = "▶  SCAN REMOTES"
end

----  PROPS  ----------------------------------------------------------
-- Props tab: show instructions; user picks from a prompted path
local function doScanProps()
    BtnScan.Active = false
    BtnScan.Text   = "SCANNING..."
    clearFrame(ContentScroll)
    setStatus("Use SCRIPTS or REMOTES tab → click item, then switch here.")

    local hint = "PROPERTIES INSPECTOR\n"
        .. string.rep("─",40) .. "\n\n"
        .. "How to inspect an instance:\n\n"
        .. "  1. Run a TREE scan.\n"
        .. "  2. Find the full instance path in the tree output.\n"
        .. "  3. Paste it into the filter bar, e.g.:\n"
        .. "        game.Workspace.MyPart\n"
        .. "  4. Click SCAN PROPS — the inspector\n"
        .. "     will resolve the path and display\n"
        .. "     all readable properties.\n\n"
        .. "-- Or call this function in your own script:\n"
        .. "-- local inst = game.Workspace.MyPart\n"
        .. "-- (inspector will render automatically)\n"

    local f = ST.filterText
    local resolved = nil

    if f ~= "" then
        -- Attempt to resolve filter as a path like "game.X.Y.Z"
        local pathStr = f:gsub("^%s+",""):gsub("%s+$","")
        local ok, inst = pcall(function()
            -- Build a traversal from the path string
            local parts = {}
            for p in pathStr:gmatch("[^%.]+") do parts[#parts+1] = p end
            if parts[1] ~= "game" then return nil end
            local cur = game
            for i = 2, #parts do
                cur = cur:FindFirstChild(parts[i]) or cur[parts[i]]
            end
            return cur
        end)
        if ok and inst and typeof(inst) == "Instance" then
            resolved = inst
        end
    end

    if resolved then
        local propsText = buildPropsText(resolved)
        ST.propsText = propsText
        renderText(ContentScroll, ContentLayout, propsText, C.TEXT)
        setStatus("Properties: " .. SP(resolved,"Name") .. "  [" .. SP(resolved,"ClassName") .. "]")
    else
        ST.propsText = hint
        renderText(ContentScroll, ContentLayout, hint, C.DIM)
        setStatus("Enter a full instance path in the filter bar, then click SCAN PROPS.")
    end

    BtnScan.Active = true
    BtnScan.Text   = "▶  SCAN PROPS"
end

----  Remote spy  -----------------------------------------------------
local function startSpy()
    if ST.spyActive then return end
    if not hookmetamethod then
        setStatus("[SPY] hookmetamethod unavailable on this executor.")
        return
    end

    ST.spyActive = true
    BtnSpyToggle.Text             = "◉  SPY: ON"
    BtnSpyToggle.BackgroundColor3 = Color3.fromRGB(220,80,80)

    local old
    old = hookmetamethod(game, "__namecall", newcclosure and newcclosure(function(self, ...)
        local method = getnamecallmethod and getnamecallmethod() or ""
        if (method == "FireServer" or method == "InvokeServer" or
            method == "FireAllClients" or method == "Fire") then
            pcall(function()
                local ok1, cls  = pcall(function() return self.ClassName end)
                local ok2, name = pcall(function() return self.Name      end)
                if ok1 and (
                    cls == "RemoteEvent"   or cls == "RemoteFunction" or
                    cls == "BindableEvent" or cls == "BindableFunction" or
                    cls == "UnreliableRemoteEvent") then
                    local args = {...}
                    local line = buildSpyLine(
                        ok2 and name or "<?>", cls, args)
                    ST.spyLines[#ST.spyLines+1] = line
                    -- Refresh spy display if still on REMOTES tab
                    if ST.activeTab == "REMOTES" then
                        local spyText = table.concat(ST.spyLines, "\n")
                        -- only re-render if last line is visible (avoid spam)
                        if #ST.spyLines % 5 == 0 then
                            renderText(SourceScroll, SourceLayout, spyText, C.SPY_ON)
                            setStatus("SPY ACTIVE — " .. #ST.spyLines .. " calls captured")
                        end
                    end
                end
            end)
        end
        return old(self, ...)
    end) or function(self, ...)
        return old(self, ...)
    end)

    ST.spyHook = old
    setStatus("SPY ACTIVE — watching all remote calls...")
end

local function stopSpy()
    ST.spyActive = false
    BtnSpyToggle.Text             = "◉  SPY: OFF"
    BtnSpyToggle.BackgroundColor3 = C.SPY_ON
    setStatus("SPY stopped — " .. #ST.spyLines .. " calls captured.")
end

-- ══════════════════════════════════════════════════════════════════
--  §11  BUTTON WIRING
-- ══════════════════════════════════════════════════════════════════

CloseBtn.MouseButton1Click:Connect(function()
    if ST.spyActive then stopSpy() end
    ScreenGui:Destroy()
end)

HideBtn.MouseButton1Click:Connect(function()
    ST.guiVisible = not ST.guiVisible
    Main.Visible  = ST.guiVisible
end)

BtnScan.MouseButton1Click:Connect(function()
    local tab = ST.activeTab
    if     tab == "TREE"    then doScanTree()
    elseif tab == "SCRIPTS" then doScanScripts()
    elseif tab == "REMOTES" then doScanRemotes()
    elseif tab == "PROPS"   then doScanProps()
    end
end)

BtnCopyMain.MouseButton1Click:Connect(function()
    local tab  = ST.activeTab
    local text = ""

    if tab == "TREE" then
        text = ST.treeText or ""
    elseif tab == "SCRIPTS" then
        -- Concatenate ALL script sources
        if #ST.scriptList == 0 then
            setStatus("No scripts scanned yet.")
            return
        end
        setStatus("Decompiling all " .. #ST.scriptList .. " scripts...")
        local parts = {}
        for i, item in ipairs(ST.scriptList) do
            setStatus("Decompiling " .. i .. "/" .. #ST.scriptList .. "...")
            task.wait()
            local src, lineCount, method = decompileScript(item)
            parts[#parts+1] = string.rep("=",60)
            parts[#parts+1] = "-- [" .. i .. "] " .. item.path
            parts[#parts+1] = "-- Class: " .. item.cls
            parts[#parts+1] = "-- Lines: " .. lineCount .. "  |  Method: " .. method
            parts[#parts+1] = string.rep("=",60)
            parts[#parts+1] = src
            parts[#parts+1] = ""
        end
        text = table.concat(parts, "\n")
    elseif tab == "REMOTES" then
        local rows = {}
        for _, r in ipairs(ST.remoteList) do
            rows[#rows+1] = r.path .. "  [" .. r.cls .. "]"
        end
        text = table.concat(rows, "\n")
    elseif tab == "PROPS" then
        text = ST.propsText or ""
    end

    if text == "" then setStatus("Nothing to copy."); return end
    local ok, err = pcall(setclipboard, text)
    if ok then
        local prev = BtnCopyMain.Text
        BtnCopyMain.Text             = "✓ COPIED!"
        BtnCopyMain.BackgroundColor3 = Color3.fromRGB(40,180,100)
        setStatus("Copied " .. #text .. " characters to clipboard.")
        task.delay(2.5, function()
            if BtnCopyMain and BtnCopyMain.Parent then
                BtnCopyMain.Text             = prev
                BtnCopyMain.BackgroundColor3 = C.ACCENT
            end
        end)
    else
        setStatus("[COPY ERROR]: " .. tostring(err))
    end
end)

BtnCopyItem.MouseButton1Click:Connect(function()
    local text = ST.selectedScript or ""
    if text == "" then setStatus("Select an item first."); return end
    local ok, err = pcall(setclipboard, text)
    if ok then
        local prev = BtnCopyItem.Text
        BtnCopyItem.Text             = "✓ COPIED!"
        BtnCopyItem.BackgroundColor3 = Color3.fromRGB(40,180,100)
        setStatus("Copied selected item (" .. #text .. " chars).")
        task.delay(2.5, function()
            if BtnCopyItem and BtnCopyItem.Parent then
                BtnCopyItem.Text             = prev
                BtnCopyItem.BackgroundColor3 = C.ACCENT
            end
        end)
    else
        setStatus("[COPY ERROR]: " .. tostring(err))
    end
end)

BtnSpyToggle.MouseButton1Click:Connect(function()
    if ST.spyActive then stopSpy()
    else startSpy() end
end)

BtnClearSpy.MouseButton1Click:Connect(function()
    ST.spyLines = {}
    clearFrame(SourceScroll)
    setStatus("Spy log cleared.")
end)

FilterInput:GetPropertyChangedSignal("Text"):Connect(function()
    ST.filterText = FilterInput.Text
    -- Live-filter the active list/tree
    if ST.activeTab == "TREE" and ST.treeText then
        local f = ST.filterText:lower()
        if f == "" then
            renderText(ContentScroll, ContentLayout, ST.treeText, C.TEXT)
        else
            local filtered = {}
            for line in (ST.treeText.."\n"):gmatch("([^\n]*)\n") do
                if line:lower():find(f,1,true) then
                    filtered[#filtered+1] = line
                end
            end
            local display = #filtered > 0
                and table.concat(filtered, "\n")
                or  "(no matches for '"..f.."')"
            renderText(ContentScroll, ContentLayout, display, C.TEXT)
            setStatus(#filtered .. " lines match '" .. f .. "'")
        end
    elseif ST.activeTab == "SCRIPTS" and #ST.scriptList > 0 then
        renderList(ST.scriptList, function(item)
            setStatus("Decompiling: " .. item.name .. "...")
            clearFrame(SourceScroll)
            task.wait()
            local src, lineCount, method = decompileScript(item)
            ST.selectedScript = src
            renderText(SourceScroll, SourceLayout, src, C.TEXT)
            setStatus(item.path .. "  |  " .. lineCount .. " lines  |  via " .. method)
        end, ST.filterText)
    elseif ST.activeTab == "REMOTES" and #ST.remoteList > 0 then
        renderList(ST.remoteList, function(item)
            ST.selectedScript = item.path
            local detail = "Path:  " .. item.path .. "\nClass: " .. item.cls
            renderText(SourceScroll, SourceLayout, detail, C.TEXT)
            setStatus(item.path)
        end, ST.filterText)
    end
end)

FilterClear.MouseButton1Click:Connect(function()
    FilterInput.Text = ""
    ST.filterText    = ""
end)

-- ══════════════════════════════════════════════════════════════════
--  §12  DRAG
-- ══════════════════════════════════════════════════════════════════
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
UIS.InputChanged:Connect(function(inp)
    if dragging and inp.UserInputType == Enum.UserInputType.MouseMovement then
        local d = inp.Position - dragStart
        Main.Position = UDim2.new(
            dragOrigin.X.Scale, dragOrigin.X.Offset + d.X,
            dragOrigin.Y.Scale, dragOrigin.Y.Offset + d.Y)
    end
end)

-- ══════════════════════════════════════════════════════════════════
--  §13  KEYBIND  (RightShift toggles visibility)
-- ══════════════════════════════════════════════════════════════════
UIS.InputBegan:Connect(function(inp, gpe)
    if not gpe and inp.KeyCode == Enum.KeyCode.RightShift then
        ST.guiVisible = not ST.guiVisible
        Main.Visible  = ST.guiVisible
    end
end)

-- ══════════════════════════════════════════════════════════════════
--  §14  INIT
-- ══════════════════════════════════════════════════════════════════
setStatus("XenoScanner v3 ready — select a tab and press SCAN.")
print("[XenoScanner v3] Loaded. RightShift = toggle GUI.")
