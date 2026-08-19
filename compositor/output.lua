local ffi = require("ffi")
local log = require("util.log")
local ffi_help = require("util.ffi_helpers")
local C = ffi.C

local Output = {}

function Output.handle_new(server, wlr_output)
    log.info("output added: %s", ffi.string(wlr_output.name))
    Output._finish_setup(server, wlr_output)
end

function Output._finish_setup(server, wlr_output)
    -- Initialize render subsystem for this output (required before commit/cursor ops)
    if not C.wlr_output_init_render(wlr_output, server.allocator, server.renderer) then
        log.error("failed to init render for %s", ffi.string(wlr_output.name))
        return
    end

    -- Add to output layout
    local layout_output = C.wlr_output_layout_add_auto(server.output_layout, wlr_output)

    -- Create scene output
    local scene_output = C.wlr_scene_output_create(server.scene, wlr_output)

    -- Create background rect so the scene always has visible content
    local box = ffi.new("struct wlr_box")
    C.wlr_output_layout_get_box(server.output_layout, wlr_output, box)
    log.info("output %s layout box: %d,%d %dx%d", ffi.string(wlr_output.name), box.x, box.y, box.width, box.height)
    local bg_color = ffi.new("float[4]", {0.1, 0.1, 0.15, 1.0})
    local bg_rect = C.wlr_scene_rect_create(server.scene.tree, box.width, box.height, bg_color)
    C.wlr_scene_node_set_position(bg_rect.node, box.x, box.y)

    local output_data = {
        wlr_output = wlr_output,
        layout_output = layout_output,
        scene_output = scene_output,
    }
    table.insert(server.outputs, output_data)

    -- Setup frame listener
    local frame_listener = ffi_help.make_listener(function()
        Output._on_frame(server, output_data)
    end)
    ffi_help.signal_add(wlr_output.events.frame, frame_listener)
    output_data.frame_listener = frame_listener

    -- Setup destroy listener
    local destroy_listener = ffi_help.make_listener(function()
        Output._on_destroy(server, output_data)
    end)
    ffi_help.signal_add(wlr_output.events.destroy, destroy_listener)
    output_data.destroy_listener = destroy_listener

    -- Apply layout for any existing views
    local surface = require("compositor.surface")
    surface._apply_layout(server)

    -- Kick the first frame - the scene graph handles modeset + render atomically
    C.wlr_output_schedule_frame(wlr_output)
end

function Output._on_frame(server, output_data)
    if output_data.scene_output == nil then
        log.warn("scene_output is nil for %s", ffi.string(output_data.wlr_output.name))
        return
    end
    local ret = C.wlr_scene_output_commit(output_data.scene_output, nil)
    if not ret then
        log.warn("scene output commit FAILED for %s", ffi.string(output_data.wlr_output.name))
    end
end

function Output._on_destroy(server, output_data)
    for i, out in ipairs(server.outputs) do
        if out == output_data then
            table.remove(server.outputs, i)
            break
        end
    end
    log.info("output removed")
end

function Output.get_layout_box(server)
    local box = ffi.new("struct wlr_box")
    C.wlr_output_layout_get_box(server.output_layout, nil, box)
    return { x = box.x, y = box.y, width = box.width, height = box.height }
end

return Output
