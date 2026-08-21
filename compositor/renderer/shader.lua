local ffi = require("ffi")
local log = require("util.log")
local C = ffi.C

local Shader = {}
Shader.__index = Shader

local GL_VERTEX_SHADER = 0x8B31
local GL_FRAGMENT_SHADER = 0x8B3F
local GL_COMPILE_STATUS = 0x8B81
local GL_LINK_STATUS = 0x8B82
local GL_INFO_LOG_LENGTH = 0x8B84

local texture_vert = [[
#version 100
precision mediump float;
attribute vec2 position;
attribute vec2 texcoord;
uniform mat3 mvp;
varying vec2 v_texcoord;
void main() {
    vec3 pos = mvp * vec3(position, 1.0);
    gl_Position = vec4(pos.xy, 0.0, pos.z);
    v_texcoord = texcoord;
}
]]

local texture_frag = [[
#version 100
precision mediump float;
varying vec2 v_texcoord;
uniform sampler2D tex;
uniform float opacity;
void main() {
    gl_FragColor = texture2D(tex, v_texcoord) * opacity;
}
]]

local solid_vert = [[
#version 100
precision mediump float;
attribute vec2 position;
uniform mat3 mvp;
void main() {
    vec3 pos = mvp * vec3(position, 1.0);
    gl_Position = vec4(pos.xy, 0.0, pos.z);
}
]]

local solid_frag = [[
#version 100
precision mediump float;
uniform vec4 color;
void main() {
    gl_FragColor = color;
}
]]

local function compile_shader(type, source)
    log.debug("Compiling shader type %d, source length %d", type, #source)
    log.debug("Shader source: %s", source)
    local shader = C.glCreateShader(type)
    local src = ffi.new("char[?]", #source + 1)
    ffi.copy(src, source)
    local src_ptr = ffi.new("const char*[1]", src)
    C.glShaderSource(shader, 1, src_ptr, nil)
    C.glCompileShader(shader)

    -- check for GL errors
    local err = C.glGetError()
    if err and err ~= 0 then
        log.debug("GL error after glCompileShader: 0x%x", err)
    end

    local status = ffi.new("int[1]")
    C.glGetShaderiv(shader, GL_COMPILE_STATUS, status)
    log.debug("Shader compile status: %d", status[0] or -1)
    if status[0] == 0 then
        local len = ffi.new("int[1]")
        C.glGetShaderiv(shader, GL_INFO_LOG_LENGTH, len)
        log.debug("Shader info log length: %d", len[0])
        local log_buf = ffi.new("char[?]", len[0] + 1)
        C.glGetShaderInfoLog(shader, len[0], nil, log_buf)
        local err_str = ffi.string(log_buf)
        log.debug("Shader error log: [%s]", err_str)
        C.glDeleteShader(shader)
        error("Shader compile failed: [" .. err_str .. "]")
    end
    return shader
end

local function link_program(vert, frag)
    local prog = C.glCreateProgram()
    C.glAttachShader(prog, vert)
    C.glAttachShader(prog, frag)
    C.glLinkProgram(prog)

    local status = ffi.new("int[1]")
    C.glGetProgramiv(prog, GL_LINK_STATUS, status)
    if status[0] == 0 then
        local len = ffi.new("int[1]")
        C.glGetProgramiv(prog, GL_INFO_LOG_LENGTH, len)
        local log_buf = ffi.new("char[?]", len[0])
        C.glGetProgramInfoLog(prog, len[0], nil, log_buf)
        error("Program link failed: " .. ffi.string(log_buf))
    end

    C.glDeleteShader(vert)
    C.glDeleteShader(frag)
    return prog
end

function Shader.new_texture_program()
    local vert = compile_shader(GL_VERTEX_SHADER, texture_vert)
    local frag = compile_shader(GL_FRAGMENT_SHADER, texture_frag)
    local prog = link_program(vert, frag)

    local self = setmetatable({
        program = prog,
        mvp_loc = C.glGetUniformLocation(prog, "mvp"),
        tex_loc = C.glGetUniformLocation(prog, "tex"),
        opacity_loc = C.glGetUniformLocation(prog, "opacity"),
        pos_attr = C.glGetAttribLocation(prog, "position"),
        tex_attr = C.glGetAttribLocation(prog, "texcoord"),
    }, Shader)

    return self
end

function Shader.new_solid_program()
    local vert = compile_shader(GL_VERTEX_SHADER, solid_vert)
    local frag = compile_shader(GL_FRAGMENT_SHADER, solid_frag)
    local prog = link_program(vert, frag)

    local self = setmetatable({
        program = prog,
        mvp_loc = C.glGetUniformLocation(prog, "mvp"),
        color_loc = C.glGetUniformLocation(prog, "color"),
        pos_attr = C.glGetAttribLocation(prog, "position"),
    }, Shader)

    return self
end

function Shader:use()
    C.glUseProgram(self.program)
end

function Shader:set_mvp(mvp)
    C.glUniformMatrix3fv(self.mvp_loc, 1, 0, mvp)
end

function Shader:set_texture(unit)
    C.glUniform1i(self.tex_loc, unit)
end

function Shader:set_opacity(opacity)
    if self.opacity_loc then
        C.glUniform1f(self.opacity_loc, opacity)
    end
end

function Shader:set_color(r, g, b, a)
    C.glUniform4f(self.color_loc, r, g, b, a)
end

function Shader:enable_position_attr()
    C.glEnableVertexAttribArray(self.pos_attr)
    C.glVertexAttribPointer(self.pos_attr, 2, 0x1406, 0, 0, nil)
end

function Shader:enable_texcoord_attr()
    if self.tex_attr then
        C.glEnableVertexAttribArray(self.tex_attr)
        C.glVertexAttribPointer(self.tex_attr, 2, 0x1406, 0, 0, nil)
    end
end

function Shader:disable_attrs()
    C.glDisableVertexAttribArray(self.pos_attr)
    if self.tex_attr then
        C.glDisableVertexAttribArray(self.tex_attr)
    end
end

return Shader