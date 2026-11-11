--- CC-Windows - fabric agent for a computer that does not run CC-Windows.
--
-- CC-Windows' Explorer hands a program to another computer with
-- "Run on". This small program is the other end on a plain CraftOS
-- machine: it announces itself on the CC:CE fabric link, runs whatever
-- CC-Windows sends it, and lets you push a program the other way from
-- its own prompt.
--
--   fabric_agent
--   fabric> run 7 /programs/hello.lua
--
-- Commands: run <id> <path>, peers, hello, help, exit.
-- What travels over the wire is the same protocol CC-Windows speaks:
-- hello / hello_reply, run / result.

if type(cee) ~= "table" or type(cee.fabricSend) ~= "function"
    or type(cee.fabricPeers) ~= "function" then
    print("This computer is not on a CC:CE fabric link.")
    print("Connect it to a gold fabric pin and run this again.")
    return
end

local labels = {}   -- peer id -> the name that peer announced
local greeted = {}  -- peer id -> true once somebody has said hello
local nonce = 0

local line = ""     -- what is typed at the prompt
local co, filter    -- the program started from this agent, and its filter
local STOP = false
local PROMPT = "fabric> "
local pollTimer

---------------------------------------------------------------------------
-- names and peers
---------------------------------------------------------------------------

local function selfId()
    local ok, v = pcall(os.getComputerID)
    if ok then return v end
    return nil
end

local function ourLabel()
    if type(os.getComputerLabel) == "function" then
        local ok, v = pcall(os.getComputerLabel)
        if ok and type(v) == "string" and v ~= "" then return v end
    end
    return "Computer " .. tostring(selfId() or "?")
end

local function peerName(id)
    if labels[id] then return labels[id] end
    return "Computer " .. tostring(id)
end

local function note(id, label)
    if type(id) ~= "number" then return end
    greeted[id] = true
    if type(label) == "string" and label ~= "" then labels[id] = label end
end

--- Every computer on the link (a list, a map or a single record).
local function peers()
    local out = {}
    local ok, raw = pcall(cee.fabricPeers)
    if not ok or type(raw) ~= "table" then return out end
    local me = selfId()
    local function take(p, keyed)
        if type(p) ~= "table" then return end
        local id = p.id or keyed
        if type(id) ~= "number" or id == me then return end
        if (p.kind or "computer") ~= "computer" then return end
        out[#out + 1] = { id = id }
    end
    if raw.id ~= nil or raw.kind ~= nil then
        take(raw, nil)
    elseif #raw > 0 then
        for i = 1, #raw do take(raw[i], nil) end
    else
        for k, p in pairs(raw) do take(p, tonumber(k)) end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

local function send(id, msg)
    local ok, sent = pcall(cee.fabricSend, id, msg)
    return ok and sent ~= false
end

local function poll()
    local seen = {}
    for _, p in ipairs(peers()) do
        seen[p.id] = true
        if not greeted[p.id] then
            greeted[p.id] = true
            send(p.id, { op = "hello", label = ourLabel() })
        end
    end
    for id in pairs(greeted) do
        if not seen[id] then greeted[id] = nil end
    end
end

---------------------------------------------------------------------------
-- screen: the prompt, and messages that arrive while it is showing
---------------------------------------------------------------------------

local function redraw()
    local _, y = term.getCursorPos()
    term.setCursorPos(1, y)
    term.clearLine()
    write(PROMPT .. line)
end

--- Take the prompt off the screen so a message can use the line. What is
-- half-typed stays in `line` and comes back with the next redraw.
local function clearPrompt()
    local _, y = term.getCursorPos()
    term.setCursorPos(1, y)
    term.clearLine()
end

local function say(msg)
    if co then return end            -- a running program owns the screen
    clearPrompt()
    print(msg)
    redraw()
end

---------------------------------------------------------------------------
-- running programs
---------------------------------------------------------------------------

local function start(path)
    co = coroutine.create(function()
        local ok, err = shell.run(path)
        if not ok and err then printError(tostring(err)) end
    end)
    filter = nil
end

--- Hand one queued event to the running program, honouring its filter.
local function pump(ev)
    if not co then return end
    if coroutine.status(co) == "dead" then
        co, filter = nil, nil
        return
    end
    if filter ~= nil and filter ~= ev[1] and ev[1] ~= "terminate" then
        return
    end
    local ok, a = coroutine.resume(co, table.unpack(ev, 1, ev.n))
    if not ok then
        printError(tostring(a))
        co, filter = nil, nil
    elseif coroutine.status(co) == "dead" then
        co, filter = nil, nil
    else
        filter = a
    end
end

--- Where an incoming program lives: the copy we already have, or the
-- source that travelled with it.
local function pickTarget(p)
    if type(p.path) == "string" and p.path ~= ""
        and fs.exists(p.path) and not fs.isDir(p.path) then
        return p.path
    end
    if type(p.source) == "string" then
        local name = tostring(p.name or ""):match("[^/\\]+$") or ""
        name = name:gsub("[^%w%._%-]", "_")
        if name == "" or name == "." or name == ".." then
            name = type(p.path) == "string" and fs.getName(p.path) or "program.lua"
            name = tostring(name):gsub("[^%w%._%-]", "_")
            if name == "" then name = "program.lua" end
        end
        local dst = fs.combine("/received", name)
        pcall(fs.makeDir, "/received")
        local f = fs.open(dst, "w")
        if not f then return nil, "cannot write " .. dst end
        f.write(p.source)
        f.close()
        return dst
    end
    return nil, "not found: " .. tostring(p.path)
end

local function handleRun(p, sender)
    if co then
        send(sender, {
            op = "result", id = p.id, ok = false,
            message = "busy: a program is already running here",
        })
        return
    end
    local target, why = pickTarget(p)
    if not target then
        send(sender, { op = "result", id = p.id, ok = false, message = why })
        return
    end
    clearPrompt()
    print("fabric: " .. peerName(sender) .. " sent " .. fs.getName(target))
    start(target)
    send(sender, {
        op = "result", id = p.id, ok = true,
        message = "running " .. fs.getName(target),
    })
end

--- Send a program of ours to a CC-Windows computer.
local function ship(id, path)
    if type(path) ~= "string" or not fs.exists(path) or fs.isDir(path) then
        print("no such program: " .. tostring(path))
        return
    end
    local f = fs.open(path, "r")
    if not f then
        print("cannot read " .. tostring(path))
        return
    end
    local src = f.readAll()
    f.close()

    nonce = nonce + 1
    local ok = send(id, {
        op = "run",
        id = nonce,
        path = path,
        name = fs.getName(path),
        source = type(src) == "string" and src or "",
    })
    if ok then
        print("sent " .. path .. " to " .. peerName(id))
    else
        print("could not reach " .. peerName(id))
    end
end

---------------------------------------------------------------------------
-- messages from the link
---------------------------------------------------------------------------

local function handleMessage(payload, sender)
    if type(payload) ~= "table" or type(payload.op) ~= "string" then return end
    local op = payload.op
    if op == "hello" then
        note(sender, payload.label)
        send(sender, { op = "hello_reply", label = ourLabel() })
    elseif op == "hello_reply" then
        note(sender, payload.label)
        say(peerName(sender) .. " is on the link")
    elseif op == "run" then
        handleRun(payload, sender)
    elseif op == "result" then
        if payload.ok == true then
            say(peerName(sender) .. ": " .. tostring(payload.message or "done"))
        else
            say(peerName(sender) .. " could not: "
                .. tostring(payload.message or "unknown error"))
        end
    end
end

---------------------------------------------------------------------------
-- typing
---------------------------------------------------------------------------

local function append(s)
    s = tostring(s or ""):gsub("[\r\n]", " ")
    local w = term.getSize()
    local room = w - #PROMPT
    if room < 1 then return end
    line = (line .. s):sub(1, room)
    redraw()
end

local function execute(s)
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return end
    local cmd, rest = s:match("^(%S+)%s*(.*)$")
    cmd = cmd:lower()

    if cmd == "help" then
        print("  run <id> <path>   send a program to a CC-Windows computer")
        print("  peers             computers on the fabric link")
        print("  hello             greet everyone on the link again")
        print("  exit              leave the agent")
    elseif cmd == "run" then
        local id, path = rest:match("^(%d+)%s+(%S+)$")
        if not id then
            print("usage: run <id> <path>")
        else
            ship(tonumber(id), path)
        end
    elseif cmd == "peers" then
        local list = peers()
        if #list == 0 then print("no computers on the link") end
        for _, p in ipairs(list) do
            print("  " .. peerName(p.id) .. "  (id " .. p.id .. ")")
        end
    elseif cmd == "hello" then
        greeted = {}
        poll()
        print("hello sent")
    elseif cmd == "exit" or cmd == "quit" then
        STOP = true
    else
        print("unknown command: " .. cmd .. " - try help")
    end
end

local function input(ev)
    local name = ev[1]
    if name == "char" then
        append(ev[2])
    elseif name == "paste" then
        append(ev[2])
    elseif name == "key" then
        local k = ev[2]
        if k == keys.enter or k == keys.numPadEnter then
            local s = line
            line = ""
            print("")           -- the prompt has already echoed it
            execute(s)
            if not STOP and not co then redraw() end
        elseif k == keys.backspace then
            if #line > 0 then
                line = line:sub(1, -2)
                redraw()
            end
        end
    end
end

---------------------------------------------------------------------------
-- the loop
---------------------------------------------------------------------------

print("CC-Windows fabric agent - type help for commands.")
poll()                            -- greet everyone already on the link
redraw()
pollTimer = os.startTimer(1)      -- and keep an eye out for computers that join

while not STOP do
    local ev = table.pack(os.pullEventRaw())
    local wasCo = co

    if ev[1] == "timer" and ev[2] == pollTimer then
        pollTimer = os.startTimer(1)
        poll()
    elseif ev[1] == "cee_fabric_message" then
        handleMessage(ev[2], ev[3])
    elseif ev[1] == "terminate" and wasCo == nil then
        STOP = true
    elseif wasCo == nil then
        input(ev)
    end

    -- A program started by this very event waits for the next one; a
    -- program that was already running still gets fed.
    if co and co == wasCo then
        pump(ev)
        if not co then
            print("")
            redraw()
        end
    end
end

print("")
print("agent stopped")
