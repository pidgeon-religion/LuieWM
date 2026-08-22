local ffi = require("ffi")
local log = require("util.log")
local ffi_help = require("util.ffi_helpers")
local C = ffi.C
local View = require("wm.view")
local Texture = require("compositor.renderer.texture")

local Surface = {}

local xdg_new_surface_listener = nil
local xdg_new_toplevel_listener = nil

-- detach globals registered in setup; wlroots asserts on non-empty signal
-- lists when the display goes away otherwise
function Surface.teardown()
	if xdg_new_toplevel_listener ~= nil then
		ffi_help.signal_remove(xdg_new_toplevel_listener)
		xdg_new_toplevel_listener = nil
	end
end

function Surface.setup(server)
	if server.xdg_shell == nil then
		log.error("xdg_shell is nil!")
		return
	end

	xdg_new_toplevel_listener = ffi_help.make_listener(function(data)
		Surface._on_new_toplevel(server, ffi.cast("struct wlr_xdg_toplevel *", data))
	end)
	ffi_help.signal_add(server.xdg_shell.events.new_toplevel, xdg_new_toplevel_listener)
	log.info("xdg_shell listeners registered")
end

function Surface._on_new_toplevel(server, xdg_toplevel)
	local xdg_surface = xdg_toplevel.base

	-- create view (no scene tree needed)
	local view = View.new(xdg_toplevel)
	view._server = server
	view.tags = { [server.current_tag] = true }
	view.border_width = server.config and server.config.border_width or 4
	server:add_view(view)

	-- add to dwindle layout
	if server.dwindle then
		server.dwindle:add_view(view, server.current_tag)
	end

	-- setup listeners for this view
	Surface._setup_view_listeners(server, view)

	log.info("new toplevel: %s", view:get_title())
end

function Surface._setup_view_listeners(server, view)
	-- commit listener - create/update texture from surface buffer, send initial configure
	local commit_listener, commit_destroy = ffi_help.make_listener(function()
		Surface._on_commit(server, view)
	end)
	ffi_help.signal_add(view.wlr_surface.events.commit, commit_listener)
	view.commit_listener = commit_listener
	view._destroy_funcs = view._destroy_funcs or {}
	table.insert(view._destroy_funcs, commit_destroy)

	-- map listener
	local map_listener, map_destroy = ffi_help.make_listener(function()
		Surface._on_map(server, view)
	end)
	ffi_help.signal_add(view.wlr_surface.events.map, map_listener)
	view.map_listener = map_listener
	table.insert(view._destroy_funcs, map_destroy)

	-- unmap listener
	local unmap_listener, unmap_destroy = ffi_help.make_listener(function()
		Surface._on_unmap(server, view)
	end)
	ffi_help.signal_add(view.wlr_surface.events.unmap, unmap_listener)
	view.unmap_listener = unmap_listener
	table.insert(view._destroy_funcs, unmap_destroy)

	-- destroy listener
	local destroy_listener, destroy_destroy = ffi_help.make_listener(function()
		Surface._on_destroy(server, view)
	end)
	ffi_help.signal_add(view.xdg_toplevel.events.destroy, destroy_listener)
	view.destroy_listener = destroy_listener
	table.insert(view._destroy_funcs, destroy_destroy)

	-- request move listener (for future floating drag)
	local request_move_listener, request_move_destroy = ffi_help.make_listener(function(data)
		log.info("request move from %s", view:get_title())
	end)
	ffi_help.signal_add(view.xdg_toplevel.events.request_move, request_move_listener)
	view.request_move_listener = request_move_listener
	table.insert(view._destroy_funcs, request_move_destroy)

	-- request resize listener
	local request_resize_listener, request_resize_destroy = ffi_help.make_listener(function(data)
		log.info("request resize from %s", view:get_title())
	end)
	ffi_help.signal_add(view.xdg_toplevel.events.request_resize, request_resize_listener)
	view.request_resize_listener = request_resize_listener
	table.insert(view._destroy_funcs, request_resize_destroy)

	-- request fullscreen listener
	local request_fullscreen_listener, request_fullscreen_destroy = ffi_help.make_listener(function()
		Surface._on_request_fullscreen(server, view)
	end)
	ffi_help.signal_add(view.xdg_toplevel.events.request_fullscreen, request_fullscreen_listener)
	view.request_fullscreen_listener = request_fullscreen_listener
	table.insert(view._destroy_funcs, request_fullscreen_destroy)

	-- ack_configure listener
	local ack_configure_listener, ack_configure_destroy = ffi_help.make_listener(function()
		if not view.initial_configure_acked then
			view.initial_configure_acked = true
		elseif not view.configured then
			view.configured = true
		end
		view:on_ack_configure()
	end)
	ffi_help.signal_add(view.xdg_surface.events.ack_configure, ack_configure_listener)
	view.ack_configure_listener = ack_configure_listener
	table.insert(view._destroy_funcs, ack_configure_destroy)

	-- new_popup listener (firefox menus, tooltips, dropdowns, etc.)
	local new_popup_listener, new_popup_destroy = ffi_help.make_listener_with_destroy(function(data)
		Surface._on_new_popup(server, view, ffi.cast("struct wlr_xdg_popup *", data))
	end)
	ffi_help.signal_add(view.xdg_surface.events.new_popup, new_popup_listener)
	view.new_popup_listener = new_popup_listener
	table.insert(view._destroy_funcs, new_popup_destroy)

	-- subsurfaces (e.g. firefox web content) - composite them with the parent
	local new_subsurface_listener, new_subsurface_destroy = ffi_help.make_listener_with_destroy(function(data)
		local sub = ffi.cast("struct wlr_subsurface *", data)
		log.debug("SUBSURFACE created for %s: surface=%p", view:get_title(), sub.surface)

		local ss = {
			subsurface = sub,
			surface = sub.surface,
			texture = nil,
			mapped = false,
			cleanup = {},
		}
		view.subsurfaces = view.subsurfaces or {}
		table.insert(view.subsurfaces, ss)

		local function on(signal, fn)
			local listener, destroy = ffi_help.make_listener_with_destroy(fn)
			ffi_help.signal_add(signal, listener)
			table.insert(ss.cleanup, destroy)
		end

		on(ss.surface.events.commit, function()
			if C.wlr_surface_has_buffer(ss.surface) then
				local tex = C.wlr_surface_get_texture(ss.surface)
				if tex ~= nil then
					if not ss.texture then
						ss.texture = Texture.from_wlr_texture(tex)
					else
						ss.texture:update_wlr_texture(tex)
					end
				end
			end
		end)

		on(ss.surface.events.map, function()
			ss.mapped = true
		end)

		on(ss.surface.events.unmap, function()
			ss.mapped = false
		end)

		on(sub.events.destroy, function()
			for i, s in ipairs(view.subsurfaces or {}) do
				if s == ss then
					table.remove(view.subsurfaces, i)
					break
				end
			end
			if ss.texture then
				ss.texture:destroy()
				ss.texture = nil
			end
			for _, fn in ipairs(ss.cleanup) do
				fn()
			end
			ss.cleanup = {}
		end)
	end)
	ffi_help.signal_add(view.wlr_surface.events.new_subsurface, new_subsurface_listener)
	table.insert(view._destroy_funcs, new_subsurface_destroy)
end

-- fill in a popup's scheduled geometry and send its configure. only legal
-- once the popup surface did its initial commit - before that wlroots'
-- unconstrain helper would assert on schedule_configure
function Surface._configure_popup(server, view, entry)
	local popup = entry.popup
	log.debug("popup %s configure: initialized=%s", tostring(popup), tostring(popup.base.initialized))
	if not popup.base.initialized then
		return
	end

	local rg = view.render_geo
	local bw = view.border_width or 0
	local surf_x = view.x + bw - (rg and rg.x or 0)
	local surf_y = view.y + bw - (rg and rg.y or 0)

	-- usable area of the output under the view
	local out = ffi.new("struct wlr_box")
	local out_wlr =
		C.wlr_output_layout_output_at(server.output_layout, view.x + view.width / 2, view.y + view.height / 2)
	if out_wlr ~= nil then
		C.wlr_output_layout_get_box(server.output_layout, out_wlr, out)
	else
		C.wlr_output_layout_get_box(server.output_layout, nil, out)
	end

	local constraint = ffi.new(
		"struct wlr_box",
		{ x = out.x - surf_x, y = out.y - surf_y, width = out.width, height = out.height }
	)
	C.wlr_xdg_popup_unconstrain_from_box(popup, constraint)
	C.wlr_xdg_surface_schedule_configure(popup.base)
end

-- track a new popup: texture lifecycle like subsurfaces plus the configure
-- handshake clients block on. nested popups recurse through base.new_popup
function Surface._on_new_popup(server, view, popup)
	log.debug("popup %s created for %s", tostring(popup), view:get_title())

	local entry = {
		popup = popup,
		view = view,
		surface = popup.base.surface,
		texture = nil,
		mapped = false,
		abs = { x = 0, y = 0, width = 0, height = 0 },
		cleanup = {},
	}
	view.popups = view.popups or {}
	table.insert(view.popups, entry)

	local function on(signal, fn)
		local listener, destroy = ffi_help.make_listener_with_destroy(fn)
		ffi_help.signal_add(signal, listener)
		table.insert(entry.cleanup, destroy)
	end

	on(entry.surface.events.commit, function()
		if C.wlr_surface_has_buffer(entry.surface) then
			local tex = C.wlr_surface_get_texture(entry.surface)
			if tex ~= nil then
				if not entry.texture then
					entry.texture = Texture.from_wlr_texture(tex)
				else
					entry.texture:update_wlr_texture(tex)
				end
			end
		end
		-- clients do an initial null commit right after creating the popup;
		-- that flips base.initialized and makes configuring legal. one shot
		-- like labwc/dwl/river - reconfiguring on later commits makes clients
		-- treat it as a reposition
		if not entry.configured_once and popup.base.initialized then
			entry.configured_once = true
			Surface._configure_popup(server, view, entry)
		end
	end)

	on(entry.surface.events.map, function()
		entry.mapped = true
		log.debug("popup %s mapped %dx%d", tostring(popup), popup.current.geometry.width, popup.current.geometry.height)
	end)

	on(entry.surface.events.unmap, function()
		entry.mapped = false
		log.debug("popup %s unmapped", tostring(popup))
		if entry.texture then
			entry.texture:destroy()
			entry.texture = nil
		end
	end)

	on(popup.events.reposition, function()
		Surface._configure_popup(server, view, entry)
	end)

	on(popup.base.events.new_popup, function(data)
		Surface._on_new_popup(server, view, ffi.cast("struct wlr_xdg_popup *", data))
	end)

	-- wlroots asserts every signal list is empty before freeing the popup
	-- struct; its own events.destroy fires right before that assert, so this
	-- is where everything must detach. the base surface can also go first
	-- depending on who initiates teardown, hence the idempotent double hook
	local function cleanup()
		if entry.dead then
			return
		end
		entry.dead = true
		log.debug("popup %s cleanup", tostring(popup))
		for i, e in ipairs(view.popups or {}) do
			if e == entry then
				table.remove(view.popups, i)
				break
			end
		end
		if entry.texture then
			entry.texture:destroy()
			entry.texture = nil
		end
		for _, fn in ipairs(entry.cleanup) do
			fn()
		end
		entry.cleanup = {}
	end
	on(popup.events.destroy, cleanup)
	on(popup.base.events.destroy, cleanup)
end

function Surface._on_commit(server, view)
	local surface = view.wlr_surface

	-- send initial configure on first commit (must run even without buffer)
	if not view.initial_configure_sent then
		view.initial_configure_sent = true
		local bw = view.border_width or 4
		local cw = math.max(1, view.width - 2 * bw)
		local ch = math.max(1, view.height - 2 * bw)
		log.debug("configure: initial %dx%d for %s", cw, ch, view:get_title())
		local serial = C.wlr_xdg_toplevel_set_size(view.xdg_toplevel, cw, ch)
		view.pending_serial = serial
		view.configure_pending = true
	elseif view.configured and not view.border_shown then
		view.border_shown = true
	end

	-- temp debug: catch bufferless commits (client frame-thirst)
	if not C.wlr_surface_has_buffer(surface) then
		log.debug("commit %s: NO BUFFER (frame callback pending?)", view:get_title())
		return
	end

	-- create or update texture from surface (wlroots caches it per commit)
	local tex = C.wlr_surface_get_texture(surface)
	if tex ~= nil then
		if not view.texture then
			view.texture = Texture.from_wlr_texture(tex)
			if view.texture then
				log.debug("created texture for %s: %dx%d", view:get_title(), view.texture.width, view.texture.height)
			end
		else
			view.texture:update_wlr_texture(tex)
		end
		-- update view size from buffer
		view.texture_width = surface.current.width
		view.texture_height = surface.current.height

		-- window geometry within the buffer (excludes csd shadow margins).
		-- the committed bitmask only marks commits that CHANGE geometry, so
		-- persistence is managed here: drop it if the surface resizes without
		-- a geometry update (stale clip otherwise)
		local geo_bit = bit.band(view.xdg_surface.current.committed, 1) ~= 0
		local g = view.xdg_surface.geometry
		local sw, sh = surface.current.width, surface.current.height
		if geo_bit then
			if g.width > 0 and g.height > 0 then
				view.render_geo = { x = g.x, y = g.y, width = g.width, height = g.height }
			else
				view.render_geo = nil
			end
		elseif view.render_geo and (view._last_sw ~= sw or view._last_sh ~= sh) then
			view.render_geo = nil
			log.debug("geometry stale after resize, ignoring: %s", view:get_title())
		end
		view._last_sw, view._last_sh = sw, sh
		local rg = view.render_geo
		log.debug("xdg commit %s: surf=%dx%d tex=%dx%d committed=%d geo=%s",
			view:get_title(), surface.current.width, surface.current.height,
			view.texture and view.texture.width or -1, view.texture and view.texture.height or -1,
			view.xdg_surface.current.committed,
			rg and string.format("%d,%d %dx%d", rg.x, rg.y, rg.width, rg.height) or "none")
	end
end

function Surface._on_map(server, view)
	view:map()
	view.visible_on_tag = true

	-- only focus if view is on the current tag
	local on_current_tag = false
	for t, _ in pairs(view.tags) do
		if t == server.current_tag then on_current_tag = true; break end
	end
	if on_current_tag then
		server:focus_view(view)
	end

	Surface._apply_layout(server)
end

function Surface._on_unmap(server, view)
	view:unmap()
	view.visible_on_tag = false

	-- client cursor surface is gone - fall back to default image
	local Input = require("compositor.input_handler")
	Input.reset_cursor(server)

	if view.focused then
		server:focus_view(nil)
		local next_view = nil
		for _, v in ipairs(server.views) do
			if v.mapped and v ~= view then
				local on_tag = false
				for t, _ in pairs(v.tags) do
					if t == server.current_tag then on_tag = true; break end
				end
				if on_tag then
					next_view = v
					break
				end
			end
		end
		if next_view then
			server:focus_view(next_view)
		end
	end

	Surface._apply_layout(server)
end

function Surface._on_destroy(server, view)
	view:cleanup_listeners()
	if view.texture then
		view.texture:destroy()
		view.texture = nil
	end
	view:destroy()
	server:remove_view(view)

	if server.dwindle then
		server.dwindle:remove_view(view)
	end

	-- focus next if this was focused
	if view.focused then
		local next_view = nil
		for _, v in ipairs(server.views) do
			if v.mapped then
				local on_tag = false
				for t, _ in pairs(v.tags) do
					if t == server.current_tag then on_tag = true; break end
				end
				if on_tag then
					next_view = v
					break
				end
			end
		end
		if next_view then
			server:focus_view(next_view)
		else
			server:focus_view(nil)
		end
	end

	Surface._apply_layout(server)
end

function Surface._on_request_fullscreen(server, view)
	log.debug("request_fullscreen from %s (currently %s)", view:get_title(), tostring(view.fullscreen))
	view.fullscreen = not view.fullscreen
	if view.fullscreen then
		local layout = server.output_layout
		local output = C.wlr_output_layout_output_at(layout, view.x + view.width / 2, view.y + view.height / 2)
		if output ~= nil then
			C.wlr_xdg_toplevel_set_fullscreen(view.xdg_toplevel, true)
			view:set_position(0, 0, output.width, output.height)
		end
	else
		C.wlr_xdg_toplevel_set_fullscreen(view.xdg_toplevel, false)
		Surface._apply_layout(server)
	end
end

local layout_in_progress = false

function Surface._apply_layout(server)
	if layout_in_progress then return end
	layout_in_progress = true

	if not server.dwindle then
		layout_in_progress = false
		return
	end

	-- update view visibility based on current tag
	for _, view in ipairs(server.views) do
		local visible = false
		for t, _ in pairs(view.tags) do
			if t == server.current_tag then visible = true; break end
		end
		view.visible_on_tag = visible and view.mapped
	end

	for i, output_data in ipairs(server.outputs) do
		local wlr_output = output_data.wlr_output
		local layout_box = ffi.new("struct wlr_box")
		C.wlr_output_layout_get_box(server.output_layout, wlr_output, layout_box)

		server.dwindle:layout(layout_box.x, layout_box.y, layout_box.width, layout_box.height, server.current_tag)
		server.dwindle:apply_pending_layout()
	end

	layout_in_progress = false
end

return Surface
