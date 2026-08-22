local ffi = require("ffi")
local log = require("util.log")
local C = ffi.C

local Actions = {}

function Actions.spawn(command)
    local display_ptr = C.getenv("WAYLAND_DISPLAY")
    local display_str = display_ptr ~= nil and ffi.string(display_ptr) or "(nil)"
    log.info("spawning: %s (WAYLAND_DISPLAY=%s)", command, display_str)
    local pid = C.fork()
    if pid == 0 then
        C.execl("/bin/sh", "/bin/sh", "-c", command, nil)
        C._exit(1)
    end
end

function Actions.close_focused(server)
    local focused = server:get_focused_view()
    if focused then
        focused:close()
    end
end

function Actions.focus_next(server)
    if server.dwindle then
        local next_view = server.dwindle:focus_next(server.current_tag)
        if next_view then
            server:focus_view(next_view)
        end
    end
end

function Actions.focus_prev(server)
    if server.dwindle then
        local prev_view = server.dwindle:focus_prev(server.current_tag)
        if prev_view then
            server:focus_view(prev_view)
        end
    end
end

function Actions.toggle_fullscreen(server)
    local focused = server:get_focused_view()
    if not focused then return end

    focused.fullscreen = not focused.fullscreen
    if focused.xdg_toplevel == nil then
        -- xwayland views push their own state directly
        if focused.xsurface ~= nil then
            C.wlr_xwayland_surface_set_fullscreen(focused.xsurface, focused.fullscreen)
        end
        if focused.fullscreen then
            for _, output_data in ipairs(server.outputs) do
                local out = output_data.wlr_output
                focused:set_position(0, 0, out.width, out.height)
            end
        else
            server:_schedule_layout()
        end
        return
    end

    if focused.fullscreen then
        for _, output_data in ipairs(server.outputs) do
            local out = output_data.wlr_output
            C.wlr_xdg_toplevel_set_fullscreen(focused.xdg_toplevel, true)
            if focused.border_rect then
                C.wlr_scene_rect_set_color(focused.border_rect, ffi.new("float[4]", 0, 0, 0, 0))
            end
            focused:set_position(0, 0, out.width, out.height)
        end
    else
        C.wlr_xdg_toplevel_set_fullscreen(focused.xdg_toplevel, false)
        server:_schedule_layout()
    end
end

function Actions.toggle_float(server)
    local focused = server:get_focused_view()
    if not focused or not server.dwindle then return end

    server.dwindle:toggle_float(focused)
    if focused.floating then
        for _, output_data in ipairs(server.outputs) do
            local out = output_data.wlr_output
            local cx = math.floor(out.width / 2 - focused.width / 2)
            local cy = math.floor(out.height / 2 - focused.height / 2)
            focused:set_position(cx, cy, focused.width, focused.height)
        end
    else
        server:_schedule_layout()
    end
end

function Actions.swap_next(server)
    if server.dwindle then
        local swapped = server.dwindle:swap_focused_with_next()
        if swapped then
            server:_schedule_layout()
        end
    end
end

function Actions.resize_ratio(server, delta)
    local focused = server:get_focused_view()
    if not focused or not server.dwindle then return end

    local node = focused._dwindle_node
    if not node then return end

    local root = server.dwindle:get_root()
    local parent = root and server.dwindle:find_parent(root, node)
    if parent and parent.children then
        parent.ratio = math.max(0.2, math.min(0.8, parent.ratio + delta))
        server:_schedule_layout()
    end
end

function Actions.move_focus(server, direction)
    if not server.dwindle then return end

    local focused = server:get_focused_view()
    if not focused then return end

    local node = focused._dwindle_node
    if not node then return end

    local root = server.dwindle:get_root()
    local parent = root and server.dwindle:find_parent(root, node)
    if not parent or not parent.children then return end

    local sibling
    if direction == "left" or direction == "up" then
        sibling = parent.children[1]
    else
        sibling = parent.children[2]
    end

    if not sibling then return end

    local leaf = server.dwindle:find_leaf(sibling)
    if leaf and leaf.view and leaf.view.mapped then
        server:focus_view(leaf.view)
    end
end

function Actions.spawn_terminal(server)
    Actions.spawn("kitty")
end

function Actions.quit(server)
    log.info("quit requested, terminating compositor...")
    C.wl_display_terminate(server.wl_display)
end

function Actions.move_to_tag(server, tag)
    local focused = server:get_focused_view()
    if not focused then return end

    focused.tags = { [tag] = true }
    if server.dwindle then
        server.dwindle:set_view_tag(focused, tag)
    end
    log.debug("moved %s to tag %d", focused:get_title(), tag)
    server:_schedule_layout()
end

function Actions.dump_views(server)
    log.info("=== VIEW DUMP (tag %d) ===", server.current_tag or 1)
    for _, v in ipairs(server.views) do
        local tex_w, tex_h = "nil", "nil"
        if v.texture ~= nil then
            tex_w, tex_h = tostring(tonumber(v.texture.width)), tostring(tonumber(v.texture.height))
        end
        local class = "?"
        if v.get_app_id ~= nil then
            class = tostring(v:get_app_id())
        end
        log.info(
            "view %s: class=%s mapped=%s float=%s pos=%d,%d size=%dx%d tex=%sx%s visible=%s",
            v:get_title(),
            class,
            tostring(v.mapped),
            tostring(v.floating),
            v.x or -1,
            v.y or -1,
            v.width or -1,
            v.height or -1,
            tex_w,
            tex_h,
            tostring(v.visible_on_tag)
        )
    end
    log.info("=== END DUMP (%d views) ===", #server.views)
end

return Actions
