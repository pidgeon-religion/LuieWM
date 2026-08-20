local ffi = require("ffi")
local log = require("util.log")
local ffi_help = require("util.ffi_helpers")
local C = ffi.C
local View = require("wm.view")

local Surface = {}

local xdg_new_surface_listener = nil
local xdg_new_toplevel_listener = nil

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

	-- create parent tree for border + window content
	local parent_tree = C.wlr_scene_tree_create(server.content_tree or server.scene.tree)

	-- create border rect, starts fully transparent (alpha=0)
	local border_width = server.config and server.config.border_width or 2
	local transparent = ffi.new("float[4]", 0, 0, 0, 0)
	local border_rect = C.wlr_scene_rect_create(parent_tree, 0, 0, transparent)

	-- create scene tree for xdg surface (positioned at offset within parent)
	local xdg_scene_tree = C.wlr_scene_xdg_surface_create(parent_tree, xdg_surface)
	if xdg_scene_tree == nil then
		log.error("failed to create scene xdg surface")
		return
	end

	-- create view and add to server
	local view = View.new(xdg_toplevel, parent_tree)
	view._server = server
	view.tags = { [server.current_tag] = true }
	view.border_rect = border_rect
	view.xdg_scene_tree = xdg_scene_tree
	server:add_view(view)

	-- add to dwindle layout
	if server.dwindle then
		server.dwindle:add_view(view, server.current_tag)
	end

	-- setup listeners for this view
	Surface._setup_view_listeners(server, view)

	-- apply layout (this sends the initial configure via set_position)
	Surface._apply_layout(server)

	log.info("new toplevel: %s", view:get_title())
end

function Surface._setup_view_listeners(server, view)
	-- commit listener - send initial configure on first commit (surface is initialized by then)
	local commit_listener, commit_destroy = ffi_help.make_listener(function()
		if not view.initial_configure_sent then
			view.initial_configure_sent = true
			local bw = server.config and server.config.border_width or 2
			local cw = math.max(1, view.width - 2 * bw)
			local ch = math.max(1, view.height - 2 * bw)
			log.debug("configure: initial %dx%d for %s", cw, ch, view:get_title())
			local serial = C.wlr_xdg_toplevel_set_size(view.xdg_toplevel, cw, ch)
			view.pending_serial = serial
			view.configure_pending = true
		elseif view.configured and not view.border_shown then
			view.border_shown = true
			view:update_border()
		end
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
			if view.mapped and not view.fullscreen then
				view:update_border()
			end
		end
		view:on_ack_configure()
	end)
	ffi_help.signal_add(view.xdg_surface.events.ack_configure, ack_configure_listener)
	view.ack_configure_listener = ack_configure_listener
	table.insert(view._destroy_funcs, ack_configure_destroy)

	-- new_popup listener (firefox menus, tooltips, dropdowns, etc.)
	local new_popup_listener, new_popup_destroy = ffi_help.make_listener(function(data)
		local popup = ffi.cast("struct wlr_xdg_popup *", data)
		if view.scene_tree ~= nil then
			C.wlr_scene_xdg_surface_create(view.scene_tree, popup.base)
			log.debug("popup created for %s", view:get_title())
		end
	end)
	ffi_help.signal_add(view.xdg_surface.events.new_popup, new_popup_listener)
	view.new_popup_listener = new_popup_listener
	table.insert(view._destroy_funcs, new_popup_destroy)
end

function Surface._on_map(server, view)
	view:map()

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
	view.fullscreen = not view.fullscreen
	if view.fullscreen then
		-- get the output layout box for fullscreen
		local layout = server.output_layout
		local output = C.wlr_output_layout_output_at(layout, view.x + view.width / 2, view.y + view.height / 2)
		if output ~= nil then
			C.wlr_xdg_toplevel_set_fullscreen(view.xdg_toplevel, true)
			if view.border_rect then
				C.wlr_scene_rect_set_color(view.border_rect, ffi.new("float[4]", 0, 0, 0, 0))
			end
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

	-- update scene node visibility based on current tag
	for _, view in ipairs(server.views) do
		if view.scene_tree then
			local visible = false
			for t, _ in pairs(view.tags) do
				if t == server.current_tag then visible = true; break end
			end
			if visible then
				C.wlr_scene_node_set_enabled(view.scene_tree.node, true)
			else
				C.wlr_scene_node_set_enabled(view.scene_tree.node, false)
			end
		end
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
