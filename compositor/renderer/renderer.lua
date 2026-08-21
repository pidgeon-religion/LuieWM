local ffi = require("ffi")
local log = require("util.log")
local C = ffi.C

local Texture = require("compositor.renderer.texture")

local Renderer = {}
Renderer.__index = Renderer

function Renderer.new(renderer_ptr)
	local self = setmetatable({
		renderer = renderer_ptr,
		_initialized = false,
	}, Renderer)
	return self
end

function Renderer:init()
	if self._initialized then
		return true
	end
	self._initialized = true
	log.info("Custom renderer initialized (wlroots render pass API)")
	return true
end

function Renderer:begin_output(output)
	-- fresh state per frame; commit happens in submit()
	local state = ffi.new("struct wlr_output_state")
	C.wlr_output_state_init(state)

	local pass = C.wlr_output_begin_render_pass(output, state, nil)
	if pass == nil then
		log.error("failed to begin render pass for output")
		C.wlr_output_state_finish(state)
		return nil
	end
	self._current_output = output
	self._current_state = state -- keep reference until submit
	return pass
end

function Renderer:clear(pass, color)
	color = color or { 0.1, 0.1, 0.12, 1.0 }
	local opts = ffi.new("struct wlr_render_rect_options")
	opts.box = ffi.new("struct wlr_box", { x = 0, y = 0, width = 32767, height = 32767 })
	opts.color.r = color[1]
	opts.color.g = color[2]
	opts.color.b = color[3]
	opts.color.a = color[4]
	C.wlr_render_pass_add_rect(pass, opts)
end

function Renderer:draw_texture(pass, texture, box, output_width, output_height, opacity, src, clip_box)
	opacity = opacity or 1.0

	local opts = ffi.new("struct wlr_render_texture_options")
	opts.texture = texture.texture
	if src then
		-- sub-rect of buffer (window geometry, excludes csd margins)
		opts.src_box = ffi.new("struct wlr_fbox", { x = src.x, y = src.y, width = src.width, height = src.height })
	else
		opts.src_box = ffi.new("struct wlr_fbox", { x = 0, y = 0, width = texture.width, height = texture.height })
	end
	opts.dst_box = ffi.new("struct wlr_box", box)
	opts.alpha = ffi.new("float[1]", opacity)
	opts.transform = 0 -- normal
	opts.filter_mode = C.WLR_SCALE_FILTER_BILINEAR

	local region
	if clip_box then
		region = ffi.new("pixman_region32_t")
		C.pixman_region32_init_rect(region, clip_box.x, clip_box.y, clip_box.width, clip_box.height)
		opts.clip = region
	end

	C.wlr_render_pass_add_texture(pass, opts)

	if region then
		C.pixman_region32_fini(region)
	end
end

function Renderer:draw_solid(pass, box, output_width, output_height, color)
	color = color or { 0, 0, 0, 1 }

	local opts = ffi.new("struct wlr_render_rect_options")
	opts.box = ffi.new("struct wlr_box", box)
	opts.color.r = color[1]
	opts.color.g = color[2]
	opts.color.b = color[3]
	opts.color.a = color[4]
	C.wlr_render_pass_add_rect(pass, opts)
end

function Renderer:draw_border(pass, view_box, border_width, output_width, output_height, color)
	local bw = border_width
	if bw <= 0 then
		return
	end

	local x, y, w, h = view_box.x, view_box.y, view_box.width, view_box.height

	self:draw_solid(pass, { x = x, y = y, width = w, height = bw }, output_width, output_height, color)
	self:draw_solid(pass, { x = x, y = y + h - bw, width = w, height = bw }, output_width, output_height, color)
	self:draw_solid(pass, { x = x, y = y + bw, width = bw, height = h - 2 * bw }, output_width, output_height, color)
	self:draw_solid(
		pass,
		{ x = x + w - bw, y = y + bw, width = bw, height = h - 2 * bw },
		output_width,
		output_height,
		color
	)
end

function Renderer:submit(pass)
	local ok = C.wlr_render_pass_submit(pass)
	if self._current_state then
		-- present the frame: submit renders, commit puts it on screen
		if self._current_output then
			if not C.wlr_output_commit_state(self._current_output, self._current_state) then
				log.warn("output commit failed")
				ok = false
			end
		end
		C.wlr_output_state_finish(self._current_state)
		self._current_output = nil
		self._current_state = nil
	end
	return ok
end

function Renderer:commit_output(output, state)
	return C.wlr_output_commit_state(output, state)
end

function Renderer:destroy()
	-- nothing to destroy for render pass API
end

return Renderer
