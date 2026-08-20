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

	-- create scene tree for this surface
	local scene_tree = C.wlr_scene_xdg_surface_create(server.content_tree or server.scene.tree, xdg_surface)
	if scene_tree == nil then
		log.error("failed to create scene xdg surface")
		return
	end

	-- create view and add to server
	local view = View.new(xdg_toplevel, scene_tree)
	view._server = server
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
	local commit_listener = ffi_help.make_listener(function()
		if not view.initial_configure_sent then
			view.initial_configure_sent = true
			log.debug("configure: initial %dx%d for %s", view.width, view.height, view:get_title())
			local serial = C.wlr_xdg_toplevel_set_size(view.xdg_toplevel, view.width, view.height)
			view.pending_serial = serial
			view.configure_pending = true
		end
	end)
	ffi_help.signal_add(view.wlr_surface.events.commit, commit_listener)
	view.commit_listener = commit_listener

	-- map listener
	local map_listener = ffi_help.make_listener(function()
		Surface._on_map(server, view)
	end)
	ffi_help.signal_add(view.wlr_surface.events.map, map_listener)
	view.map_listener = map_listener

	-- unmap listener
	local unmap_listener = ffi_help.make_listener(function()
		Surface._on_unmap(server, view)
	end)
	ffi_help.signal_add(view.wlr_surface.events.unmap, unmap_listener)
	view.unmap_listener = unmap_listener

	-- destroy listener
	local destroy_listener = ffi_help.make_listener(function()
		Surface._on_destroy(server, view)
	end)
	ffi_help.signal_add(view.xdg_toplevel.events.destroy, destroy_listener)
	view.destroy_listener = destroy_listener

	-- request move listener (for future floating drag)
	local request_move_listener = ffi_help.make_listener(function(data)
		log.info("request move from %s", view:get_title())
	end)
	ffi_help.signal_add(view.xdg_toplevel.events.request_move, request_move_listener)
	view.request_move_listener = request_move_listener

	-- request resize listener
	local request_resize_listener = ffi_help.make_listener(function(data)
		log.info("request resize from %s", view:get_title())
	end)
	ffi_help.signal_add(view.xdg_toplevel.events.request_resize, request_resize_listener)
	view.request_resize_listener = request_resize_listener

	-- request fullscreen listener
	local request_fullscreen_listener = ffi_help.make_listener(function()
		Surface._on_request_fullscreen(server, view)
	end)
	ffi_help.signal_add(view.xdg_toplevel.events.request_fullscreen, request_fullscreen_listener)
	view.request_fullscreen_listener = request_fullscreen_listener

	-- ack_configure listener
	local ack_configure_listener = ffi_help.make_listener(function()
		view:on_ack_configure()
	end)
	ffi_help.signal_add(view.xdg_surface.events.ack_configure, ack_configure_listener)
	view.ack_configure_listener = ack_configure_listener

	-- new_popup listener (firefox menus, tooltips, dropdowns, etc.)
	local new_popup_listener = ffi_help.make_listener(function(data)
		local popup = ffi.cast("struct wlr_xdg_popup *", data)
		if view.scene_tree ~= nil then
			C.wlr_scene_xdg_surface_create(view.scene_tree, popup.base)
			log.debug("popup created for %s", view:get_title())
		end
	end)
	ffi_help.signal_add(view.xdg_surface.events.new_popup, new_popup_listener)
	view.new_popup_listener = new_popup_listener
end

function Surface._on_map(server, view)
	view:map()

	-- focus the newly mapped view
	server:focus_view(view)

	-- re-apply layout to position everything
	Surface._apply_layout(server)
end

function Surface._on_unmap(server, view)
	view:unmap()

	if view.focused then
		server:focus_view(nil)
	-- focus next view
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
				next_view = v
				break
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
