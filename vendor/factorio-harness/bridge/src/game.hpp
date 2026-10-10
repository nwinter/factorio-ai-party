// Factorio engine structures used by the bridge. Everything here was derived
// from one pinned executable build (see kSupportedBuilds in game.cpp); other
// builds keep the bridge inert rather than guessing at layouts.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "image.hpp"

namespace fh::game {

// InputActionType values (from the engine's own name table).
enum class ActionType : uint16_t {
  Nothing = 0,
  StopWalking = 1,
  BeginMining = 2,
  StopMining = 3,
  SelectedEntityCleared = 10,
  ClearCursor = 11,
  Build = 66,
  StartWalking = 67,
  CursorTransfer = 76,
  FastEntityTransfer = 264,
  RotateEntity = 265,
  Craft = 83,
  WriteToConsole = 104,
  SelectedEntityChanged = 87,
};
constexpr size_t kActionTypeCount = 0x150;

// Fixed-point map coordinates: 1/256 tile.
struct MapPosition {
  int32_t x = 0;
  int32_t y = 0;
  double tile_x() const { return x / 256.0; }
  double tile_y() const { return y / 256.0; }
  static MapPosition from_tiles(double x, double y);
};

// sizeof(InputAction) == 0x80; payload union starts at +0x10.
struct alignas(16) InputAction {
  uint64_t tick = 0;
  uint16_t type = 0;
  uint16_t player_index = 0xffff;
  uint32_t padding = 0;
  unsigned char data[0x70] = {};

  explicit InputAction(ActionType kind) : type(static_cast<uint16_t>(kind)) {}
  template <typename T>
  void set(size_t offset, T value) { std::memcpy(data + offset, &value, sizeof value); }
};
static_assert(sizeof(InputAction) == 0x80);
static_assert(offsetof(InputAction, data) == 0x10);

struct PrototypeRef {
  uint16_t id = 0;
  std::string name;
};

// PrototypeList<T>::indexToPrototype: a std::vector<T*> indexed by ID.
class PrototypeTable {
 public:
  PrototypeTable() = default;
  explicit PrototypeTable(const void* vector) : vector_(static_cast<const void* const*>(vector)) {}

  std::vector<PrototypeRef> all() const;
  std::optional<std::string_view> name(uint16_t id) const;
  std::optional<uint16_t> id(std::string_view name) const;

 private:
  const void* const* begin() const { return static_cast<const void* const*>(vector_[0]); }
  const void* const* end() const { return static_cast<const void* const*>(vector_[1]); }
  const void* const* vector_ = nullptr;
};

struct ItemCount {
  uint16_t item = 0;
  uint8_t quality = 0;
  uint64_t count = 0;
};

struct StackRef {
  uint16_t slot = 0;
  uint16_t item = 0;
  uint8_t quality = 0;
  uint32_t count = 0;
};

struct CraftingEntry {
  uint16_t recipe = 0;
  uint32_t count = 0;
};

struct EntityRef {
  uint16_t prototype = 0;  // EntityPrototype ID
  std::string name;
  MapPosition position;
};

struct ScannedEntity {
  const void* entity = nullptr;
  std::string_view name;
  std::string_view type;
  MapPosition position;
  std::optional<uint32_t> amount;  // resources only
  uint8_t direction = 0;
};

struct ScanRequest {
  MapPosition center;
  double radius = 16;  // tiles
  size_t limit = 500;
  std::vector<std::string> names;  // empty: any
  std::vector<std::string> types;  // empty: any
};

struct ScanResult {
  std::vector<ScannedEntity> entities;  // nearest first
  bool truncated = false;
};

struct EntityDetails {
  uint8_t direction = 0;            // 16-way: north 0, east 4, south 8, west 12
  uint8_t status = 0;               // defines.entity_status value, 0 = none
  std::vector<std::vector<ItemCount>> belt_lines;  // transport belts: items per lane on this tile
  std::vector<std::pair<uint16_t, double>> fluids;  // fluid prototype ID, amount
  std::optional<uint16_t> recipe;   // crafting machines
  std::vector<std::pair<uint8_t, std::vector<ItemCount>>> inventories;  // by inventory index
};

// defines.entity_status names by value (from LuaDefines::pushEntityStatus).
std::string_view entity_status_name(uint8_t status);

enum class ControllerKind { None, Character, Remote, God, Spectator, Editor, Cutscene, Other };

// A consistent read of the local player's state, taken on the game thread.
struct PlayerState {
  uint16_t index = 0;
  uint64_t map_tick = 0;
  ControllerKind controller = ControllerKind::None;
  bool has_character = false;
  std::optional<MapPosition> position;
  std::vector<ItemCount> main_inventory;
  uint16_t main_inventory_slots = 0;
  uint16_t main_inventory_free = 0;
  std::vector<CraftingEntry> crafting_queue;
  bool mining = false;
  std::optional<EntityRef> selected;
  std::optional<ItemCount> cursor;
};

// Resolved engine entry points and globals.
class Engine {
 public:
  static std::vector<std::string_view> required_symbols();
  static bool supported_build(std::string_view build_id);

  bool bind(const Image& image);

  void** player_input_source_vtable() const { return player_input_source_vtable_; }
  // Engine: staging an action through the virtual PlayerInputSource::process
  // (vtable slot) is exactly the GUI path, including permission checks.
  bool submit(void* input_source, InputAction& action) const;

  // Builds an action from its network payload with the engine's own loader.
  // Rejects payloads that are too short or too long for the action type.
  bool load_payload(InputAction& action, const std::string& payload, std::string* error) const;

  std::string action_name(uint16_t type) const;
  std::optional<uint16_t> action_type(std::string_view name) const;

  const PrototypeTable& recipes() const { return recipes_; }
  const PrototypeTable& items() const { return items_; }
  const PrototypeTable& qualities() const { return qualities_; }
  const PrototypeTable& entities() const { return entities_; }
  const PrototypeTable& fluids() const { return fluids_; }

  // Local player reachable from the input source; call on the game thread.
  PlayerState player_state(void* input_source) const;
  EntityRef entity_ref(const void* entity) const;
  EntityDetails details(const void* entity) const;
  bool mining(void* input_source) const;
  // Progress towards the current mining result; changes only while really mining.
  double mining_progress(void* input_source) const;
  std::optional<EntityRef> selected(void* input_source) const;
  // First main-inventory stack of an item (plain items only: no item data).
  std::optional<StackRef> find_stack(void* input_source, uint16_t item, uint8_t quality) const;
  // The simulated (not latency-predicted) walking state of the player.
  bool walking(void* input_source) const;
  // Entities on the player's surface near a point, read without touching the
  // simulation (no chunk creation, no entity flags).
  std::optional<ScanResult> scan(void* input_source, const ScanRequest& request) const;
  // True when this input source feeds the multiplayer connection (not, e.g.,
  // the main menu's background simulation or a replay).
  bool feeds_network(const void* input_source) const;

 private:
  using DestroyValue = void (*)(void* action);
  using Process = bool (*)(void* input_source, void* action);
  using LoadConstruct = void (*)(void* action, void* deserialiser);

  void** player_input_source_vtable_ = nullptr;
  DestroyValue destroy_value_ = nullptr;
  LoadConstruct load_construct_ = nullptr;
  struct WalkingStatus {
    bool walking;
    double x, y;
  };
  // Standard SysV call: the 24-byte result is returned through a hidden pointer.
  using GetWalkingStatus = WalkingStatus (*)(const void* adapter, int type);
  GetWalkingStatus get_walking_status_ = nullptr;
  const char* const* action_names_ = nullptr;
  PrototypeTable recipes_, items_, qualities_, entities_, fluids_;
  uintptr_t character_controller_vtable_ = 0, remote_controller_vtable_ = 0, god_controller_vtable_ = 0;
  uintptr_t network_input_listener_vtable_ = 0;
  uintptr_t spectator_controller_vtable_ = 0, editor_controller_vtable_ = 0, cutscene_controller_vtable_ = 0;
};

// Structure offsets and virtual slots for the pinned build. Factorio's own
// types are absent from its debug info; each group names the engine function
// whose disassembly it was read from. Re-derive them from the same functions
// when porting to another build.
namespace layout {
// PlayerInputSource vtable (from `vtable for PlayerInputSource`); fields from
// PlayerInputSource::process and InputSource::flushActions.
constexpr size_t kVtableProcess = 8;            // process(InputAction&&)
constexpr size_t kVtableFlushActions = 12;      // flushActions(bool, MapTick)
constexpr size_t kInputSourceListeners = 0x20;  // std::vector<InputListener*>
constexpr size_t kInputSourcePlayer = 0xd0;     // Player*

// Player: PlayerInputSource::process, LuaControl::luaReadPosition,
// LuaControl::luaReadCraftingQueueSize, LuaControl::luaReadMiningState.
constexpr size_t kPlayerMap = 0x20;                   // Map*
constexpr size_t kPlayerIndex = 0x28;                 // uint16_t, zero-based
constexpr size_t kPlayerControlAdapter = 0x40;        // embedded ControlAdapter
constexpr size_t kPlayerController = 0x740;           // Controller*: the active one
constexpr size_t kPlayerCharacterController = 0x750;  // CharacterController*, null without a character
constexpr size_t kMapTick = 0x170;                    // uint64_t (PlayerInputSource::process)
// PrototypeBase name: LuaPrototypeTemplate<...>::luaReadName.
constexpr size_t kPrototypeName = 0x08;  // std::string

// Controller virtual slots (byte offsets): `vtable for CharacterController`,
// used as in LuaControl::luaReadPosition, LuaInventory::luaGetContents,
// LuaControl::luaReadCraftingQueue and Controller::getSurface.
constexpr size_t kControllerGetNavigation = 0xd8;  // -> object whose slot 0 returns MapPosition
constexpr size_t kControllerGetSurface = 0xe0;     // -> Surface*
constexpr size_t kControllerGetInventory = 0x1a0;  // (uint8 index) -> Inventory*
constexpr size_t kControllerGetManualCrafter = 0x698;

// ControlAdapter virtual slots and the objects they return:
// LuaControl::luaReadMiningState, luaReadSelected, luaReadCursorStack,
// luaReadWalkingState (WalkingStateLogic::getVehicleOrPlayerWalkingStatus).
constexpr size_t kAdapterGetManualMiner = 0x140;
constexpr size_t kAdapterGetCursorStack = 0x150;  // -> ItemStack*
constexpr size_t kAdapterGetEntitySelector = 0x188;
constexpr int kWalkingStateSimulated = 1;         // WalkingState::Type used by LuaControl::walking_state
constexpr size_t kManualMinerProgress = 0x50;   // double (LuaControl::luaReadCharacterMiningProgress)
constexpr size_t kManualMinerState = 0x58;        // 0 idle; 2 when the mine button is held (CommonInputHandler::beginMining)
constexpr size_t kEntitySelectorSelected = 0x08;  // Entity*

// Entity: LuaEntity::luaReadName, luaReadType, luaReadAmount,
// LuaControl::luaReadPosition (entity branch).
constexpr size_t kEntityPrototype = 0x48;    // EntityPrototype*
constexpr size_t kEntityPosition = 0x50;     // MapPosition
constexpr size_t kEntityAsResource = 0xf90;  // virtual: ResourceEntity* or null
constexpr size_t kResourceAmount = 0x88;     // uint32_t
constexpr size_t kPrototypeTypeName = 0x10;  // virtual: const char*
// Entity virtual slots (vtable for AssemblingMachine; LuaEntity::luaReadStatus, luaGetRecipe).
constexpr size_t kEntityGetInventory = 0x368;      // (uint8 index) -> Inventory*, null if absent
constexpr size_t kEntityGetStatus = 0x650;         // -> uint8 status, 0 = none
constexpr size_t kEntityAsCraftingMachine = 0xbe0;  // -> CraftingMachine* or null
constexpr size_t kEntityAsGhost = 0xc48;           // -> EntityGhost* or null
constexpr size_t kCraftingMachineRecipe = 0x216;   // uint16_t recipe, uint8_t quality at +2
constexpr uint8_t kMaxInventoryIndex = 9;
// Entity::sumCounts(std::map<ID<FluidPrototype>, FixedPoint<long, 24>>&): all fluid in the entity.
constexpr size_t kEntitySumFluids = 0x910;
constexpr double kFluidFixedPointScale = 1.0 / (1 << 24);
constexpr size_t kEntityGetDirection = 0x4d8;           // -> uint8 Direction
// Belts: TransportBeltConnectable (LuaEntity::luaGetTransportLine, LuaTransportLine::luaGetItemCount,
// TransportLine::getItemCount).
constexpr size_t kEntityAsTransportBeltConnectable = 0x1140;  // -> connectable or null
constexpr size_t kConnectableGetTransportLine = 0x1300;       // (uint8 index) -> line view
constexpr size_t kConnectableLineCount = 0x1308;              // getMaxTransportLineIndex: valid indices are 1..max
constexpr size_t kLineViewLine = 0x10;      // TransportLine*
constexpr size_t kLineViewRange = 0x18;     // int32 start, int32 end: this tile's part of the line
constexpr size_t kLineFirstPosition = 0x38;  // int32
constexpr size_t kLineItems = 0x50;          // ring buffer of 0x20-byte items
constexpr size_t kLineItemsCapacity = 0x58;  // uint32
constexpr size_t kLineItemsHead = 0x5c;      // uint32
constexpr size_t kLineItemsCount = 0x60;     // uint32
constexpr size_t kLineItemStride = 0x20;     // { i32 distance; ...; i32 count @8; u16 item @0xc; u8 quality @0xe }

// Chunks: Surface::getChunk, InfiniteVector<Chunk*>::operator[],
// Surface::findAllEntities.
constexpr size_t kSurfaceChunks = 0x18;           // InfiniteVector<InfiniteVector<Chunk*>>, indexed [x][y]
constexpr size_t kInfiniteVectorStride = 0x10;    // { T* data; int32 size; int32 offset }
constexpr int kChunkShift = 13;                   // MapPosition units per chunk: 32 tiles * 256
constexpr size_t kChunkEntityListsBegin = 0xc50;  // 256 singly linked entity lists
constexpr size_t kChunkEntityListsEnd = 0x1450;
constexpr size_t kEntityNodeNext = 0x08;
constexpr size_t kEntityNodeEntity = 0x20;

// Inventories: LuaInventory::luaGetContents, Inventory::sumCounts,
// Controller::sanitizeClientItemStackLocation; crafting queue from
// LuaControl::luaReadCraftingQueue.
constexpr uint8_t kCharacterMainInventory = 1;  // defines.inventory.character_main
constexpr size_t kInventoryStacks = 0x08;       // ItemStack*
constexpr size_t kInventorySize = 0x10;         // uint16_t slot count (+0x16 counts used slots)
constexpr size_t kItemStackStride = 0x18;       // { u32 count; u16 item; u8 quality; ...; ItemData* at +8 }
constexpr size_t kItemStackData = 0x08;         // non-null for items with data (blueprints, armor, ...)
constexpr size_t kManualCrafterQueueBegin = 0x68;  // std::vector<CraftingQueueItem*>
constexpr size_t kCraftingItemRecipe = 0x18;       // uint16_t
constexpr size_t kCraftingItemCount = 0x1c;        // uint32_t
}  // namespace layout

template <typename T>
T read(const void* base, size_t offset) {
  T value;
  std::memcpy(&value, static_cast<const unsigned char*>(base) + offset, sizeof value);
  return value;
}

std::string_view std_string_view(const void* string_object);

}  // namespace fh::game
