local ffi = require("ffi")
local log = require("util.log")
local C = ffi.C

local Texture = require("compositor.renderer.texture")
local Shader = require("compositor.renderer.shader")

local Renderer = {}
Renderer.__index = Renderer

-- gl consts
local GL_TEXTURE_2D = 0x0DE1
local GL_TRIANGLE_STRIP = 0x0005
local GL_BLEND = 0x0BE2
local GL_ONE = 0x0001
local GL_ONE_MINUS_SRC_ALPHA = 0x0303
local GL_FLOAT = 0x1406

function Renderer.new(renderer_ptr)
	local self = setmetatable({
		renderer = renderer_ptr,
		_initialized = false,
		_gl_ready = false,
	}, Renderer)
	return self
end

-- lazily compile the rounded corner programs; needs a current gl context so
-- this runs inside a render pass
function Renderer:_ensure_gl()
	if self._gl_ready then
		return
	end
	self._gl_tex_prog = Shader.new_rounded_texture_program()
	self._gl_solid_prog = Shader.new_rounded_solid_program()
	self._attribs = ffi.new("struct wlr_gles2_texture_attribs")
	self._verts = ffi.new("float[16]")
	self._gl_ready = true
	log.info("rounded corner shaders compiled")
end

-- upload positions for tl/tr/bl/br strip verts and set up the sdf geometry;
-- only position slots are written here, uv slots belong to textured callers
function Renderer:_begin_rounded(prog, quad, sdf_box, output_width, output_height, radii)
	self:_ensure_gl()

	local x, y, w, h = quad.x, quad.y, quad.width, quad.height
	-- ndc from px (y-down): x = 2*px/out_w - 1, y = 1 - 2*px/out_h
	local ndc_x1 = (2 * x / output_width) - 1
	local ndc_y1 = 1 - (2 * y / output_height)
	local ndc_x2 = (2 * (x + w) / output_width) - 1
	local ndc_y2 = 1 - (2 * (y + h) / output_height)
	local verts = self._verts
	verts[0], verts[1] = ndc_x1, ndc_y1
	verts[4], verts[5] = ndc_x2, ndc_y1
	verts[8], verts[9] = ndc_x1, ndc_y2
	verts[12], verts[13] = ndc_x2, ndc_y2

	prog:use()
	prog:set_res(output_width, output_height)
	prog:set_center(sdf_box.x + sdf_box.width * 0.5, sdf_box.y + sdf_box.height * 0.5)
	prog:set_half_size(sdf_box.width * 0.5, sdf_box.height * 0.5)
	prog:set_radii(radii)

	C.glEnable(GL_BLEND)
	-- premultiplied alpha, same convention wlroots' own pass draws with
	C.glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
end

function Renderer:_submit_rounded(prog)
	-- client-side arrays like wlroots' own gles2 pass (no vbo); interleaved
	-- pos.xy + uv.xy per vertex
	local verts = self._verts
	C.glEnableVertexAttribArray(prog.pos_attr)
	C.glVertexAttribPointer(prog.pos_attr, 2, GL_FLOAT, false, 16, verts)
	if prog.tex_attr >= 0 then
		C.glEnableVertexAttribArray(prog.tex_attr)
		C.glVertexAttribPointer(prog.tex_attr, 2, GL_FLOAT, false, 16, ffi.cast("float *", verts) + 2)
	end

	C.glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)

	C.glDisableVertexAttribArray(prog.pos_attr)
	if prog.tex_attr >= 0 then
		C.glDisableVertexAttribArray(prog.tex_attr)
	end
	C.glUseProgram(0)
	C.glDisable(GL_BLEND)
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

-- rounded solid rect; paints only the outer border_width band when
-- border_width > 0 (border ring), otherwise fills the whole box
function Renderer:draw_solid_rounded(pass, box, output_width, output_height, radius, color, border_width)
	self:_ensure_gl()
	local prog = self._gl_solid_prog
	local r = math.max(0, math.min(radius or 0, box.width * 0.5, box.height * 0.5))
	self:_begin_rounded(prog, box, box, output_width, output_height, { r, r, r, r })
	prog:set_color(color[1], color[2], color[3], color[4])
	prog:set_border_width(border_width or 0)
	prog:set_opacity(1.0)
	self:_submit_rounded(prog)
end

-- rounded textured rect. quad is what gets drawn, sdf_box is what gets
-- rounded, src maps 1:1 onto quad; radii = { tl, tr, bl, br } in px
function Renderer:draw_texture_rounded(pass, texture, quad, sdf_box, output_width, output_height, opacity, src, radii)
	self:_ensure_gl()

	-- external oes planes (dmabuf) can't bind to our sampler, fall back to
	-- the plain unclipped path rather than drawing nothing
	C.wlr_gles2_texture_get_attribs(texture.texture, self._attribs)
	if self._attribs.target ~= GL_TEXTURE_2D then
		return self:draw_texture(pass, texture, quad, output_width, output_height, opacity, src)
	end

	local tw, th = texture.width, texture.height
	local sx, sy, sw, sh = 0, 0, tw, th
	if src then
		sx, sy, sw, sh = src.x, src.y, src.width, src.height
	end

	local prog = self._gl_tex_prog
	self:_begin_rounded(prog, quad, sdf_box, output_width, output_height, radii)

	-- uv per corner (interleaved after pos.xy): tl, tr, bl, br. wlroots keeps
	-- client textures flipped vs our y-down quads, so quad top samples v1
	local u0, u1 = sx / tw, (sx + sw) / tw
	local v0, v1 = sy / th, (sy + sh) / th
	local verts = self._verts
	verts[2], verts[3] = u0, v1
	verts[6], verts[7] = u1, v1
	verts[10], verts[11] = u0, v0
	verts[14], verts[15] = u1, v0

	C.glActiveTexture(0x84C0) -- gl_texture0
	C.glBindTexture(GL_TEXTURE_2D, self._attribs.tex)
	-- client textures default to a mipmap min filter (incomplete -> black);
	-- wlroots sets these per draw, so must we
	C.glTexParameteri(GL_TEXTURE_2D, 0x2800, 0x2601) -- min filter = linear
	C.glTexParameteri(GL_TEXTURE_2D, 0x2801, 0x2601) -- mag filter = linear

	prog:set_texture(0)
	prog:set_opacity(opacity or 1.0)
	prog:set_has_alpha(self._attribs.has_alpha ~= 0)
	self:_submit_rounded(prog)
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
