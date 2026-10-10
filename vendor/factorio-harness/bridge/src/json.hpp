// Minimal JSON value, parser, and writer for the bridge's line protocol.
#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

namespace fh {

class Json {
 public:
  using Array = std::vector<Json>;
  using Object = std::map<std::string, Json, std::less<>>;

  Json() = default;
  Json(std::nullptr_t) {}
  Json(bool value) : value_(value) {}
  Json(int value) : value_(static_cast<double>(value)) {}
  Json(unsigned value) : value_(static_cast<double>(value)) {}
  Json(int64_t value) : value_(static_cast<double>(value)) {}
  Json(uint64_t value) : value_(static_cast<double>(value)) {}
  Json(double value) : value_(value) {}
  Json(const char* value) : value_(std::string(value)) {}
  Json(std::string value) : value_(std::move(value)) {}
  Json(std::string_view value) : value_(std::string(value)) {}
  Json(Array value) : value_(std::make_shared<Array>(std::move(value))) {}
  Json(Object value) : value_(std::make_shared<Object>(std::move(value))) {}

  static Json parse(std::string_view text);

  bool is_null() const { return std::holds_alternative<std::monostate>(value_); }
  bool is_bool() const { return std::holds_alternative<bool>(value_); }
  bool is_number() const { return std::holds_alternative<double>(value_); }
  bool is_string() const { return std::holds_alternative<std::string>(value_); }
  bool is_array() const { return std::holds_alternative<std::shared_ptr<Array>>(value_); }
  bool is_object() const { return std::holds_alternative<std::shared_ptr<Object>>(value_); }

  bool as_bool() const;
  double as_number() const;
  const std::string& as_string() const;
  const Array& as_array() const;
  const Object& as_object() const;

  // Object lookup; returns nullptr when absent or when this is not an object.
  const Json* find(std::string_view key) const;

  std::string dump() const;

 private:
  void dump_to(std::string& out) const;
  std::variant<std::monostate, bool, double, std::string, std::shared_ptr<Array>, std::shared_ptr<Object>> value_;
};

// Typed argument access with protocol-level error messages.
class ArgError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

std::optional<double> number_arg(const Json& args, std::string_view key);
std::optional<std::string> string_arg(const Json& args, std::string_view key);
std::optional<bool> bool_arg(const Json& args, std::string_view key);
// A map coordinate in tiles, limited to the engine's fixed-point range.
std::optional<double> coordinate_arg(const Json& args, std::string_view key);
int64_t integer_arg(const Json& args, std::string_view key, int64_t fallback, int64_t min, int64_t max);

}  // namespace fh
