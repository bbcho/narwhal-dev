#ifndef NARWHAL_LUA_SHIM_H
#define NARWHAL_LUA_SHIM_H

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct {
    size_t used_bytes;
    size_t maximum_bytes;
    uint64_t remaining_instructions;
    int hook_interval;
    int memory_limit_exceeded;
    int instruction_limit_exceeded;
} narwhal_lua_limits;

typedef struct {
    size_t size;
} narwhal_lua_allocation;

static inline void *narwhal_lua_allocate(void *user_data, void *pointer, size_t old_size, size_t new_size) {
    (void)old_size;
    narwhal_lua_limits *limits = (narwhal_lua_limits *)user_data;

    if (new_size == 0) {
        if (pointer != NULL) {
            narwhal_lua_allocation *allocation = ((narwhal_lua_allocation *)pointer) - 1;
            limits->used_bytes -= allocation->size;
            free(allocation);
        }
        return NULL;
    }

    size_t prior_size = 0;
    narwhal_lua_allocation *prior_allocation = NULL;
    if (pointer != NULL) {
        prior_allocation = ((narwhal_lua_allocation *)pointer) - 1;
        prior_size = prior_allocation->size;
    }

    const size_t retained_bytes = limits->used_bytes - prior_size;
    if (new_size > limits->maximum_bytes - retained_bytes ||
        new_size > SIZE_MAX - sizeof(narwhal_lua_allocation)) {
        limits->memory_limit_exceeded = 1;
        return NULL;
    }

    narwhal_lua_allocation *allocation = (narwhal_lua_allocation *)realloc(
        prior_allocation,
        sizeof(narwhal_lua_allocation) + new_size
    );
    if (allocation == NULL) {
        return NULL;
    }
    allocation->size = new_size;
    limits->used_bytes = retained_bytes + new_size;
    return allocation + 1;
}

static inline lua_State *narwhal_lua_newstate(size_t maximum_bytes) {
    narwhal_lua_limits *limits = (narwhal_lua_limits *)calloc(1, sizeof(narwhal_lua_limits));
    if (limits == NULL) {
        return NULL;
    }
    limits->maximum_bytes = maximum_bytes;
    lua_State *state = lua_newstate(narwhal_lua_allocate, limits, arc4random());
    if (state == NULL) {
        free(limits);
    }
    return state;
}

static inline int narwhal_lua_open_config_libraries_function(lua_State *state) {
    const luaL_Reg libraries[] = {
        {LUA_GNAME, luaopen_base},
        {LUA_TABLIBNAME, luaopen_table},
        {LUA_STRLIBNAME, luaopen_string},
        {LUA_MATHLIBNAME, luaopen_math},
        {LUA_UTF8LIBNAME, luaopen_utf8},
        {NULL, NULL}
    };
    const luaL_Reg *library = libraries;
    for (; library->func != NULL; library++) {
        luaL_requiref(state, library->name, library->func, 1);
        lua_pop(state, 1);
    }

    lua_pushnil(state);
    lua_setglobal(state, "dofile");
    lua_pushnil(state);
    lua_setglobal(state, "loadfile");
    return 0;
}

static inline int narwhal_lua_open_config_libraries(lua_State *state) {
    lua_pushcfunction(state, narwhal_lua_open_config_libraries_function);
    return lua_pcall(state, 0, 0, 0);
}

static inline void narwhal_lua_instruction_hook(lua_State *state, lua_Debug *debug) {
    (void)debug;
    void *user_data = NULL;
    lua_getallocf(state, &user_data);
    narwhal_lua_limits *limits = (narwhal_lua_limits *)user_data;
    if (limits->remaining_instructions <= (uint64_t)limits->hook_interval) {
        limits->instruction_limit_exceeded = 1;
        luaL_error(state, "configuration instruction limit exceeded");
        return;
    }
    limits->remaining_instructions -= (uint64_t)limits->hook_interval;
}

static inline void narwhal_lua_set_instruction_limit(lua_State *state, uint64_t maximum_instructions) {
    void *user_data = NULL;
    lua_getallocf(state, &user_data);
    narwhal_lua_limits *limits = (narwhal_lua_limits *)user_data;
    limits->remaining_instructions = maximum_instructions;
    limits->hook_interval = maximum_instructions < 1000 ? (int)maximum_instructions : 1000;
    lua_sethook(state, narwhal_lua_instruction_hook, LUA_MASKCOUNT, limits->hook_interval);
}

static inline int narwhal_lua_memory_limit_exceeded(lua_State *state) {
    void *user_data = NULL;
    lua_getallocf(state, &user_data);
    return ((narwhal_lua_limits *)user_data)->memory_limit_exceeded;
}

static inline int narwhal_lua_instruction_limit_exceeded(lua_State *state) {
    void *user_data = NULL;
    lua_getallocf(state, &user_data);
    return ((narwhal_lua_limits *)user_data)->instruction_limit_exceeded;
}

static inline void narwhal_lua_close(lua_State *state) {
    void *user_data = NULL;
    lua_getallocf(state, &user_data);
    lua_close(state);
    free(user_data);
}

static inline int narwhal_lua_loadfile(lua_State *state, const char *path) {
    return luaL_loadfile(state, path);
}

static inline int narwhal_lua_pcall(lua_State *state, int args, int results, int errfunc) {
    return lua_pcall(state, args, results, errfunc);
}

static inline int narwhal_lua_type(lua_State *state, int index) {
    return lua_type(state, index);
}

static inline int narwhal_lua_absindex(lua_State *state, int index) {
    return lua_absindex(state, index);
}

static inline int narwhal_lua_gettop(lua_State *state) {
    return lua_gettop(state);
}

static inline void narwhal_lua_settop(lua_State *state, int index) {
    lua_settop(state, index);
}

static inline void narwhal_lua_pop(lua_State *state, int count) {
    lua_pop(state, count);
}

static inline void narwhal_lua_pushnil(lua_State *state) {
    lua_pushnil(state);
}

static inline int narwhal_lua_next(lua_State *state, int index) {
    return lua_next(state, index);
}

static inline lua_Unsigned narwhal_lua_rawlen(lua_State *state, int index) {
    return lua_rawlen(state, index);
}

static inline const void *narwhal_lua_topointer(lua_State *state, int index) {
    return lua_topointer(state, index);
}

static inline int narwhal_lua_geti(lua_State *state, int index, lua_Integer key) {
    return lua_geti(state, index, key);
}

static inline int narwhal_lua_toboolean(lua_State *state, int index) {
    return lua_toboolean(state, index);
}

static inline lua_Number narwhal_lua_tonumber(lua_State *state, int index, int *isnum) {
    return lua_tonumberx(state, index, isnum);
}

static inline lua_Integer narwhal_lua_tointeger(lua_State *state, int index, int *isnum) {
    return lua_tointegerx(state, index, isnum);
}

static inline int narwhal_lua_isinteger(lua_State *state, int index) {
    return lua_isinteger(state, index);
}

static inline const char *narwhal_lua_tolstring(lua_State *state, int index, size_t *length) {
    return lua_tolstring(state, index, length);
}

static inline int narwhal_lua_type_nil(void) {
    return LUA_TNIL;
}

static inline int narwhal_lua_type_boolean(void) {
    return LUA_TBOOLEAN;
}

static inline int narwhal_lua_type_number(void) {
    return LUA_TNUMBER;
}

static inline int narwhal_lua_type_string(void) {
    return LUA_TSTRING;
}

static inline int narwhal_lua_type_table(void) {
    return LUA_TTABLE;
}

#endif
