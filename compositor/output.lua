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
	-- initialize render subsystem for this output (required before commit/cursor ops)
	if not C.wlr_output_init_render(wlr_output, server.allocator, server.renderer) then
		log.error("failed to init render for %s", ffi.string(wlr_output.name))
		return
	end

	-- add to output layout
	local layout_output = C.wlr_output_layout_add_auto(server.output_layout, wlr_output)

	-- create scene output
	local scene_output = C.wlr_scene_output_create(server.scene, wlr_output)

	-- create background rect so the scene always has visible content
	local box = ffi.new("struct wlr_box")
	C.wlr_output_layout_get_box(server.output_layout, wlr_output, box)
	log.info("output %s layout box: %d,%d %dx%d", ffi.string(wlr_output.name), box.x, box.y, box.width, box.height)
	local bg_color = ffi.new("float[4]", { 0.1, 0.1, 0.15, 1.0 })
	local bg_parent = server.content_tree or server.scene.tree
	local bg_rect = C.wlr_scene_rect_create(bg_parent, box.width, box.height, bg_color)
	C.wlr_scene_node_set_position(bg_rect.node, box.x, box.y)

	local output_data = {
		wlr_output = wlr_output,
		layout_output = layout_output,
		scene_output = scene_output,
		bg_rect = bg_rect,
	}
	table.insert(server.outputs, output_data)

	-- setup frame listener
	local frame_listener, frame_destroy = ffi_help.make_listener(function()
		Output._on_frame(server, output_data)
	end)
	ffi_help.signal_add(wlr_output.events.frame, frame_listener)
	output_data.frame_listener = frame_listener
	output_data.frame_destroy = frame_destroy

	-- setup destroy listener
	local destroy_listener, destroy_destroy = ffi_help.make_listener(function()
		Output._on_destroy(server, output_data)
	end)
	ffi_help.signal_add(wlr_output.events.destroy, destroy_listener)
	output_data.destroy_listener = destroy_listener
	output_data.destroy_destroy = destroy_destroy

	-- apply layout for any existing views
	server:_schedule_layout()

	-- kick the first frame - the scene graph handles modeset + render atomically
	C.wlr_output_schedule_frame(wlr_output)
end

function Output._on_frame(server, output_data)
	if output_data.scene_output == nil then
		log.warn("scene_output is nil for %s", ffi.string(output_data.wlr_output.name))
		C.wlr_output_schedule_frame(output_data.wlr_output)
		return
	end
	local ret = C.wlr_scene_output_commit(output_data.scene_output, nil)
	if not ret then
		log.warn("scene output commit FAILED for %s", ffi.string(output_data.wlr_output.name))
	end

	-- send frame_done to all surfaces with pending frame callbacks
	-- the scene graph doesn't reliably do this for xdg surfaces
	local now = ffi.new("struct timespec")
	C.clock_gettime(1, now) -- CLOCK_MONOTONIC
	for _, view in ipairs(server.views) do
		if view.mapped and view.wlr_surface ~= nil then
			C.wlr_surface_send_frame_done(view.wlr_surface, now)
		end
	end
	-- layer surfaces also need frame_done
	if server.layer_surfaces then
		for _, entry in ipairs(server.layer_surfaces) do
			local ls = entry.layer_surface
			if ls.surface ~= nil then
				C.wlr_surface_send_frame_done(ls.surface, now)
			end
		end
	end

	C.wlr_output_schedule_frame(output_data.wlr_output)
end

function Output._on_destroy(server, output_data)
	for i, out in ipairs(server.outputs) do
		if out == output_data then
			table.remove(server.outputs, i)
			break
		end
	end
	if output_data.frame_destroy then output_data.frame_destroy() end
	if output_data.destroy_destroy then output_data.destroy_destroy() end
	if output_data.bg_rect then C.wlr_scene_node_destroy(output_data.bg_rect.node) end
	log.info("output removed")
end

function Output.get_layout_box(server)
	local box = ffi.new("struct wlr_box")
	C.wlr_output_layout_get_box(server.output_layout, nil, box)
	return { x = box.x, y = box.y, width = box.width, height = box.height }
end

return Output
