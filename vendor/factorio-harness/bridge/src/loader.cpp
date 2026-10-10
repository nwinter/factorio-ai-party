// Preloaded into a Factorio client with LD_PRELOAD; inert unless
// FH_BRIDGE_SOCKET is set. Owns what must live as long as the process: the
// two PlayerInputSource vtable hooks and the request socket. Everything else
// lives in libfh-logic.so, which `bridge_reload` swaps between ticks, so the
// bridge can be updated without leaving the game.
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/sendfile.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <shared_mutex>
#include <string>

#include "builds.hpp"
#include "game.hpp"
#include "image.hpp"
#include "json.hpp"
#include "logic_api.h"
#include "server.hpp"

namespace fh {
namespace {

using Flush = void (*)(void* self, bool flag, uint64_t tick);
using Process = bool (*)(void* self, void* action);

constexpr std::string_view kPlayerInputSourceVtable = "_ZTV17PlayerInputSource";

Json error_reply(const Json& id, const char* code, const std::string& message) {
  return Json(Json::Object{{"id", id}, {"ok", false}, {"error", Json(Json::Object{{"code", code}, {"message", message}})}});
}

class Loader {
 public:
  void activate(const std::string& socket);
  void shutdown() { server_.stop(); }
  void on_flush(void* self, bool flag, uint64_t tick);
  bool on_process(void* self, void* action);

  Flush original_flush_ = nullptr;
  Process original_process_ = nullptr;
  Server server_;

 private:
  std::optional<Json> immediate(const Request& request);
  bool load_logic(std::string* error);
  void unload_logic();
  void reload(void* self, uint64_t tick);

  std::string logic_path_;
  std::string inactive_reason_;  // immutable once the server thread runs
  bool hooked_ = false;

  // Logic calls hold the shared lock; swapping the library holds it exclusively.
  std::shared_mutex logic_mutex_;
  void* handle_ = nullptr;
  std::string loaded_copy_;
  FhLogic logic_{};
  FhHost host_{};
  std::atomic<uint64_t> generation_{0};

  std::mutex reload_mutex_;
  std::vector<std::pair<uint64_t, Json>> reload_waiters_;  // connection, request id
  std::atomic<bool> reload_requested_{false};
  std::string last_reload_error_;  // guarded by reload_mutex_
};

Loader* g_loader = nullptr;

void flush_hook(void* self, bool flag, uint64_t tick) {
  g_loader->on_flush(self, flag, tick);
  g_loader->original_flush_(self, flag, tick);
}

bool process_hook(void* self, void* action) { return g_loader->on_process(self, action); }

void host_reply(uint64_t connection, const char* json, size_t length) {
  try {
    g_loader->server_.reply_raw(connection, std::string(json, length));
  } catch (...) {
  }
}

int host_original_process(void* self, void* action) { return g_loader->original_process_(self, action) ? 1 : 0; }

std::string directory_of_this_library() {
  Dl_info info{};
  if (!dladdr(reinterpret_cast<void*>(&directory_of_this_library), &info) || !info.dli_fname) return ".";
  std::string path = info.dli_fname;
  auto slash = path.rfind('/');
  return slash == std::string::npos ? "." : path.substr(0, slash);
}

// dlopen caches by path, and a library rebuilt in place must not be mapped
// while it is being written: load a private copy of every version.
bool copy_file(const std::string& from, const std::string& to, std::string* error) {
  int in = ::open(from.c_str(), O_RDONLY | O_CLOEXEC);
  if (in < 0) { *error = "cannot open " + from; return false; }
  struct stat info {};
  ::fstat(in, &info);
  int out = ::open(to.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0700);
  if (out < 0) { ::close(in); *error = "cannot create " + to; return false; }
  off_t offset = 0;
  bool ok = true;
  while (offset < info.st_size) {
    ssize_t sent = ::sendfile(out, in, &offset, static_cast<size_t>(info.st_size - offset));
    if (sent <= 0) { ok = false; break; }
  }
  ::close(in);
  ::close(out);
  if (!ok) *error = "copy of " + from + " failed";
  return ok;
}

void Loader::activate(const std::string& socket) {
  logic_path_ = std::getenv("FH_BRIDGE_LOGIC") ? std::getenv("FH_BRIDGE_LOGIC") : directory_of_this_library() + "/libfh-logic.so";
  Image image = Image::inspect_self({kPlayerInputSourceVtable});
  if (!image.ok()) inactive_reason_ = image.error();
  else if (!supported_build(image.build_id())) inactive_reason_ = "unsupported Factorio build " + image.build_id();

  if (inactive_reason_.empty()) {
    void** vtable = image.pointer<void*>(kPlayerInputSourceVtable) + 2;
    void* previous = nullptr;
    if (!patch_pointer(&vtable[game::layout::kVtableFlushActions], reinterpret_cast<void*>(&flush_hook), &previous)) {
      inactive_reason_ = "could not install input hook";
    } else {
      original_flush_ = reinterpret_cast<Flush>(previous);
      if (!patch_pointer(&vtable[game::layout::kVtableProcess], reinterpret_cast<void*>(&process_hook), &previous)) {
        patch_pointer(&vtable[game::layout::kVtableFlushActions], reinterpret_cast<void*>(original_flush_), nullptr);
        inactive_reason_ = "could not install arbitration hook";
      } else {
        original_process_ = reinterpret_cast<Process>(previous);
        hooked_ = true;
      }
    }
  }
  if (hooked_) {
    std::string error;
    std::unique_lock lock(logic_mutex_);
    if (!load_logic(&error)) std::fprintf(stderr, "[fh-bridge] logic not loaded: %s\n", error.c_str());
  }

  std::string error;
  if (!server_.start(socket, [this](const Request& r) { return immediate(r); }, std::chrono::milliseconds(5000), &error)) {
    std::fprintf(stderr, "[fh-bridge] cannot listen on %s: %s\n", socket.c_str(), error.c_str());
    return;
  }
  if (!inactive_reason_.empty()) std::fprintf(stderr, "[fh-bridge] inactive: %s\n", inactive_reason_.c_str());
  else std::fprintf(stderr, "[fh-bridge] loader active on %s\n", socket.c_str());
}

// Caller holds logic_mutex_ exclusively.
bool Loader::load_logic(std::string* error) {
  std::string copy = "/tmp/fh-logic-" + std::to_string(::getpid()) + "-" + std::to_string(generation_.load() + 1) + ".so";
  if (!copy_file(logic_path_, copy, error)) return false;
  void* handle = ::dlopen(copy.c_str(), RTLD_NOW | RTLD_LOCAL);
  ::unlink(copy.c_str());  // the mapping stays valid; nothing is left behind
  if (!handle) { *error = ::dlerror(); return false; }
  auto create = reinterpret_cast<FhLogicCreate>(::dlsym(handle, FH_LOGIC_CREATE_SYMBOL));
  if (!create) { *error = "no " FH_LOGIC_CREATE_SYMBOL " in logic library"; ::dlclose(handle); return false; }
  FhHost host{FH_LOGIC_API_VERSION, &host_reply, &host_original_process, generation_.load() + 1};
  FhLogic logic{};
  char message[512] = {};
  if (create(&host, &logic, message, sizeof message) != 0) {
    *error = message;
    ::dlclose(handle);
    return false;
  }
  unload_logic();
  host_ = host;
  logic_ = logic;
  handle_ = handle;
  generation_.fetch_add(1);
  return true;
}

// Caller holds logic_mutex_ exclusively.
void Loader::unload_logic() {
  if (!handle_) return;
  logic_.destroy(logic_.state);
  ::dlclose(handle_);
  handle_ = nullptr;
  logic_ = {};
}

void Loader::reload(void* self, uint64_t tick) {
  std::string error;
  {
    std::unique_lock lock(logic_mutex_);
    // Never leave a key "held" by code that is about to disappear.
    if (handle_) logic_.release(logic_.state, self, tick);
    if (!load_logic(&error)) {
      // The previous logic stays loaded; its controls were released.
    }
  }
  std::vector<std::pair<uint64_t, Json>> waiters;
  {
    std::lock_guard lock(reload_mutex_);
    waiters.swap(reload_waiters_);
    last_reload_error_ = error;
  }
  for (auto& [connection, id] : waiters) {
    if (error.empty()) {
      server_.reply(connection, Json(Json::Object{{"id", id}, {"ok", true}, {"tick", tick},
                                                  {"result", Json(Json::Object{{"generation", generation_.load()}})}}));
    } else {
      server_.reply(connection, error_reply(id, "reload_failed", error + " (previous logic kept)"));
    }
  }
}

void Loader::on_flush(void* self, bool, uint64_t tick) {
  try {
    if (reload_requested_.exchange(false)) reload(self, tick);
    std::shared_lock lock(logic_mutex_);
    if (!handle_) {
      for (Request& request : server_.take()) {
        server_.reply(request.connection, error_reply(request.id, "logic_unavailable", "the logic library is not loaded"));
      }
      return;
    }
    // The logic decides which input source is the local player's and takes
    // requests only there; others (main menu simulation) get none.
    std::vector<Request> requests = server_.take();
    std::vector<FhRequest> view;
    view.reserve(requests.size());
    for (const Request& request : requests) view.push_back({request.connection, request.line.data(), request.line.size()});
    logic_.on_flush(logic_.state, self, tick, view.data(), view.size());
  } catch (...) {
    std::fprintf(stderr, "[fh-bridge] unexpected exception in the flush hook\n");
  }
}

bool Loader::on_process(void* self, void* action) {
  try {
    std::shared_lock lock(logic_mutex_);
    if (handle_) {
      int result = logic_.arbitrate(logic_.state, self, action);
      if (result >= 0) return result != 0;
    }
  } catch (...) {
  }
  return original_process_(self, action);
}

std::optional<Json> Loader::immediate(const Request& request) {
  if (!hooked_) return error_reply(request.id, "bridge_inactive", inactive_reason_);
  if (request.action == "bridge_reload") {
    // Swap at the next flush, on the game thread, between ticks.
    std::lock_guard lock(reload_mutex_);
    reload_waiters_.emplace_back(request.connection, request.id);
    reload_requested_ = true;
    return Json();  // taken: reload() replies from the game thread
  }
  std::shared_lock lock(logic_mutex_);
  if (!handle_) {
    if (request.action == "bridge_status") {
      std::lock_guard reload_lock(reload_mutex_);
      return Json(Json::Object{{"id", request.id}, {"ok", true},
                               {"result", Json(Json::Object{{"active", false}, {"logic_loaded", false},
                                                            {"inactive_reason", "logic library not loaded: " + last_reload_error_}})}});
    }
    return error_reply(request.id, "logic_unavailable", "the logic library is not loaded");
  }
  char* answer = logic_.immediate(logic_.state, request.line.data(), request.line.size());
  if (!answer) return std::nullopt;
  std::string text(answer);
  logic_.free_string(answer);
  return Json::parse(text);
}

// LD_PRELOAD also reaches launcher shells; only the game itself may claim the
// socket, or the environment would no longer carry it to the game.
bool is_factorio_process() {
  char path[4096];
  ssize_t length = ::readlink("/proc/self/exe", path, sizeof path - 1);
  if (length <= 0) return false;
  std::string_view exe(path, static_cast<size_t>(length));
  return exe.substr(exe.rfind('/') + 1) == "factorio";
}

__attribute__((constructor)) void load() {
  if (!std::getenv("FH_BRIDGE_SOCKET") || !is_factorio_process()) return;
  // Child processes inherit the environment; only this process may own the socket.
  std::string socket = std::getenv("FH_BRIDGE_SOCKET");
  ::unsetenv("FH_BRIDGE_SOCKET");
  g_loader = new Loader();  // intentionally never freed: hooks may run until exit
  g_loader->activate(socket);
}

__attribute__((destructor)) void unload() {
  if (g_loader) g_loader->shutdown();
}

}  // namespace
}  // namespace fh
