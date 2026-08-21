local ffi = require("ffi")
local C = ffi.C

local Texture = {}
Texture.__index = Texture

function Texture.from_buffer(renderer, buffer)
	local tex = C.wlr_texture_from_buffer(renderer, buffer)
	if tex == nil then
		return nil, "failed to create texture from buffer"
	end

	local self = setmetatable({
		texture = tex,
		width = tex.width,
		height = tex.height,
		renderer = renderer,
		_owned = true,
		_destroyed = false,
	}, Texture)

	return self
end

-- wrap a wlroots-owned texture (e.g. from wlr_surface_get_texture)
-- wlroots manages its lifetime - never destroy it ourselves
function Texture.from_wlr_texture(tex)
	if tex == nil then
		return nil, "no texture"
	end

	local self = setmetatable({
		texture = tex,
		width = tex.width,
		height = tex.height,
		renderer = nil,
		_owned = false,
		_destroyed = false,
	}, Texture)

	return self
end

-- refresh wrapper to a new wlr texture pointer (surface committed new buffer)
function Texture:update_wlr_texture(tex)
	if self._destroyed or self._owned or tex == nil then
		return false
	end
	self.texture = tex
	self.width = tex.width
	self.height = tex.height
	return true
end

function Texture:update_from_buffer(buffer)
	if self._destroyed then
		return
	end
	local new_tex = C.wlr_texture_from_buffer(self.renderer, buffer)
	if new_tex == nil then
		return false
	end
	C.wlr_texture_destroy(self.texture)
	self.texture = new_tex
	self.width = new_tex.width
	self.height = new_tex.height
	return true
end

function Texture:get_attribs()
	if self._destroyed then
		return nil
	end
	local attribs = ffi.new("struct wlr_gles2_texture_attribs")
	if C.wlr_gles2_renderer_check_ext(self.renderer, "GL_EXT_texture_format_BGRA8888") then
	end
	return attribs
end

function Texture:bind(unit)
	unit = unit or 0
	C.glActiveTexture(0x84C0 + unit)
	local attribs = ffi.new("struct wlr_gles2_texture_attribs")
	-- we can't easily get the GL texture ID from wlr_texture in wlroots 0.20
	-- wlr_render_texture_with_matrix handles binding internally
	return true
end

function Texture:destroy()
	if self._destroyed then
		return
	end
	if self.texture and self._owned then
		C.wlr_texture_destroy(self.texture)
	end
	self.texture = nil
	self._destroyed = true
end

return Texture
