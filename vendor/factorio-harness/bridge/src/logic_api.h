/* Interface between the preloaded loader (hooks, socket) and the hot-swappable
 * logic library. Plain C: the two libraries each link their own C++ runtime,
 * so nothing but POD and C strings crosses this boundary. */
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FH_LOGIC_API_VERSION 1

typedef struct FhRequest {
  uint64_t connection;
  const char* json; /* one request line: {"id","action","args"} */
  size_t length;
} FhRequest;

typedef struct FhHost {
  int api_version;
  /* Queue one reply line (without the newline) for a connection. Any thread. */
  void (*reply)(uint64_t connection, const char* json, size_t length);
  /* The engine's own PlayerInputSource::process, for GUI input the logic passes on. */
  int (*original_process)(void* input_source, void* action);
  uint64_t generation; /* how many times logic has been (re)loaded */
} FhHost;

typedef struct FhLogic {
  void* state;
  /* Game thread, inside PlayerInputSource::flushActions before the engine's. */
  void (*on_flush)(void* state, void* input_source, uint64_t tick, const FhRequest* requests, size_t count);
  /* Game thread, for every staged action: -1 to pass it on, 0/1 to swallow it
   * with that result. Never unwinds. */
  int (*arbitrate)(void* state, void* input_source, void* action);
  /* Server thread: answer without the game thread, or return NULL to queue.
   * The returned string is released with free_string. */
  char* (*immediate)(void* state, const char* json, size_t length);
  void (*free_string)(char* text);
  /* Game thread, before unloading: release held inputs (stop walking, mining). */
  void (*release)(void* state, void* input_source, uint64_t tick);
  void (*destroy)(void* state);
} FhLogic;

/* Exported by the logic library. Returns 0 and fills *logic on success, or a
 * negative value with a message in error. */
typedef int (*FhLogicCreate)(const FhHost* host, FhLogic* logic, char* error, size_t error_size);
#define FH_LOGIC_CREATE_SYMBOL "fh_logic_create"

#ifdef __cplusplus
}
#endif
