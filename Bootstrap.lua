-- ============================================================
-- XenoScanner v4.2 Bootstrap
-- ============================================================
-- PASTE THIS INTO XENO INSTEAD OF YOUR NORMAL LOADSTRING.
-- Keep using this permanently -- it is safe whether or not the
-- __namecall hook is currently broken.
--
-- WHY THIS EXISTS:
-- Your normal load call is:
--   loadstring(game:HttpGet("..."))()
-- game:HttpGet is a method call on game. Method calls on game go
-- through game.__namecall. If a previous spy session crashed and
-- left a broken hook on __namecall, game:HttpGet triggers it and
-- crashes BEFORE the scanner script body even starts. The S0.5
-- recovery block inside GameScanner.lua never gets to run.
--
-- This bootstrap uses http_request / request -- executor-level
-- C globals that bypass Roblox's metatable entirely. They do NOT
-- go through game.__namecall. So this load works even when the
-- hook is broken, the scanner loads, S0.5 runs, hook is restored,
-- everything is clean for the rest of the session.
-- ============================================================

local URL = "https://raw.githubusercontent.com/peyton2065/Game-scanner/refs/heads/main/Gamescanner1.lua"
local src = nil

-- http_request and request are UNC executor globals -- no game namecall.
if typeof(http_request) == "function" then
    local ok, res = pcall(http_request, { Url = URL, Method = "GET" })
    if ok and res and type(res.Body) == "string" and #res.Body > 0 then
        src = res.Body
    end
end

if not src and typeof(request) == "function" then
    local ok, res = pcall(request, { Url = URL, Method = "GET" })
    if ok and res and type(res.Body) == "string" and #res.Body > 0 then
        src = res.Body
    end
end

if src then
    local fn, err = loadstring(src)
    if fn then
        fn()
    else
        print("[Bootstrap] loadstring compile error: " .. tostring(err))
    end
else
    -- Fallback: neither http_request nor request available.
    -- This means we are on an executor that only has game:HttpGet.
    -- Only safe if __namecall is NOT currently broken.
    print("[Bootstrap] No executor HTTP API found. Falling back to game:HttpGet.")
    print("[Bootstrap] If this crashes, rejoin and re-inject via the bootstrap.")
    loadstring(game:HttpGet(URL))()
end
