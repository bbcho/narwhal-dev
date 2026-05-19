#ifndef WINMGR_LUA_SHIM_H
#define WINMGR_LUA_SHIM_H

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

static inline lua_State *winmgr_lua_newstate(void) {
    return luaL_newstate();
}

static inline void winmgr_lua_openlibs(lua_State *state) {
    luaL_openlibs(state);
}

static inline void winmgr_lua_close(lua_State *state) {
    lua_close(state);
}

static inline int winmgr_lua_loadfile(lua_State *state, const char *path) {
    return luaL_loadfile(state, path);
}

static inline int winmgr_lua_pcall(lua_State *state, int args, int results, int errfunc) {
    return lua_pcall(state, args, results, errfunc);
}

static inline int winmgr_lua_type(lua_State *state, int index) {
    return lua_type(state, index);
}

static inline int winmgr_lua_absindex(lua_State *state, int index) {
    return lua_absindex(state, index);
}

static inline int winmgr_lua_gettop(lua_State *state) {
    return lua_gettop(state);
}

static inline void winmgr_lua_settop(lua_State *state, int index) {
    lua_settop(state, index);
}

static inline void winmgr_lua_pop(lua_State *state, int count) {
    lua_pop(state, count);
}

static inline void winmgr_lua_pushnil(lua_State *state) {
    lua_pushnil(state);
}

static inline int winmgr_lua_next(lua_State *state, int index) {
    return lua_next(state, index);
}

static inline lua_Unsigned winmgr_lua_rawlen(lua_State *state, int index) {
    return lua_rawlen(state, index);
}

static inline const void *winmgr_lua_topointer(lua_State *state, int index) {
    return lua_topointer(state, index);
}

static inline int winmgr_lua_geti(lua_State *state, int index, lua_Integer key) {
    return lua_geti(state, index, key);
}

static inline int winmgr_lua_toboolean(lua_State *state, int index) {
    return lua_toboolean(state, index);
}

static inline lua_Number winmgr_lua_tonumber(lua_State *state, int index, int *isnum) {
    return lua_tonumberx(state, index, isnum);
}

static inline lua_Integer winmgr_lua_tointeger(lua_State *state, int index, int *isnum) {
    return lua_tointegerx(state, index, isnum);
}

static inline int winmgr_lua_isinteger(lua_State *state, int index) {
    return lua_isinteger(state, index);
}

static inline const char *winmgr_lua_tolstring(lua_State *state, int index, size_t *length) {
    return lua_tolstring(state, index, length);
}

static inline int winmgr_lua_type_nil(void) {
    return LUA_TNIL;
}

static inline int winmgr_lua_type_boolean(void) {
    return LUA_TBOOLEAN;
}

static inline int winmgr_lua_type_number(void) {
    return LUA_TNUMBER;
}

static inline int winmgr_lua_type_string(void) {
    return LUA_TSTRING;
}

static inline int winmgr_lua_type_table(void) {
    return LUA_TTABLE;
}

#endif
