local ffi = require("ffi")
local log = require("util.log")
local ffi_help = require("util.ffi_helpers")
local C = ffi.C
local Texture = require("compositor.renderer.texture")

local LayerSurface = {}

function LayerSurface.setup(server, layer_shell)
    server.layer_shell = layer_shell
    server.layer_surfaces = {}

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

    -- track it
    local entry = {
        layer_surface = layer_surface,
        layer = layer,
        texture = nil,
        x = 0,
        y = 0,
        width = 0,
        height = 0,
        mapped = false, -- wlr_layer_surface_v1 has no mapped member in 0.20
        cleanup = {},
    }
    table.insert(server.layer_surfaces, entry)

    -- helper: register a listener that we'll clean up on destroy
    local function on(signal, fn)
        local listener, destroy = ffi_help.make_listener_with_destroy(fn)
        ffi_help.signal_add(signal, listener)
        table.insert(entry.cleanup, destroy)
    end

    -- listen for commit - create/update texture from buffer
    on(surface.events.commit, function()
        if layer_surface.initialized then
            LayerSurface._arrange(server, layer_surface)
        end

        -- create/update texture from surface (wlroots caches it per commit)
        if C.wlr_surface_has_buffer(surface) then
            local tex = C.wlr_surface_get_texture(surface)
            if tex ~= nil then
                if not entry.texture then
                    entry.texture = Texture.from_wlr_texture(tex)
                    if entry.texture then
                        log.debug("created layer texture: %dx%d", entry.texture.width, entry.texture.height)
                    end
                else
                    entry.texture:update_wlr_texture(tex)
                end
                entry.width = surface.current.width
                entry.height = surface.current.height
            end
        end
    end)

    -- listen for map
    on(surface.events.map, function()
        entry.mapped = true
        LayerSurface._on_map(server, layer_surface, entry)
    end)

    -- listen for unmap
    on(surface.events.unmap, function()
        entry.mapped = false
        log.info("layer surface unmapped: %s",
            layer_surface.namespace ~= nil and ffi.string(layer_surface.namespace) or "(nil)")
    end)

    -- listen for new_popup (popups will be rendered as part of layer surface)
    on(layer_surface.events.new_popup, function(data)
        local popup = ffi.cast("struct wlr_xdg_popup *", data)
        log.debug("layer popup created")
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

        if entry.texture then
            entry.texture:destroy()
            entry.texture = nil
        end

        -- remove all listeners (required by wlroots before destroy completes)
        for _, fn in ipairs(entry.cleanup) do
            fn()
        end
        entry.cleanup = {}
    end)
end

-- anchor bits from wlr-layer-shell-v1 protocol
local ANCHOR_TOP, ANCHOR_BOTTOM, ANCHOR_LEFT, ANCHOR_RIGHT = 1, 2, 4, 8

-- size + position a layer surface per anchor/gravity/margin
function LayerSurface._arrange(server, layer_surface)
    local entry
    for _, e in ipairs(server.layer_surfaces) do
        if e.layer_surface == layer_surface then
            entry = e
            break
        end
    end
    if not entry then return end

    local box = ffi.new("struct wlr_box")
    C.wlr_output_layout_get_box(server.output_layout, layer_surface.output, box)

    local cur = layer_surface.current
    local ml, mr = cur.margin.left, cur.margin.right
    local mt, mb = cur.margin.top, cur.margin.bottom

    local a_left = bit.band(cur.anchor, ANCHOR_LEFT) ~= 0
    local a_right = bit.band(cur.anchor, ANCHOR_RIGHT) ~= 0
    local a_top = bit.band(cur.anchor, ANCHOR_TOP) ~= 0
    local a_bottom = bit.band(cur.anchor, ANCHOR_BOTTOM) ~= 0

    -- stretched axes take size from output box minus margins, free axes use client's desired size
    local tw = (a_left and a_right) and (box.width - ml - mr) or cur.desired_width
    local th = (a_top and a_bottom) and (box.height - mt - mb) or cur.desired_height

    -- only reconfigure when the target actually changes (avoids ping-pong)
    if tw ~= entry.last_cw or th ~= entry.last_ch then
        entry.last_cw, entry.last_ch = tw, th
        C.wlr_layer_surface_v1_configure(layer_surface, math.max(tw, 0), math.max(th, 0))
    end

    -- position by actual committed size (client may pick smaller than configured)
    local surf = layer_surface.surface
    local aw = surf and surf.current.width > 0 and surf.current.width or tw
    local ah = surf and surf.current.height > 0 and surf.current.height or th

    local x, y
    if a_left and not a_right then x = box.x + ml
    elseif a_right and not a_left then x = box.x + box.width - mr - aw
    else x = box.x + math.floor((box.width - aw) / 2) end

    if a_top and not a_bottom then y = box.y + mt
    elseif a_bottom and not a_top then y = box.y + box.height - mb - ah
    else y = box.y + math.floor((box.height - ah) / 2) end

    entry.x, entry.y = x, y
    entry.width, entry.height = aw, ah
    entry.output_box = { x = box.x, y = box.y, width = box.width, height = box.height }
    log.debug("layer arrange: %s -> %d,%d %dx%d (anchor=%d)",
        layer_surface.namespace ~= nil and ffi.string(layer_surface.namespace) or "?",
        x, y, aw, ah, cur.anchor)
end

function LayerSurface._on_map(server, layer_surface, entry)
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
