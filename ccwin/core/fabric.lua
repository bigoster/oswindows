--- CC-Windows - the CC:CE fabric link.
--
-- Hands a program to another computer on the same fabric (gold pins) and
-- takes programs from them: the other side opens a console and runs what
-- it was sent, then answers with the outcome. Everything here degrades to
-- a quiet no-op when the CC:CE `cee` API is not there, so a machine
-- without CC:CE behaves exactly as it did before the link existed.
--
-- Protocol - the payloads travel inside `cee_fabric_message(payload, sender)`:
--   hello        { op, label }                     "I am here, this is my name"
--   hello_reply  { op, label }                     the answer to a hello
--   run          { op, id, path, name, source }    run this program for me
--   result       { op, id, ok, message }           the answer to a run
--
-- `id` of a run is the sender's nonce; the answer carries it back so the
-- sender can match it to the callback it is waiting on.
local fabric = {}

local wm          -- window manager, handed over by attach()
local labels = {}  -- peer id -> the name that peer announced
local greeted = {} -- peer id -> true once somebody has said hello
local pending = {} -- our run nonce -> callback waiting for the answer
local nonce = 0

---------------------------------------------------------------------------
-- presence and names
---------------------------------------------------------------------------

--- True when the CC:CE fabric API is really there.
function fabric.present()
    return type(cee) == "table"
        and type(cee.fabricPeers) == "function"
        and type(cee.fabricSend) == "function"
end

local function selfId()
    if type(os.getComputerID) ~= "function" then return nil end
    local ok, v = pcall(os.getComputerID)
    if ok and type(v) == "number" then return v end
    return nil
end

--- Our own name, falling back to "Computer <id>" the way CC does.
local function ourLabel()
    if type(os.getComputerLabel) == "function" then
        local ok, v = pcall(os.getComputerLabel)
        if ok and type(v) == "string" and v ~= "" then return v end
    end
    return "Computer " .. tostring(selfId() or "?")
end

--- The name of a peer we have heard from, "Computer <id>" until we have.
function fabric.peerName(id)
    if labels[id] then return labels[id] end
    return "Computer " .. tostring(id)
end

---------------------------------------------------------------------------
-- peers
---------------------------------------------------------------------------

--- Every computer on the link, sorted by id.
-- fabricPeers has been documented as a plain peer record, but a list of
-- them is what a real link holds, so both shapes (and a map keyed by id)
-- are accepted. Hubs and storages are dropped: fabricSend can only target
-- other computers, and so can "Run on".
function fabric.peers()
    local out = {}
    if not fabric.present() then return out end
    local ok, raw = pcall(cee.fabricPeers)
    if not ok or type(raw) ~= "table" then return out end

    local me = selfId()
    local function take(p, keyed)
        if type(p) ~= "table" then return end
        local id = p.id or keyed
        if type(id) ~= "number" or id == me then return end
        if (p.kind or "computer") ~= "computer" then return end
        out[#out + 1] = { id = id, kind = "computer", label = labels[id] }
    end

    if raw.id ~= nil or raw.kind ~= nil then
        take(raw, nil)                       -- a single peer record
    elseif #raw > 0 then
        for i = 1, #raw do take(raw[i], nil) end
    else
        for k, p in pairs(raw) do take(p, tonumber(k)) end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

---------------------------------------------------------------------------
-- sending
---------------------------------------------------------------------------

--- Push one payload to one computer. Returns false when the link is not
-- there or the message could not go out.
function fabric.send(id, msg)
    if not fabric.present() or type(id) ~= "number" or msg == nil then
        return false
    end
    local ok, sent = pcall(cee.fabricSend, id, msg)
    if not ok then return false end
    return sent ~= false
end

--- Ship `path` to peer `id` so that computer runs it.
-- `cb(ok, message)` fires when the peer answers - or straight away if the
-- message never left. The whole file travels with the message, so the
-- other side can run it even when it has no copy of its own.
function fabric.runOn(id, path, cb)
    local function answer(ok, msg)
        if cb then cb(ok, msg) end
        return false
    end

    if not fabric.present() then
        return answer(false, "the fabric link is not available")
    end
    if type(path) ~= "string" or not fs.exists(path) or fs.isDir(path) then
        return answer(false, "not a program: " .. tostring(path))
    end
    local f = fs.open(path, "r")
    if not f then return answer(false, "cannot read " .. path) end
    local src = f.readAll()
    f.close()

    nonce = nonce + 1
    local mine = nonce
    if cb then pending[mine] = cb end

    local sent = fabric.send(id, {
        op = "run",
        id = mine,
        path = path,
        name = fs.getName(path),
        source = type(src) == "string" and src or "",
    })
    if not sent then
        pending[mine] = nil
        return answer(false, "could not reach " .. fabric.peerName(id))
    end
    return true
end

---------------------------------------------------------------------------
-- receiving
---------------------------------------------------------------------------

--- Record who a peer says they are; they know about us now either way.
local function note(id, label)
    if type(id) ~= "number" then return end
    greeted[id] = true
    if type(label) == "string" and label ~= "" then labels[id] = label end
end

--- Keep a name we got over the wire inside the filesystem's own rules.
local function safeName(name)
    local n = tostring(name or ""):match("[^/\\]+$") or ""
    n = n:gsub("[^%w%._%-]", "_")
    if n == "" or n == "." or n == ".." then n = "program.lua" end
    return n
end

--- Run what a peer sent us and answer with how it went.
local function handleRun(p, sender)
    local name = safeName(p.name or (type(p.path) == "string" and fs.getName(p.path)))
    local target, why

    if type(p.path) == "string" and p.path ~= ""
        and fs.exists(p.path) and not fs.isDir(p.path) then
        target = p.path                     -- we have that program already
    elseif type(p.source) == "string" then
        -- Only the source travelled: lay it down in /received and run it.
        target = fs.combine("/received", name)
        pcall(fs.makeDir, "/received")
        local f = fs.open(target, "w")
        if f then
            f.write(p.source)
            f.close()
        else
            target, why = nil, "cannot write " .. target
        end
    end

    if not target then
        fabric.send(sender, {
            op = "result", id = p.id, ok = false,
            message = why or ("not found: " .. tostring(p.path)),
        })
        return
    end

    local started = false
    if wm then
        started = pcall(wm.create, "console", { program = target })
    end
    fabric.send(sender, {
        op = "result", id = p.id, ok = started,
        message = started and ("running " .. name) or "no console to run it in",
    })
end

--- Handle one `cee_fabric_message`. Returns true when it was ours.
function fabric.receive(payload, sender)
    if type(payload) ~= "table" or type(payload.op) ~= "string" then
        return false
    end
    local op = payload.op
    if op == "hello" then
        note(sender, payload.label)
        fabric.send(sender, { op = "hello_reply", label = ourLabel() })
        return true
    elseif op == "hello_reply" then
        note(sender, payload.label)
        return true
    elseif op == "run" then
        handleRun(payload, sender)
        return true
    elseif op == "result" then
        local cb = pending[payload.id]
        if cb then
            pending[payload.id] = nil
            cb(payload.ok == true, payload.message)
        end
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- housekeeping
---------------------------------------------------------------------------

--- Called once a second from the event loop: greet computers we have not
-- met yet, and forget the ones that dropped off the link so they get a
-- fresh hello when they come back.
function fabric.poll()
    if not fabric.present() then return end
    local seen = {}
    for _, p in ipairs(fabric.peers()) do
        seen[p.id] = true
        if not greeted[p.id] then
            greeted[p.id] = true
            fabric.send(p.id, { op = "hello", label = ourLabel() })
        end
    end
    for id in pairs(greeted) do
        if not seen[id] then greeted[id] = nil end
    end
end

function fabric.attach(d)
    wm = d and d.wm or nil
end

return fabric
