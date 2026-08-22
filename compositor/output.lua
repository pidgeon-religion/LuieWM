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

	-- find preferred mode - use current_mode first (most reliable).
	-- ~= nil on purpose: a NULL cdata is truthy in luajit, and nested or
	-- headless outputs have no mode until one is set
	local preferred_mode = nil
	if wlr_output.current_mode ~= nil then
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
		if wlr_output.current_mode ~= nil then
			C.wlr_output_state_set_mode(state, wlr_output.current_mode)
		else
			-- nested/headless outputs have no mode list; refresh 0 lets the
			-- backend pick its own pace
			C.wlr_output_state_set_custom_mode(state, box.width, box.height, 0)
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
	-- event.state is const; we amend it before committing, so cast
	local state = ffi.cast("struct wlr_output_state *", event.state)

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

	-- frame trace: when a popup draws, dump every draw of that frame so
	-- overdraw order can be verified against the popup position
	local frame_trace = {}
	local drew_popup = false

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
				table.insert(
					frame_trace,
					string.format("layer at %d,%d %dx%d", ls_box.x, ls_box.y, ls_box.width, ls_box.height)
				)
				server.custom_renderer:draw_texture(pass, entry.texture, ls_box, output_width, output_height, 1.0)
			end
		end
	end

	draw_layers(true)

	-- render views (tiled first, then floating on top)
	local corner_radius = (server.config and server.config.corner_radius) or 0
	for _, view in ipairs(server.views) do
		if view.mapped and view.texture and view.visible_on_tag then
			table.insert(
				frame_trace,
				string.format("view %s at %d,%d %dx%d", view:get_title(), view.x, view.y, view.width, view.height)
			)
			local bw = view.border_width or 0
			local cx, cy = view.x + bw, view.y + bw
			-- content box: view minus borders; clients configure at this size
			local cw = math.max(1, view.width - 2 * bw)
			local ch = math.max(1, view.height - 2 * bw)
			local rg = view.render_geo

			-- rounded mode: border ring + content via the sdf shaders;
			-- plain mode keeps wlroots draws with strip borders
			local rounded_mode = not view.fullscreen and corner_radius > 0

			local dst
			local clip
			local quad
			local src
			if rg then
				-- csd: whole buffer incl shadow margins, offset so the window
				-- geometry lands on the content box; clipped so shadows never
				-- paint. rounded mode additionally caps the visible area at
				-- the content box instead of spilling past it
				dst = { x = cx - rg.x, y = cy - rg.y, width = view.texture.width, height = view.texture.height }
				local vw = math.min(rg.width, cw)
				local vh = math.min(rg.height, ch)
				src = { x = rg.x, y = rg.y, width = vw, height = vh }
				quad = { x = cx, y = cy, width = vw, height = vh }
				clip = { x = cx, y = cy, width = rg.width, height = rg.height }
			else
				-- no geometry: draw the buffer 1:1 anchored top-left like
				-- scene does. rounded mode clips it into the content box,
				-- plain mode lets margins spill out (sway/hyprland behavior)
				local vw = math.min(view.texture.width, cw)
				local vh = math.min(view.texture.height, ch)
				src = { x = 0, y = 0, width = vw, height = vh }
				quad = { x = cx, y = cy, width = vw, height = vh }
				dst = { x = cx, y = cy, width = view.texture.width, height = view.texture.height }
			end

			-- temp debug: throttle to every 60th frame
			server._dbg_frame_n = (server._dbg_frame_n or 0) + 1
			if server._dbg_frame_n % 60 == 1 then
				log.debug(
					"draw view: quad=%d,%d %dx%d tex=%dx%d ptr=%s opacity=%s geo=%s",
					quad.x,
					quad.y,
					quad.width,
					quad.height,
					view.texture.width,
					view.texture.height,
					view.texture._destroyed and "DESTROYED" or "ok",
					view.opacity or 1.0,
					rg and string.format("%d,%d %dx%d", rg.x, rg.y, rg.width, rg.height) or "none"
				)
			end

			if rounded_mode then
				local content_box = { x = cx, y = cy, width = cw, height = ch }
				local r = math.max(0, math.min(corner_radius, view.width * 0.5, view.height * 0.5))
				local r_inner = math.max(0, r - bw)

				-- border ring underlay, then content on top; both edges get
				-- their aa from the same sdf family so nothing double-blends
				if bw > 0 then
					local border_color = view.focused
							and (server.config and server.config.focus_color or { 0.0, 0.478, 0.8, 1.0 })
						or (server.config and server.config.unfocus_color or { 0.078, 0.078, 0.078, 1.0 })
					local view_box = { x = view.x, y = view.y, width = view.width, height = view.height }
					server.custom_renderer:draw_solid_rounded(
						pass,
						view_box,
						output_width,
						output_height,
						r,
						border_color,
						bw
					)
				end

				-- content always at the client's committed size (src maps 1:1
				-- onto quad), anchored top-left until the resize catches up -
				-- never stretched
				server.custom_renderer:draw_texture_rounded(
					pass,
					view.texture,
					quad,
					content_box,
					output_width,
					output_height,
					view.opacity or 1.0,
					src,
					{ r_inner, r_inner, r_inner, r_inner }
				)

				-- subsurfaces: positions are relative to the parent surface
				-- origin; clipped into the content box and rounded only where
				-- they actually form one of its corners (firefox web content)
				local surf_x = cx - (rg and rg.x or 0)
				local surf_y = cy - (rg and rg.y or 0)
				if view.subsurfaces then
					for _, ss in ipairs(view.subsurfaces) do
						if ss.mapped and ss.texture then
						if not ss._logged then
							ss._logged = true
							if C.wlr_renderer_is_gles2(server.renderer) then
								local attribs = ffi.new("struct wlr_gles2_texture_attribs")
								C.wlr_gles2_texture_get_attribs(ss.texture.texture, attribs)
								log.debug(
									"subsurface draw %dx%d target=%d gl_tex=%u alpha=%s",
									ss.texture.width,
									ss.texture.height,
									attribs.target,
									attribs.tex,
									tostring(attribs.has_alpha ~= 0)
								)
							else
								log.debug("subsurface draw %dx%d", ss.texture.width, ss.texture.height)
							end
						end
							local srect = {
								x = surf_x + ss.subsurface.current.x,
								y = surf_y + ss.subsurface.current.y,
								width = ss.texture.width,
								height = ss.texture.height,
							}
							local ix = math.max(srect.x, cx)
							local iy = math.max(srect.y, cy)
							local ix2 = math.min(srect.x + srect.width, cx + cw)
							local iy2 = math.min(srect.y + srect.height, cy + ch)
							local iw, ih = ix2 - ix, iy2 - iy
							if iw > 0 and ih > 0 then
								-- corner counts as "at the box corner" within
								-- half a pixel; everything else stays square
								local e = 0.5
								local function near(a, b)
									return math.abs(a - b) < e
								end
								local tl = near(ix, cx) and near(iy, cy)
								local tr = near(ix + iw, cx + cw) and near(iy, cy)
								local bl = near(ix, cx) and near(iy + ih, cy + ch)
								local br = near(ix + iw, cx + cw) and near(iy + ih, cy + ch)
								server.custom_renderer:draw_texture_rounded(
									pass,
									ss.texture,
									{ x = ix, y = iy, width = iw, height = ih },
									content_box,
									output_width,
									output_height,
									view.opacity or 1.0,
									{ x = ix - srect.x, y = iy - srect.y, width = iw, height = ih },
									{
										tl and r_inner or 0,
										tr and r_inner or 0,
										bl and r_inner or 0,
										br and r_inner or 0,
									}
								)
							end
						end
					end
				end
			else
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
			-- popups (menus/tooltips): geometry is relative to the parent's
			-- window geometry origin, so nested popups chain offsets upward
			-- until the toplevel
			if view.popups then
				for _, entry in ipairs(view.popups) do
					if entry.mapped and entry.texture then
						local ox, oy = cx, cy
						local parent = entry.popup.parent
						for _ = 1, 10 do
							local ancestor = nil
							for _, other in ipairs(view.popups) do
								if other ~= entry and other.surface == parent then
									ancestor = other
									break
								end
							end
							if not ancestor then
								break
							end
							ox = ox + ancestor.popup.current.geometry.x
							oy = oy + ancestor.popup.current.geometry.y
							parent = ancestor.popup.parent
						end

						local gx = ox + entry.popup.current.geometry.x
						local gy = oy + entry.popup.current.geometry.y
						-- abs feeds pointer hit-testing next frame
						entry.abs = { x = gx, y = gy, width = entry.texture.width, height = entry.texture.height }
						drew_popup = true
						table.insert(
							frame_trace,
							string.format(
								"popup %s at %d,%d %dx%d",
								entry.texture._destroyed and "DESTROYED" or "ok",
								gx,
								gy,
								entry.texture.width,
								entry.texture.height
							)
						)
						if not entry._drew then
							entry._drew = true
							-- attribs probe is gles2-only; pixman textures abort it
							if C.wlr_renderer_is_gles2(server.renderer) then
								local attribs = ffi.new("struct wlr_gles2_texture_attribs")
								C.wlr_gles2_texture_get_attribs(entry.texture.texture, attribs)
								log.debug(
									"popup draw at %d,%d %dx%d target=%d gl_tex=%u alpha=%s",
									gx,
									gy,
									entry.texture.width,
									entry.texture.height,
									attribs.target,
									attribs.tex,
									tostring(attribs.has_alpha ~= 0)
								)
							else
								log.debug("popup draw at %d,%d %dx%d", gx, gy, entry.texture.width, entry.texture.height)
							end
						end
						server.custom_renderer:draw_texture(
							pass,
							entry.texture,
							entry.abs,
							output_width,
							output_height,
							view.opacity or 1.0
						)

						-- popup subsurfaces (gecko paints menu content into
						-- them): offsets are relative to the popup surface
						-- origin, which our base draw anchors at gx,gy
						for _, ss in ipairs(entry.subsurfaces or {}) do
							if ss.mapped and ss.texture then
								server.custom_renderer:draw_texture(
									pass,
									ss.texture,
									{
										x = gx + ss.subsurface.current.x,
										y = gy + ss.subsurface.current.y,
										width = ss.texture.width,
										height = ss.texture.height,
									},
									output_width,
									output_height,
									view.opacity or 1.0
								)
							end
						end
					end
				end
			end
		end
	end

	-- top/overlay layers above views
	draw_layers(false)

	-- dump the frame's draw order once a popup participated in it
	if drew_popup then
		for _, line in ipairs(frame_trace) do
			log.debug("frame: %s", line)
		end
	end

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
			if view.popups then
				for _, entry in ipairs(view.popups) do
					if entry.mapped then
						C.wlr_surface_send_frame_done(entry.surface, now)
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
	if output_data.request_state_destroy then
		-- wlroots asserts if a signal still has listeners at destroy time
		output_data.request_state_destroy()
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
