// Factorio executables whose engine layouts the bridge was derived from.
#pragma once

#include <array>
#include <string_view>

namespace fh {

// Factorio 2.0.77, Linux x64 Steam build.
inline constexpr std::array<std::string_view, 1> kSupportedBuilds = {"3d00bbaf7a9327409d801c9db540573578334fb1"};

inline bool supported_build(std::string_view build_id) {
  for (auto supported : kSupportedBuilds) if (supported == build_id) return true;
  return false;
}

}  // namespace fh
