local ffi = require("ffi")
local log = require("util.log")
local ffi_help = require("util.ffi_helpers")
local C = ffi.C

local Input = {}

local mod_logo_pressed = false
local mod_ctrl_pressed = false
local mod_shift_pressed = false

-- x11 keysym consts (from keysymdef.h)
local XKB_KEY_Super_L = 0xffeb
local XKB_KEY_Super_R = 0xffec
local XKB_KEY_Control_L = 0xffe3
local XKB_KEY_Control_R = 0xffe4
local XKB_KEY_Shift_L = 0xffe1
local XKB_KEY_Shift_R = 0xffe2

local function get_time_msec()
	local ts = ffi.new("struct timespec[1]")
	C.clock_gettime(0, ts)
	return tonumber(ts[0].tv_sec) * 1000 + math.floor(tonumber(ts[0].tv_nsec) / 1000000)
end

-- hit-test views: check if cursor is within view geometry (including border)
local function get_view_at(server, lx, ly)
	-- check views in reverse order (top-most first); view box includes borders
	for i = #server.views, 1, -1 do
		local view = server.views[i]
		if view.mapped and view.visible_on_tag then
			if lx >= view.x and lx < view.x + view.width and ly >= view.y and ly < view.y + view.height then
				local bw = view.border_width or 0
				-- pointer events are surface-local: origin is the buffer
				-- origin, not the window geometry. clients route events into
				-- their own subsurfaces, so we always target the toplevel
				local rg = view.render_geo
				local psx = lx - view.x - bw + (rg and rg.x or 0)
				local psy = ly - view.y - bw + (rg and rg.y or 0)
				return view.wlr_surface, psx, psy, view
			end
		end
	end

	-- check layer surfaces against their arranged rect
	if server.layer_surfaces then
		for _, entry in ipairs(server.layer_surfaces) do
			local ls = entry.layer_surface
			if ls and ls.surface and entry.mapped and entry.texture then
				if lx >= entry.x and lx < entry.x + entry.width and ly >= entry.y and ly < entry.y + entry.height then
					return ls.surface, lx - entry.x, ly - entry.y, nil
				end
			end
		end
	end

	return nil, 0, 0, nil
end

function Input.setup(server)
	Input._setup_cursor(server)
end

function Input._setup_cursor(server)
	local motion_listener = ffi_help.make_listener(function(data)
		local event = ffi.cast("struct wlr_cursor_motion_event *", data)
		Input._on_cursor_motion(server, event)
	end)
	ffi_help.signal_add(server.cursor.events.motion, motion_listener)

	local motion_abs_listener = ffi_help.make_listener(function(data)
		local event = ffi.cast("struct wlr_cursor_motion_absolute_event *", data)
		Input._on_cursor_motion_absolute(server, event)
	end)
	ffi_help.signal_add(server.cursor.events.motion_absolute, motion_abs_listener)

	local button_listener = ffi_help.make_listener(function(data)
		Input._on_cursor_button(server, ffi.cast("struct wlr_pointer_button_event *", data))
	end)
	ffi_help.signal_add(server.cursor.events.button, button_listener)

	local axis_listener = ffi_help.make_listener(function(data)
		Input._on_cursor_axis(server, ffi.cast("struct wlr_pointer_axis_event *", data))
	end)
	ffi_help.signal_add(server.cursor.events.axis, axis_listener)

	local frame_listener = ffi_help.make_listener(function()
		C.wlr_seat_pointer_notify_frame(server.seat)
	end)
	ffi_help.signal_add(server.cursor.events.frame, frame_listener)
end

function Input.handle_new_input(server, device)
	if device.type == C.WLR_INPUT_DEVICE_KEYBOARD then
		Input._setup_keyboard(server, device)
	elseif device.type == C.WLR_INPUT_DEVICE_POINTER then
		Input._setup_pointer(server, device)
	end

	C.wlr_seat_set_capabilities(server.seat, bit.bor(C.WL_SEAT_CAPABILITY_POINTER, C.WL_SEAT_CAPABILITY_KEYBOARD))
end

function Input._setup_keyboard(server, device)
	local keyboard = C.wlr_keyboard_from_input_device(device)

	local xkb_context = C.xkb_context_new(C.XKB_CONTEXT_NO_FLAGS)
	if xkb_context == nil then
		log.error("failed to create xkb context")
		return
	end

	local rule_names = ffi.new("struct xkb_rule_names")
	rule_names.rules = "evdev"
	rule_names.model = "pc105"
	rule_names.layout = "us"
	rule_names.variant = ""
	rule_names.options = ""

	local keymap = C.xkb_keymap_new_from_names(xkb_context, rule_names, C.XKB_KEYMAP_COMPILE_NO_FLAGS)
	if keymap == nil then
		log.error("failed to create xkb keymap")
		C.xkb_context_unref(xkb_context)
		return
	end

	if not C.wlr_keyboard_set_keymap(keyboard, keymap) then
		log.error("failed to set keyboard keymap")
		C.xkb_keymap_unref(keymap)
		C.xkb_context_unref(xkb_context)
		return
	end

	C.xkb_keymap_unref(keymap)
	C.xkb_context_unref(xkb_context)

	keyboard.repeat_info.rate = 25
	keyboard.repeat_info.delay = 600

	table.insert(server.keyboards, keyboard)
	C.wlr_seat_set_keyboard(server.seat, keyboard)

	local key_listener = ffi_help.make_listener(function(data)
		Input._on_keyboard_key(server, keyboard, ffi.cast("struct wlr_keyboard_key_event *", data))
	end)
	ffi_help.signal_add(keyboard.events.key, key_listener)

	local modifiers_listener = ffi_help.make_listener(function()
		Input._on_keyboard_modifiers(server, keyboard)
	end)
	ffi_help.signal_add(keyboard.events.modifiers, modifiers_listener)

	log.info("keyboard added: %s", ffi.string(device.name))
end

function Input._setup_pointer(server, device)
	C.wlr_cursor_attach_input_device(server.cursor, device)
	log.info("pointer added: %s", ffi.string(device.name))
end

function Input._on_keyboard_key(server, keyboard, event)
	local sym = 0
	local xkb_state = keyboard.xkb_state

	if xkb_state ~= nil then
		sym = C.xkb_state_key_get_one_sym(xkb_state, event.keycode + 8)
	end

	local pressed = (event.state == C.WL_KEYBOARD_KEY_STATE_PRESSED)
	log.debug("key: sym=%d pressed=%s mod_logo=%s", sym, pressed, mod_logo_pressed)

	if sym == XKB_KEY_Super_L or sym == XKB_KEY_Super_R then
		mod_logo_pressed = pressed
	end
	if sym == XKB_KEY_Control_L or sym == XKB_KEY_Control_R then
		mod_ctrl_pressed = pressed
	end
	if sym == XKB_KEY_Shift_L or sym == XKB_KEY_Shift_R then
		mod_shift_pressed = pressed
	end

	if pressed and mod_logo_pressed then
		local keybinds = require("wm.keybinds")
		keybinds.set_shift(mod_shift_pressed)
		if keybinds.handle(server, sym) then
			return
		end
	end

	C.wlr_seat_keyboard_notify_key(server.seat, event.time_msec, event.keycode, event.state)
end

function Input._on_keyboard_modifiers(server, keyboard)
	local modifiers = keyboard.modifiers
	C.wlr_seat_keyboard_notify_modifiers(server.seat, modifiers)
end

function Input._schedule_output_frames(server)
	for _, output_data in ipairs(server.outputs) do
		C.wlr_output_schedule_frame(output_data.wlr_output)
	end
end

-- fall back to default xcursor image (after client cursor surface dies)
function Input.reset_cursor(server)
	C.wlr_cursor_set_xcursor(server.cursor, server.cursor_mgr, "left_ptr")
end

-- only send enter when focus target changes; re-entering every motion
-- makes clients reset their hover state continuously
local function notify_pointer(server, msec, surface, sx, sy)
	local focused = server.seat.pointer_state.focused_surface
	if focused ~= surface then
		C.wlr_seat_pointer_notify_enter(server.seat, surface, sx, sy)
	end
	C.wlr_seat_pointer_notify_motion(server.seat, msec, sx, sy)
end

function Input._on_cursor_motion(server, event)
	C.wlr_cursor_move(server.cursor, ffi.cast("struct wlr_input_device *", event.pointer), event.delta_x, event.delta_y)

	local msec = get_time_msec()
	local surface, sx, sy, view = get_view_at(server, server.cursor.x, server.cursor.y)

	if surface ~= nil then
		log.debug(
			"pointer motion: surface=%p at %.0f,%.0f (cursor at %.0f,%.0f)",
			surface,
			sx,
			sy,
			server.cursor.x,
			server.cursor.y
		)
		notify_pointer(server, msec, surface, sx, sy)
	else
		C.wlr_seat_pointer_notify_clear_focus(server.seat)
		Input.reset_cursor(server)
	end
end

function Input._on_cursor_motion_absolute(server, event)
	C.wlr_cursor_warp_absolute(server.cursor, ffi.cast("struct wlr_input_device *", event.pointer), event.x, event.y)

	local msec = get_time_msec()
	local surface, sx, sy, view = get_view_at(server, server.cursor.x, server.cursor.y)

	if surface ~= nil then
		log.debug("pointer absolute: surface=%p at %.0f,%.0f", surface, sx, sy)
		notify_pointer(server, msec, surface, sx, sy)
	else
		C.wlr_seat_pointer_notify_clear_focus(server.seat)
		Input.reset_cursor(server)
	end
end

function Input._on_cursor_button(server, event)
	local msec = get_time_msec()
	C.wlr_seat_pointer_notify_button(server.seat, msec, event.button, event.state)

	if event.state == C.WL_POINTER_BUTTON_STATE_PRESSED then
		local surface, sx, sy, view = get_view_at(server, server.cursor.x, server.cursor.y)
		if surface ~= nil and view then
			server:focus_view(view)
		end
	end
end

function Input._on_cursor_axis(server, event)
	local msec = get_time_msec()
	C.wlr_seat_pointer_notify_axis(
		server.seat,
		msec,
		event.orientation,
		event.delta,
		event.delta_discrete,
		event.source,
		0
	)
end

return Input
