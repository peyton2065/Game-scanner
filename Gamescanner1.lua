-- XenoScanner v4.2  --  Rayfield Edition  --  Production  --  Safe re-execute
-- Tabs: TREE | SCRIPTS | REMOTES | PROPERTIES | INFO
-- Keybind: RightShift = toggle GUI  (Rayfield native)
-- Load via Bootstrap.lua -- do NOT use raw loadstring(game:HttpGet(...))()
-- ============================================================
-- CHANGELOG
-- v4.2 Rayfield: Full Rayfield GUI rewrite. All v4.2 backend fixes preserved.
--   N2: S0.5 early __namecall hook recovery (_G persistence)
--   N3: startSpy uses rawget pre-capture -- timing race structurally impossible
--   N4: stopSpy clears _G key on clean stop
--   N5: top-level pcall for real init error messages
--   Luau fix: local args = {...} before nested pcall in spy hook
-- ============================================================

-- ============================================================
-- S0  UNC SHIMS
-- ============================================================
if not cloneref          then cloneref          = function(o)  return o    end end
if not getnilinstances   then getnilinstances   = function()   return {}   end end
if not getinstances      then getinstances      = function()   return {}   end end
if not getscripts        then getscripts        = function()   return {}   end end
if not decompile         then decompile         = function()   return nil  end end
if not getscriptclosure  then getscriptclosure  = function()   return nil  end end
if not getconstants      then getconstants      = function()   return {}   end end
if not getupvalues       then getupvalues       = function()   return {}   end end
if not getgc             then getgc             = function()   return {}   end end
if not checkcaller       then checkcaller       = function()   return false end end
if not newcclosure       then newcclosure       = function(f)  return f    end end
if not getnamecallmethod then getnamecallmethod = function()   return ""   end end
if not gethui            then gethui            = function()   return nil  end end
if not hookmetamethod    then hookmetamethod    = nil end
if not task.cancel       then task.cancel       = function()               end end
if not getrawmetatable   then
    getrawmetatable = function(o) return getmetatable(o) end
end
if not setclipboard then
    setclipboard = function()
        error("[XenoScanner] setclipboard not available on this executor")
    end
end

-- ============================================================
-- S0.5  EARLY HOOK RECOVERY
-- Runs before ANY game namecall (before even game:GetService).
-- hookmetamethod is a direct executor C-call -- safe even when
-- __namecall is broken. If a prior session crashed mid-spy,
-- _G.__XenoScannerNamecallOrig holds the original __namecall.
-- Restore it here before anything else touches the metatable.
-- ============================================================
do
    local stored = _G.__XenoScannerNamecallOrig
    if stored ~= nil and hookmetamethod then
        pcall(hookmetamethod, game, "__namecall", stored)
        _G.__XenoScannerNamecallOrig = nil
        print("[XenoScanner v4.2] Restored __namecall from crashed prior session.")
    end
end

-- ============================================================
-- S1  SERVICES
-- ============================================================
local Players = cloneref(game:GetService("Players"))
local UIS     = cloneref(game:GetService("UserInputService"))
local CoreGui = cloneref(game:GetService("CoreGui"))
local LP      = Players.LocalPlayer

-- ============================================================
-- S1.5  CONNECTION REGISTRY
-- UIS connections tracked for cleanup on script close.
-- ============================================================
local _connections = {}
local function track(conn)
    _connections[#_connections + 1] = conn
    return conn
end
local function disconnectAll()
    for _, c in ipairs(_connections) do pcall(function() c:Disconnect() end) end
    _connections = {}
end

-- ============================================================
-- S2  GUI PARENT  (needed by destroyOld)
-- ============================================================
local GUI_PARENT
do
    local ok = pcall(function()
        local t = Instance.new("ScreenGui")
        t.Parent = CoreGui
        assert(t:IsDescendantOf(CoreGui), "rejected")
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
-- S3  CLEANUP
-- Destroys prior XenoScanner and Rayfield GUIs from all parents.
-- Also disconnects prior execution's tracked connections from _G.
-- ============================================================
local SCRIPT_NAME = "XenoScannerV4"

local function destroyOld()
    local oldConns = _G[SCRIPT_NAME .. "_conns"]
    if type(oldConns) == "table" then
        for _, c in ipairs(oldConns) do pcall(function() c:Disconnect() end) end
    end

    local parents = { CoreGui }
    local pg = LP:FindFirstChild("PlayerGui")
    if pg then parents[#parents + 1] = pg end
    local ok2, hui = pcall(gethui)
    if ok2 and hui and typeof(hui) == "Instance" then
        parents[#parents + 1] = hui
    end

    for _, p in ipairs(parents) do
        -- Destroy prior XenoScanner ScreenGui
        local ok, desc = pcall(function() return p:GetDescendants() end)
        if ok and type(desc) == "table" then
            for _, inst in ipairs(desc) do
                local okN, n = pcall(function() return inst.Name end)
                local okC, c = pcall(function() return inst.ClassName end)
                if okN and okC and c == "ScreenGui" and type(n) == "string"
                    and n:find("XenoScanner", 1, true) then
                    pcall(function() inst:Destroy() end)
                end
            end
        end
        -- Destroy prior Rayfield ScreenGui
        local rayfieldGui = p:FindFirstChild("Rayfield")
        if rayfieldGui then pcall(function() rayfieldGui:Destroy() end) end
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
    SKIP         = { Terrain = true },
    MAX_DEPTH    = 64,
    CHUNK        = 175000,
    SPY_POLL_RATE = 0.25,
    MAX_PARA_TREE   = 3500,
    MAX_PARA_SOURCE = 4500,
    MAX_SPY_LINES   = 80,
}

local ROOTS_SET = {}
for _, name in ipairs(C.ROOTS) do ROOTS_SET[name] = true end

-- ============================================================
-- S5  STATE + UI ELEMENT REFERENCES
-- UI table holds all live Rayfield element references so scan
-- actions and the spy thread can update them after creation.
-- ============================================================
local ST = {
    scanning       = false,
    -- Per-tab filter/path state
    treeFilter     = "",
    scriptFilter   = "",
    remoteFilter   = "",
    propsPath      = "",
    -- Data caches
    treeText            = nil,
    scriptList          = {},
    remoteList          = {},
    selectedScriptSource = nil,
    selectedRemotePath   = nil,
    propsText           = nil,
    -- Spy state
    spyActive      = false,
    spyOriginal    = nil,
    spyHookRef     = nil,
    spyLines       = {},
    spyRenderThread = nil,
    spyDirty       = false,
    spyGen         = 0,
    -- Dropdown rebuild counter (unique flags when config saving is off)
    dropdownGen    = 0,
}

-- Rayfield element references -- populated during window construction
local UI = {
    -- TREE tab
    TreeScanLabel    = nil,
    TreeParagraph    = nil,
    -- SCRIPTS tab
    ScriptsTab       = nil,   -- tab ref needed for dynamic dropdown creation
    ScriptScanLabel  = nil,
    ScriptDropdown   = nil,
    ScriptParagraph  = nil,
    -- REMOTES tab
    RemotesTab       = nil,
    RemoteScanLabel  = nil,
    RemoteDropdown   = nil,
    RemoteParagraph  = nil,
    SpyToggle        = nil,
    SpyCountLabel    = nil,
    SpyParagraph     = nil,
    -- PROPERTIES tab
    PropsLabel       = nil,
    PropsParagraph   = nil,
    PropsInput       = nil,
    -- INFO tab
    StatusLabel      = nil,
    InfoParagraph    = nil,
    -- Rayfield root
    Window           = nil,
}

-- ============================================================
-- S6  UTILITY
-- ============================================================

local function SP(inst, prop)
    local ok, v = pcall(function() return inst[prop] end)
    return ok and tostring(v) or "<?>"
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

local function isInstanceAlive(inst)
    local ok, parent = pcall(function() return inst.Parent end)
    if not ok then return false end
    if parent == nil then
        local okN, nilInsts = pcall(getnilinstances)
        if okN and type(nilInsts) == "table" then
            for _, ni in ipairs(nilInsts) do
                if ni == inst then return true end
            end
        end
        return false
    end
    return true
end

-- Truncates text for Paragraph display, appending a note if cut.
local function truncate(text, limit)
    if not text or #text == 0 then return "(empty)" end
    if #text <= limit then return text end
    return text:sub(1, limit)
        .. "\n\n... ["
        .. tostring(#text)
        .. " chars total — use Copy button for full output]"
end

-- Fires a Rayfield notification AND updates the INFO tab status label.
local function setStatus(msg)
    msg = tostring(msg)
    if UI.StatusLabel then
        pcall(function() UI.StatusLabel:Set(msg) end)
    end
end

local function notify(title, content, icon, duration)
    if UI.Window then
        pcall(function()
            UI.Window:Notify({
                Title    = title or "XenoScanner",
                Content  = content or "",
                Duration = duration or 4,
                Image    = icon or "info",
            })
        end)
    end
end

-- ============================================================
-- S7  SCANNERS  (logic unchanged from v4.1 — only display changed)
-- ============================================================

-- S7-A  TREE
local function buildTree()
    local lines = {}
    local function ins(s) lines[#lines + 1] = s end
    ins("XENO GAME SCANNER v4.2  --  Full Hierarchy")
    ins("Game:    " .. SP(game, "Name"))
    ins("PlaceId: " .. SP(game, "PlaceId"))
    ins("JobId:   " .. SP(game, "JobId"))
    ins(string.rep("-", 60))
    ins("")

    local function recurse(inst, prefix, isLast, depth)
        if depth > C.MAX_DEPTH then
            lines[#lines + 1] = prefix .. (isLast and "\\- " or "|- ") .. "[MAX DEPTH]"
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
            ins(">> " .. svcName .. "  [" .. SP(svc, "ClassName") .. "]  (" .. count .. " children)")
            if ok2 and type(ch) == "table" then
                for i = 1, #ch do pcall(recurse, ch[i], "  ", i == #ch, 1) end
            end
            ins("")
        end
    end
    ins(string.rep("-", 60))
    ins("Scan complete  --  " .. #lines .. " lines")
    return table.concat(lines, "\n")
end

-- S7-B  SCRIPTS
local function buildScriptList()
    local list, seen = {}, {}
    local ok, scripts = pcall(getscripts)
    if ok and type(scripts) == "table" then
        for _, s in ipairs(scripts) do
            if not seen[s] then
                seen[s] = true
                local ok2, cls  = pcall(function() return s.ClassName end)
                local ok3, name = pcall(function() return s.Name end)
                if ok2 and (cls == "LocalScript" or cls == "Script" or cls == "ModuleScript") then
                    list[#list + 1] = {
                        name = ok3 and tostring(name) or "<?>",
                        cls  = cls, path = fullPath(s), instance = s,
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
                    if ok3 and (cls == "LocalScript" or cls == "Script" or cls == "ModuleScript") then
                        local ok4, name = pcall(function() return s.Name end)
                        list[#list + 1] = {
                            name = ok4 and tostring(name) or "<?>",
                            cls = cls, path = fullPath(s), instance = s,
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
    if not isInstanceAlive(inst) then
        local w = "-- WARNING: Instance appears destroyed since scan.\n-- Path was: "
            .. entry.path .. "\n-- Decompilation skipped."
        local numbered, n = numberLines(w)
        return numbered, n, "destroyed"
    end
    local ok1, src = pcall(decompile, inst)
    if ok1 and type(src) == "string" and #src > 0 then
        local numbered, n = numberLines(src)
        return numbered, n, "decompile()"
    end
    local ok2, closure = pcall(getscriptclosure, inst)
    if ok2 and closure then
        local buf = {
            "-- decompile() unavailable for this script.",
            "-- Fallback: closure analysis", "--", "-- CONSTANTS:",
        }
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
                buf[#buf + 1] = string.format("--   [%s] = %s", tostring(k), tostring(v))
            end
        else
            buf[#buf + 1] = "--   (none)"
        end
        local numbered, n = numberLines(table.concat(buf, "\n"))
        return numbered, n, "closure dump"
    end
    local fallback = "-- Source unavailable.\n-- Script is protected or obfuscated."
    local numbered, n = numberLines(fallback)
    return numbered, n, "unavailable"
end

-- S7-C  REMOTES
local function buildRemoteList()
    local list, seen = {}, {}
    local TARGET = {
        RemoteEvent = true, RemoteFunction = true,
        BindableEvent = true, BindableFunction = true,
        UnreliableRemoteEvent = true,
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
                        name = ok3 and tostring(name) or "<?>",
                        cls  = cls, path = fullPath(inst), instance = inst,
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
                        name = ok3 and tostring(name) or "<?>",
                        cls  = cls,
                        path = "(nil-parent) " .. (ok3 and tostring(name) or "<?>"),
                        instance = inst,
                    }
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.path < b.path end)
    return list
end

-- S7-D  PROPERTIES
local function buildPropsText(inst)
    if not inst then return "No instance selected." end
    local lines = {}
    local function ins(s) lines[#lines + 1] = s end
    ins("PROPERTIES  --  " .. SP(inst, "Name") .. "  [" .. SP(inst, "ClassName") .. "]")
    ins("Full path: " .. fullPath(inst))
    ins(string.rep("-", 56))
    ins("")
    local PROPS = {
        "Name","ClassName","Parent","Archivable","Locked",
        "Position","Orientation","Size","CFrame",
        "Color","BrickColor","Material","Transparency",
        "Anchored","CanCollide","CanQuery","CastShadow","Massless","RootPriority",
        "Health","MaxHealth","WalkSpeed","JumpPower","JumpHeight","DisplayName",
        "Disabled","RunContext","Source","Value",
        "SoundId","Volume","PlayOnRemove","IsPlaying","Looped",
        "Text","TextColor3","Font","TextSize","BackgroundColor3","Visible","ZIndex",
        "RespawnLocation","Team","TeamColor","Neutral",
    }
    for _, p in ipairs(PROPS) do
        local ok, v = pcall(function() return inst[p] end)
        if ok then ins(string.format("  %-28s = %s", p, tostring(v))) end
    end
    ins("")
    local okC, ch = pcall(function() return inst:GetChildren() end)
    local childCount = (okC and type(ch) == "table") and #ch or 0
    ins("CHILDREN  (" .. childCount .. ")")
    if okC and type(ch) == "table" then
        for _, child in ipairs(ch) do
            ins("    " .. SP(child, "Name") .. "  [" .. SP(child, "ClassName") .. "]")
        end
    end
    return table.concat(lines, "\n")
end

-- S7-E  PATH RESOLVER
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
        local seg   = parts[i]
        local child = cur:FindFirstChild(seg)
        if child then
            cur = child
        elseif i == 2 then
            if not ROOTS_SET[seg] then
                return nil, "service '" .. seg .. "' is not in the scanner whitelist"
            end
            local ok2, svc = pcall(function() return game:GetService(seg) end)
            if ok2 and svc and typeof(svc) == "Instance" then
                cur = svc
            else
                return nil, "could not find service or child '" .. seg .. "' under game"
            end
        else
            return nil, "could not find '" .. seg .. "' under " .. parts[i - 1]
        end
    end
    if typeof(cur) ~= "Instance" then return nil, "resolved value is not an Instance" end
    return cur, nil
end

-- ============================================================
-- RAYFIELD LOAD
-- Runs after S0.5 has restored any broken hook, so game:HttpGet
-- goes through a clean __namecall and will not crash.
-- ============================================================
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

-- ============================================================
-- S8  DYNAMIC DROPDOWN HELPERS
-- Destroy old dropdown element and recreate in same tab with
-- updated options. This is the Rayfield pattern for dynamic lists.
-- ============================================================

-- Builds a display label for a script item used in dropdown options.
local function scriptLabel(item)
    return item.name .. "  [" .. item.cls .. "]"
end

-- Builds a display label for a remote item.
local function remoteLabel(item)
    return item.name .. "  [" .. item.cls .. "]"
end

-- Rebuild the script browser dropdown after a scan or filter change.
local function rebuildScriptDropdown(filterStr)
    -- Destroy old instance if present
    if UI.ScriptDropdown then
        pcall(function() UI.ScriptDropdown:Destroy() end)
        UI.ScriptDropdown = nil
    end
    if not UI.ScriptsTab then return end

    local f = (filterStr or ""):lower()
    local options  = {}
    local itemMap  = {}  -- label -> item

    for _, item in ipairs(ST.scriptList) do
        if f == ""
            or item.name:lower():find(f, 1, true)
            or item.cls:lower():find(f, 1, true)
            or item.path:lower():find(f, 1, true) then
            local lbl = scriptLabel(item)
            options[#options + 1] = lbl
            itemMap[lbl] = item
        end
    end

    local shown = #options
    if shown == 0 then
        options = { "(no matches — adjust filter)" }
    end

    ST.dropdownGen = ST.dropdownGen + 1
    local flagName = "ScriptBrowser_" .. ST.dropdownGen

    UI.ScriptDropdown = UI.ScriptsTab:CreateDropdown({
        Name          = "Script Browser  (" .. shown .. " scripts)",
        Options       = options,
        CurrentOption = { options[1] },
        MultipleOptions = false,
        SearchEnabled = true,
        Flag          = flagName,
        Callback      = function(selected)
            local lbl  = type(selected) == "table" and selected[1] or selected
            local item = itemMap[lbl]
            if not item then return end

            setStatus("Decompiling: " .. item.name .. "...")
            task.spawn(function()
                local src, lineCount, method = decompileScript(item)
                ST.selectedScriptSource = src
                local statusStr = item.path .. " | " .. lineCount .. " lines | via " .. method
                setStatus(statusStr)
                if UI.ScriptScanLabel then
                    pcall(function() UI.ScriptScanLabel:Set(statusStr) end)
                end
                if UI.ScriptParagraph then
                    pcall(function()
                        UI.ScriptParagraph:Set({
                            Title   = item.name .. "  [" .. lineCount .. " lines, " .. method .. "]",
                            Content = truncate(src, C.MAX_PARA_SOURCE),
                        })
                    end)
                end
            end)
        end,
    })
end

-- Rebuild the remote browser dropdown after a scan or filter change.
local function rebuildRemoteDropdown(filterStr)
    if UI.RemoteDropdown then
        pcall(function() UI.RemoteDropdown:Destroy() end)
        UI.RemoteDropdown = nil
    end
    if not UI.RemotesTab then return end

    local f = (filterStr or ""):lower()
    local options = {}
    local itemMap = {}

    for _, item in ipairs(ST.remoteList) do
        if f == ""
            or item.name:lower():find(f, 1, true)
            or item.cls:lower():find(f, 1, true)
            or item.path:lower():find(f, 1, true) then
            local lbl = remoteLabel(item)
            -- Deduplicate labels (same name + class in different paths)
            local uniqueLbl = lbl
            if itemMap[uniqueLbl] then
                local count = 2
                while itemMap[uniqueLbl .. " #" .. count] do count = count + 1 end
                uniqueLbl = lbl .. " #" .. count
            end
            options[#options + 1] = uniqueLbl
            itemMap[uniqueLbl] = item
        end
    end

    local shown = #options
    if shown == 0 then
        options = { "(no matches — adjust filter)" }
    end

    ST.dropdownGen = ST.dropdownGen + 1
    local flagName = "RemoteBrowser_" .. ST.dropdownGen

    UI.RemoteDropdown = UI.RemotesTab:CreateDropdown({
        Name          = "Remote Browser  (" .. shown .. " remotes)",
        Options       = options,
        CurrentOption = { options[1] },
        MultipleOptions = false,
        SearchEnabled = true,
        Flag          = flagName,
        Callback      = function(selected)
            local lbl  = type(selected) == "table" and selected[1] or selected
            local item = itemMap[lbl]
            if not item then return end

            ST.selectedRemotePath = item.path
            local detail = "Name:   " .. item.name
                .. "\nClass:  " .. item.cls
                .. "\nPath:   " .. item.path
                .. "\n\n-- FireServer snippet:\nlocal rem = " .. item.path
                .. "\nrem:FireServer()"
                .. "\n\n-- InvokeServer snippet:\nlocal rem = " .. item.path
                .. "\nlocal result = rem:InvokeServer()"

            setStatus(item.path)
            if UI.RemoteParagraph then
                pcall(function()
                    UI.RemoteParagraph:Set({
                        Title   = "Remote Detail — " .. item.name,
                        Content = detail,
                    })
                end)
            end
        end,
    })
end

-- ============================================================
-- S9  SPY LINE BUILDER
-- ============================================================
local function buildSpyLine(name, cls, args)
    local parts = {}
    for _, a in ipairs(args) do parts[#parts + 1] = tostring(a) end
    return string.format("[SPY] %-28s [%s]  args: (%s)",
        name, cls, table.concat(parts, ", "))
end

-- ============================================================
-- S11  SCAN ACTIONS
-- ============================================================

-- TREE
local function doScanTree()
    if ST.scanning then
        notify("Busy", "A scan is already running.", "clock", 3)
        return
    end
    ST.scanning = true
    setStatus("Building hierarchy tree...")
    if UI.TreeScanLabel then
        pcall(function() UI.TreeScanLabel:Set("Scanning...") end)
    end

    local ok, result = pcall(buildTree)
    if not ok then
        result = "[TREE ERROR]: " .. tostring(result)
    end
    ST.treeText = result

    -- Apply current filter to display output
    local f = ST.treeFilter:lower()
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

    local lc = 0
    for _ in result:gmatch("\n") do lc = lc + 1 end
    local statusStr = "Tree: " .. lc .. " lines  |  " .. #result .. " chars"
    if f ~= "" then
        statusStr = statusStr .. "  |  filtered"
    end

    if UI.TreeScanLabel then
        pcall(function() UI.TreeScanLabel:Set(statusStr) end)
    end
    if UI.TreeParagraph then
        pcall(function()
            UI.TreeParagraph:Set({
                Title   = "Hierarchy Output  (" .. lc .. " lines)",
                Content = truncate(display, C.MAX_PARA_TREE),
            })
        end)
    end

    setStatus(statusStr)
    notify("Scan Complete", statusStr, "check-circle", 4)
    ST.scanning = false
end

-- SCRIPTS
local function doScanScripts()
    if ST.scanning then
        notify("Busy", "A scan is already running.", "clock", 3)
        return
    end
    ST.scanning = true
    ST.selectedScriptSource = nil
    setStatus("Enumerating scripts...")
    if UI.ScriptScanLabel then
        pcall(function() UI.ScriptScanLabel:Set("Scanning for scripts...") end)
    end

    local ok, err = pcall(function()
        ST.scriptList = buildScriptList()
    end)

    if not ok then
        local errStr = "[SCRIPTS ERROR]: " .. tostring(err)
        setStatus(errStr)
        notify("Scan Error", errStr, "alert-circle", 5)
        ST.scanning = false
        return
    end

    rebuildScriptDropdown(ST.scriptFilter)

    local statusStr = "Scripts found: " .. #ST.scriptList
    if UI.ScriptScanLabel then
        pcall(function() UI.ScriptScanLabel:Set(statusStr) end)
    end
    if UI.ScriptParagraph then
        pcall(function()
            UI.ScriptParagraph:Set({
                Title   = "Source Preview",
                Content = "Select a script from the dropdown above to decompile and preview its source.",
            })
        end)
    end

    setStatus(statusStr)
    notify("Scan Complete", statusStr, "check-circle", 4)
    ST.scanning = false
end

-- REMOTES
local function doScanRemotes()
    if ST.scanning then
        notify("Busy", "A scan is already running.", "clock", 3)
        return
    end
    ST.scanning = true
    ST.selectedRemotePath = nil
    setStatus("Enumerating remotes...")
    if UI.RemoteScanLabel then
        pcall(function() UI.RemoteScanLabel:Set("Scanning for remotes...") end)
    end

    local ok, err = pcall(function()
        ST.remoteList = buildRemoteList()
    end)

    if not ok then
        local errStr = "[REMOTES ERROR]: " .. tostring(err)
        setStatus(errStr)
        notify("Scan Error", errStr, "alert-circle", 5)
        ST.scanning = false
        return
    end

    rebuildRemoteDropdown(ST.remoteFilter)

    local statusStr = "Remotes found: " .. #ST.remoteList
    if UI.RemoteScanLabel then
        pcall(function() UI.RemoteScanLabel:Set(statusStr) end)
    end
    if UI.RemoteParagraph then
        pcall(function()
            UI.RemoteParagraph:Set({
                Title   = "Remote Detail",
                Content = "Select a remote from the dropdown above to view its path and code snippets.",
            })
        end)
    end

    setStatus(statusStr)
    notify("Scan Complete", statusStr, "check-circle", 4)
    ST.scanning = false
end

-- PROPERTIES
local function doScanProps()
    if ST.scanning then
        notify("Busy", "A scan is already running.", "clock", 3)
        return
    end
    ST.scanning = true

    local f = ST.propsPath:gsub("^%s+", ""):gsub("%s+$", "")

    if f == "" then
        local hint = "Enter a full instance path in the input above.\n"
            .. "Example:  game.Workspace.Baseplate\n"
            .. "Then press Inspect."
        if UI.PropsParagraph then
            pcall(function()
                UI.PropsParagraph:Set({ Title = "Properties Inspector", Content = hint })
            end)
        end
        if UI.PropsLabel then pcall(function() UI.PropsLabel:Set("Enter a path above.") end) end
        setStatus("Enter an instance path and click Inspect.")
        ST.scanning = false
        return
    end

    local inst, errMsg = resolvePath(f)
    if not inst then
        local errStr = "[PROPS] " .. (errMsg or "unknown error")
        if UI.PropsLabel then pcall(function() UI.PropsLabel:Set(errStr) end) end
        if UI.PropsParagraph then
            pcall(function()
                UI.PropsParagraph:Set({ Title = "Resolution Failed", Content = errStr .. "\n\nCheck the path format and try again." })
            end)
        end
        setStatus(errStr)
        notify("Path Error", errStr, "alert-circle", 5)
        ST.scanning = false
        return
    end

    local propsText = buildPropsText(inst)
    ST.propsText    = propsText
    local statusStr = "Properties: " .. SP(inst, "Name") .. "  [" .. SP(inst, "ClassName") .. "]"

    if UI.PropsLabel then pcall(function() UI.PropsLabel:Set(statusStr) end) end
    if UI.PropsParagraph then
        pcall(function()
            UI.PropsParagraph:Set({
                Title   = statusStr,
                Content = truncate(propsText, C.MAX_PARA_SOURCE),
            })
        end)
    end

    setStatus(statusStr)
    notify("Inspect Complete", statusStr, "layout-list", 4)
    ST.scanning = false
end

-- ============================================================
-- S12  REMOTE SPY
-- N3: origNamecall pre-captured via rawget BEFORE hookmetamethod.
-- N4: _G.__XenoScannerNamecallOrig persists for S0.5 recovery.
-- Luau fix: local args = {...} before nested pcall closure.
-- ============================================================

local function isNewcclosureShimmed()
    local testFn  = function() end
    local wrapped = newcclosure(testFn)
    return wrapped == testFn
end

local startSpy, stopSpy  -- forward declarations for toggle callback

startSpy = function()
    if ST.spyActive then return end

    if not hookmetamethod then
        notify("SPY UNAVAILABLE", "hookmetamethod not available on this executor.", "alert-circle", 5)
        if UI.SpyToggle then pcall(function() UI.SpyToggle:Set(false) end) end
        return
    end

    if isNewcclosureShimmed() then
        notify("SPY BLOCKED",
            "newcclosure is unavailable. Hook would be detectable by anti-cheat.", "shield-off", 5)
        if UI.SpyToggle then pcall(function() UI.SpyToggle:Set(false) end) end
        return
    end

    if not getrawmetatable then
        notify("SPY ERROR", "getrawmetatable unavailable.", "alert-circle", 5)
        if UI.SpyToggle then pcall(function() UI.SpyToggle:Set(false) end) end
        return
    end

    local mt = getrawmetatable(game)
    if not mt then
        notify("SPY ERROR", "Could not access game metatable.", "alert-circle", 5)
        if UI.SpyToggle then pcall(function() UI.SpyToggle:Set(false) end) end
        return
    end

    -- N3: capture BEFORE hook closure is created — no upvalue timing race possible.
    local origNamecall = rawget(mt, "__namecall")
    if not origNamecall then
        notify("SPY ERROR", "Could not read __namecall. Already hooked or unavailable.", "alert-circle", 5)
        if UI.SpyToggle then pcall(function() UI.SpyToggle:Set(false) end) end
        return
    end

    -- N4: persist in _G for S0.5 recovery if this session crashes mid-spy.
    _G.__XenoScannerNamecallOrig = origNamecall

    ST.spyActive   = true
    ST.spyDirty    = false
    ST.spyOriginal = origNamecall

    -- Generation counter: incrementing it kills any orphaned render threads.
    ST.spyGen = ST.spyGen + 1
    local myGen = ST.spyGen

    -- Spy render thread — separate coroutine, never touches the hook.
    ST.spyRenderThread = task.spawn(function()
        local lastCount = 0
        while ST.spyActive and ST.spyGen == myGen do
            if ST.spyDirty and #ST.spyLines ~= lastCount then
                ST.spyDirty = false
                lastCount   = #ST.spyLines

                -- Build display: last MAX_SPY_LINES lines
                local lines = ST.spyLines
                local startIdx = math.max(1, #lines - C.MAX_SPY_LINES + 1)
                local subset = {}
                for i = startIdx, #lines do subset[#subset + 1] = lines[i] end
                local content = table.concat(subset, "\n")
                if #lines > C.MAX_SPY_LINES then
                    content = "(showing last " .. C.MAX_SPY_LINES
                        .. " of " .. #lines .. " calls)\n\n" .. content
                end

                if UI.SpyCountLabel then
                    pcall(function()
                        UI.SpyCountLabel:Set("Calls captured: " .. lastCount)
                    end)
                end
                if UI.SpyParagraph then
                    pcall(function()
                        UI.SpyParagraph:Set({
                            Title   = "Spy Log  (" .. lastCount .. " calls)",
                            Content = content,
                        })
                    end)
                end
            end
            task.wait(C.SPY_POLL_RATE)
        end
    end)

    -- Install hook. origNamecall is populated above — structurally no race.
    local ourHook = newcclosure(function(self, ...)
        local method = getnamecallmethod()
        if  method == "FireServer"
         or method == "InvokeServer"
         or method == "FireAllClients"
         or method == "Fire" then
            -- Luau fix: capture varargs BEFORE nested pcall closure.
            -- Luau does not allow '...' inside a nested non-vararg function.
            local args = { ... }
            pcall(function()
                local ok1, cls  = pcall(function() return self.ClassName end)
                local ok2, name = pcall(function() return self.Name end)
                if ok1 and (
                    cls == "RemoteEvent"          or
                    cls == "RemoteFunction"        or
                    cls == "BindableEvent"         or
                    cls == "BindableFunction"      or
                    cls == "UnreliableRemoteEvent") then
                    local line = buildSpyLine(ok2 and tostring(name) or "<?>", cls, args)
                    ST.spyLines[#ST.spyLines + 1] = line
                    ST.spyDirty = true
                end
            end)
        end
        -- '...' at direct scope of function(self,...) — valid Luau.
        return origNamecall(self, ...)
    end)

    hookmetamethod(game, "__namecall", ourHook)
    ST.spyHookRef = ourHook

    notify("Spy Active", "Intercepting all remote calls.", "radio", 3)
    setStatus("SPY ACTIVE — intercepting all remote calls...")
end

stopSpy = function()
    if not ST.spyActive then return end
    ST.spyActive = false

    -- Kill render thread via generation increment
    ST.spyGen = ST.spyGen + 1
    if ST.spyRenderThread then
        pcall(task.cancel, ST.spyRenderThread)
        ST.spyRenderThread = nil
    end

    -- Verify hook identity before restoring (HK-001)
    if hookmetamethod and ST.spyOriginal and ST.spyHookRef then
        local shouldRestore = true
        pcall(function()
            local mt = getrawmetatable(game)
            if mt and rawget(mt, "__namecall") ~= ST.spyHookRef then
                shouldRestore = false
                warn("[XenoScanner] Hook chain modified by third party — skipping restore.")
            end
        end)
        if shouldRestore then
            pcall(function() hookmetamethod(game, "__namecall", ST.spyOriginal) end)
        end
    end

    ST.spyOriginal = nil
    ST.spyHookRef  = nil

    -- N4: clear _G key — hook restored cleanly, no S0.5 recovery needed.
    _G.__XenoScannerNamecallOrig = nil

    local captured = #ST.spyLines
    setStatus("SPY stopped — " .. captured .. " calls captured.")
    notify("Spy Stopped", captured .. " calls captured.", "radio-tower", 4)
end

-- ============================================================
-- S13  WINDOW + UI CONSTRUCTION
-- N5: entire construction wrapped in pcall for real error messages.
-- ============================================================
local _MAIN_OK, _MAIN_ERR = pcall(function()

    UI.Window = Rayfield:CreateWindow({
        Name                   = "XENO GAME SCANNER  v4.2",
        Icon                   = "radar",
        LoadingTitle           = "XenoScanner v4.2",
        LoadingSubtitle        = "Rayfield Edition",
        Theme                  = "Default",
        ToggleUIKeybind        = Enum.KeyCode.RightShift,
        DisableRayfieldPrompts = true,
        DisableBuildWarnings   = true,
        ConfigurationSaving    = { Enabled = false },
    })

    -- --------------------------------------------------------
    -- TAB 1: TREE
    -- --------------------------------------------------------
    local TreeTab = UI.Window:CreateTab("Tree", "tree-pine")

    TreeTab:CreateSection("Scan")
    UI.TreeScanLabel = TreeTab:CreateLabel("Status: Ready")
    TreeTab:CreateButton({
        Name     = "Scan Hierarchy",
        Callback = function() task.spawn(doScanTree) end,
    })

    TreeTab:CreateSection("Filter")
    TreeTab:CreateInput({
        Name                   = "Filter Output",
        PlaceholderText        = "Type to filter tree lines...",
        RemoveTextAfterFocusLost = false,
        Flag                   = "TreeFilterInput",
        Callback               = function(text)
            ST.treeFilter = text
            if ST.scanning or not ST.treeText then return end
            local f = text:lower()
            local display = ST.treeText
            if f ~= "" then
                local filtered = {}
                for line in (ST.treeText .. "\n"):gmatch("([^\n]*)\n") do
                    if line:lower():find(f, 1, true) then
                        filtered[#filtered + 1] = line
                    end
                end
                display = #filtered > 0
                    and table.concat(filtered, "\n")
                    or  "(no matches for '" .. f .. "')"
            end
            if UI.TreeParagraph then
                pcall(function()
                    UI.TreeParagraph:Set({
                        Title   = "Hierarchy Output (filtered)",
                        Content = truncate(display, C.MAX_PARA_TREE),
                    })
                end)
            end
        end,
    })

    TreeTab:CreateSection("Output")
    UI.TreeParagraph = TreeTab:CreateParagraph({
        Title   = "Hierarchy Output",
        Content = "Click 'Scan Hierarchy' to build the full game tree.",
    })

    TreeTab:CreateSection("Export")
    TreeTab:CreateButton({
        Name     = "Copy Full Output",
        Callback = function()
            if not ST.treeText or ST.treeText == "" then
                notify("Nothing to Copy", "Run a tree scan first.", "alert-circle", 3)
                return
            end
            local ok, err = pcall(setclipboard, ST.treeText)
            if ok then
                notify("Copied", #ST.treeText .. " chars copied to clipboard.", "clipboard-check", 3)
            else
                notify("Copy Error", tostring(err), "alert-circle", 4)
            end
        end,
    })

    -- --------------------------------------------------------
    -- TAB 2: SCRIPTS
    -- --------------------------------------------------------
    local ScriptsTab = UI.Window:CreateTab("Scripts", "scroll-text")
    UI.ScriptsTab = ScriptsTab  -- stored so rebuildScriptDropdown can add to it

    ScriptsTab:CreateSection("Scan")
    UI.ScriptScanLabel = ScriptsTab:CreateLabel("Status: Ready")
    ScriptsTab:CreateButton({
        Name     = "Scan Scripts",
        Callback = function() task.spawn(doScanScripts) end,
    })

    ScriptsTab:CreateSection("Filter")
    ScriptsTab:CreateInput({
        Name                   = "Filter Scripts",
        PlaceholderText        = "Filter by name, class, or path...",
        RemoveTextAfterFocusLost = false,
        Flag                   = "ScriptFilterInput",
        Callback               = function(text)
            ST.scriptFilter = text
            if ST.scanning then return end
            if #ST.scriptList > 0 then
                rebuildScriptDropdown(text)
            end
        end,
    })

    ScriptsTab:CreateSection("Script Browser")
    -- Initial placeholder dropdown — replaced after scan
    UI.ScriptDropdown = ScriptsTab:CreateDropdown({
        Name            = "Script Browser  (scan first)",
        Options         = { "(run Scan Scripts first)" },
        CurrentOption   = { "(run Scan Scripts first)" },
        MultipleOptions = false,
        SearchEnabled   = false,
        Flag            = "ScriptBrowser_0",
        Callback        = function() end,
    })

    ScriptsTab:CreateSection("Source Preview")
    UI.ScriptParagraph = ScriptsTab:CreateParagraph({
        Title   = "Source Preview",
        Content = "Select a script from the browser above after scanning.",
    })

    ScriptsTab:CreateSection("Export")
    ScriptsTab:CreateButton({
        Name     = "Copy Selected Source",
        Callback = function()
            local text = ST.selectedScriptSource or ""
            if text == "" then
                notify("Nothing Selected", "Select a script first.", "alert-circle", 3)
                return
            end
            local ok, err = pcall(setclipboard, text)
            if ok then
                notify("Copied", #text .. " chars copied.", "clipboard-check", 3)
            else
                notify("Copy Error", tostring(err), "alert-circle", 4)
            end
        end,
    })
    ScriptsTab:CreateButton({
        Name     = "Copy All Sources (bulk decompile)",
        Callback = function()
            if #ST.scriptList == 0 then
                notify("No Scripts", "Run Scan Scripts first.", "alert-circle", 3)
                return
            end
            if ST.scanning then
                notify("Busy", "A scan is already running.", "clock", 3)
                return
            end
            ST.scanning = true
            task.spawn(function()
                local snapshot = {}
                for i, v in ipairs(ST.scriptList) do snapshot[i] = v end
                notify("Bulk Decompile", "Decompiling " .. #snapshot .. " scripts...", "loader", 4)
                local parts = {}
                for i, item in ipairs(snapshot) do
                    setStatus("Decompiling " .. i .. "/" .. #snapshot .. " — " .. item.name)
                    task.wait()
                    local src, lineCount, method = decompileScript(item)
                    parts[#parts + 1] = string.rep("=", 60)
                    parts[#parts + 1] = "-- [" .. i .. "]  " .. item.path
                    parts[#parts + 1] = "-- Class: " .. item.cls
                    parts[#parts + 1] = "-- Lines: " .. lineCount .. "  |  Method: " .. method
                    parts[#parts + 1] = string.rep("=", 60)
                    parts[#parts + 1] = src
                    parts[#parts + 1] = ""
                end
                local allSrc = table.concat(parts, "\n")
                ST.scanning = false
                local ok, err = pcall(setclipboard, allSrc)
                if ok then
                    notify("Bulk Copy Done", #allSrc .. " chars copied.", "clipboard-check", 5)
                    setStatus("Bulk copy: " .. #allSrc .. " chars copied.")
                else
                    notify("Copy Error", tostring(err), "alert-circle", 5)
                end
            end)
        end,
    })

    -- --------------------------------------------------------
    -- TAB 3: REMOTES
    -- --------------------------------------------------------
    local RemotesTab = UI.Window:CreateTab("Remotes", "radio")
    UI.RemotesTab = RemotesTab

    RemotesTab:CreateSection("Scan")
    UI.RemoteScanLabel = RemotesTab:CreateLabel("Status: Ready")
    RemotesTab:CreateButton({
        Name     = "Scan Remotes",
        Callback = function() task.spawn(doScanRemotes) end,
    })

    RemotesTab:CreateSection("Filter")
    RemotesTab:CreateInput({
        Name                   = "Filter Remotes",
        PlaceholderText        = "Filter by name, class, or path...",
        RemoveTextAfterFocusLost = false,
        Flag                   = "RemoteFilterInput",
        Callback               = function(text)
            ST.remoteFilter = text
            if ST.scanning then return end
            if #ST.remoteList > 0 then
                rebuildRemoteDropdown(text)
            end
        end,
    })

    RemotesTab:CreateSection("Remote Browser")
    UI.RemoteDropdown = RemotesTab:CreateDropdown({
        Name            = "Remote Browser  (scan first)",
        Options         = { "(run Scan Remotes first)" },
        CurrentOption   = { "(run Scan Remotes first)" },
        MultipleOptions = false,
        SearchEnabled   = false,
        Flag            = "RemoteBrowser_0",
        Callback        = function() end,
    })

    RemotesTab:CreateSection("Remote Detail")
    UI.RemoteParagraph = RemotesTab:CreateParagraph({
        Title   = "Remote Detail",
        Content = "Select a remote from the browser above after scanning.",
    })

    RemotesTab:CreateSection("Export")
    RemotesTab:CreateButton({
        Name     = "Copy Remote List",
        Callback = function()
            if #ST.remoteList == 0 then
                notify("No Remotes", "Run Scan Remotes first.", "alert-circle", 3)
                return
            end
            local rows = {}
            for _, r in ipairs(ST.remoteList) do
                rows[#rows + 1] = r.path .. "  [" .. r.cls .. "]"
            end
            local text = table.concat(rows, "\n")
            local ok, err = pcall(setclipboard, text)
            if ok then
                notify("Copied", #ST.remoteList .. " remotes copied.", "clipboard-check", 3)
            else
                notify("Copy Error", tostring(err), "alert-circle", 4)
            end
        end,
    })
    RemotesTab:CreateButton({
        Name     = "Copy Selected Remote Path",
        Callback = function()
            local text = ST.selectedRemotePath or ""
            if text == "" then
                notify("Nothing Selected", "Select a remote from the browser.", "alert-circle", 3)
                return
            end
            local ok, err = pcall(setclipboard, text)
            if ok then
                notify("Copied", text, "clipboard-check", 3)
            else
                notify("Copy Error", tostring(err), "alert-circle", 4)
            end
        end,
    })

    RemotesTab:CreateSection("Remote Spy")
    if not hookmetamethod then
        RemotesTab:CreateLabel("SPY UNAVAILABLE — hookmetamethod not present on this executor.")
    else
        UI.SpyToggle = RemotesTab:CreateToggle({
            Name         = "Spy Active",
            CurrentValue = false,
            Flag         = "SpyActiveToggle",
            Callback     = function(value)
                if value then startSpy() else stopSpy() end
            end,
        })
        RemotesTab:CreateButton({
            Name     = "Clear Spy Log",
            Callback = function()
                ST.spyLines = {}
                if UI.SpyCountLabel then
                    pcall(function() UI.SpyCountLabel:Set("Calls captured: 0") end)
                end
                if UI.SpyParagraph then
                    pcall(function()
                        UI.SpyParagraph:Set({ Title = "Spy Log", Content = "(cleared)" })
                    end)
                end
                setStatus("Spy log cleared.")
                notify("Spy Log Cleared", "All captured calls removed.", "trash-2", 3)
            end,
        })
        RemotesTab:CreateButton({
            Name     = "Copy Spy Log",
            Callback = function()
                if #ST.spyLines == 0 then
                    notify("Empty Log", "No calls captured yet. Enable spy first.", "alert-circle", 3)
                    return
                end
                local text = table.concat(ST.spyLines, "\n")
                local ok, err = pcall(setclipboard, text)
                if ok then
                    notify("Copied", #ST.spyLines .. " spy entries copied.", "clipboard-check", 3)
                else
                    notify("Copy Error", tostring(err), "alert-circle", 4)
                end
            end,
        })
    end

    RemotesTab:CreateSection("Spy Output")
    UI.SpyCountLabel = RemotesTab:CreateLabel("Calls captured: 0")
    UI.SpyParagraph  = RemotesTab:CreateParagraph({
        Title   = "Spy Log",
        Content = "Enable the spy toggle above to begin intercepting remote calls.",
    })

    -- --------------------------------------------------------
    -- TAB 4: PROPERTIES
    -- --------------------------------------------------------
    local PropsTab = UI.Window:CreateTab("Properties", "layout-list")

    PropsTab:CreateSection("Path Input")
    PropsTab:CreateParagraph({
        Title   = "Usage",
        Content = "Enter a full instance path below, then click Inspect.\n"
            .. "Example: game.Workspace.Baseplate\n"
            .. "Paths must start with 'game' and use dot notation.",
    })
    UI.PropsInput = PropsTab:CreateInput({
        Name                   = "Instance Path",
        PlaceholderText        = "game.Workspace.BasePlate",
        RemoveTextAfterFocusLost = false,
        Flag                   = "PropsPathInput",
        Callback               = function(text)
            ST.propsPath = text
        end,
    })
    PropsTab:CreateButton({
        Name     = "Inspect",
        Callback = function() task.spawn(doScanProps) end,
    })

    PropsTab:CreateSection("Properties Output")
    UI.PropsLabel     = PropsTab:CreateLabel("Status: Enter a path above.")
    UI.PropsParagraph = PropsTab:CreateParagraph({
        Title   = "Properties",
        Content = "Enter an instance path and click Inspect.",
    })

    PropsTab:CreateSection("Export")
    PropsTab:CreateButton({
        Name     = "Copy Properties",
        Callback = function()
            local text = ST.propsText or ""
            if text == "" then
                notify("Nothing to Copy", "Run an Inspect first.", "alert-circle", 3)
                return
            end
            local ok, err = pcall(setclipboard, text)
            if ok then
                notify("Copied", #text .. " chars copied.", "clipboard-check", 3)
            else
                notify("Copy Error", tostring(err), "alert-circle", 4)
            end
        end,
    })

    -- --------------------------------------------------------
    -- TAB 5: INFO
    -- --------------------------------------------------------
    local InfoTab = UI.Window:CreateTab("Info", "info")

    InfoTab:CreateSection("Live Status")
    UI.StatusLabel = InfoTab:CreateLabel("XenoScanner v4.2 — Ready.")

    InfoTab:CreateSection("About")
    UI.InfoParagraph = InfoTab:CreateParagraph({
        Title   = "XenoScanner v4.2  —  Rayfield Edition",
        Content = "Backend: v4.2 (rawget hook pre-capture, _G persistence, pcall wrapper)\n"
            .. "GUI: Rayfield Build 1.68\n\n"
            .. "Keybind: RightShift  —  toggle GUI visibility\n\n"
            .. "TABS\n"
            .. "  Tree       —  Full DataModel hierarchy scan\n"
            .. "  Scripts    —  Enumerate + decompile all scripts\n"
            .. "  Remotes    —  Enumerate remotes + live spy\n"
            .. "  Properties —  Inspect any instance by path\n\n"
            .. "LOAD VIA BOOTSTRAP.LUA\n"
            .. "Do not use loadstring(game:HttpGet(...))() directly.\n"
            .. "The bootstrap uses http_request to bypass __namecall\n"
            .. "so it loads safely even if a prior spy session crashed.",
    })

    InfoTab:CreateSection("Danger Zone")
    InfoTab:CreateButton({
        Name     = "Force Stop Spy + Restore Hook",
        Callback = function()
            if ST.spyActive then
                stopSpy()
                if UI.SpyToggle then pcall(function() UI.SpyToggle:Set(false) end) end
            else
                notify("Spy Inactive", "Spy is not currently running.", "info", 3)
            end
        end,
    })
    InfoTab:CreateButton({
        Name     = "Close Scanner",
        Callback = function()
            if ST.spyActive then stopSpy() end
            disconnectAll()
            _G[SCRIPT_NAME .. "_conns"] = {}
            pcall(function() Rayfield:Destroy() end)
        end,
    })

end) -- end pcall main body (N5)

-- ============================================================
-- S17  INIT
-- ============================================================

-- Store tracked connections for cross-execution cleanup
_G[SCRIPT_NAME .. "_conns"] = _connections

if _MAIN_OK then
    setStatus("XenoScanner v4.2 — GUI parent: " .. tostring(GUI_PARENT))
    print("[XenoScanner v4.2 Rayfield] Loaded. GUI parent: " .. tostring(GUI_PARENT))
else
    -- N5: real error message with real line number
    print("[XenoScanner v4.2 Rayfield] FATAL INIT ERROR: " .. tostring(_MAIN_ERR))
end
