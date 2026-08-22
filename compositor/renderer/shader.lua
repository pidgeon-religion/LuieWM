local ffi = require("ffi")
local log = require("util.log")
-- registers the gl symbol declarations this module compiles against
require("bindings.gles2")
local C = ffi.C

local Shader = {}
Shader.__index = Shader

local GL_VERTEX_SHADER = 0x8B31
local GL_FRAGMENT_SHADER = 0x8B30
local GL_COMPILE_STATUS = 0x8B81
local GL_LINK_STATUS = 0x8B82
local GL_INFO_LOG_LENGTH = 0x8B84

-- shared vertex stage; v_local = output px relative to box centre
local rounded_vert = [[
#version 100
precision highp float;
attribute vec2 position;
attribute vec2 texcoord;
uniform vec2 res;
uniform vec2 center;
varying vec2 v_texcoord;
varying vec2 v_local;
void main() {
    gl_Position = vec4(position, 0.0, 1.0);
    vec2 px = vec2((position.x + 1.0) * 0.5 * res.x, (1.0 - position.y) * 0.5 * res.y);
    v_local = px - center;
    v_texcoord = texcoord;
}
]]

-- textured rounded rect; per-corner radii for clipped subsurfaces.
-- output is premultiplied to match our blend func
local rounded_texture_frag = [[
#version 100
precision highp float;
varying vec2 v_texcoord;
varying vec2 v_local;
uniform sampler2D tex;
uniform float opacity;
uniform vec2 half_size;
uniform vec4 radii;
uniform bool has_alpha;
void main() {
    float r = v_local.x < 0.0
        ? (v_local.y < 0.0 ? radii.x : radii.z)
        : (v_local.y < 0.0 ? radii.y : radii.w);
    vec2 q = abs(v_local) - (half_size - vec2(r));
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    float mask = 1.0 - smoothstep(-0.5, 0.5, d);
    if (mask <= 0.004) discard;
    vec4 c = texture2D(tex, v_texcoord);
    float a = (has_alpha ? c.a : 1.0) * opacity * mask;
    gl_FragColor = vec4(c.rgb * a, a);
}
]]

-- fill at border_width 0, else only the outer band paints (border ring)
local rounded_solid_frag = [[
#version 100
precision highp float;
varying vec2 v_local;
uniform vec4 color;
uniform vec2 half_size;
uniform vec4 radii;
uniform float border_width;
uniform float opacity;
void main() {
    float r = v_local.x < 0.0
        ? (v_local.y < 0.0 ? radii.x : radii.z)
        : (v_local.y < 0.0 ? radii.y : radii.w);
    vec2 q = abs(v_local) - (half_size - vec2(r));
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    float outer_mask = 1.0 - smoothstep(-0.5, 0.5, d);
    if (outer_mask <= 0.004) discard;
    float band = border_width > 0.0
        ? smoothstep(-border_width - 0.5, -border_width + 0.5, d)
        : 1.0;
    float a = color.a * outer_mask * band * opacity;
    gl_FragColor = vec4(color.rgb * a, a);
}
]]

local function compile_shader(shader_type, source)
	local shader = C.glCreateShader(shader_type)
	local src = ffi.new("char[?]", #source + 1)
	ffi.copy(src, source)
	local src_ptr = ffi.new("const char*[1]", src)
	C.glShaderSource(shader, 1, src_ptr, nil)
	C.glCompileShader(shader)

	local status = ffi.new("int[1]")
	C.glGetShaderiv(shader, GL_COMPILE_STATUS, status)
	if status[0] == 0 then
		local len = ffi.new("int[1]")
		C.glGetShaderiv(shader, GL_INFO_LOG_LENGTH, len)
		local log_buf = ffi.new("char[?]", len[0] + 1)
		C.glGetShaderInfoLog(shader, len[0], nil, log_buf)
		C.glDeleteShader(shader)
		error(string.format("shader compile failed: %s", ffi.string(log_buf)))
	end
	return shader
end

local function link_program(vert_src, frag_src)
	local vert = compile_shader(GL_VERTEX_SHADER, vert_src)
	local frag = compile_shader(GL_FRAGMENT_SHADER, frag_src)
	local prog = C.glCreateProgram()
	C.glAttachShader(prog, vert)
	C.glAttachShader(prog, frag)
	C.glLinkProgram(prog)
	C.glDeleteShader(vert)
	C.glDeleteShader(frag)

	local status = ffi.new("int[1]")
	C.glGetProgramiv(prog, GL_LINK_STATUS, status)
	if status[0] == 0 then
		local len = ffi.new("int[1]")
		C.glGetProgramiv(prog, GL_INFO_LOG_LENGTH, len)
		local log_buf = ffi.new("char[?]", len[0] + 1)
		C.glGetProgramInfoLog(prog, len[0], nil, log_buf)
		error(string.format("program link failed: %s", ffi.string(log_buf)))
	end
	return prog
end

-- both rounded programs share the vertex layout and sdf uniforms
local function new_rounded_program(frag_src)
	local prog = link_program(rounded_vert, frag_src)
	return setmetatable({
		program = prog,
		res_loc = C.glGetUniformLocation(prog, "res"),
		center_loc = C.glGetUniformLocation(prog, "center"),
		half_size_loc = C.glGetUniformLocation(prog, "half_size"),
		radii_loc = C.glGetUniformLocation(prog, "radii"),
		tex_loc = C.glGetUniformLocation(prog, "tex"),
		opacity_loc = C.glGetUniformLocation(prog, "opacity"),
		has_alpha_loc = C.glGetUniformLocation(prog, "has_alpha"),
		color_loc = C.glGetUniformLocation(prog, "color"),
		border_width_loc = C.glGetUniformLocation(prog, "border_width"),
		pos_attr = C.glGetAttribLocation(prog, "position"),
		tex_attr = C.glGetAttribLocation(prog, "texcoord"),
	}, Shader)
end

function Shader.new_rounded_texture_program()
	return new_rounded_program(rounded_texture_frag)
end

function Shader.new_rounded_solid_program()
	return new_rounded_program(rounded_solid_frag)
end

function Shader:use()
	C.glUseProgram(self.program)
end

function Shader:set_res(w, h)
	C.glUniform2f(self.res_loc, w, h)
end

function Shader:set_center(x, y)
	C.glUniform2f(self.center_loc, x, y)
end

function Shader:set_half_size(w, h)
	C.glUniform2f(self.half_size_loc, w, h)
end

-- radii table { tl, tr, bl, br } in output px
function Shader:set_radii(radii)
	C.glUniform4f(self.radii_loc, radii[1], radii[2], radii[3], radii[4])
end

function Shader:set_texture(unit)
	C.glUniform1i(self.tex_loc, unit)
end

function Shader:set_opacity(opacity)
	if self.opacity_loc >= 0 then
		C.glUniform1f(self.opacity_loc, opacity)
	end
end

function Shader:set_has_alpha(has_alpha)
	if self.has_alpha_loc >= 0 then
		C.glUniform1i(self.has_alpha_loc, has_alpha and 1 or 0)
	end
end

function Shader:set_color(r, g, b, a)
	if self.color_loc >= 0 then
		C.glUniform4f(self.color_loc, r, g, b, a)
	end
end

function Shader:set_border_width(border_width)
	if self.border_width_loc >= 0 then
		C.glUniform1f(self.border_width_loc, border_width)
	end
end

return Shader
