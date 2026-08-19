local ffi = require("ffi")
local log = require("util.log")
local C = ffi.C

local View = {}
View.__index = View

function View.new(xdg_toplevel, scene_tree)
    local self = setmetatable({}, View)

    self.xdg_toplevel = xdg_toplevel
    self.xdg_surface = xdg_toplevel.base
    self.wlr_surface = self.xdg_surface.surface
    self.scene_tree = scene_tree

    self.mapped = false
    self.floating = false
    self.fullscreen = false
    self.pending_serial = 0

    self.x = 0
    self.y = 0
    self.width = 0
    self.height = 0

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
    self.width = w
    self.height = h
    local node_ptr = self.scene_tree.node
    C.wlr_scene_node_set_position(node_ptr, x, y)
    if self.mapped then
        local serial = C.wlr_xdg_toplevel_set_size(self.xdg_toplevel, w, h)
        self.pending_serial = serial
    end
end

function View:configure()
    if self.floating then
        C.wlr_xdg_toplevel_set_size(self.xdg_toplevel, self.width, self.height)
    end
end

function View:map()
    self.mapped = true
    log.info("view mapped: %s (%s)", self:get_title(), self:get_app_id())
end

function View:unmap()
    self.mapped = false
    log.info("view unmapped: %s", self:get_title())
end

function View:destroy()
    log.info("view destroyed: %s", self:get_title())
    self.mapped = false
    if self.scene_tree then
        C.wlr_scene_node_destroy(self.scene_tree.node)
        self.scene_tree = nil
    end
end

function View:focus()
    if not self.mapped then return end

    self.focused = true
    C.wlr_xdg_toplevel_set_activated(self.xdg_toplevel, true)

    local focused_surface = self.xdg_surface.surface
    local seat = self._server.seat

    -- Keyboard focus
    local keyboard = C.wlr_seat_get_keyboard(seat)
    if keyboard ~= nil then
        C.wlr_seat_keyboard_notify_enter(seat, focused_surface,
            keyboard.keycodes, keyboard.num_keycodes, keyboard.modifiers)
    end

    -- Pointer focus
    local node = self.scene_tree.node
    local success = ffi.new("int[1]")
    local lx = ffi.new("int[1]")
    local ly = ffi.new("int[1]")
    if C.wlr_scene_node_coords(node, lx, ly) then
        C.wlr_seat_pointer_notify_enter(seat, focused_surface,
            lx[0] - self.x, ly[0] - self.y)
    end
end

function View:unfocus()
    self.focused = false
    if self.mapped then
        C.wlr_xdg_toplevel_set_activated(self.xdg_toplevel, false)
    end
end

function View:close()
    C.wlr_xdg_toplevel_send_close(self.xdg_toplevel)
end

return View
