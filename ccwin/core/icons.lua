--- CC-Windows - 8x8 pixel icons.
--
-- An icon is a list of 8 strings of 8 characters. "." is transparent; any
-- other character looks its colour up in the icon's own colour map.
-- Icons are drawn with run-merging, so a 16x16 desktop icon costs about a
-- dozen fills instead of 64.
local icons = {}

local function def(name, colours, rows)
    icons.defs[name] = { colours = colours, rows = rows }
end

icons.defs = {}

---------------------------------------------------------------------------
-- artwork
---------------------------------------------------------------------------

def("computer", { ["1"] = 80, ["2"] = 69, ["3"] = 79 }, {
    "11111111",
    "12222221",
    "12222221",
    "12222221",
    "11111111",
    "..3333..",
    "..3333..",
    ".333333.",
})

def("folder", { ["1"] = 62, ["2"] = 63 }, {
    "........",
    ".1111...",
    ".1..1111",
    "11111111",
    "11111111",
    "11111111",
    "11111111",
    "22222222",
})

def("terminal", { ["1"] = 66, ["2"] = 67 }, {
    "11111111",
    "11111111",
    "11221111",
    "11122111",
    "11221111",
    "11112222",
    "11111111",
    "11111111",
})

def("editor", { ["1"] = 64, ["2"] = 65, ["3"] = 79 }, {
    "33333333",
    "31111113",
    "31222113",
    "31111113",
    "31221113",
    "31111113",
    "31222113",
    "33333333",
})

def("paint", { ["1"] = 76, ["2"] = 68, ["3"] = 69, ["4"] = 75 }, {
    "..1111..",
    ".111111.",
    "12233441",
    "11111111",
    "11111111",
    ".111111.",
    "..1111..",
    "........",
})

def("settings", { ["1"] = 70, ["2"] = 71 }, {
    "........",
    "..1111..",
    ".111111.",
    "11122111",
    "11122111",
    ".111111.",
    "..1111..",
    "........",
})

def("system", { ["1"] = 72, ["2"] = 73, ["3"] = 74 }, {
    ".3.3.3.3",
    "11111111",
    "12222221",
    "12222221",
    "12222221",
    "11111111",
    ".3.3.3.3",
    "........",
})

def("file", { ["1"] = 64, ["2"] = 65, ["3"] = 79 }, {
    "11111133",
    "11111133",
    "12222221",
    "11111111",
    "12222221",
    "11111111",
    "12222211",
    "11111111",
})

def("power", { ["1"] = 68 }, {
    "..1111..",
    ".1.11.1.",
    "1..11..1",
    "1......1",
    "1......1",
    "1......1",
    ".1....1.",
    "..1111..",
})

def("info", { ["1"] = 69, ["2"] = 82 }, {
    "..1111..",
    ".111111.",
    "11122111",
    "11111111",
    "11122111",
    "11122111",
    ".111111.",
    "..1111..",
})

def("trash", { ["1"] = 79, ["2"] = 80 }, {
    "..1111..",
    ".111111.",
    "11222211",
    ".122221.",
    ".122221.",
    ".122221.",
    ".111111.",
    "..1111..",
})

---------------------------------------------------------------------------
-- drawing
---------------------------------------------------------------------------

function icons.draw(dc, name, x, y, scale)
    local ic = icons.defs[name]
    if not ic then return end
    scale = scale or 1
    for row = 0, 7 do
        local line = ic.rows[row + 1]
        local col = 0
        while col < 8 do
            local ch = line:sub(col + 1, col + 1)
            if ch == "." then
                col = col + 1
            else
                local run = 1
                while col + run < 8 and line:sub(col + run + 1, col + run + 1) == ch do
                    run = run + 1
                end
                local colour = ic.colours[ch]
                if colour then
                    dc:fill(x + col * scale, y + row * scale, run * scale, scale, colour)
                end
                col = col + run
            end
        end
    end
end

function icons.exists(name) return icons.defs[name] ~= nil end

return icons
