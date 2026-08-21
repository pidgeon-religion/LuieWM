local ffi = require("ffi")
local log = require("util.log")
local ffi_help = require("util.ffi_helpers")
local C = ffi.C

local Output = {}

function Output.handle_new(server, wlr_output)
	log.info("output added: %s", ffi.string(wlr_output.name))
	-- check if already added
	for _, out in ipairs(server.outputs) do
		if out.wlr_output == wlr_output then
			log.warn("output %s already tracked, skipping", ffi.string(wlr_output.name))
			return
		end
	end
	Output._finish_setup(server, wlr_output)
end

function Output._finish_setup(server, wlr_output)
	log.info("output added: %s", ffi.string(wlr_output.name))

	-- initialize render subsystem for this output (required before commit/cursor ops)
	if not C.wlr_output_init_render(wlr_output, server.allocator, server.renderer) then
		log.error("failed to init render for %s", ffi.string(wlr_output.name))
		return
	end

	-- add to output layout
	local layout_output = C.wlr_output_layout_add_auto(server.output_layout, wlr_output)

	local box = ffi.new("struct wlr_box")
	C.wlr_output_layout_get_box(server.output_layout, wlr_output, box)
	log.info("output %s layout box: %d,%d %dx%d", ffi.string(wlr_output.name), box.x, box.y, box.width, box.height)

	-- configure output state (set mode and enable)
	local state = ffi.new("struct wlr_output_state[1]")
	C.wlr_output_state_init(state)
	C.wlr_output_state_set_enabled(state, true)

	-- find preferred mode - use current_mode first (most reliable)
	local preferred_mode = nil
	if wlr_output.current_mode then
		preferred_mode = wlr_output.current_mode
		log.info(
			"using current_mode %dx%d@%dHz for %s",
			preferred_mode.width,
			preferred_mode.height,
			preferred_mode.refresh,
			ffi.string(wlr_output.name)
		)
	else
		-- fallback to iterating modes list
		local modes_list = wlr_output.modes
		if modes_list.next ~= nil and modes_list.next ~= modes_list then
			local mode = modes_list.next
			while mode ~= modes_list do
				local m = ffi.cast("struct wlr_output_mode *", mode)
				if m.preferred then
					preferred_mode = m
					break
				end
				mode = mode.next
			end
		end
	end

	if preferred_mode then
		log.info(
			"setting mode %dx%d@%dHz for %s",
			preferred_mode.width,
			preferred_mode.height,
			preferred_mode.refresh,
			ffi.string(wlr_output.name)
		)
		C.wlr_output_state_set_mode(state, preferred_mode)
	else
		-- fallback to current mode or custom mode
		if wlr_output.current_mode then
			C.wlr_output_state_set_mode(state, wlr_output.current_mode)
		else
			C.wlr_output_state_set_custom_mode(state, box.width, box.height, 60)
		end
	end

	if not C.wlr_output_commit_state(wlr_output, state) then
		log.error("failed to commit output state for %s", ffi.string(wlr_output.name))
	else
		log.info("output state committed successfully for %s", ffi.string(wlr_output.name))
	end
	C.wlr_output_state_finish(state)

	local output_data = {
		wlr_output = wlr_output,
		layout_output = layout_output,
		width = box.width,
		height = box.height,
		configured = true,
	}
	table.insert(server.outputs, output_data)

	-- setup frame listener
	local frame_listener, frame_destroy = ffi_help.make_listener(function()
		Output._on_frame(server, output_data)
	end)
	ffi_help.signal_add(wlr_output.events.frame, frame_listener)
	output_data.frame_listener = frame_listener
	output_data.frame_destroy = frame_destroy

	-- listen for request_state (when mode changes)
	local request_state_listener, request_state_destroy = ffi_help.make_listener(function(data)
		Output._on_request_state(server, output_data, ffi.cast("struct wlr_output_event_request_state *", data))
	end)
	ffi_help.signal_add(wlr_output.events.request_state, request_state_listener)
	output_data.request_state_listener = request_state_listener
	output_data.request_state_destroy = request_state_destroy

	-- setup destroy listener
	local destroy_listener, destroy_destroy = ffi_help.make_listener(function()
		Output._on_destroy(server, output_data)
	end)
	ffi_help.signal_add(wlr_output.events.destroy, destroy_listener)
	output_data.destroy_listener = destroy_listener
	output_data.destroy_destroy = destroy_destroy

	-- apply layout for any existing views
	server:_schedule_layout()

	-- kick the first frame
	C.wlr_output_schedule_frame(wlr_output)
end

function Output._on_request_state(server, output_data, event)
	local wlr_output = output_data.wlr_output
	local state = event.state

	-- ensure output stays enabled
	C.wlr_output_state_set_enabled(state, true)

	if not C.wlr_output_commit_state(wlr_output, state) then
		log.warn("failed to commit request_state for %s", ffi.string(wlr_output.name))
	end
end

function Output._on_frame(server, output_data)
	local wlr_output = output_data.wlr_output
	local output_width = output_data.width
	local output_height = output_data.height

	-- get current output box in case it changed
	local box = ffi.new("struct wlr_box")
	C.wlr_output_layout_get_box(server.output_layout, wlr_output, box)
	output_data.width = box.width
	output_data.height = box.height
	output_width = box.width
	output_height = box.height

	-- begin render pass for this output
	local pass = server.custom_renderer:begin_output(wlr_output)
	if pass == nil then
		log.warn("render pass begin failed for %s", ffi.string(wlr_output.name))
		C.wlr_output_schedule_frame(wlr_output)
		return
	end

	-- clear background
	local bg_color = server.config and server.config.background_color or { 0.1, 0.1, 0.12, 1.0 }
	server.custom_renderer:clear(pass, bg_color)

	-- layer shell stacking: background(0)/bottom(1) below views,
	-- top(2)/overlay(3) above them
	local function draw_layers(below)
		if not server.layer_surfaces then
			return
		end
		for _, entry in ipairs(server.layer_surfaces) do
			local ls = entry.layer_surface
			local is_below = (entry.layer or 0) <= 1
			if is_below == below and ls.surface and entry.mapped and entry.texture then
				local ls_box = { x = entry.x or 0, y = entry.y or 0, width = entry.width, height = entry.height }
				server.custom_renderer:draw_texture(pass, entry.texture, ls_box, output_width, output_height, 1.0)
			end
		end
	end

	draw_layers(true)

	-- render views (tiled first, then floating on top)
	for _, view in ipairs(server.views) do
		if view.mapped and view.texture and view.visible_on_tag then
			local bw = view.border_width or 0
			local cx, cy = view.x + bw, view.y + bw

			-- draw at the client's committed size, never stretched
			local dst
			local clip
			local rg = view.render_geo
			if rg then
				-- csd: whole buffer incl shadow margins, offset so the window
				-- geometry lands on the content box; clipped so shadows never paint
				dst = { x = cx - rg.x, y = cy - rg.y, width = view.texture.width, height = view.texture.height }
				clip = { x = cx, y = cy, width = rg.width, height = rg.height }
			elseif view.texture.width > view.width - 2 * bw or view.texture.height > view.height - 2 * bw then
				-- oversized buffer without geometry: top-left like scene does,
				-- margins spill out (matches sway/hyprland behavior)
				dst = { x = cx, y = cy, width = view.texture.width, height = view.texture.height }
			else
				dst = { x = cx, y = cy, width = view.texture.width, height = view.texture.height }
			end
			server.custom_renderer:draw_texture(
				pass,
				view.texture,
				dst,
				output_width,
				output_height,
				view.opacity or 1.0,
				nil,
				clip
			)

			-- subsurfaces (positions are relative to parent surface origin = dst origin)
			if view.subsurfaces then
				for _, ss in ipairs(view.subsurfaces) do
					if ss.mapped and ss.texture then
						local sdst = {
							x = dst.x + ss.subsurface.current.x,
							y = dst.y + ss.subsurface.current.y,
							width = ss.texture.width,
							height = ss.texture.height,
						}
						server.custom_renderer:draw_texture(
							pass,
							ss.texture,
							sdst,
							output_width,
							output_height,
							view.opacity or 1.0
						)
					end
				end
			end

			-- temp debug: throttle to every 60th frame
			server._dbg_frame_n = (server._dbg_frame_n or 0) + 1
			if server._dbg_frame_n % 60 == 1 then
				log.debug(
					"draw view: dst=%d,%d %dx%d tex=%dx%d ptr=%s opacity=%s geo=%s",
					dst.x,
					dst.y,
					dst.width,
					dst.height,
					view.texture.width,
					view.texture.height,
					view.texture._destroyed and "DESTROYED" or "ok",
					view.opacity or 1.0,
					rg and string.format("%d,%d %dx%d", rg.x, rg.y, rg.width, rg.height) or "none"
				)
			end

			-- draw border if not fullscreen
			if not view.fullscreen and view.border_width and view.border_width > 0 then
				local border_color = view.focused
						and (server.config and server.config.focus_color or { 0.0, 0.478, 0.8, 1.0 })
					or (server.config and server.config.unfocus_color or { 0.078, 0.078, 0.078, 1.0 })
				local view_box = { x = view.x, y = view.y, width = view.width, height = view.height }
				server.custom_renderer:draw_border(
					pass,
					view_box,
					view.border_width,
					output_width,
					output_height,
					border_color
				)
			end
		end
	end

	-- top/overlay layers above views
	draw_layers(false)

	-- submit render pass
	if not server.custom_renderer:submit(pass) then
		log.warn("render pass submit failed for %s", ffi.string(wlr_output.name))
	end

	-- send frame_done to all surfaces with pending frame callbacks
	local now = ffi.new("struct timespec")
	C.clock_gettime(1, now)
	for _, view in ipairs(server.views) do
		if view.mapped and view.wlr_surface ~= nil then
			C.wlr_surface_send_frame_done(view.wlr_surface, now)
			if view.subsurfaces then
				for _, ss in ipairs(view.subsurfaces) do
					if ss.mapped and ss.surface ~= nil then
						C.wlr_surface_send_frame_done(ss.surface, now)
					end
				end
			end
			-- temp debug
			view._fd_n = (view._fd_n or 0) + 1
			if view._fd_n % 120 == 1 then
				log.debug("frame_done #%d -> %s", view._fd_n, view:get_title())
			end
		end
	end
	if server.layer_surfaces then
		for _, entry in ipairs(server.layer_surfaces) do
			local ls = entry.layer_surface
			if ls.surface ~= nil then
				C.wlr_surface_send_frame_done(ls.surface, now)
			end
		end
	end

	C.wlr_output_schedule_frame(wlr_output)
end

function Output._on_destroy(server, output_data)
	for i, out in ipairs(server.outputs) do
		if out == output_data then
			table.remove(server.outputs, i)
			break
		end
	end
	if output_data.frame_destroy then
		output_data.frame_destroy()
	end
	if output_data.destroy_destroy then
		output_data.destroy_destroy()
	end
	log.info("output removed")
end

function Output.get_layout_box(server)
	local box = ffi.new("struct wlr_box")
	C.wlr_output_layout_get_box(server.output_layout, nil, box)
	return { x = box.x, y = box.y, width = box.width, height = box.height }
end

return Output
