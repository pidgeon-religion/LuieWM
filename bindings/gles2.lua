local ffi = require("ffi")

ffi.cdef[[
// gles2 subset used by the rounded corner shaders (libGLESv2)
typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef int GLint;
typedef int GLsizei;
typedef float GLfloat;

GLuint glCreateShader(GLenum type);
void glShaderSource(GLuint shader, GLsizei count, const char **string, const GLint *length);
void glCompileShader(GLuint shader);
void glGetShaderiv(GLuint shader, GLenum pname, GLint *params);
void glGetShaderInfoLog(GLuint shader, GLsizei bufSize, GLsizei *length, char *infoLog);
void glDeleteShader(GLuint shader);

GLuint glCreateProgram(void);
void glAttachShader(GLuint program, GLuint shader);
void glLinkProgram(GLuint program);
void glGetProgramiv(GLuint program, GLenum pname, GLint *params);
void glGetProgramInfoLog(GLuint program, GLsizei bufSize, GLsizei *length, char *infoLog);

GLint glGetUniformLocation(GLuint program, const char *name);
GLint glGetAttribLocation(GLuint program, const char *name);
void glUseProgram(GLuint program);

void glUniform1i(GLint location, GLint v0);
void glUniform1f(GLint location, GLfloat v0);
void glUniform2f(GLint location, GLfloat v0, GLfloat v1);
void glUniform4f(GLint location, GLfloat v0, GLfloat v1, GLfloat v2, GLfloat v3);

void glEnableVertexAttribArray(GLuint index);
void glDisableVertexAttribArray(GLuint index);
void glVertexAttribPointer(GLuint index, GLint size, GLenum type, bool normalized, GLsizei stride, const void *pointer);

void glEnable(GLenum cap);
void glDisable(GLenum cap);
void glBlendFuncSeparate(GLenum sfactorRGB, GLenum dfactorRGB, GLenum sfactorAlpha, GLenum dfactorAlpha);
void glActiveTexture(GLenum texture);
void glBindTexture(GLenum target, GLuint texture);
void glTexParameteri(GLenum target, GLenum pname, GLint param);
void glDrawArrays(GLenum mode, GLint first, GLsizei count);
GLenum glGetError(void);
]]

return {}
