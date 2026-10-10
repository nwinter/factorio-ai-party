// Bridge behaviour, loaded (and hot-swapped) by the preloaded loader. Submits
// ordinary player input actions through the client's own PlayerInputSource,
// so the server receives normal actions, and reads state between ticks.
#include <sys/syscall.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <utility>

#include "game.hpp"
#include "image.hpp"
#include "json.hpp"
#include "logic_api.h"

namespace fh {

using game::ActionType;
using game::InputAction;

constexpr const char* kVersion = "0.1.0";
constexpr uint64_t kMineReassertTicks = 1;
// Latency plus a margin: the simulation shows our input only after the round trip.
constexpr uint64_t kMineStallTicks = 180;
// Upper bound for a submitted input to show in the simulation (multiplayer latency).
constexpr uint64_t kSettleTicks = 120;

pid_t thread_id() { return static_cast<pid_t>(::syscall(SYS_gettid)); }

std::string hex(const void* data, size_t size) {
  static const char digits[] = "0123456789abcdef";
  std::string out;
  auto* bytes = static_cast<const unsigned char*>(data);
  for (size_t i = 0; i < size; ++i) { out += digits[bytes[i] >> 4]; out += digits[bytes[i] & 15]; }
  return out;
}

std::string unhex(const std::string& text) {
  if (text.size() % 2) throw ArgError("hex payload must have an even length");
  auto nibble = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    throw ArgError("hex payload has a non-hex character");
  };
  std::string out;
  for (size_t i = 0; i < text.size(); i += 2) out += static_cast<char>(nibble(text[i]) << 4 | nibble(text[i + 1]));
  return out;
}

std::string hex_address(uintptr_t value) {
  char buffer[32];
  std::snprintf(buffer, sizeof buffer, "%lx", static_cast<unsigned long>(value));
  return buffer;
}

// Little-endian network payload, in the engine's wire order.
class Payload {
 public:
  template <typename T>
  Payload& put(T value) {
    bytes_.append(reinterpret_cast<const char*>(&value), sizeof value);
    return *this;
  }
  const std::string& bytes() const { return bytes_; }

 private:
  std::string bytes_;
};

// Direction is 16-way; entities use the 8 even values (north=0, east=4, ...).
std::optional<uint8_t> direction_value(std::string_view name) {
  static constexpr std::pair<std::string_view, uint8_t> kNames[] = {
      {"north", 0}, {"northeast", 2}, {"east", 4}, {"southeast", 6}, {"south", 8}, {"southwest", 10}, {"west", 12}, {"northwest", 14}};
  for (auto [key, value] : kNames) if (key == name) return value;
  return std::nullopt;
}

struct Failure : std::runtime_error {
  Failure(std::string code, const std::string& message) : std::runtime_error(message), code(std::move(code)) {}
  std::string code;
};

struct Direction {
  const char* name;
  double x, y;
};
// The engine rejects walking vectors longer than 1; sqrt(0.5) rounds up.
constexpr double kDiagonal = 0.7071067811865475;
constexpr Direction kDirections[] = {
    {"north", 0, -1}, {"northeast", kDiagonal, -kDiagonal}, {"east", 1, 0}, {"southeast", kDiagonal, kDiagonal},
    {"south", 0, 1},  {"southwest", -kDiagonal, kDiagonal}, {"west", -1, 0}, {"northwest", -kDiagonal, -kDiagonal},
};

// A parsed request line.
struct Request {
  uint64_t connection = 0;
  Json id;
  std::string action;
  Json args;
};

class Bridge {
 public:
  explicit Bridge(const FhHost& host) : host_(host) {}
  // Returns an empty string on success, else why the logic cannot run here.
  std::string activate();

  void on_flush(void* self, uint64_t tick, const FhRequest* requests, size_t count);
  std::optional<bool> arbitrate(void* self, const InputAction* raw);
  std::optional<Json> immediate(const Request& request);
  void release(void* self, uint64_t tick);

 private:
  void reply(uint64_t connection, const Json& message) {
    std::string text = message.dump();
    host_.reply(connection, text.data(), text.size());
  }
  bool in_game() const {
    auto age = std::chrono::steady_clock::now().time_since_epoch().count() - last_flush_ns_.load(std::memory_order_relaxed);
    return last_flush_ns_.load(std::memory_order_relaxed) != 0 && age < std::chrono::nanoseconds(std::chrono::seconds(1)).count();
  }
  Json execute(const Request& request, void* source, uint64_t tick);
  Json status(void* source, uint64_t tick) const;
  Json controls() const;
  void advance(void* source, uint64_t tick);
  void advance_walk(void* source, uint64_t tick);
  void advance_mine(void* source, uint64_t tick);
  void advance_build(void* source, uint64_t tick);
  void end_controls(const char* outcome, uint64_t tick);
  void submit(void* source, InputAction& action, const char* what);

  Json walk(const Json& args, void* source, uint64_t tick);
  Json path(const Json& args, void* source, uint64_t tick);
  void advance_path(void* source, uint64_t tick);
  Json stop(void* source);
  Json craft(const Json& args, void* source);
  Json mine(const Json& args, void* source, uint64_t tick);
  Json build(const Json& args, void* source, uint64_t tick);
  void pick_up(void* source, const game::StackRef& stack) {
    submit_payload(source, ActionType::CursorTransfer,
                   Payload()
                       .put<uint16_t>(stack.item)
                       .put<uint8_t>(stack.quality)
                       .put<uint64_t>(0)   // no item data
                       .put<uint8_t>(0)    // not the cursor itself
                       .put<uint8_t>(game::layout::kCharacterMainInventory)
                       .put<uint16_t>(stack.slot)
                       .put<uint8_t>(1));  // RelativeItemStackLocation::Source: the controller's own inventories
  }
  uint64_t item_count(void* source, uint16_t item, uint8_t quality) const {
    uint64_t total = 0;
    for (const auto& entry : engine_.player_state(source).main_inventory) {
      if (entry.item == item && entry.quality == quality) total += entry.count;
    }
    return total;
  }
  void submit_payload(void* source, ActionType type, const Payload& payload) {
    InputAction action(type);
    std::string error;
    if (!engine_.load_payload(action, payload.bytes(), &error)) throw Failure("bad_payload", engine_.action_name(static_cast<uint16_t>(type)) + ": " + error);
    submit(source, action, engine_.action_name(static_cast<uint16_t>(type)).c_str());
  }
  void select_target(void* source);
  // Whether the entity the miner selected is still in the world.
  bool target_exists(void* source) const {
    game::ScanRequest request;
    request.center = mining_.entity.position;
    request.radius = 1.0 / 256.0;
    request.names = {mining_.entity.name};
    auto result = engine_.scan(source, request);
    return result && !result->entities.empty();
  }
  void finish(const char* kind, const char* outcome, uint64_t tick) {
    last_[kind] = Json(Json::Object{{"outcome", outcome}, {"tick", tick}});
  }
  Json prototypes(const Json& args) const;
  Json say(const Json& args, void* source);
  Json inspect(const Json& args, void* source) const;
  Json transfer(bool insert, const Json& args, void* source, uint64_t tick);
  Json rotate(const Json& args, void* source, uint64_t tick);
  Json survey(const Json& args, void* source) const;
  Json items_json(const std::vector<game::ItemCount>& items) const {
    Json::Array list;
    for (const auto& entry : items) {
      Json::Object item{{"name", engine_.items().name(entry.item) ? Json(*engine_.items().name(entry.item)) : Json()}, {"count", entry.count}};
      if (auto quality = engine_.qualities().name(entry.quality); quality && *quality != "normal") item["quality"] = Json(*quality);
      list.push_back(Json(std::move(item)));
    }
    return Json(std::move(list));
  }
  // The entity nearest to a position (within tolerance), skipping characters.
  std::optional<game::ScannedEntity> entity_at(void* source, double x, double y, double tolerance) const {
    game::ScanRequest request;
    request.center = game::MapPosition::from_tiles(x, y);
    request.radius = tolerance;
    request.limit = 8;
    auto found = engine_.scan(source, request);
    if (found) for (const auto& entity : found->entities) if (entity.type != "character") return entity;
    return std::nullopt;
  }
  Json scan(const Json& args, void* source, double default_radius, int64_t default_limit) const;
  Json raw(const Json& args, void* source);
  Json peek(const Json& args) const;

  FhHost host_;
  Image image_;
  game::Engine engine_;
  bool developer_ = false;
  FILE* capture_ = nullptr;
  std::mutex capture_mutex_;

  // Updated on the game thread, read by status requests on the server thread.
  std::atomic<uint64_t> flushes_{0};
  std::atomic<uint64_t> last_tick_{0};
  std::atomic<pid_t> game_thread_{0};
  std::atomic<void*> source_{nullptr};
  std::atomic<int64_t> last_flush_ns_{0};
  void* player_ = nullptr;  // game thread only
  std::atomic<uint64_t> sessions_{0};

  // Game thread only (GUI input and flushes share the GameUpdate thread).
  bool submitting_ = false;
  Json::Object last_;  // most recent outcome per control kind
  struct Walking {
    bool active = false;
    uint64_t until = 0;
    double x = 0, y = 0;
    // StopWalking was submitted; the control ends once the simulation shows
    // the character standing (inputs apply after the multiplayer latency).
    bool stopping = false;
    bool seen_walking = false;  // the simulation has applied StartWalking
    uint64_t stop_deadline = 0;
    const char* outcome = nullptr;
  } walking_;
  struct Building {
    bool active = false;
    uint16_t item = 0;
    uint8_t quality = 0;
    uint64_t count_before = 0;
    std::string name;
    game::MapPosition target;
    uint64_t deadline = 0;
  } building_;
  // Continuous movement along waypoints, steered every tick from the simulated
  // position; direction changes are issued early by the measured input latency.
  struct Path {
    bool active = false;
    std::vector<std::pair<double, double>> points;
    size_t next = 0;
    int direction = -1;           // index into kDirections currently held, -1 none
    uint64_t submitted = 0;       // tick of the last StartWalking
    uint64_t latency = 25;        // ticks from input to simulation, measured
    bool measuring = false;
    double last_x = 0, last_y = 0;
    uint64_t moved_tick = 0;      // last tick the character moved
    uint64_t stop_deadline = 0;
    bool stopping = false;
    struct Command { uint64_t tick; double vx, vy; };
    std::vector<Command> commands;  // recent inputs, still travelling through the latency
  } path_;
  struct Mining {
    bool active = false;
    uint64_t started = 0;
    uint64_t until = 0;
    game::EntityRef entity;       // the target, resolved when the mine starts
    bool confirmed = false;       // the simulation has mined this target at some point
    uint64_t last_progress = 0;   // last tick the simulation's mining progress moved on the target
    double progress = 0;
    uint64_t next_assert = 0;     // rate limit for re-selecting the target
  } mining_;
};

std::string Bridge::activate() {
  developer_ = std::getenv("FH_BRIDGE_DEVELOPER") != nullptr;
  if (const char* capture = std::getenv("FH_BRIDGE_CAPTURE")) capture_ = std::fopen(capture, "ae");
  image_ = Image::inspect_self(game::Engine::required_symbols());
  if (!image_.ok()) return image_.error();
  if (!game::Engine::supported_build(image_.build_id())) return "unsupported Factorio build " + image_.build_id();
  if (!engine_.bind(image_)) return "engine entry points did not match the expected code";
  return {};
}

Json describe(bool developer) {
  auto action = [](const char* summary, Json::Object args) {
    return Json(Json::Object{{"summary", summary}, {"args", Json(std::move(args))}});
  };
  Json::Object actions{
      {"bridge_status", action("Bridge health: build, hook state, whether a multiplayer game is running.", {})},
      {"describe", action("This action list.", {})},
      {"observe", action("Local player (position, inventory, crafting queue, selection, active controls) plus nearby entities.",
                         {{"radius", "tiles, default 12"}, {"limit", "default 200"}, {"names", "entity name filter"}, {"types", "entity type filter"}})},
      {"scan", action("Entities near the player or a point, nearest first, with resource amounts.",
                      {{"radius", "tiles 0..256, default 32"}, {"limit", "1..5000, default 500"}, {"names", "string or array"},
                       {"types", "string or array, e.g. resource, tree, simple-entity"}, {"x", "center x (default player)"}, {"y", "center y"}})},
      {"status", action("Alias of observe.", {})},
      {"path", action("Walk continuously through waypoints (e.g. from a planner), steering every tick; outcome arrived/blocked/stopped_short.",
                      {{"points", "[[x,y], ...], required"}})},
      {"walk", action("Hold a movement direction for a number of ticks; the character moves in 8 directions (vectors snap), "
                      "about 0.15 tiles per tick unmodified.",
                      {{"direction", "north|northeast|east|southeast|south|southwest|west|northwest"},
                       {"x", "number, alternative to direction"}, {"y", "number, alternative to direction"},
                       {"ticks", "integer 1..36000, default 60"}})},
      {"mine", action("Select the entity at a map position and hold the mine button, like the GUI. Ends when the target is gone "
                      "(target_mined), the miner gives up (miner_stopped: out of reach, ~2.7 tiles for resources), or after ticks. "
                      "Resources keep yielding until ticks elapse.",
                      {{"x", "number, required"}, {"y", "number, required"}, {"ticks", "integer 1..36000, default 120"}})},
      {"build", action("Place an item from the main inventory like a cursor click (pick up stack, build, clear cursor). "
                       "Outcome built/not_built once the client simulation shows it.",
                       {{"item", "item name, required"}, {"x", "number, required"}, {"y", "number, required"},
                        {"direction", "north|east|south|west|..., default north"}, {"quality", "default normal"}})},
      {"craft", action("Queue hand-crafting like the crafting GUI.", {{"recipe", "recipe name, required"}, {"count", "integer 1..10000, default 1"}})},
      {"say", action("Send a chat message like the console (no commands).", {{"text", "1..500 bytes, required"}})},
      {"inspect", action("One entity: status, recipe, inventories by index (1 fuel/chest, 2 input/source, 3 output/result, 4 modules, ...).",
                         {{"x", "required"}, {"y", "required"}, {"tolerance", "tiles, default 1"}})},
      {"survey", action("Machine health in an area: status counts per machine and recipe, and where the non-working ones are.",
                        {{"radius", "tiles 1..256, default 64"}, {"x", "center"}, {"y", "center"}, {"types", "entity types"}, {"limit", "non-working list size, default 40"}})},
      {"insert", action("Ctrl+click a stack from the main inventory into an entity (fuel, ingredients, chest).",
                        {{"item", "required"}, {"x", "required"}, {"y", "required"}})},
      {"take", action("Ctrl+click an entity with an empty hand: take its output/contents.", {{"x", "required"}, {"y", "required"}})},
      {"rotate", action("Hover an entity and press R (reverse: shift+R). Underground belts swap entrance/exit.",
                        {{"x", "required"}, {"y", "required"}, {"reverse", "bool"}})},
      {"stop", action("Release movement and mining.", {})},
      {"prototypes", action("Names of loaded prototypes.", {{"kind", "recipe|item|entity|quality, default recipe"}})},
  };
  if (developer) {
    actions["raw"] = action("Developer: submit any input action from its network payload.", {{"type", "action type name or number"}, {"payload", "hex"}});
    actions["peek"] = action("Developer: read process memory.", {{"address", "hex"}, {"length", "integer 1..4096"}});
    actions["pointers"] = action("Developer: engine object addresses.", {});
  }
  return Json(Json::Object{{"transport", "client-bridge"}, {"version", kVersion}, {"actions", Json(std::move(actions))},
                           {"semantics", "Actions are normal player input sent through this client; replies confirm submission. "
                                         "Use observe and the last outcomes to confirm effects."}});
}

std::optional<Json> Bridge::immediate(const Request& request) {
  if (request.action == "describe") return Json(Json::Object{{"id", request.id}, {"ok", true}, {"result", describe(developer_)}});
  if (request.action == "bridge_status") {
    return Json(Json::Object{
        {"id", request.id},
        {"ok", true},
        {"result", Json(Json::Object{
                       {"version", kVersion},
                       {"build_id", image_.build_id()},
                       {"active", true},
                       {"logic_generation", host_.generation},
                       {"flushes", flushes_.load()},
                       {"last_tick", last_tick_.load()},
                       {"game_thread", static_cast<int64_t>(game_thread_.load())},
                       {"in_game", in_game()},
                       {"sessions", sessions_.load()},
                   })},
    });
  }
  return std::nullopt;
}

// Returns a result when the GUI action is swallowed, nullopt to pass it on.
std::optional<bool> Bridge::arbitrate(void* self, const InputAction* raw) {
  if (capture_) {
    std::lock_guard lock(capture_mutex_);
    std::fprintf(capture_, "{\"thread\":%d,\"type\":%u,\"name\":\"%s\",\"player\":%u,\"data\":\"%s\"}\n", thread_id(), raw->type,
                 engine_.action_name(raw->type).c_str(), raw->player_index, hex(raw->data, sizeof raw->data).c_str());
    std::fflush(capture_);
  }
  if (!submitting_ && self == source_.load(std::memory_order_relaxed)) {
    // GUI input. A released keyboard re-asserts "stop"; swallow that while the
    // agent walks. Pressed movement keys are a human takeover.
    auto type = static_cast<ActionType>(raw->type);
    if ((walking_.active || path_.active) && type == ActionType::StopWalking) return true;  // swallowed
    if (path_.active && type == ActionType::StartWalking) {
      path_ = {};
      finish("path", "human_input", last_tick_.load(std::memory_order_relaxed));
    }
    if (walking_.active && type == ActionType::StartWalking) {
      walking_.active = false;
      finish("walk", "human_input", last_tick_.load(std::memory_order_relaxed));
    }
    // The mouse would re-select whatever it hovers and release the mine button.
    if (mining_.active && type == ActionType::BeginMining) {
      mining_.active = false;
      finish("mine", "human_input", last_tick_.load(std::memory_order_relaxed));
    }
    if (mining_.active && (type == ActionType::SelectedEntityChanged || type == ActionType::SelectedEntityCleared ||
                           type == ActionType::StopMining)) return true;
  }
  return std::nullopt;
}

void Bridge::on_flush(void* self, uint64_t tick, const FhRequest* requests, size_t count) {
  // Act only for the local player of a multiplayer session. The main menu's
  // background simulation also has a player but no network listener.
  if (!game::read<void*>(self, game::layout::kInputSourcePlayer) || !engine_.feeds_network(self)) {
    // Requests are only for the local player's game; others must not be lost.
    for (size_t i = 0; i < count; ++i) {
      reply(requests[i].connection, Json(Json::Object{{"ok", false}, {"error", Json(Json::Object{{"code", "game_not_running"},
                                                     {"message", "not in a multiplayer game"}})}}));
    }
    return;
  }
  int64_t now = std::chrono::steady_clock::now().time_since_epoch().count();
  int64_t previous_flush = last_flush_ns_.exchange(now, std::memory_order_relaxed);
  uint64_t previous_tick = last_tick_.exchange(tick, std::memory_order_relaxed);
  flushes_.fetch_add(1, std::memory_order_relaxed);
  game_thread_.store(thread_id(), std::memory_order_relaxed);
  // A new game session (join or reconnect): controls never carry over. Objects
  // can be reallocated at old addresses, so also watch the player and time
  // going backwards. Stalls (autosaves) are not new sessions.
  void* player = game::read<void*>(self, game::layout::kInputSourcePlayer);
  bool new_source = source_.exchange(self, std::memory_order_relaxed) != self;
  bool new_player = std::exchange(player_, player) != player;
  if (new_source || new_player || tick < previous_tick || previous_flush == 0) {
    try { end_controls("session_changed", tick); } catch (...) {}
    sessions_.fetch_add(1, std::memory_order_relaxed);
  }
  // Separate phases: a failing control must never block request handling.
  try {
    advance(self, tick);
  } catch (...) {
    std::fprintf(stderr, "[fh-bridge] unexpected exception while advancing controls\n");
  }
  try {
    for (size_t i = 0; i < count; ++i) {
      Request request;
      request.connection = requests[i].connection;
      Json message = Json::parse(std::string_view(requests[i].json, requests[i].length));
      if (const Json* id = message.find("id")) request.id = *id;
      if (const Json* action = message.find("action"); action && action->is_string()) request.action = action->as_string();
      const Json* args = message.find("args");
      request.args = args && args->is_object() ? *args : Json(Json::Object{});
      reply(request.connection, execute(request, self, tick));
    }
  } catch (...) {
    // Never unwind into engine frames.
    std::fprintf(stderr, "[fh-bridge] unexpected exception while handling requests\n");
  }
}

void Bridge::end_controls(const char* outcome, uint64_t tick) {
  if (walking_.active) finish("walk", outcome, tick);
  if (path_.active) finish("path", outcome, tick);
  if (mining_.active) finish("mine", outcome, tick);
  if (building_.active) finish("build", outcome, tick);
  walking_ = {};
  path_ = {};
  mining_ = {};
  building_ = {};
}

void Bridge::submit(void* source, InputAction& action, const char* what) {
  submitting_ = true;
  bool accepted = engine_.submit(source, action);
  submitting_ = false;
  if (!accepted) throw Failure("rejected", std::string(what) + " was rejected by the client (permissions?)");
}

void Bridge::advance(void* source, uint64_t tick) {
  // A control whose input the client rejects (permissions, dead player) ends
  // as "rejected" instead of failing again on every flush.
  try { advance_walk(source, tick); } catch (const Failure&) { walking_ = {}; finish("walk", "rejected", tick); }
  try { advance_path(source, tick); } catch (const Failure&) { path_ = {}; finish("path", "rejected", tick); }
  try { advance_mine(source, tick); } catch (const Failure&) { mining_ = {}; finish("mine", "rejected", tick); }
  advance_build(source, tick);
}

void Bridge::advance_walk(void* source, uint64_t tick) {
  if (walking_.active && !walking_.seen_walking) walking_.seen_walking = engine_.walking(source);
  if (walking_.active && !walking_.stopping && tick >= walking_.until) {
    InputAction stop(ActionType::StopWalking);
    submit(source, stop, "StopWalking");
    walking_.stopping = true;
    walking_.stop_deadline = tick + kSettleTicks;
    walking_.outcome = "duration_elapsed";
  }
  if (walking_.active && walking_.stopping) {
    bool walking = engine_.walking(source);
    // A short walk can start and stop within the input latency: wait until the
    // simulation has shown the start, then the stop.
    if ((walking_.seen_walking && !walking) || tick >= walking_.stop_deadline) {
      walking_.active = false;
      finish("walk", walking ? "stop_unconfirmed" : walking_.seen_walking ? walking_.outcome : "not_started", tick);
    }
  }
}

void Bridge::advance_mine(void* source, uint64_t tick) {
  if (!mining_.active) return;
  const char* outcome = nullptr;
  auto selected = engine_.selected(source);
  bool on_target = selected && selected->name == mining_.entity.name &&
                   selected->position.x == mining_.entity.position.x && selected->position.y == mining_.entity.position.y;
  bool mining = engine_.mining(source);
  double progress = engine_.mining_progress(source);
  if (on_target && progress != mining_.progress) {
    mining_.confirmed = true;
    mining_.last_progress = tick;
  }
  mining_.progress = progress;
  if (!target_exists(source)) outcome = "target_mined";
  else if (tick >= mining_.until) outcome = "duration_elapsed";
  // Held on target but the miner will not work (out of reach, full inventory):
  // allow for the multiplayer latency before giving up.
  else if (tick - std::max(mining_.last_progress, mining_.started) > kMineStallTicks) outcome = "miner_stopped";
  if (outcome) {
    InputAction stop(ActionType::StopMining);
    submit(source, stop, "StopMining");
    mining_.active = false;
    finish("mine", outcome, tick);
    return;
  }
  // Like a player keeping the cursor on the target: the client's own
  // selection logic (mouse hover) can move it away, so put it back.
  if ((!on_target || !mining) && tick >= mining_.next_assert) {
    mining_.next_assert = tick + kMineReassertTicks;
    if (!on_target) select_target(source);
    InputAction begin(ActionType::BeginMining);
    submit(source, begin, "BeginMining");
  }
}

void Bridge::advance_build(void* source, uint64_t tick) {
  if (!building_.active) return;
  uint64_t count = item_count(source, building_.item, building_.quality);
  if (count < building_.count_before || tick >= building_.deadline) {
    building_.active = false;
    finish("build", count < building_.count_before ? "built" : "not_built", tick);
  }
}

Json Bridge::execute(const Request& request, void* source, uint64_t tick) {
  Json::Object reply{{"id", request.id}, {"tick", tick}};
  try {
    Json result;
    const std::string& action = request.action;
    if (action == "status") result = status(source, tick);
    else if (action == "observe") {
      result = status(source, tick);
      Json::Object object = result.as_object();
      Json scanned = scan(request.args, source, 12, 200);
      object["entities"] = *scanned.find("entities");
      object["entities_truncated"] = *scanned.find("truncated");
      result = Json(std::move(object));
    } else if (action == "scan") result = scan(request.args, source, 32, 500);
    else if (action == "walk") result = walk(request.args, source, tick);
    else if (action == "path") result = path(request.args, source, tick);
    else if (action == "stop") result = stop(source);
    else if (action == "craft") result = craft(request.args, source);
    else if (action == "mine") result = mine(request.args, source, tick);
    else if (action == "build") result = build(request.args, source, tick);
    else if (action == "prototypes") result = prototypes(request.args);
    else if (action == "say") result = say(request.args, source);
    else if (action == "inspect") result = inspect(request.args, source);
    else if (action == "insert" || action == "take") result = transfer(action == "insert", request.args, source, tick);
    else if (action == "rotate") result = rotate(request.args, source, tick);
    else if (action == "survey") result = survey(request.args, source); else if (developer_ && action == "raw") result = raw(request.args, source);
    else if (developer_ && action == "peek") result = peek(request.args);
    else if (developer_ && action == "pointers") {
      void* player = game::read<void*>(source, game::layout::kInputSourcePlayer);
      Json::Object pointers{{"bias", hex_address(image_.bias())}, {"source", hex_address(reinterpret_cast<uintptr_t>(source))},
                            {"player", hex_address(reinterpret_cast<uintptr_t>(player))}};
      for (size_t offset : {0x740, 0x748, 0x750, 0x758}) {
        void* object = game::read<void*>(player, offset);
        std::string key = "player+" + std::to_string(offset);
        pointers[key] = hex_address(reinterpret_cast<uintptr_t>(object));
        if (object) pointers[key + ".vtable-bias"] = hex_address(game::read<uintptr_t>(object, 0) - image_.bias());
      }
      if (void* character = game::read<void*>(player, game::layout::kPlayerCharacterController)) {
        auto* vtable = game::read<unsigned char*>(character, 0);
        auto get = game::read<void* (*)(void*, uint8_t)>(vtable, game::layout::kControllerGetInventory);
        pointers["main_inventory"] = hex_address(reinterpret_cast<uintptr_t>(get(character, 1)));
      }
      result = Json(std::move(pointers));
    }
    else throw Failure("unknown_action", "unknown action " + action);
    reply["ok"] = true;
    reply["result"] = std::move(result);
  } catch (const Failure& failure) {
    reply["ok"] = false;
    reply["error"] = Json(Json::Object{{"code", failure.code}, {"message", failure.what()}});
  } catch (const ArgError& failure) {
    reply["ok"] = false;
    reply["error"] = Json(Json::Object{{"code", "invalid_args"}, {"message", failure.what()}});
  } catch (const std::exception& failure) {
    reply["ok"] = false;
    reply["error"] = Json(Json::Object{{"code", "internal_error"}, {"message", failure.what()}});
  }
  return Json(std::move(reply));
}

Json entity_json(const game::EntityRef& entity) {
  return Json(Json::Object{{"name", entity.name}, {"position", Json(Json::Object{{"x", entity.position.tile_x()}, {"y", entity.position.tile_y()}})}});
}

const char* controller_name(game::ControllerKind kind) {
  switch (kind) {
    case game::ControllerKind::None: return "none";
    case game::ControllerKind::Character: return "character";
    case game::ControllerKind::Remote: return "remote";
    case game::ControllerKind::God: return "god";
    case game::ControllerKind::Spectator: return "spectator";
    case game::ControllerKind::Editor: return "editor";
    case game::ControllerKind::Cutscene: return "cutscene";
    case game::ControllerKind::Other: return "other";
  }
  return "other";
}

Json Bridge::controls() const {
  Json walk, mine;
  if (walking_.active) {
    walk = Json(Json::Object{{"until_tick", walking_.until}, {"vector", Json(Json::Array{walking_.x, walking_.y})},
                             {"stopping", walking_.stopping}});
  }
  if (mining_.active) {
    mine = Json(Json::Object{{"until_tick", mining_.until}, {"confirmed", mining_.confirmed}, {"target", entity_json(mining_.entity)}});
  }
  Json build;
  if (building_.active) {
    build = Json(Json::Object{{"item", building_.name},
                              {"position", Json(Json::Object{{"x", building_.target.tile_x()}, {"y", building_.target.tile_y()}})}});
  }
  Json path;
  if (path_.active) path = Json(Json::Object{{"next", static_cast<uint64_t>(path_.next)}, {"points", static_cast<uint64_t>(path_.points.size())},
                                             {"latency", path_.latency}});
  return Json(Json::Object{{"walk", walk}, {"mine", mine}, {"build", build}, {"path", path}});
}

Json Bridge::status(void* source, uint64_t tick) const {
  game::PlayerState state = engine_.player_state(source);
  auto name = [](const game::PrototypeTable& table, uint16_t id) {
    auto found = table.name(id);
    return found ? Json(*found) : Json("#" + std::to_string(id));
  };
  Json::Array inventory;
  for (const auto& entry : state.main_inventory) {
    Json::Object item{{"name", name(engine_.items(), entry.item)}, {"count", entry.count}};
    if (auto quality = engine_.qualities().name(entry.quality); quality && *quality != "normal") item["quality"] = Json(*quality);
    inventory.push_back(Json(std::move(item)));
  }
  Json::Array queue;
  for (const auto& entry : state.crafting_queue) {
    queue.push_back(Json(Json::Object{{"recipe", name(engine_.recipes(), entry.recipe)}, {"count", entry.count}}));
  }
  Json::Object player{
      {"index", state.index + 1},
      {"controller", controller_name(state.controller)},
      {"character", state.has_character},
      {"position", state.position ? Json(Json::Object{{"x", state.position->tile_x()}, {"y", state.position->tile_y()}}) : Json()},
  };
  player["mining"] = state.mining;
  player["selected"] = state.selected ? entity_json(*state.selected) : Json();
  if (state.cursor) {
    player["cursor"] = Json(Json::Object{{"name", name(engine_.items(), state.cursor->item)}, {"count", state.cursor->count}});
  }
  if (state.has_character) {
    player["inventory"] = Json(std::move(inventory));
    player["inventory_slots"] = Json(Json::Object{{"total", state.main_inventory_slots}, {"free", state.main_inventory_free}});
    player["crafting_queue"] = Json(std::move(queue));
  }
  return Json(Json::Object{
      {"map_tick", state.map_tick},
      {"input_tick", tick},
      {"player", Json(std::move(player))},
      {"controls", controls()},
      {"last", Json(last_)},
  });
}

Json Bridge::walk(const Json& args, void* source, uint64_t tick) {
  double x = 0, y = 0;
  if (auto name = string_arg(args, "direction")) {
    const Direction* found = nullptr;
    for (const auto& direction : kDirections) if (*name == direction.name) found = &direction;
    if (!found) throw ArgError("direction must be one of north, northeast, east, southeast, south, southwest, west, northwest");
    x = found->x;
    y = found->y;
  } else {
    x = coordinate_arg(args, "x").value_or(0);
    y = coordinate_arg(args, "y").value_or(0);
    double length = std::hypot(x, y);
    if (length < 1e-6) throw ArgError("walk needs a direction or a nonzero x/y vector");
    x /= length;
    y /= length;
    while (x * x + y * y > 1.0) {
      x = std::nextafter(x, 0.0);
      y = std::nextafter(y, 0.0);
    }
  }
  int64_t ticks = integer_arg(args, "ticks", 60, 1, 60 * 60 * 10);
  if (path_.active) { path_ = {}; finish("path", "replaced", tick); }
  InputAction start(ActionType::StartWalking);
  start.set<double>(0, x);
  start.set<double>(8, y);
  submit(source, start, "StartWalking");
  walking_ = {};
  walking_.active = true;
  walking_.until = tick + static_cast<uint64_t>(ticks);
  walking_.x = x;
  walking_.y = y;
  return Json(Json::Object{{"submitted_tick", tick}, {"until_tick", walking_.until}, {"vector", Json(Json::Array{x, y})}});
}

Json Bridge::path(const Json& args, void* source, uint64_t tick) {
  const Json* points = args.find("points");
  if (!points || !points->is_array() || points->as_array().empty()) throw ArgError("path needs points: [[x,y],...]");
  std::vector<std::pair<double, double>> list;
  for (const Json& point : points->as_array()) {
    if (!point.is_array() || point.as_array().size() != 2) throw ArgError("each point is [x, y]");
    double x = point.as_array()[0].as_number(), y = point.as_array()[1].as_number();
    if (std::fabs(x) > 1'000'000 || std::fabs(y) > 1'000'000) throw ArgError("point out of range");
    list.emplace_back(x, y);
  }
  if (list.size() > 2000) throw ArgError("at most 2000 points");
  if (walking_.active) { walking_ = {}; finish("walk", "replaced", tick); }
  uint64_t latency = path_.latency;
  path_ = {};
  path_.active = true;
  path_.points = std::move(list);
  path_.latency = latency;
  path_.moved_tick = tick;
  advance_path(source, tick);
  return Json(Json::Object{{"submitted_tick", tick}, {"points", static_cast<uint64_t>(path_.points.size())}});
}

void Bridge::advance_path(void* source, uint64_t tick) {
  if (!path_.active) return;
  auto position = engine_.player_state(source).position;
  if (!position) return;
  double px = position->tile_x(), py = position->tile_y();
  constexpr double kSpeed = 0.1484;  // tiles per tick, unmodified character
  if (std::hypot(px - path_.last_x, py - path_.last_y) > 0.01) {
    if (path_.measuring) {  // first movement after starting from rest: that is the latency
      path_.latency = std::clamp<uint64_t>(tick - path_.submitted, 1, 120);
      path_.measuring = false;
    }
    path_.moved_tick = tick;
  }
  path_.last_x = px;
  path_.last_y = py;
  // Where the character will be once every input already sent has taken
  // effect: commands reach the simulation `latency` ticks after submission.
  const uint64_t latency = path_.latency;
  double fx = px, fy = py;
  for (size_t i = 0; i < path_.commands.size(); ++i) {
    uint64_t from = std::max(path_.commands[i].tick, tick > latency ? tick - latency : 0);
    uint64_t to = i + 1 < path_.commands.size() ? path_.commands[i + 1].tick : tick;
    if (to <= from) continue;
    fx += path_.commands[i].vx * kSpeed * static_cast<double>(to - from);
    fy += path_.commands[i].vy * kSpeed * static_cast<double>(to - from);
  }
  while (path_.commands.size() > 1 && path_.commands[1].tick + latency < tick) path_.commands.erase(path_.commands.begin());
  auto command = [&](int direction) {
    double vx = direction >= 0 ? kDirections[direction].x : 0, vy = direction >= 0 ? kDirections[direction].y : 0;
    if (direction >= 0) {
      InputAction start(ActionType::StartWalking);
      start.set<double>(0, vx);
      start.set<double>(8, vy);
      submit(source, start, "StartWalking");
    } else {
      InputAction stop(ActionType::StopWalking);
      submit(source, stop, "StopWalking");
    }
    if (path_.direction < 0 && direction >= 0) { path_.measuring = true; path_.submitted = tick; }
    path_.direction = direction;
    path_.commands.push_back({tick, vx, vy});
  };
  if (path_.stopping) {
    if ((!engine_.walking(source) && tick >= path_.stop_deadline - kSettleTicks + latency) || tick >= path_.stop_deadline) {
      path_.active = false;
      auto [tx, ty] = path_.points.back();
      finish("path", std::hypot(tx - px, ty - py) < 1.0 ? "arrived" : "stopped_short", tick);
    }
    return;
  }
  bool stuck = path_.direction >= 0 && tick - path_.moved_tick > latency + 40;
  if (stuck) {
    command(-1);
    path_.active = false;
    finish("path", "blocked", tick);
    return;
  }
  // Advance past waypoints the predicted position has reached.
  const double reach = kSpeed * 0.75;
  while (path_.next + 1 < path_.points.size() &&
         std::hypot(path_.points[path_.next].first - fx, path_.points[path_.next].second - fy) <= std::max(reach, 0.25)) ++path_.next;
  auto [tx, ty] = path_.points[path_.next];
  bool last = path_.next + 1 == path_.points.size();
  if (last && std::hypot(tx - fx, ty - fy) <= std::max(reach, 0.2)) {
    command(-1);
    path_.stopping = true;
    path_.stop_deadline = tick + kSettleTicks;
    return;
  }
  // Nearest of the 8 directions from the predicted position to the target.
  double angle = std::atan2(ty - fy, tx - fx);  // y grows southward
  static constexpr int kOrder[8] = {2, 3, 4, 5, 6, 7, 0, 1};  // east, se, s, sw, w, nw, n, ne
  int wanted = kOrder[static_cast<int>(std::lround(angle / (M_PI / 4))) & 7];
  if (wanted != path_.direction) command(wanted);
}

Json Bridge::stop(void* source) {
  InputAction walking(ActionType::StopWalking);
  submit(source, walking, "StopWalking");
  InputAction mining(ActionType::StopMining);
  submit(source, mining, "StopMining");
  if (walking_.active) finish("walk", "stopped", last_tick_.load(std::memory_order_relaxed));
  if (mining_.active) finish("mine", "stopped", last_tick_.load(std::memory_order_relaxed));
  if (path_.active) finish("path", "stopped", last_tick_.load(std::memory_order_relaxed));
  path_ = {};
  walking_.active = false;
  mining_.active = false;
  return Json(Json::Object{{"stopped", Json(Json::Array{"walking", "mining"})}});
}

void Bridge::select_target(void* source) {
  InputAction select(ActionType::SelectedEntityChanged);
  select.set<int32_t>(0, mining_.entity.position.x);
  select.set<int32_t>(4, mining_.entity.position.y);
  submit(source, select, "SelectedEntityChanged");
}

Json Bridge::mine(const Json& args, void* source, uint64_t tick) {
  auto x = coordinate_arg(args, "x");
  auto y = coordinate_arg(args, "y");
  if (!x || !y) throw ArgError("mine needs the target's x and y map position");
  int64_t ticks = integer_arg(args, "ticks", 120, 1, 60 * 60 * 10);
  // Resolve the entity the player means: the nearest one at the position.
  game::ScanRequest request;
  request.center = game::MapPosition::from_tiles(*x, *y);
  request.radius = number_arg(args, "tolerance").value_or(1.0);
  request.limit = 8;
  auto found = engine_.scan(source, request);
  const game::ScannedEntity* target = nullptr;
  if (found) {
    for (const auto& entity : found->entities) {
      if (entity.type != "character") { target = &entity; break; }
    }
  }
  if (!target) throw Failure("no_target", "nothing to mine at that position");
  mining_ = {};
  mining_.active = true;
  mining_.started = tick;
  mining_.until = tick + static_cast<uint64_t>(ticks);
  mining_.entity = {0, std::string(target->name), target->position};
  select_target(source);
  InputAction begin(ActionType::BeginMining);
  submit(source, begin, "BeginMining");
  mining_.next_assert = tick + kMineReassertTicks;
  return Json(Json::Object{{"submitted_tick", tick}, {"until_tick", mining_.until}, {"target", entity_json(mining_.entity)}});
}

Json Bridge::build(const Json& args, void* source, uint64_t tick) {
  auto name = string_arg(args, "item");
  auto x = coordinate_arg(args, "x");
  auto y = coordinate_arg(args, "y");
  if (!name || !x || !y) throw ArgError("build needs item, x and y");
  auto item = engine_.items().id(*name);
  if (!item) throw Failure("unknown_item", "no item named " + *name);
  std::string quality_name = string_arg(args, "quality").value_or("normal");
  auto quality = engine_.qualities().id(quality_name);
  if (!quality) throw Failure("unknown_quality", "no quality named " + quality_name);
  uint8_t direction = 0;
  if (auto text = string_arg(args, "direction")) {
    auto value = direction_value(*text);
    if (!value) throw ArgError("direction must be north, northeast, east, southeast, south, southwest, west, or northwest");
    direction = *value;
  }
  auto stack = engine_.find_stack(source, *item, static_cast<uint8_t>(*quality));
  if (!stack) throw Failure("missing_item", "no plain " + *name + " stack in the main inventory");
  auto flags = static_cast<uint8_t>(integer_arg(args, "flags", 0, 0, 0x7f));
  game::MapPosition target = game::MapPosition::from_tiles(*x, *y);

  // The GUI sequence: pick the stack up, click the world, put the rest back.
  pick_up(source, *stack);
  auto clear_cursor = [&] {
    InputAction clear(ActionType::ClearCursor);
    submit(source, clear, "ClearCursor");
  };
  try {
    submit_payload(source, ActionType::Build,
                   Payload()
                       .put<int32_t>(target.x)
                       .put<int32_t>(target.y)
                       .put<uint8_t>(direction)
                       .put<uint8_t>(0)    // not a drag build
                       .put<uint8_t>(0)    // BuildMode::Normal
                       .put<uint8_t>(flags));  // flags byte; bit 7 (blueprint parameters) never set
  } catch (...) {
    clear_cursor();  // never leave the picked-up stack in the hand
    throw;
  }
  clear_cursor();

  building_ = {true, *item, static_cast<uint8_t>(*quality), item_count(source, *item, static_cast<uint8_t>(*quality)), *name, target,
               tick + kSettleTicks};
  return Json(Json::Object{{"submitted_tick", tick}, {"item", *name}, {"slot", stack->slot},
                           {"position", Json(Json::Object{{"x", target.tile_x()}, {"y", target.tile_y()}})}, {"direction", direction}});
}

Json Bridge::craft(const Json& args, void* source) {
  auto recipe = string_arg(args, "recipe");
  if (!recipe) throw ArgError("craft needs a recipe name");
  auto id = engine_.recipes().id(*recipe);
  if (!id) throw Failure("unknown_recipe", "no recipe named " + *recipe);
  int64_t count = integer_arg(args, "count", 1, 1, 10000);
  InputAction craft(ActionType::Craft);
  craft.set<uint16_t>(0, *id);
  craft.set<uint32_t>(4, static_cast<uint32_t>(count));
  submit(source, craft, "Craft");
  return Json(Json::Object{{"recipe", *recipe}, {"recipe_id", *id}, {"count", count}});
}

Json Bridge::say(const Json& args, void* source) {
  auto text = string_arg(args, "text");
  if (!text || text->empty()) throw ArgError("say needs text");
  if (text->size() > 500) throw ArgError("text is limited to 500 bytes");
  // Chat is plain console input. A leading '/' would run a console command.
  if ((*text)[0] == '/') throw ArgError("text must not start with '/'");
  // Engine string: u8 length, or 0xff then u32 length; then the bytes.
  Payload payload;
  if (text->size() < 0xff) payload.put<uint8_t>(static_cast<uint8_t>(text->size()));
  else payload.put<uint8_t>(0xff).put<uint32_t>(static_cast<uint32_t>(text->size()));
  for (char c : *text) payload.put<char>(c);
  submit_payload(source, ActionType::WriteToConsole, payload);
  return Json(Json::Object{{"said", *text}});
}

Json Bridge::transfer(bool insert, const Json& args, void* source, uint64_t tick) {
  auto x = coordinate_arg(args, "x");
  auto y = coordinate_arg(args, "y");
  if (!x || !y) throw ArgError("insert/take need the entity's x and y");
  auto entity = entity_at(source, *x, *y, number_arg(args, "tolerance").value_or(1.0));
  if (!entity) throw Failure("no_entity", "no entity at that position");
  // Ctrl+click, as the GUI does it, in one batch so nothing can reorder it:
  // hover the entity, [pick up a stack], fast-transfer, put the hand back.
  InputAction select(ActionType::SelectedEntityChanged);
  select.set<int32_t>(0, entity->position.x);
  select.set<int32_t>(4, entity->position.y);
  InputAction clear(ActionType::ClearCursor);
  Json::Object result{{"submitted_tick", tick}, {"entity", std::string(entity->name)},
                      {"position", Json(Json::Object{{"x", entity->position.tile_x()}, {"y", entity->position.tile_y()}})}};
  if (insert) {
    auto name = string_arg(args, "item");
    if (!name) throw ArgError("insert needs an item");
    auto item = engine_.items().id(*name);
    if (!item) throw Failure("unknown_item", "no item named " + *name);
    auto stack = engine_.find_stack(source, *item, 1 /* normal */);
    if (!stack) throw Failure("missing_item", "no plain " + *name + " stack in the main inventory");
    submit(source, select, "SelectedEntityChanged");
    pick_up(source, *stack);
    try {
      // Payload: whether the hand holds something, as the client believes.
      submit_payload(source, ActionType::FastEntityTransfer, Payload().put<uint8_t>(1));
    } catch (...) {
      submit(source, clear, "ClearCursor");
      throw;
    }
    submit(source, clear, "ClearCursor");
    result["item"] = *name;
    result["stack"] = stack->count;
  } else {
    submit(source, clear, "ClearCursor");
    submit(source, select, "SelectedEntityChanged");
    submit_payload(source, ActionType::FastEntityTransfer, Payload().put<uint8_t>(0));
  }
  return Json(std::move(result));
}

Json Bridge::rotate(const Json& args, void* source, uint64_t tick) {
  auto x = coordinate_arg(args, "x");
  auto y = coordinate_arg(args, "y");
  if (!x || !y) throw ArgError("rotate needs the entity's x and y");
  auto entity = entity_at(source, *x, *y, number_arg(args, "tolerance").value_or(0.6));
  if (!entity) throw Failure("no_entity", "no entity at that position");
  // Hover and press R (shift+R when reverse); underground belts swap entrance/exit.
  InputAction select(ActionType::SelectedEntityChanged);
  select.set<int32_t>(0, entity->position.x);
  select.set<int32_t>(4, entity->position.y);
  submit(source, select, "SelectedEntityChanged");
  submit_payload(source, ActionType::RotateEntity, Payload().put<uint8_t>(bool_arg(args, "reverse").value_or(false) ? 1 : 0));
  return Json(Json::Object{{"submitted_tick", tick}, {"entity", std::string(entity->name)},
                           {"position", Json(Json::Object{{"x", entity->position.tile_x()}, {"y", entity->position.tile_y()}})}});
}

Json Bridge::inspect(const Json& args, void* source) const {
  auto x = coordinate_arg(args, "x");
  auto y = coordinate_arg(args, "y");
  if (!x || !y) throw ArgError("inspect needs x and y");
  auto entity = entity_at(source, *x, *y, number_arg(args, "tolerance").value_or(1.0));
  if (!entity) throw Failure("no_entity", "no entity at that position");
  game::EntityDetails details = engine_.details(entity->entity);
  Json::Object result{{"name", entity->name}, {"type", entity->type},
                      {"position", Json(Json::Object{{"x", entity->position.tile_x()}, {"y", entity->position.tile_y()}})},
                      {"status", details.status ? Json(game::entity_status_name(details.status)) : Json()},
                      {"direction", details.direction}};
  if (!details.fluids.empty()) {
    Json::Object fluids;
    for (auto [id, amount] : details.fluids) {
      auto name = engine_.fluids().name(id);
      fluids[name ? std::string(*name) : "#" + std::to_string(id)] = amount;
    }
    result["fluids"] = Json(std::move(fluids));
  }
  if (!details.belt_lines.empty()) {
    Json::Array lanes;
    for (const auto& lane : details.belt_lines) lanes.push_back(items_json(lane));
    result["belt_lanes"] = Json(std::move(lanes));
  }
  if (details.recipe) {
    auto recipe = engine_.recipes().name(*details.recipe);
    result["recipe"] = recipe ? Json(*recipe) : Json();
  }
  Json::Object inventories;
  for (const auto& [index, items] : details.inventories) inventories[std::to_string(index)] = items_json(items);
  result["inventories"] = Json(std::move(inventories));
  if (entity->amount) result["amount"] = *entity->amount;
  return Json(std::move(result));
}

Json Bridge::survey(const Json& args, void* source) const {
  // Machine health over an area: status counts per entity name, plus where
  // the unhappy ones are. The basis for finding a bottleneck.
  game::ScanRequest request;
  request.radius = number_arg(args, "radius").value_or(64);
  if (!(request.radius > 0 && request.radius <= 256)) throw ArgError("radius must be in 0..256 tiles");
  request.limit = 20000;
  auto x = coordinate_arg(args, "x");
  auto y = coordinate_arg(args, "y");
  if (x && y) request.center = game::MapPosition::from_tiles(*x, *y);
  else {
    auto position = engine_.player_state(source).position;
    if (!position) throw Failure("no_position", "the player has no position");
    request.center = *position;
  }
  const Json* types = args.find("types");
  std::vector<std::string> wanted = {"assembling-machine", "furnace", "mining-drill", "lab", "boiler", "generator",
                                     "reactor", "rocket-silo", "offshore-pump", "ammo-turret", "electric-turret"};
  if (types && types->is_array()) {
    wanted.clear();
    for (const auto& type : types->as_array()) wanted.push_back(type.as_string());
  }
  request.types = wanted;
  auto found = engine_.scan(source, request);
  if (!found) throw Failure("no_surface", "the player is not on a surface");
  std::map<std::string, std::map<std::string, int64_t>> counts;  // "name recipe" -> status -> count
  Json::Array idle;
  size_t idle_limit = static_cast<size_t>(integer_arg(args, "limit", 40, 0, 1000));
  for (const auto& entity : found->entities) {
    game::EntityDetails details = engine_.details(entity.entity);
    std::string key(entity.name);
    if (details.recipe) if (auto recipe = engine_.recipes().name(*details.recipe)) key += " (" + std::string(*recipe) + ")";
    std::string status(details.status ? game::entity_status_name(details.status) : "none");
    ++counts[key][status];
    if (status != "working" && status != "normal" && status != "none" && idle.size() < idle_limit) {
      idle.push_back(Json(Json::Object{{"name", key}, {"status", status},
                                       {"position", Json(Json::Object{{"x", entity.position.tile_x()}, {"y", entity.position.tile_y()}})}}));
    }
  }
  Json::Object summary;
  for (auto& [key, statuses] : counts) {
    Json::Object by_status;
    for (auto& [status, count] : statuses) by_status[status] = count;
    summary[key] = Json(std::move(by_status));
  }
  return Json(Json::Object{{"center", Json(Json::Object{{"x", request.center.tile_x()}, {"y", request.center.tile_y()}})},
                           {"radius", request.radius}, {"entities", static_cast<uint64_t>(found->entities.size())},
                           {"truncated", found->truncated}, {"by_machine", Json(std::move(summary))}, {"not_working", Json(std::move(idle))}});
}

Json Bridge::prototypes(const Json& args) const {
  std::string kind = string_arg(args, "kind").value_or("recipe");
  const game::PrototypeTable* table = kind == "recipe" ? &engine_.recipes() : kind == "item" ? &engine_.items()
                                    : kind == "entity" ? &engine_.entities() : kind == "quality" ? &engine_.qualities() : nullptr;
  if (!table) throw ArgError("kind must be recipe, item, entity, or quality");
  Json::Array names;
  for (auto& prototype : table->all()) names.push_back(Json(prototype.name));
  return Json(std::move(names));
}

Json Bridge::scan(const Json& args, void* source, double default_radius, int64_t default_limit) const {
  game::ScanRequest request;
  request.radius = number_arg(args, "radius").value_or(default_radius);
  if (!(request.radius >= 0 && request.radius <= 256)) throw ArgError("radius must be in 0..256 tiles");
  request.limit = static_cast<size_t>(integer_arg(args, "limit", default_limit, 1, 5000));
  auto strings = [&](const char* key) {
    std::vector<std::string> values;
    const Json* list = args.find(key);
    if (!list || list->is_null()) return values;
    if (list->is_string()) return std::vector<std::string>{list->as_string()};
    if (!list->is_array()) throw ArgError(std::string(key) + " must be a string or an array of strings");
    for (const Json& item : list->as_array()) {
      if (!item.is_string()) throw ArgError(std::string(key) + " must contain strings");
      values.push_back(item.as_string());
    }
    return values;
  };
  request.names = strings("names");
  request.types = strings("types");
  auto x = coordinate_arg(args, "x");
  auto y = coordinate_arg(args, "y");
  if (x.has_value() != y.has_value()) throw ArgError("give both x and y, or neither to scan around the player");
  if (x) request.center = game::MapPosition::from_tiles(*x, *y);
  else {
    auto position = engine_.player_state(source).position;
    if (!position) throw Failure("no_position", "the player has no position to scan around");
    request.center = *position;
  }
  auto result = engine_.scan(source, request);
  if (!result) throw Failure("no_surface", "the player is not on a surface");
  Json::Array entities;
  for (const auto& entity : result->entities) {
    Json::Object item{{"name", entity.name}, {"type", entity.type},
                      {"position", Json(Json::Object{{"x", entity.position.tile_x()}, {"y", entity.position.tile_y()}})}};
    if (entity.amount) item["amount"] = *entity.amount;
    else item["direction"] = entity.direction;
    entities.push_back(Json(std::move(item)));
  }
  return Json(Json::Object{{"center", Json(Json::Object{{"x", request.center.tile_x()}, {"y", request.center.tile_y()}})},
                           {"radius", request.radius}, {"entities", Json(std::move(entities))}, {"truncated", result->truncated}});
}

Json Bridge::raw(const Json& args, void* source) {
  uint16_t type;
  if (auto name = string_arg(args, "type")) {
    auto found = engine_.action_type(*name);
    if (!found) throw ArgError("unknown action type " + *name);
    type = *found;
  } else {
    type = static_cast<uint16_t>(integer_arg(args, "type", 0, 1, game::kActionTypeCount - 1));
  }
  InputAction action(static_cast<ActionType>(type));
  std::string error;
  if (!engine_.load_payload(action, unhex(string_arg(args, "payload").value_or("")), &error)) throw ArgError(error);
  std::string name = engine_.action_name(type);
  submit(source, action, name.c_str());
  return Json(Json::Object{{"type", type}, {"name", name}});
}

Json Bridge::peek(const Json& args) const {
  // Developer-only memory inspection for mapping engine layouts.
  auto address = string_arg(args, "address");
  if (!address) throw ArgError("peek needs a hex address");
  uintptr_t base = std::strtoull(address->c_str(), nullptr, 16);
  int64_t length = integer_arg(args, "length", 64, 1, 4096);
  return Json(Json::Object{{"address", *address}, {"bytes", hex(reinterpret_cast<const void*>(base), static_cast<size_t>(length))}});
}

void Bridge::release(void* self, uint64_t tick) {
  // Only the local player's source holds our inputs.
  if (self != source_.load(std::memory_order_relaxed) || !game::read<void*>(self, game::layout::kInputSourcePlayer)) return;
  if (!walking_.active && !path_.active && !mining_.active && !building_.active) return;
  try {
    stop(self);
  } catch (...) {
  }
  end_controls("reloaded", tick);
}

// C entry points for the loader. None of them may unwind.

void c_on_flush(void* state, void* self, uint64_t tick, const FhRequest* requests, size_t count) {
  try {
    static_cast<Bridge*>(state)->on_flush(self, tick, requests, count);
  } catch (...) {
  }
}

int c_arbitrate(void* state, void* self, void* action) {
  try {
    auto result = static_cast<Bridge*>(state)->arbitrate(self, static_cast<const InputAction*>(action));
    return result ? (*result ? 1 : 0) : -1;
  } catch (...) {
    return -1;
  }
}

char* c_immediate(void* state, const char* json, size_t length) {
  try {
    Json message = Json::parse(std::string_view(json, length));
    Request request;
    if (const Json* id = message.find("id")) request.id = *id;
    if (const Json* action = message.find("action"); action && action->is_string()) request.action = action->as_string();
    const Json* args = message.find("args");
    request.args = args && args->is_object() ? *args : Json(Json::Object{});
    auto answer = static_cast<Bridge*>(state)->immediate(request);
    if (!answer) return nullptr;
    return ::strdup(answer->dump().c_str());
  } catch (...) {
    return nullptr;
  }
}

void c_free_string(char* text) { std::free(text); }

void c_release(void* state, void* self, uint64_t tick) {
  try {
    static_cast<Bridge*>(state)->release(self, tick);
  } catch (...) {
  }
}

void c_destroy(void* state) { delete static_cast<Bridge*>(state); }

}  // namespace fh

extern "C" __attribute__((visibility("default"))) int fh_logic_create(const FhHost* host, FhLogic* logic, char* error,
                                                                       size_t error_size) {
  auto fail = [&](const std::string& message) {
    std::snprintf(error, error_size, "%s", message.c_str());
    return -1;
  };
  if (!host || host->api_version != FH_LOGIC_API_VERSION) return fail("logic API version mismatch");
  try {
    auto bridge = std::make_unique<fh::Bridge>(*host);
    if (std::string reason = bridge->activate(); !reason.empty()) return fail(reason);
    *logic = FhLogic{bridge.release(), &fh::c_on_flush, &fh::c_arbitrate, &fh::c_immediate, &fh::c_free_string, &fh::c_release,
                     &fh::c_destroy};
    return 0;
  } catch (const std::exception& failure) {
    return fail(failure.what());
  }
}
