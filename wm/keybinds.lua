local ffi = require("ffi")
local log = require("util.log")
local C = ffi.C
local Actions = require("wm.actions")

local Keybinds = {}

-- key syms (xkbcommon)
local SYM_q      = 0x0071  -- q
local SYM_b      = 0x0062  -- b
local SYM_z      = 0x007a  -- z
local SYM_j      = 0x006a  -- j
local SYM_k      = 0x006b  -- k
local SYM_f      = 0x0066  -- f
local SYM_space  = 0x0020  -- space
local SYM_Return = 0xff0d  -- Return
local SYM_Tab    = 0xff09  -- Tab
local SYM_h      = 0x0068  -- h
local SYM_l      = 0x006c  -- l
local SYM_comma  = 0x002c  -- ,
local SYM_period = 0x002e  -- .
local SYM_x      = 0x0078  -- x
local SYM_w      = 0x0077  -- w
local SYM_1      = 0x0031  -- 1
local SYM_2      = 0x0032  -- 2
local SYM_3      = 0x0033  -- 3
local SYM_4      = 0x0034  -- 4
local SYM_5      = 0x0035  -- 5

local mod_shift = false

function Keybinds.set_shift(pressed)
    mod_shift = pressed
end

function Keybinds.handle(server, sym)
    -- super+q: open terminal
    if sym == SYM_q and not mod_shift then
        Actions.spawn_terminal(server)
        return true
    end

    -- super+b: open firefox
    if sym == SYM_b then
        Actions.spawn("firefox")
        return true
    end

    -- super+z: open wofi
    if sym == SYM_z then
        Actions.spawn("wofi --show drun")
        return true
    end

    -- super+x: quit compositor
    if sym == SYM_x then
        Actions.quit(server)
        return true
    end

    -- super+w: close focused window
    if sym == SYM_w then
        Actions.close_focused(server)
        return true
    end

    -- super+j: focus next
    if sym == SYM_j then
        Actions.focus_next(server)
        return true
    end

    -- super+k: focus prev
    if sym == SYM_k then
        Actions.focus_prev(server)
        return true
    end

    -- super+h: resize smaller (decrease split ratio)
    if sym == SYM_h then
        Actions.resize_ratio(server, -0.05)
        return true
    end

    -- super+l: resize larger (increase split ratio)
    if sym == SYM_l then
        Actions.resize_ratio(server, 0.05)
        return true
    end

    -- super+comma: swap with master area
    if sym == SYM_comma then
        Actions.swap_next(server)
        return true
    end

    -- super+f: toggle fullscreen
    if sym == SYM_f then
        Actions.toggle_fullscreen(server)
        return true
    end

    -- super+space: toggle floating
    if sym == SYM_space then
        Actions.toggle_float(server)
        return true
    end

    -- super+1..5: switch tag
    if sym >= SYM_1 and sym <= SYM_5 then
        local tag = sym - SYM_1 + 1
        Keybinds.switch_tag(server, tag)
        return true
    end

    return false
end

function Keybinds.switch_tag(server, tag)
    server.current_tag = tag
    log.debug("switched to tag %d", tag)
    server:_schedule_layout()
end

return Keybinds
