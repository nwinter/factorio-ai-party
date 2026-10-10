#include "game.hpp"

#include "builds.hpp"
#include "stream.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <map>
#include <unordered_set>

namespace fh::game {
namespace {


constexpr std::string_view kPlayerInputSourceVtable = "_ZTV17PlayerInputSource";
constexpr std::string_view kDestroyValue = "_ZN11InputAction12destroyValueEv";
constexpr std::string_view kLoadConstruct = "_ZN11InputAction23loadConstructActionDataER12Deserialiser";
constexpr std::string_view kInputActionStr = "_ZNK11InputAction3strB5cxx11Ev";
constexpr std::string_view kRecipeList = "_ZN13PrototypeListI15RecipePrototypeE16indexToPrototypeE";
constexpr std::string_view kItemList = "_ZN13PrototypeListI13ItemPrototypeE16indexToPrototypeE";
constexpr std::string_view kQualityList = "_ZN13PrototypeListI16QualityPrototypeE16indexToPrototypeE";
constexpr std::string_view kEntityList = "_ZN13PrototypeListI15EntityPrototypeE16indexToPrototypeE";
constexpr std::string_view kFluidList = "_ZN13PrototypeListI14FluidPrototypeE16indexToPrototypeE";
constexpr std::string_view kGetWalkingStatus = "_ZN17WalkingStateLogic31getVehicleOrPlayerWalkingStatusERK11GameAdapterN12WalkingState4TypeE";
constexpr std::string_view kNetworkInputListenerVtable = "_ZTV20NetworkInputListener";
constexpr std::string_view kCharacterControllerVtable = "_ZTV19CharacterController";
constexpr std::string_view kRemoteControllerVtable = "_ZTV16RemoteController";
constexpr std::string_view kGodControllerVtable = "_ZTV13GodController";
constexpr std::string_view kSpectatorControllerVtable = "_ZTV19SpectatorController";
constexpr std::string_view kEditorControllerVtable = "_ZTV16EditorController";
constexpr std::string_view kCutsceneControllerVtable = "_ZTV18CutsceneController";

template <typename Result, typename... Args>
Result virtual_call(const void* object, size_t slot_offset, Args... args) {
  auto* vtable = read<const unsigned char*>(object, 0);
  auto function = read<Result (*)(const void*, Args...)>(vtable, slot_offset);
  return function(object, args...);
}

// InputAction::str() indexes this pointer table by type; its address is the
// rip-relative operand of the `lea` at this offset inside the function.
constexpr size_t kActionNameLeaOffset = 0x34;

}  // namespace

MapPosition MapPosition::from_tiles(double x, double y) {
  return {static_cast<int32_t>(std::lround(x * 256.0)), static_cast<int32_t>(std::lround(y * 256.0))};
}

std::string_view std_string_view(const void* string_object) {
  // libstdc++ std::string: { char* data; size_t size; ... }
  return {read<const char*>(string_object, 0), read<size_t>(string_object, 8)};
}

std::vector<std::string_view> Engine::required_symbols() {
  return {kPlayerInputSourceVtable, kDestroyValue, kLoadConstruct, kInputActionStr, kRecipeList, kItemList, kQualityList, kEntityList, kFluidList,
          kCharacterControllerVtable, kRemoteControllerVtable, kGodControllerVtable, kSpectatorControllerVtable,
          kEditorControllerVtable, kCutsceneControllerVtable, kNetworkInputListenerVtable, kGetWalkingStatus};
}

bool Engine::supported_build(std::string_view build_id) { return fh::supported_build(build_id); }

bool Engine::bind(const Image& image) {
  // A vtable symbol points at offset-to-top; virtual slots start two words later.
  player_input_source_vtable_ = image.pointer<void*>(kPlayerInputSourceVtable) + 2;
  destroy_value_ = reinterpret_cast<DestroyValue>(image.address(kDestroyValue));
  load_construct_ = reinterpret_cast<LoadConstruct>(image.address(kLoadConstruct));
  get_walking_status_ = reinterpret_cast<GetWalkingStatus>(image.address(kGetWalkingStatus));
  recipes_ = PrototypeTable(image.pointer<const void>(kRecipeList));
  items_ = PrototypeTable(image.pointer<const void>(kItemList));
  qualities_ = PrototypeTable(image.pointer<const void>(kQualityList));
  entities_ = PrototypeTable(image.pointer<const void>(kEntityList));
  fluids_ = PrototypeTable(image.pointer<const void>(kFluidList));
  // An object's vtable pointer addresses the first slot, two words in.
  auto slots = [&](std::string_view symbol) { return image.address(symbol) + 2 * sizeof(void*); };
  character_controller_vtable_ = slots(kCharacterControllerVtable);
  remote_controller_vtable_ = slots(kRemoteControllerVtable);
  god_controller_vtable_ = slots(kGodControllerVtable);
  spectator_controller_vtable_ = slots(kSpectatorControllerVtable);
  editor_controller_vtable_ = slots(kEditorControllerVtable);
  cutscene_controller_vtable_ = slots(kCutsceneControllerVtable);
  network_input_listener_vtable_ = slots(kNetworkInputListenerVtable);

  auto* lea = image.pointer<const unsigned char>(kInputActionStr) + kActionNameLeaOffset;
  // lea rax, [rip+disp32] == 48 8d 05 disp32
  if (lea[0] != 0x48 || lea[1] != 0x8d || lea[2] != 0x05) return false;
  int32_t displacement;
  std::memcpy(&displacement, lea + 3, sizeof displacement);
  action_names_ = reinterpret_cast<const char* const*>(lea + 7 + displacement);
  return player_input_source_vtable_ && destroy_value_ && load_construct_;
}

bool Engine::submit(void* input_source, InputAction& action) const {
  void** vtable = *static_cast<void***>(input_source);
  auto process = reinterpret_cast<Process>(vtable[layout::kVtableProcess]);
  bool accepted = process(input_source, &action);
  // process() moved the payload out; the moved-from action still owns storage.
  destroy_value_(&action);
  return accepted;
}

bool Engine::load_payload(InputAction& action, const std::string& payload, std::string* error) const {
  BufferReadStream stream(payload);
  Deserialiser deserialiser;
  deserialiser.stream = &stream;
  load_construct_(&action, &deserialiser);
  if (!stream.overrun() && stream.remaining() == 0) return true;
  destroy_value_(&action);
  action.type = static_cast<uint16_t>(ActionType::Nothing);
  *error = stream.overrun() ? "payload is shorter than the action requires" : "payload has trailing bytes";
  return false;
}

std::optional<uint16_t> Engine::action_type(std::string_view name) const {
  for (uint16_t type = 0; type < kActionTypeCount && action_names_; ++type) {
    if (name == action_names_[type]) return type;
  }
  return std::nullopt;
}

std::string Engine::action_name(uint16_t type) const {
  if (type >= kActionTypeCount || !action_names_) return "Unknown" + std::to_string(type);
  return action_names_[type];
}

std::vector<PrototypeRef> PrototypeTable::all() const {
  std::vector<PrototypeRef> result;
  for (auto* it = begin(); it != end(); ++it) {
    if (*it) result.push_back({static_cast<uint16_t>(it - begin()), std::string(std_string_view(static_cast<const char*>(*it) + layout::kPrototypeName))});
  }
  return result;
}

std::optional<std::string_view> PrototypeTable::name(uint16_t id) const {
  if (id >= end() - begin() || !begin()[id]) return std::nullopt;
  return std_string_view(static_cast<const char*>(begin()[id]) + layout::kPrototypeName);
}

std::optional<uint16_t> PrototypeTable::id(std::string_view name) const {
  for (auto* it = begin(); it != end(); ++it) {
    if (*it && std_string_view(static_cast<const char*>(*it) + layout::kPrototypeName) == name) return static_cast<uint16_t>(it - begin());
  }
  return std::nullopt;
}

bool Engine::feeds_network(const void* input_source) const {
  auto* begin = read<const void* const*>(input_source, layout::kInputSourceListeners);
  auto* end = read<const void* const*>(input_source, layout::kInputSourceListeners + 8);
  for (auto* it = begin; it != end; ++it) {
    if (*it && read<uintptr_t>(*it, 0) == network_input_listener_vtable_) return true;
  }
  return false;
}

namespace {

// InfiniteVector<T>: element i lives at data[i + offset] for -offset <= i < size - offset.
const void* infinite_vector_at(const void* vector, int index, size_t stride) {
  auto* data = read<const unsigned char*>(vector, 0);
  int32_t size = read<int32_t>(vector, 8);
  int32_t offset = read<int32_t>(vector, 12);
  if (!data || index < -offset || index >= size - offset) return nullptr;
  return data + static_cast<size_t>(index + offset) * stride;
}

}  // namespace

std::optional<ScanResult> Engine::scan(void* input_source, const ScanRequest& request) const {
  void* player = read<void*>(input_source, layout::kInputSourcePlayer);
  const void* controller = read<const void*>(player, layout::kPlayerController);
  if (!controller) return std::nullopt;
  const void* surface = virtual_call<const void*>(controller, layout::kControllerGetSurface);
  if (!surface) return std::nullopt;

  const int64_t radius = static_cast<int64_t>(std::ceil(request.radius * 256.0));
  auto chunk_of = [](int64_t coordinate) { return static_cast<int>(coordinate >> layout::kChunkShift); };
  const auto* columns = static_cast<const char*>(surface) + layout::kSurfaceChunks;
  std::unordered_set<const void*> seen;
  std::vector<std::pair<double, ScannedEntity>> found;
  for (int cx = chunk_of(request.center.x - radius); cx <= chunk_of(request.center.x + radius); ++cx) {
    const void* column = infinite_vector_at(columns, cx, layout::kInfiniteVectorStride);
    if (!column) continue;
    for (int cy = chunk_of(request.center.y - radius); cy <= chunk_of(request.center.y + radius); ++cy) {
      const void* slot = infinite_vector_at(column, cy, sizeof(void*));
      const void* chunk = slot ? read<const void*>(slot, 0) : nullptr;
      if (!chunk) continue;
      for (size_t list = layout::kChunkEntityListsBegin; list < layout::kChunkEntityListsEnd; list += sizeof(void*)) {
        for (const void* node = read<const void*>(chunk, list); node; node = read<const void*>(node, layout::kEntityNodeNext)) {
          const void* entity = read<const void*>(node, layout::kEntityNodeEntity);
          // Large entities are linked from several lists.
          if (!entity || !seen.insert(entity).second) continue;
          uint64_t packed = read<uint64_t>(entity, layout::kEntityPosition);
          MapPosition position{static_cast<int32_t>(packed & 0xffffffff), static_cast<int32_t>(packed >> 32)};
          double dx = (position.x - request.center.x) / 256.0, dy = (position.y - request.center.y) / 256.0;
          double distance = std::hypot(dx, dy);
          if (distance > request.radius) continue;
          const void* prototype = read<const void*>(entity, layout::kEntityPrototype);
          ScannedEntity scanned{entity, std_string_view(static_cast<const char*>(prototype) + layout::kPrototypeName),
                                virtual_call<const char*>(prototype, layout::kPrototypeTypeName), position, std::nullopt};
          auto listed = [](const std::vector<std::string>& filter, std::string_view value) {
            return filter.empty() || std::find(filter.begin(), filter.end(), value) != filter.end();
          };
          if (!listed(request.names, scanned.name) || !listed(request.types, scanned.type)) continue;
          scanned.direction = virtual_call<uint8_t>(entity, layout::kEntityGetDirection);
          if (const void* resource = virtual_call<const void*>(entity, layout::kEntityAsResource)) {
            scanned.amount = read<uint32_t>(resource, layout::kResourceAmount);
          }
          found.emplace_back(distance, scanned);
        }
      }
    }
  }
  std::sort(found.begin(), found.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
  ScanResult result;
  result.truncated = found.size() > request.limit;
  if (result.truncated) found.resize(request.limit);
  for (auto& [distance, entity] : found) result.entities.push_back(entity);
  return result;
}

std::optional<StackRef> Engine::find_stack(void* input_source, uint16_t item, uint8_t quality) const {
  void* player = read<void*>(input_source, layout::kInputSourcePlayer);
  void* character = read<void*>(player, layout::kPlayerCharacterController);
  if (!character || read<uintptr_t>(character, 0) != character_controller_vtable_) return std::nullopt;
  const void* inventory = virtual_call<const void*>(character, layout::kControllerGetInventory, layout::kCharacterMainInventory);
  if (!inventory) return std::nullopt;
  auto* stacks = read<const unsigned char*>(inventory, layout::kInventoryStacks);
  uint16_t slots = read<uint16_t>(inventory, layout::kInventorySize);
  for (uint16_t slot = 0; slot < slots; ++slot) {
    const unsigned char* stack = stacks + slot * layout::kItemStackStride;
    if (read<uint16_t>(stack, 4) == item && read<uint8_t>(stack, 6) == quality && !read<const void*>(stack, layout::kItemStackData)) {
      return StackRef{slot, item, quality, read<uint32_t>(stack, 0)};
    }
  }
  return std::nullopt;
}

bool Engine::walking(void* input_source) const {
  void* player = read<void*>(input_source, layout::kInputSourcePlayer);
  return get_walking_status_(static_cast<const char*>(player) + layout::kPlayerControlAdapter, layout::kWalkingStateSimulated).walking;
}

std::optional<EntityRef> Engine::selected(void* input_source) const {
  void* player = read<void*>(input_source, layout::kInputSourcePlayer);
  const void* adapter = static_cast<const char*>(player) + layout::kPlayerControlAdapter;
  const void* selector = virtual_call<const void*>(adapter, layout::kAdapterGetEntitySelector);
  const void* entity = selector ? read<const void*>(selector, layout::kEntitySelectorSelected) : nullptr;
  if (!entity) return std::nullopt;
  return entity_ref(entity);
}

double Engine::mining_progress(void* input_source) const {
  void* player = read<void*>(input_source, layout::kInputSourcePlayer);
  const void* adapter = static_cast<const char*>(player) + layout::kPlayerControlAdapter;
  const void* miner = virtual_call<const void*>(adapter, layout::kAdapterGetManualMiner);
  return miner ? read<double>(miner, layout::kManualMinerProgress) : 0.0;
}

bool Engine::mining(void* input_source) const {
  void* player = read<void*>(input_source, layout::kInputSourcePlayer);
  const void* adapter = static_cast<const char*>(player) + layout::kPlayerControlAdapter;
  const void* miner = virtual_call<const void*>(adapter, layout::kAdapterGetManualMiner);
  return miner && (read<uint64_t>(miner, layout::kManualMinerState) & ~uint64_t{1}) != 0;
}

std::string_view entity_status_name(uint8_t status) {
  static constexpr std::string_view kNames[] = {
      "none", "working", "normal", "ghost", "broken", "not_plugged_in_electric_network", "networks_connected",
      "networks_disconnected", "charging", "discharging", "fully_charged", "turned_off_during_daytime", "cant_divide_segments",
      "not_connected_to_rail", "low_power", "out_of_logistic_network", "waiting_for_plants_to_grow", "no_spot_seedable_by_inputs",
      "no_ingredients", "no_recipe", "no_research_in_progress", "no_minable_resources", "not_connected_to_hub_or_pad",
      "low_input_fluid", "no_input_fluid", "fluid_ingredient_shortage", "item_ingredient_shortage", "full_output",
      "not_enough_space_in_output", "full_burnt_result_output", "missing_required_fluid", "missing_science_packs",
      "waiting_for_source_items", "waiting_for_more_items", "waiting_for_space_in_destination", "preparing_rocket_for_launch",
      "waiting_to_launch_rocket", "waiting_for_space_in_platform_hub", "launching_rocket", "thrust_not_required", "on_the_way",
      "waiting_in_orbit", "waiting_at_stop", "waiting_for_rockets_to_arrive", "not_enough_thrust", "destination_stop_full",
      "no_path", "no_modules_to_transmit", "recharging_after_power_outage", "waiting_for_target_to_be_built",
      "waiting_for_train", "no_ammo", "low_temperature", "no_fuel", "no_power", "disabled_by_control_behavior",
      "closed_by_circuit_network", "opened_by_circuit_network", "frozen", "paused", "disabled_by_script", "disabled",
      "marked_for_deconstruction", "computing_navigation", "no_filter", "pipeline_overextended", "recipe_not_researched",
      "recipe_is_parameter"};
  return status < std::size(kNames) ? kNames[status] : "unknown";
}

namespace {
std::vector<ItemCount> inventory_contents(const void* inventory) {
  std::vector<ItemCount> contents;
  auto* stacks = read<const unsigned char*>(inventory, layout::kInventoryStacks);
  uint16_t slots = read<uint16_t>(inventory, layout::kInventorySize);
  for (uint16_t slot = 0; slot < slots; ++slot) {
    const unsigned char* stack = stacks + slot * layout::kItemStackStride;
    uint16_t item = read<uint16_t>(stack, 4);
    if (!item) continue;
    uint8_t quality = read<uint8_t>(stack, 6);
    uint32_t count = read<uint32_t>(stack, 0);
    auto same = [&](const ItemCount& entry) { return entry.item == item && entry.quality == quality; };
    auto it = std::find_if(contents.begin(), contents.end(), same);
    if (it == contents.end()) contents.push_back({item, quality, count});
    else it->count += count;
  }
  return contents;
}
}  // namespace

namespace {
// Items of one transport line lying on this belt tile's range of it.
std::vector<ItemCount> belt_line_contents(const void* view) {
  std::vector<ItemCount> contents;
  const void* line = read<const void*>(view, layout::kLineViewLine);
  if (!line) return contents;
  int32_t start = read<int32_t>(view, layout::kLineViewRange);
  int32_t end = read<int32_t>(view, layout::kLineViewRange + 4);
  auto* items = read<const unsigned char*>(line, layout::kLineItems);
  uint32_t capacity = read<uint32_t>(line, layout::kLineItemsCapacity);
  uint32_t head = read<uint32_t>(line, layout::kLineItemsHead);
  uint32_t count = read<uint32_t>(line, layout::kLineItemsCount);
  if (!items || count > capacity) return contents;
  int64_t position = read<int32_t>(line, layout::kLineFirstPosition);
  for (uint32_t i = 0; i < count; ++i) {
    uint32_t index = head + i;
    if (index >= capacity) index -= capacity;
    const unsigned char* item = items + static_cast<size_t>(index) * layout::kLineItemStride;
    if (i) position += read<int32_t>(item, 0);
    if (position < start) continue;
    if (position >= end) break;
    uint16_t id = read<uint16_t>(item, 0xc);
    uint8_t quality = read<uint8_t>(item, 0xe);
    uint32_t amount = read<uint32_t>(item, 8);
    auto same = [&](const ItemCount& entry) { return entry.item == id && entry.quality == quality; };
    auto it = std::find_if(contents.begin(), contents.end(), same);
    if (it == contents.end()) contents.push_back({id, quality, amount});
    else it->count += amount;
  }
  return contents;
}
}  // namespace

EntityDetails Engine::details(const void* entity) const {
  EntityDetails details;
  details.direction = virtual_call<uint8_t>(entity, layout::kEntityGetDirection);
  details.status = virtual_call<uint8_t>(entity, layout::kEntityGetStatus);
  {
    // The engine fills a libstdc++ std::map (same node layout as ours); its
    // nodes come from malloc, which our allocator frees.
    std::map<uint16_t, int64_t> fluids;
    virtual_call<void>(entity, layout::kEntitySumFluids, &fluids);
    for (auto [id, amount] : fluids) details.fluids.emplace_back(id, static_cast<double>(amount) * layout::kFluidFixedPointScale);
  }
  if (const void* connectable = virtual_call<const void*>(entity, layout::kEntityAsTransportBeltConnectable)) {
    // Belts have two lanes; undergrounds and splitters more.
    uint8_t lanes = virtual_call<uint8_t>(connectable, layout::kConnectableLineCount);
    // Line indices are 1-based; getTransportLine throws on anything else.
    for (uint8_t lane = 1; lane <= lanes && lane <= 16; ++lane) {
      const void* view = virtual_call<const void*>(connectable, layout::kConnectableGetTransportLine, lane);
      if (!view) break;
      details.belt_lines.push_back(belt_line_contents(view));
    }
  }
  if (!virtual_call<const void*>(entity, layout::kEntityAsGhost)) {
    if (const void* machine = virtual_call<const void*>(entity, layout::kEntityAsCraftingMachine)) {
      if (uint16_t recipe = read<uint16_t>(machine, layout::kCraftingMachineRecipe)) details.recipe = recipe;
    }
    for (uint8_t index = 1; index <= layout::kMaxInventoryIndex; ++index) {
      if (const void* inventory = virtual_call<const void*>(entity, layout::kEntityGetInventory, index)) {
        details.inventories.emplace_back(index, inventory_contents(inventory));
      }
    }
  }
  return details;
}

EntityRef Engine::entity_ref(const void* entity) const {
  EntityRef ref;
  const void* prototype = read<const void*>(entity, layout::kEntityPrototype);
  ref.name = std::string(std_string_view(static_cast<const char*>(prototype) + layout::kPrototypeName));
  ref.prototype = entities_.id(ref.name).value_or(0);
  uint64_t packed = read<uint64_t>(entity, layout::kEntityPosition);
  ref.position = {static_cast<int32_t>(packed & 0xffffffff), static_cast<int32_t>(packed >> 32)};
  return ref;
}

PlayerState Engine::player_state(void* input_source) const {
  PlayerState state;
  void* player = read<void*>(input_source, layout::kInputSourcePlayer);
  state.index = read<uint16_t>(player, layout::kPlayerIndex);
  state.map_tick = read<uint64_t>(read<void*>(player, layout::kPlayerMap), layout::kMapTick);

  if (void* controller = read<void*>(player, layout::kPlayerController)) {
    uintptr_t vtable = read<uintptr_t>(controller, 0);
    state.controller = vtable == character_controller_vtable_   ? ControllerKind::Character
                       : vtable == remote_controller_vtable_    ? ControllerKind::Remote
                       : vtable == god_controller_vtable_       ? ControllerKind::God
                       : vtable == spectator_controller_vtable_ ? ControllerKind::Spectator
                       : vtable == editor_controller_vtable_    ? ControllerKind::Editor
                       : vtable == cutscene_controller_vtable_  ? ControllerKind::Cutscene
                                                                : ControllerKind::Other;
    if (const void* navigation = virtual_call<const void*>(controller, layout::kControllerGetNavigation)) {
      uint64_t packed = virtual_call<uint64_t>(navigation, 0);
      state.position = MapPosition{static_cast<int32_t>(packed & 0xffffffff), static_cast<int32_t>(packed >> 32)};
    }
  }

  const void* adapter = static_cast<const char*>(player) + layout::kPlayerControlAdapter;
  if (const void* miner = virtual_call<const void*>(adapter, layout::kAdapterGetManualMiner)) {
    // Mirrors LuaControl::mining_state: the low bit alone is not "mining".
    state.mining = (read<uint64_t>(miner, layout::kManualMinerState) & ~uint64_t{1}) != 0;
  }
  state.selected = selected(input_source);
  if (const void* cursor = virtual_call<const void*>(adapter, layout::kAdapterGetCursorStack)) {
    if (uint16_t item = read<uint16_t>(cursor, 4)) state.cursor = ItemCount{item, read<uint8_t>(cursor, 6), read<uint32_t>(cursor, 0)};
  }

  void* character = read<void*>(player, layout::kPlayerCharacterController);
  // Only trust the slots below on the exact class they were derived from.
  if (!character || read<uintptr_t>(character, 0) != character_controller_vtable_) return state;
  state.has_character = true;
  if (const void* inventory = virtual_call<const void*>(character, layout::kControllerGetInventory, layout::kCharacterMainInventory)) {
    auto* stacks = read<const unsigned char*>(inventory, layout::kInventoryStacks);
    state.main_inventory_slots = read<uint16_t>(inventory, layout::kInventorySize);
    for (uint16_t slot = 0; slot < state.main_inventory_slots; ++slot) {
      const unsigned char* stack = stacks + slot * layout::kItemStackStride;
      uint16_t item = read<uint16_t>(stack, 4);
      if (!item) { ++state.main_inventory_free; continue; }
      uint8_t quality = read<uint8_t>(stack, 6);
      uint32_t count = read<uint32_t>(stack, 0);
      auto same = [&](const ItemCount& entry) { return entry.item == item && entry.quality == quality; };
      auto it = std::find_if(state.main_inventory.begin(), state.main_inventory.end(), same);
      if (it == state.main_inventory.end()) state.main_inventory.push_back({item, quality, count});
      else it->count += count;
    }
  }
  if (const void* crafter = virtual_call<const void*>(character, layout::kControllerGetManualCrafter)) {
    auto* begin = read<const void* const*>(crafter, layout::kManualCrafterQueueBegin);
    auto* end = read<const void* const*>(crafter, layout::kManualCrafterQueueBegin + 8);
    for (auto* it = begin; it != end; ++it) {
      state.crafting_queue.push_back({read<uint16_t>(*it, layout::kCraftingItemRecipe), read<uint32_t>(*it, layout::kCraftingItemCount)});
    }
  }
  return state;
}

}  // namespace fh::game
