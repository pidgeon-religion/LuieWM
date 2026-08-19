local ffi = require("ffi")
local log = require("util.log")
local ffi_help = require("util.ffi_helpers")
local C = ffi.C
local View = require("wm.view")

local Surface = {}

local xdg_new_surface_listener = nil
local xdg_new_toplevel_listener = nil

function Surface.setup(server)
    log.info("setting up surface handling...")

    if server.xdg_shell == nil then
        log.error("xdg_shell is nil!")
        return
    end
    log.info("xdg_shell pointer: %p", server.xdg_shell)

    xdg_new_toplevel_listener = ffi_help.make_listener(function(data)
        log.info("=== new_toplevel signal fired! data=%p ===", data)
        Surface._on_new_toplevel(server, ffi.cast("struct wlr_xdg_toplevel *", data))
    end)
    ffi_help.signal_add(server.xdg_shell.events.new_toplevel, xdg_new_toplevel_listener)
    log.info("registered new_toplevel listener on signal at %p", server.xdg_shell.events.new_toplevel)

    local new_surface_listener = ffi_help.make_listener(function(data)
        log.info("=== new_surface signal fired! data=%p ===", data)
    end)
    ffi_help.signal_add(server.xdg_shell.events.new_surface, new_surface_listener)
    log.info("registered new_surface listener")
end

function Surface._on_new_toplevel(server, xdg_toplevel)
    local xdg_surface = xdg_toplevel.base
    local wlr_surface = xdg_surface.surface

    log.info("new toplevel: xdg_surface=%p surface=%p", xdg_surface, wlr_surface)
    log.info("new toplevel: xdg_toplevel=%p xdg_surface=%p surface=%p", xdg_toplevel, xdg_surface, wlr_surface)
    log.info("new toplevel: xdg_surface.toplevel=%p", xdg_surface.toplevel)
    log.info("new toplevel: wlr_surface=%p events=%p", wlr_surface, wlr_surface.events)

    -- Create scene tree for this surface
    -- wlr_scene_xdg_surface_create auto-manages visibility (maps when client commits)
    log.info("STEP1: calling wlr_scene_xdg_surface_create...")
    local scene_tree = C.wlr_scene_xdg_surface_create(server.scene.tree, xdg_surface)
    log.info("STEP2: scene_tree=%p", scene_tree)
    if scene_tree == nil then
        log.error("failed to create scene xdg surface")
        return
    end

    -- Create View
    log.info("STEP3: creating View...")
    local view = View.new(xdg_toplevel, scene_tree)
    view._server = server
    log.info("STEP4: adding view to server...")
    server:add_view(view)

    -- Add to dwindle layout
    if server.dwindle then
        log.info("STEP5: adding to dwindle...")
        server.dwindle:add_view(view, server.current_tag)
    end

    -- Setup listeners for this view
    log.info("STEP6: setting up listeners...")
    Surface._setup_view_listeners(server, view)

    -- Apply layout
    -- Set initial view size to a reasonable default before layout
    local initial_width = 800
    local initial_height = 600
    view.width = initial_width
    view.height = initial_height

    log.info("STEP7: applying layout...")
    Surface._apply_layout(server)

    log.info("STEP8: new xdg toplevel: %s (initial_size=%dx%d)", view:get_title(), initial_width, initial_height)
end

function Surface._setup_view_listeners(server, view)
    -- Store initial configure size (before layout overwrites it)
    local initial_width = 800
    local initial_height = 600

    -- Commit listener (to see if client ever commits a buffer, and send initial configure)
    local commit_listener = ffi_help.make_listener(function()
        if not view.initial_configure_sent then
            log.info("=== COMMIT on surface %s: sending initial configure %dx%d ===", view:get_title(), initial_width, initial_height)
            C.wlr_xdg_toplevel_set_size(view.xdg_toplevel, initial_width, initial_height)
            view.pending_serial = C.wlr_xdg_toplevel_set_size(view.xdg_toplevel, initial_width, initial_height)
            view.initial_configure_sent = true
        end
    end)
    ffi_help.signal_add(view.wlr_surface.events.commit, commit_listener)
    view.commit_listener = commit_listener

    -- Map listener
    local map_listener = ffi_help.make_listener(function()
        Surface._on_map(server, view)
    end)
    ffi_help.signal_add(view.wlr_surface.events.map, map_listener)
    view.map_listener = map_listener

    -- Unmap listener
    local unmap_listener = ffi_help.make_listener(function()
        Surface._on_unmap(server, view)
    end)
    ffi_help.signal_add(view.wlr_surface.events.unmap, unmap_listener)
    view.unmap_listener = unmap_listener

    -- Destroy listener
    local destroy_listener = ffi_help.make_listener(function()
        Surface._on_destroy(server, view)
    end)
    ffi_help.signal_add(view.xdg_toplevel.events.destroy, destroy_listener)
    view.destroy_listener = destroy_listener

    -- Request move listener (for future floating drag)
    local request_move_listener = ffi_help.make_listener(function(data)
        log.info("request move from %s", view:get_title())
    end)
    ffi_help.signal_add(view.xdg_toplevel.events.request_move, request_move_listener)
    view.request_move_listener = request_move_listener

    -- Request resize listener
    local request_resize_listener = ffi_help.make_listener(function(data)
        log.info("request resize from %s", view:get_title())
    end)
    ffi_help.signal_add(view.xdg_toplevel.events.request_resize, request_resize_listener)
    view.request_resize_listener = request_resize_listener

    -- Request fullscreen listener
    local request_fullscreen_listener = ffi_help.make_listener(function()
        Surface._on_request_fullscreen(server, view)
    end)
    ffi_help.signal_add(view.xdg_toplevel.events.request_fullscreen, request_fullscreen_listener)
    view.request_fullscreen_listener = request_fullscreen_listener
end

function Surface._on_map(server, view)
    view:map()

    -- Focus the newly mapped view
    server:focus_view(view)

    -- Re-apply layout to position everything
    Surface._apply_layout(server)
end

function Surface._on_unmap(server, view)
    view:unmap()

    if view.focused then
        server:focus_view(nil)
        -- Focus next view
        local next_view = nil
        for _, v in ipairs(server.views) do
            if v.mapped and v ~= view then
                next_view = v
                break
            end
        end
        if next_view then
            server:focus_view(next_view)
        end
    end

    Surface._apply_layout(server)
end

function Surface._on_destroy(server, view)
    view:destroy()
    server:remove_view(view)

    if server.dwindle then
        server.dwindle:remove_view(view)
    end

    Surface._apply_layout(server)
end

function Surface._on_request_fullscreen(server, view)
    view.fullscreen = not view.fullscreen
    if view.fullscreen then
        -- Get the output layout box for fullscreen
        local layout = server.output_layout
        local output = C.wlr_output_layout_output_at(layout, view.x + view.width / 2, view.y + view.height / 2)
        if output ~= nil then
            local out = output.output
            C.wlr_xdg_toplevel_set_fullscreen(view.xdg_toplevel, true)
            view:set_position(0, 0, out.width, out.height)
        end
    else
        C.wlr_xdg_toplevel_set_fullscreen(view.xdg_toplevel, false)
        Surface._apply_layout(server)
    end
end

function Surface._apply_layout(server)
    if not server.dwindle then log.info("_apply_layout: no dwindle, returning"); return end

    log.info("_apply_layout: %d outputs", #server.outputs)
    for i, output_data in ipairs(server.outputs) do
        local wlr_output = output_data.wlr_output
        local layout_box = ffi.new("struct wlr_box")
        log.info("_apply_layout: getting layout box for output %d, wlr_output=%p", i, wlr_output)
        C.wlr_output_layout_get_box(server.output_layout, wlr_output, layout_box)
        log.info("_apply_layout: layout box = %d,%d %dx%d", layout_box.x, layout_box.y, layout_box.width, layout_box.height)

        log.info("_apply_layout: calling dwindle layout...")
        server.dwindle:layout(
            layout_box.x, layout_box.y,
            layout_box.width, layout_box.height,
            server.current_tag
        )
        log.info("_apply_layout: dwindle layout done")
    end
end

return Surface
