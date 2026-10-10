#include "json.hpp"

#include <charconv>
#include <cmath>
#include <cstdio>

namespace fh {
namespace {

constexpr int kMaxDepth = 64;

class Parser {
 public:
  explicit Parser(std::string_view text) : text_(text) {}

  Json document() {
    Json value = parse_value(0);
    skip_space();
    if (pos_ != text_.size()) fail("trailing characters");
    return value;
  }

 private:
  [[noreturn]] void fail(const char* message) const {
    throw ArgError(std::string("invalid JSON at byte ") + std::to_string(pos_) + ": " + message);
  }

  void skip_space() {
    while (pos_ < text_.size() && (text_[pos_] == ' ' || text_[pos_] == '\t' || text_[pos_] == '\n' || text_[pos_] == '\r')) ++pos_;
  }

  bool consume(std::string_view literal) {
    if (text_.substr(pos_, literal.size()) != literal) return false;
    pos_ += literal.size();
    return true;
  }

  Json parse_value(int depth) {
    if (depth > kMaxDepth) fail("nesting too deep");
    skip_space();
    if (pos_ >= text_.size()) fail("unexpected end");
    switch (text_[pos_]) {
      case '{': return parse_object(depth);
      case '[': return parse_array(depth);
      case '"': return Json(parse_string());
      case 't': if (consume("true")) return Json(true); break;
      case 'f': if (consume("false")) return Json(false); break;
      case 'n': if (consume("null")) return Json(nullptr); break;
      default: return parse_number();
    }
    fail("unexpected token");
  }

  Json parse_object(int depth) {
    ++pos_;
    Json::Object object;
    skip_space();
    if (pos_ < text_.size() && text_[pos_] == '}') { ++pos_; return Json(std::move(object)); }
    for (;;) {
      skip_space();
      if (pos_ >= text_.size() || text_[pos_] != '"') fail("expected key");
      std::string key = parse_string();
      skip_space();
      if (pos_ >= text_.size() || text_[pos_] != ':') fail("expected ':'");
      ++pos_;
      object.insert_or_assign(std::move(key), parse_value(depth + 1));
      skip_space();
      if (pos_ < text_.size() && text_[pos_] == ',') { ++pos_; continue; }
      if (pos_ < text_.size() && text_[pos_] == '}') { ++pos_; return Json(std::move(object)); }
      fail("expected ',' or '}'");
    }
  }

  Json parse_array(int depth) {
    ++pos_;
    Json::Array array;
    skip_space();
    if (pos_ < text_.size() && text_[pos_] == ']') { ++pos_; return Json(std::move(array)); }
    for (;;) {
      array.push_back(parse_value(depth + 1));
      skip_space();
      if (pos_ < text_.size() && text_[pos_] == ',') { ++pos_; continue; }
      if (pos_ < text_.size() && text_[pos_] == ']') { ++pos_; return Json(std::move(array)); }
      fail("expected ',' or ']'");
    }
  }

  unsigned hex4() {
    if (pos_ + 4 > text_.size()) fail("short unicode escape");
    unsigned value = 0;
    for (int i = 0; i < 4; ++i) {
      char c = text_[pos_++];
      value <<= 4;
      if (c >= '0' && c <= '9') value |= c - '0';
      else if (c >= 'a' && c <= 'f') value |= c - 'a' + 10;
      else if (c >= 'A' && c <= 'F') value |= c - 'A' + 10;
      else fail("bad unicode escape");
    }
    return value;
  }

  static void append_utf8(std::string& out, unsigned cp) {
    if (cp < 0x80) out += static_cast<char>(cp);
    else if (cp < 0x800) { out += static_cast<char>(0xC0 | (cp >> 6)); out += static_cast<char>(0x80 | (cp & 0x3F)); }
    else if (cp < 0x10000) {
      out += static_cast<char>(0xE0 | (cp >> 12)); out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
      out += static_cast<char>(0x80 | (cp & 0x3F));
    } else {
      out += static_cast<char>(0xF0 | (cp >> 18)); out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
      out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F)); out += static_cast<char>(0x80 | (cp & 0x3F));
    }
  }

  std::string parse_string() {
    ++pos_;
    std::string out;
    while (pos_ < text_.size()) {
      char c = text_[pos_++];
      if (c == '"') return out;
      if (static_cast<unsigned char>(c) < 0x20) fail("control character in string");
      if (c != '\\') { out += c; continue; }
      if (pos_ >= text_.size()) break;
      switch (text_[pos_++]) {
        case '"': out += '"'; break;
        case '\\': out += '\\'; break;
        case '/': out += '/'; break;
        case 'b': out += '\b'; break;
        case 'f': out += '\f'; break;
        case 'n': out += '\n'; break;
        case 'r': out += '\r'; break;
        case 't': out += '\t'; break;
        case 'u': {
          unsigned cp = hex4();
          if (cp >= 0xD800 && cp < 0xDC00) {
            if (!consume("\\u")) fail("unpaired surrogate");
            unsigned low = hex4();
            if (low < 0xDC00 || low >= 0xE000) fail("unpaired surrogate");
            cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
          } else if (cp >= 0xDC00 && cp < 0xE000) {
            fail("unpaired surrogate");
          }
          append_utf8(out, cp);
          break;
        }
        default: fail("bad escape");
      }
    }
    fail("unterminated string");
  }

  Json parse_number() {
    size_t start = pos_;
    if (pos_ < text_.size() && text_[pos_] == '-') ++pos_;
    if (pos_ >= text_.size() || !(text_[pos_] >= '0' && text_[pos_] <= '9')) fail("unexpected token");
    while (pos_ < text_.size() && ((text_[pos_] >= '0' && text_[pos_] <= '9') || text_[pos_] == '.' ||
                                   text_[pos_] == 'e' || text_[pos_] == 'E' || text_[pos_] == '+' || text_[pos_] == '-')) ++pos_;
    // from_chars ignores the process locale (which the game may set).
    std::string_view token = text_.substr(start, pos_ - start);
    double value = 0;
    auto [end, error] = std::from_chars(token.data(), token.data() + token.size(), value);
    if (error != std::errc() || end != token.data() + token.size() || !std::isfinite(value)) fail("bad number");
    return Json(value);
  }

  std::string_view text_;
  size_t pos_ = 0;
};

void dump_string(std::string& out, const std::string& value) {
  out += '"';
  for (unsigned char c : value) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buffer[8];
          std::snprintf(buffer, sizeof buffer, "\\u%04x", c);
          out += buffer;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  out += '"';
}

}  // namespace

Json Json::parse(std::string_view text) { return Parser(text).document(); }

bool Json::as_bool() const {
  if (!is_bool()) throw ArgError("expected boolean");
  return std::get<bool>(value_);
}
double Json::as_number() const {
  if (!is_number()) throw ArgError("expected number");
  return std::get<double>(value_);
}
const std::string& Json::as_string() const {
  if (!is_string()) throw ArgError("expected string");
  return std::get<std::string>(value_);
}
const Json::Array& Json::as_array() const {
  if (!is_array()) throw ArgError("expected array");
  return *std::get<std::shared_ptr<Array>>(value_);
}
const Json::Object& Json::as_object() const {
  if (!is_object()) throw ArgError("expected object");
  return *std::get<std::shared_ptr<Object>>(value_);
}

const Json* Json::find(std::string_view key) const {
  if (!is_object()) return nullptr;
  const auto& object = *std::get<std::shared_ptr<Object>>(value_);
  auto it = object.find(key);
  return it == object.end() ? nullptr : &it->second;
}

std::string Json::dump() const {
  std::string out;
  dump_to(out);
  return out;
}

void Json::dump_to(std::string& out) const {
  if (is_null()) out += "null";
  else if (is_bool()) out += std::get<bool>(value_) ? "true" : "false";
  else if (is_number()) {
    double value = std::get<double>(value_);
    if (!std::isfinite(value)) { out += "null"; return; }
    // Shortest round-trip form, independent of the process locale.
    char buffer[32];
    auto [end, error] = std::to_chars(buffer, buffer + sizeof buffer, value);
    out.append(buffer, error == std::errc() ? end : buffer);
  } else if (is_string()) dump_string(out, std::get<std::string>(value_));
  else if (is_array()) {
    out += '[';
    bool first = true;
    for (const auto& item : as_array()) {
      if (!first) out += ',';
      first = false;
      item.dump_to(out);
    }
    out += ']';
  } else {
    out += '{';
    bool first = true;
    for (const auto& [key, item] : as_object()) {
      if (!first) out += ',';
      first = false;
      dump_string(out, key);
      out += ':';
      item.dump_to(out);
    }
    out += '}';
  }
}

std::optional<double> number_arg(const Json& args, std::string_view key) {
  const Json* value = args.find(key);
  if (!value || value->is_null()) return std::nullopt;
  if (!value->is_number()) throw ArgError(std::string(key) + " must be a number");
  return value->as_number();
}

std::optional<std::string> string_arg(const Json& args, std::string_view key) {
  const Json* value = args.find(key);
  if (!value || value->is_null()) return std::nullopt;
  if (!value->is_string()) throw ArgError(std::string(key) + " must be a string");
  return value->as_string();
}

std::optional<bool> bool_arg(const Json& args, std::string_view key) {
  const Json* value = args.find(key);
  if (!value || value->is_null()) return std::nullopt;
  if (!value->is_bool()) throw ArgError(std::string(key) + " must be a boolean");
  return value->as_bool();
}

std::optional<double> coordinate_arg(const Json& args, std::string_view key) {
  auto value = number_arg(args, key);
  // MapPosition is int32 in 1/256 tiles; Factorio maps end at +-1,000,000 tiles.
  if (value && std::fabs(*value) > 1'000'000) throw ArgError(std::string(key) + " must be within +-1000000 tiles");
  return value;
}

int64_t integer_arg(const Json& args, std::string_view key, int64_t fallback, int64_t min, int64_t max) {
  auto value = number_arg(args, key);
  if (!value) return fallback;
  if (*value != std::floor(*value) || *value < static_cast<double>(min) || *value > static_cast<double>(max)) {
    throw ArgError(std::string(key) + " must be an integer in " + std::to_string(min) + ".." + std::to_string(max));
  }
  return static_cast<int64_t>(*value);
}

}  // namespace fh
