// The running Factorio executable: load bias, build identity, local symbols.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace fh {

class Image {
 public:
  // Inspects the main executable of this process. Never throws; check ok().
  static Image inspect_self(const std::vector<std::string_view>& wanted_symbols);

  bool ok() const { return error_.empty(); }
  const std::string& error() const { return error_; }
  const std::string& build_id() const { return build_id_; }
  uintptr_t bias() const { return bias_; }

  // Runtime address of a resolved symbol (mangled name), or 0.
  uintptr_t address(std::string_view mangled) const;

  template <typename T>
  T* pointer(std::string_view mangled) const { return reinterpret_cast<T*>(address(mangled)); }

 private:
  std::string error_;
  std::string build_id_;
  uintptr_t bias_ = 0;
  std::unordered_map<std::string, uintptr_t> symbols_;
};

// Replaces one pointer-sized slot in read-only relocated data (a vtable) and
// returns the previous value. Restores the page protection afterwards.
bool patch_pointer(void** slot, void* replacement, void** previous);

}  // namespace fh
