local ffi = require("ffi")
local log = require("util.log")
local C = ffi.C

local View = {}
View.__index = View

function View.new(xdg_toplevel)
    local self = setmetatable({}, View)

    self.xdg_toplevel = xdg_toplevel
    self.xdg_surface = xdg_toplevel.base
    self.wlr_surface = self.xdg_surface.surface

    self.texture = nil
    self.texture_width = 0
    self.texture_height = 0

    self.mapped = false
    self.configured = false
    self.initial_configure_acked = false
    self.border_shown = false
    self.floating = false
    self.fullscreen = false
    self.visible_on_tag = false
    self.pending_serial = 0
    self.configure_pending = false
    self.configure_queue = {}
    self.initial_configure_sent = false
    self.opacity = 1.0

    self.x = 0
    self.y = 0
    self.width = 0
    self.height = 0
    self.border_width = 4

    self.tags = { [1] = true }
    self.focused = false

    self.destroy_listener = nil
    self.map_listener = nil
    self.unmap_listener = nil
    self.request_move_listener = nil
    self.request_resize_listener = nil
    self.request_fullscreen_listener = nil
    self.set_title_listener = nil
    self.set_app_id_listener = nil

    return self
end

function View:get_title()
    if self.xdg_toplevel.title ~= nil then
        return ffi.string(self.xdg_toplevel.title)
    end
    return "unnamed"
end

function View:get_app_id()
    if self.xdg_toplevel.app_id ~= nil then
        return ffi.string(self.xdg_toplevel.app_id)
    end
    return "unknown"
end

function View:set_position(x, y, w, h)
    self.x = x
    self.y = y
    log.debug("set_position: %s -> %d,%d %dx%d", self:get_title(), x, y, w, h)
    self.width = w
    self.height = h

    if self.mapped then
        local bw = self.border_width or 4
        self:queue_configure(w - 2 * bw, h - 2 * bw)
    end
end

function View:queue_configure(w, h)
    if not self.configure_pending then
        local serial = C.wlr_xdg_toplevel_set_size(self.xdg_toplevel, w, h)
        self.pending_serial = serial
        self.configure_pending = true
        log.debug("configure: sent %dx%d serial=%u for %s", w, h, serial, self:get_title())
    else
        self.configure_queue = { { w = w, h = h } }
        log.debug("configure: queued %dx%d for %s (queue=%d)", w, h, self:get_title(), #self.configure_queue)
    end
end

function View:on_ack_configure()
    log.debug("ack_configure: received for %s, queue=%d", self:get_title(), self.configure_queue and #self.configure_queue or 0)
    self.configure_pending = false
    if self.configure_queue and #self.configure_queue > 0 then
        local next = table.remove(self.configure_queue, 1)
        local serial = C.wlr_xdg_toplevel_set_size(self.xdg_toplevel, next.w, next.h)
        self.pending_serial = serial
        self.configure_pending = true
        log.debug("ack_configure: sent queued %dx%d serial=%u for %s", next.w, next.h, serial, self:get_title())
    end
end

function View:configure()
    if self.floating then
        local bw = self.border_width or 4
        C.wlr_xdg_toplevel_set_size(self.xdg_toplevel, self.width - 2 * bw, self.height - 2 * bw)
    end
end

function View:map()
    self.mapped = true
    self.visible_on_tag = true
    log.info("view mapped: %s (%s)", self:get_title(), self:get_app_id())
end

function View:unmap()
    self.mapped = false
    self.visible_on_tag = false
    log.info("view unmapped: %s", self:get_title())
end

function View:destroy()
    log.info("view destroyed: %s", self:get_title())
    self.mapped = false
    self.visible_on_tag = false
    if self.texture then
        self.texture:destroy()
        self.texture = nil
    end
    self.wlr_surface = nil
end

function View:cleanup_listeners()
	if self._destroy_funcs then
		for _, destroy in ipairs(self._destroy_funcs) do
			destroy()
		end
		self._destroy_funcs = nil
	end
	self.commit_listener = nil
	self.map_listener = nil
	self.unmap_listener = nil
	self.destroy_listener = nil
	self.request_move_listener = nil
	self.request_resize_listener = nil
	self.request_fullscreen_listener = nil
	self.ack_configure_listener = nil
	self.new_popup_listener = nil
end

function View:focus()
    if not self.mapped then return end

    self.focused = true
    log.debug("focus: %s", self:get_title())
    C.wlr_xdg_toplevel_set_activated(self.xdg_toplevel, true)

    local focused_surface = self.xdg_surface.surface
    local seat = self._server.seat

    -- keyboard focus
    local keyboard = C.wlr_seat_get_keyboard(seat)
    if keyboard ~= nil then
        log.debug("focus: keyboard enter for %s", self:get_title())
        C.wlr_seat_keyboard_notify_enter(seat, focused_surface,
            keyboard.keycodes, keyboard.num_keycodes, keyboard.modifiers)
    else
        log.debug("focus: no keyboard for %s", self:get_title())
    end

    -- pointer focus is deliberately left alone here: motion handling owns it,
    -- and re-entering the toplevel mid-interaction would close popups
end

function View:unfocus()
    self.focused = false
    if self.mapped then
        C.wlr_xdg_toplevel_set_activated(self.xdg_toplevel, false)
    end
end

function View:update_border()
    -- border is drawn by renderer, no scene node to update
end

function View:close()
    C.wlr_xdg_toplevel_send_close(self.xdg_toplevel)
end

return View
