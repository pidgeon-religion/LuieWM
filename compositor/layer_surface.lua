local ffi = require("ffi")
local log = require("util.log")
local ffi_help = require("util.ffi_helpers")
local C = ffi.C

local LayerSurface = {}

-- layer index → scene tree (set up by server)
-- stored as server.layer_trees[0..3]

function LayerSurface.setup(server, layer_shell)
    server.layer_shell = layer_shell
    server.layer_surfaces = {}

    -- create 4 scene trees for the 4 layers
    server.layer_trees = {}
    for i = 0, 3 do
        server.layer_trees[i] = C.wlr_scene_tree_create(server.scene.tree)
    end

    -- create content tree for xdg surfaces (between bottom and top)
    server.content_tree = C.wlr_scene_tree_create(server.scene.tree)

    -- z-order from bottom to top:
    --   layer0(bg), layer1(bottom), content_tree, layer2(top), layer3(overlay)
    C.wlr_scene_node_lower_to_bottom(server.layer_trees[0].node)
    C.wlr_scene_node_lower_to_bottom(server.layer_trees[1].node)
    C.wlr_scene_node_raise_to_top(server.layer_trees[2].node)
    C.wlr_scene_node_raise_to_top(server.layer_trees[3].node)

    -- listen for new layer surfaces
    local new_surface_listener = ffi_help.make_listener(function(data)
        LayerSurface._on_new_surface(server, ffi.cast("struct wlr_layer_surface_v1 *", data))
    end)
    ffi_help.signal_add(layer_shell.events.new_surface, new_surface_listener)
    server.layer_surface_listener = new_surface_listener

    log.info("layer shell setup complete")
end

function LayerSurface._on_new_surface(server, layer_surface)
    local surface = layer_surface.surface
    local state = layer_surface.pending
    local layer = state.layer

    log.info("new layer surface: layer=%d namespace=%s", layer,
        layer_surface.namespace ~= nil and ffi.string(layer_surface.namespace) or "(nil)")

        -- pick the right scene tree
    local tree = server.layer_trees[layer]
    if tree == nil then
        log.warn("unknown layer %d, using overlay", layer)
        tree = server.layer_trees[3]
    end

        -- create the scene layer surface
    local scene_layer = C.wlr_scene_layer_surface_v1_create(tree, layer_surface)
    if scene_layer == nil then
        log.error("failed to create scene layer surface")
        return
    end

        -- store reference on the layer_surface so we can find it later
    layer_surface.data = ffi.cast("void *", scene_layer)

        -- track it
    local entry = {
        layer_surface = layer_surface,
        scene_layer = scene_layer,
        layer = layer,
        cleanup = {},
    }
    table.insert(server.layer_surfaces, entry)

        -- helper: register a listener that we'll clean up on destroy
    local function on(signal, fn)
        local listener, destroy = ffi_help.make_listener_with_destroy(fn)
        ffi_help.signal_add(signal, listener)
        table.insert(entry.cleanup, destroy)
    end

    -- listen for initial commit (surface->initialized becomes true after this)
    on(surface.events.commit, function()
        if layer_surface.initialized then
            LayerSurface._configure_all(server, layer_surface)
        end
    end)

    -- listen for map
    on(surface.events.map, function()
        LayerSurface._on_map(server, layer_surface)
    end)

    -- listen for new_popup
    on(layer_surface.events.new_popup, function(data)
        local popup = ffi.cast("struct wlr_xdg_popup *", data)
        local popup_tree = C.wlr_scene_xdg_surface_create(tree, popup.base)
        if popup_tree ~= nil then
            log.debug("layer popup created")
        end
    end)

    -- listen for destroy (must be last - cleanup all listeners)
    on(layer_surface.events.destroy, function()
        log.info("layer surface destroyed")

        -- remove from tracking list
        for i, e in ipairs(server.layer_surfaces) do
            if e == entry then
                table.remove(server.layer_surfaces, i)
                break
            end
        end

        -- remove all listeners (required by wlroots before destroy completes)
        for _, fn in ipairs(entry.cleanup) do
            fn()
        end
        entry.cleanup = {}
    end)
end

function LayerSurface._configure_all(server, layer_surface)
    for _, out in ipairs(server.outputs) do
        local box = ffi.new("struct wlr_box")
        C.wlr_output_layout_get_box(server.output_layout, out.wlr_output, box)
        local usable = ffi.new("struct wlr_box")
        usable.x = box.x
        usable.y = box.y
        usable.width = box.width
        usable.height = box.height

        -- tell client the dimensions it gets
        C.wlr_layer_surface_v1_configure(layer_surface, usable.width, usable.height)

        -- position the scene node based on anchors/margins/exclusive_zone
        local scene_layer = ffi.cast("struct wlr_scene_layer_surface_v1 *", layer_surface.data)
        if scene_layer ~= nil then
            C.wlr_scene_layer_surface_v1_configure(scene_layer, box, usable)
        end
    end
end

function LayerSurface._on_map(server, layer_surface)
    local surface = layer_surface.surface
    log.info("layer surface mapped: %s",
        layer_surface.namespace ~= nil and ffi.string(layer_surface.namespace) or "(nil)")

    -- send frame_done so it starts rendering
    local now = ffi.new("struct timespec")
    C.clock_gettime(1, now)
    C.wlr_surface_send_frame_done(surface, now)

    -- handle keyboard interactivity
    local state = layer_surface.current
    if state.keyboard_interactive == 1 then -- exclusive
        -- focus this surface
        local seat = server.seat
        local keyboard = C.wlr_seat_get_keyboard(seat)
        if keyboard ~= nil then
            C.wlr_seat_keyboard_notify_enter(seat, surface,
                keyboard.keycodes, keyboard.num_keycodes, keyboard.modifiers)
        end
    end
end

function LayerSurface.get_mapped_surfaces(server)
    local result = {}
    for _, entry in ipairs(server.layer_surfaces) do
        if entry.layer_surface.surface ~= nil and entry.layer_surface.configured then
            table.insert(result, entry.layer_surface.surface)
        end
    end
    return result
end

return LayerSurface
