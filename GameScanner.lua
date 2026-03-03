--[[
    ╔══════════════════════════════════════════════════════╗
    ║         XENO GAME STRUCTURE SCANNER v2.0            ║
    ║   Fixed: 200k char limit, concat error, stability   ║
    ╚══════════════════════════════════════════════════════╝
]]

-- ───────────────────────────────────────────────────────────
--  SERVICES
-- ───────────────────────────────────────────────────────────
local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")

local LocalPlayer       = Players.LocalPlayer
local PlayerGui         = LocalPlayer:WaitForChild("PlayerGui")

-- ───────────────────────────────────────────────────────────
--  CONFIG
-- ───────────────────────────────────────────────────────────
local CONFIG = {
    SCAN_ROOTS = {
        game:GetService("Workspace"),
        game:GetService("Players"),
        game:GetService("Lighting"),
        game:GetService("MaterialService"),
        game:GetService("ReplicatedFirst"),
        game:GetService("ReplicatedStorage"),
        game:GetService("ServerScriptService"),
        game:GetService("ServerStorage"),
        game:GetService("StarterGui"),
        game:GetService("StarterPack"),
        game:GetService("StarterPlayer"),
        game:GetService("Teams"),
        game:GetService("SoundService"),
        game:GetService("TextChatService"),
    },

    BRANCH      = "|- ",
    LAST_BRANCH = "\\- ",
    PIPE        = "|   ",
    EMPTY       = "    ",
    INDENT      = "    ",

    -- Skip these classes to avoid lag
    SKIP_CLASSES = { Terrain = true },

    -- Roblox TextLabel hard cap is 200,000 chars.
    -- 180,000 keeps us safely under it.
    CHUNK_SIZE  = 180000,

    -- GUI colours
    BG_COLOR    = Color3.fromRGB(14, 14, 20),
    HDR_COLOR   = Color3.fromRGB(24, 24, 36),
    ACCENT      = Color3.fromRGB(108, 92, 231),
    TEXT_COLOR  = Color3.fromRGB(220, 220, 235),
    DIM_TEXT    = Color3.fromRGB(120, 120, 150),
    BTN_SCAN    = Color3.fromRGB(40, 180, 100),
    BTN_COPY    = Color3.fromRGB(108, 92, 231),
    BTN_CLOSE   = Color3.fromRGB(200, 60, 60),
}

-- ───────────────────────────────────────────────────────────
--  SCANNER
-- ───────────────────────────────────────────────────────────
local function scanTree(instance, prefix, isLast, lines, depth)
    -- Hard guard: lines MUST be a table or we bail immediately
    if type(lines) ~= "table" then return end
    depth = depth or 0

    if depth > 60 then
        lines[#lines + 1] = prefix
            .. (isLast and CONFIG.LAST_BRANCH or CONFIG.BRANCH)
            .. "[MAX DEPTH]"
        return
    end

    local connector = isLast and CONFIG.LAST_BRANCH or CONFIG.BRANCH

    local ok1, name      = pcall(function() return instance.Name      end)
    local ok2, className = pcall(function() return instance.ClassName end)
    name      = ok1 and tostring(name)      or "<?>"
    className = ok2 and tostring(className) or "<?>"

    lines[#lines + 1] = prefix .. connector .. name .. "  [" .. className .. "]"

    if CONFIG.SKIP_CLASSES[className] then
        local p = prefix .. (isLast and CONFIG.EMPTY or CONFIG.PIPE)
        lines[#lines + 1] = p .. CONFIG.LAST_BRANCH .. "... (skipped)"
        return
    end

    local ok3, children = pcall(function() return instance:GetChildren() end)
    if not ok3 or type(children) ~= "table" or #children == 0 then return end

    local childPfx = prefix .. (isLast and CONFIG.EMPTY or CONFIG.PIPE)
    for i = 1, #children do
        -- Wrap each child in pcall so one bad child can't abort the whole scan
        pcall(scanTree, children[i], childPfx, (i == #children), lines, depth + 1)
    end
end

local function runFullScan()
    local lines = {}

    lines[#lines + 1] = "XENO GAME STRUCTURE SCANNER v2.0"
    lines[#lines + 1] = "Game:    " .. tostring(game.Name)
    lines[#lines + 1] = "PlaceId: " .. tostring(game.PlaceId)
    lines[#lines + 1] = "JobId:   " .. tostring(game.JobId)
    lines[#lines + 1] = string.rep("-", 56)
    lines[#lines + 1] = ""

    for _, root in ipairs(CONFIG.SCAN_ROOTS) do
        local ok1, rootName  = pcall(function() return root.Name      end)
        local ok2, rootClass = pcall(function() return root.ClassName end)
        rootName  = ok1 and tostring(rootName)  or "<?>"
        rootClass = ok2 and tostring(rootClass) or "<?>"

        lines[#lines + 1] = "[" .. rootName .. "]  (" .. rootClass .. ")"

        local ok3, children = pcall(function() return root:GetChildren() end)
        if not ok3 or type(children) ~= "table" or #children == 0 then
            lines[#lines + 1] = CONFIG.INDENT .. CONFIG.LAST_BRANCH .. "(empty)"
        else
            for i = 1, #children do
                pcall(scanTree, children[i], CONFIG.INDENT, (i == #children), lines, 1)
            end
        end

        lines[#lines + 1] = ""
    end

    lines[#lines + 1] = string.rep("-", 56)
    lines[#lines + 1] = "Scan complete. " .. #lines .. " lines total."

    -- lines is guaranteed a table here — safe to concat
    return table.concat(lines, "\n")
end

-- ───────────────────────────────────────────────────────────
--  CHUNK HELPER
--  Splits a long string into chunks <= CHUNK_SIZE on
--  newline boundaries to stay under Roblox's 200k limit.
-- ───────────────────────────────────────────────────────────
local function chunkString(str)
    local chunks = {}
    local startPos = 1
    local len = #str

    while startPos <= len do
        local endPos = math.min(startPos + CONFIG.CHUNK_SIZE - 1, len)

        -- Walk back to last newline to avoid cutting mid-line
        if endPos < len then
            for i = endPos, startPos, -1 do
                if str:sub(i, i) == "\n" then
                    endPos = i
                    break
                end
            end
        end

        chunks[#chunks + 1] = str:sub(startPos, endPos)
        startPos = endPos + 1
    end

    return chunks
end

-- ───────────────────────────────────────────────────────────
--  GUI
-- ───────────────────────────────────────────────────────────
local existing = PlayerGui:FindFirstChild("XenoScanner")
if existing then existing:Destroy() end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name            = "XenoScanner"
ScreenGui.ResetOnSpawn    = false
ScreenGui.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
ScreenGui.IgnoreGuiInset  = true
ScreenGui.Parent          = PlayerGui

local Main = Instance.new("Frame")
Main.Name             = "Main"
Main.Size             = UDim2.new(0, 640, 0, 500)
Main.Position         = UDim2.new(0.5, -320, 0.5, -250)
Main.BackgroundColor3 = CONFIG.BG_COLOR
Main.BorderSizePixel  = 0
Main.ClipsDescendants = true
Main.Parent           = ScreenGui
Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 10)

-- Header
local Header = Instance.new("Frame")
Header.Name             = "Header"
Header.Size             = UDim2.new(1, 0, 0, 44)
Header.BackgroundColor3 = CONFIG.HDR_COLOR
Header.BorderSizePixel  = 0
Header.ZIndex           = 3
Header.Parent           = Main
Instance.new("UICorner", Header).CornerRadius = UDim.new(0, 10)

local Patch = Instance.new("Frame")
Patch.Size             = UDim2.new(1, 0, 0, 10)
Patch.Position         = UDim2.new(0, 0, 1, -10)
Patch.BackgroundColor3 = CONFIG.HDR_COLOR
Patch.BorderSizePixel  = 0
Patch.ZIndex           = 3
Patch.Parent           = Header

local AccentBar = Instance.new("Frame")
AccentBar.Size             = UDim2.new(0, 4, 1, 0)
AccentBar.BackgroundColor3 = CONFIG.ACCENT
AccentBar.BorderSizePixel  = 0
AccentBar.ZIndex           = 4
AccentBar.Parent           = Header

local Title = Instance.new("TextLabel")
Title.Text               = "XENO GAME SCANNER  v2"
Title.Size               = UDim2.new(1, -80, 1, 0)
Title.Position           = UDim2.new(0, 16, 0, 0)
Title.BackgroundTransparency = 1
Title.TextColor3         = CONFIG.TEXT_COLOR
Title.Font               = Enum.Font.GothamBold
Title.TextSize           = 14
Title.TextXAlignment     = Enum.TextXAlignment.Left
Title.ZIndex             = 4
Title.Parent             = Header

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size             = UDim2.new(0, 30, 0, 30)
CloseBtn.Position         = UDim2.new(1, -38, 0.5, -15)
CloseBtn.BackgroundColor3 = CONFIG.BTN_CLOSE
CloseBtn.Text             = "X"
CloseBtn.TextColor3       = Color3.new(1,1,1)
CloseBtn.Font             = Enum.Font.GothamBold
CloseBtn.TextSize         = 13
CloseBtn.BorderSizePixel  = 0
CloseBtn.ZIndex           = 5
CloseBtn.Parent           = Header
Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(0, 6)

-- Status bar
local StatusBar = Instance.new("Frame")
StatusBar.Size             = UDim2.new(1, 0, 0, 26)
StatusBar.Position         = UDim2.new(0, 0, 0, 44)
StatusBar.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
StatusBar.BorderSizePixel  = 0
StatusBar.ZIndex           = 3
StatusBar.Parent           = Main

local StatusLabel = Instance.new("TextLabel")
StatusLabel.Size             = UDim2.new(1, -12, 1, 0)
StatusLabel.Position         = UDim2.new(0, 12, 0, 0)
StatusLabel.BackgroundTransparency = 1
StatusLabel.TextColor3       = CONFIG.DIM_TEXT
StatusLabel.Font             = Enum.Font.Code
StatusLabel.TextSize         = 11
StatusLabel.TextXAlignment   = Enum.TextXAlignment.Left
StatusLabel.Text             = "Ready -- press SCAN to begin."
StatusLabel.ZIndex           = 4
StatusLabel.Parent           = StatusBar

-- Scroll frame
local ScrollFrame = Instance.new("ScrollingFrame")
ScrollFrame.Size                = UDim2.new(1, -16, 1, -134)
ScrollFrame.Position            = UDim2.new(0, 8, 0, 78)
ScrollFrame.BackgroundColor3    = Color3.fromRGB(10, 10, 16)
ScrollFrame.BorderSizePixel     = 0
ScrollFrame.ScrollBarThickness  = 5
ScrollFrame.ScrollBarImageColor3 = CONFIG.ACCENT
ScrollFrame.CanvasSize          = UDim2.new(0, 0, 0, 0)
ScrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
ScrollFrame.ZIndex              = 2
ScrollFrame.Parent              = Main
Instance.new("UICorner", ScrollFrame).CornerRadius = UDim.new(0, 6)

-- UIListLayout stacks chunk labels vertically
local ListLayout = Instance.new("UIListLayout")
ListLayout.SortOrder = Enum.SortOrder.LayoutOrder
ListLayout.Padding   = UDim.new(0, 0)
ListLayout.Parent    = ScrollFrame

-- Button row
local BtnRow = Instance.new("Frame")
BtnRow.Size             = UDim2.new(1, -16, 0, 40)
BtnRow.Position         = UDim2.new(0, 8, 1, -48)
BtnRow.BackgroundTransparency = 1
BtnRow.ZIndex           = 3
BtnRow.Parent           = Main

local BtnLayout = Instance.new("UIListLayout")
BtnLayout.FillDirection     = Enum.FillDirection.Horizontal
BtnLayout.Padding           = UDim.new(0, 8)
BtnLayout.VerticalAlignment = Enum.VerticalAlignment.Center
BtnLayout.Parent            = BtnRow

local function makeBtn(label, color)
    local b = Instance.new("TextButton")
    b.Size             = UDim2.new(0.5, -4, 1, 0)
    b.BackgroundColor3 = color
    b.Text             = label
    b.TextColor3       = Color3.new(1, 1, 1)
    b.Font             = Enum.Font.GothamBold
    b.TextSize         = 12
    b.BorderSizePixel  = 0
    b.ZIndex           = 4
    b.AutoButtonColor  = true
    b.Parent           = BtnRow
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 7)
    return b
end

local ScanBtn = makeBtn("SCAN GAME", CONFIG.BTN_SCAN)
local CopyBtn = makeBtn("COPY TO CLIPBOARD", CONFIG.BTN_COPY)
CopyBtn.Active = false
CopyBtn.BackgroundTransparency = 0.5

-- ───────────────────────────────────────────────────────────
--  RENDER CHUNKS
-- ───────────────────────────────────────────────────────────
local function clearScrollFrame()
    for _, child in ipairs(ScrollFrame:GetChildren()) do
        if child:IsA("TextLabel") then child:Destroy() end
    end
end

local function renderChunks(chunks)
    clearScrollFrame()
    local maxWidth = ScrollFrame.AbsoluteSize.X

    for i, chunk in ipairs(chunks) do
        local lbl = Instance.new("TextLabel")
        lbl.Name                   = "Chunk_" .. i
        lbl.LayoutOrder            = i
        lbl.Size                   = UDim2.new(1, 0, 0, 10)
        lbl.AutomaticSize          = Enum.AutomaticSize.Y
        lbl.BackgroundTransparency = 1
        lbl.TextColor3             = CONFIG.TEXT_COLOR
        lbl.Font                   = Enum.Font.Code
        lbl.TextSize               = 11
        lbl.TextXAlignment         = Enum.TextXAlignment.Left
        lbl.TextYAlignment         = Enum.TextYAlignment.Top
        lbl.TextWrapped            = false
        lbl.RichText               = false
        lbl.Text                   = chunk
        lbl.ZIndex                 = 3
        lbl.Parent                 = ScrollFrame

        -- Yield briefly every chunk so Roblox doesn't time out rendering
        task.wait()

        -- Expand canvas width if lines are wider than the frame
        local w = lbl.TextBounds.X + 16
        if w > maxWidth then
            maxWidth = w
        end
    end

    -- X axis doesn't auto-size, so set it manually
    ScrollFrame.CanvasSize = UDim2.new(0, maxWidth, 0, 0)
end

-- ───────────────────────────────────────────────────────────
--  DRAG
-- ───────────────────────────────────────────────────────────
local dragging, dragStart, startPos

Header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging  = true
        dragStart = input.Position
        startPos  = Main.Position
    end
end)

Header.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = false
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
        local d = input.Position - dragStart
        Main.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + d.X,
            startPos.Y.Scale, startPos.Y.Offset + d.Y
        )
    end
end)

-- ───────────────────────────────────────────────────────────
--  BUTTONS
-- ───────────────────────────────────────────────────────────
CloseBtn.MouseButton1Click:Connect(function()
    ScreenGui:Destroy()
end)

local lastScanText = nil

ScanBtn.MouseButton1Click:Connect(function()
    ScanBtn.Active           = false
    ScanBtn.Text             = "SCANNING..."
    ScanBtn.BackgroundColor3 = Color3.fromRGB(30, 120, 60)
    CopyBtn.Active           = false
    CopyBtn.BackgroundTransparency = 0.5
    StatusLabel.Text         = "Scanning game structure... please wait."
    clearScrollFrame()
    lastScanText = nil

    task.wait()

    local ok, result = pcall(runFullScan)
    if not ok then
        result = "[SCAN FAILED]: " .. tostring(result)
    end

    lastScanText = result

    StatusLabel.Text = "Rendering " .. #result .. " characters..."
    task.wait()

    local chunks = chunkString(result)
    renderChunks(chunks)

    local lineCount = 0
    for _ in result:gmatch("\n") do lineCount += 1 end

    StatusLabel.Text = string.format(
        "Done -- %d lines, %d chars, %d chunk(s) rendered.",
        lineCount, #result, #chunks
    )

    ScanBtn.Active           = true
    ScanBtn.Text             = "SCAN GAME"
    ScanBtn.BackgroundColor3 = CONFIG.BTN_SCAN
    CopyBtn.Active           = true
    CopyBtn.BackgroundTransparency = 0
end)

CopyBtn.MouseButton1Click:Connect(function()
    if not lastScanText then return end

    local ok, err = pcall(setclipboard, lastScanText)
    if ok then
        local prev = CopyBtn.Text
        CopyBtn.Text             = "COPIED!"
        CopyBtn.BackgroundColor3 = Color3.fromRGB(40, 180, 100)
        StatusLabel.Text         = "Copied " .. #lastScanText .. " characters to clipboard."
        task.delay(2.5, function()
            if CopyBtn and CopyBtn.Parent then
                CopyBtn.Text             = prev
                CopyBtn.BackgroundColor3 = CONFIG.BTN_COPY
            end
        end)
    else
        StatusLabel.Text = "[CLIPBOARD ERROR]: " .. tostring(err)
    end
end)

print("[XenoScanner v2] Loaded. Press SCAN.")
