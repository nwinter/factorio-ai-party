// Host-side unit tests for the bridge pieces that do not need a running game.
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <string>

#include "../src/json.hpp"
#include "../src/stream.hpp"

namespace {

int failures = 0;

void check(bool condition, const char* expression, int line) {
  if (condition) return;
  std::fprintf(stderr, "unit_test.cpp:%d: check failed: %s\n", line, expression);
  ++failures;
}
#define CHECK(expression) check((expression), #expression, __LINE__)

bool throws(const std::function<void()>& body) {
  try { body(); } catch (const fh::ArgError&) { return true; }
  return false;
}

void json_round_trips_protocol_values() {
  auto value = fh::Json::parse(R"({"id":"a\"b","action":"walk","args":{"x":-1.5,"ticks":60,"names":["coal","\u00e9"],"flag":true,"none":null}})");
  CHECK(value.find("id")->as_string() == "a\"b");
  const fh::Json& args = *value.find("args");
  CHECK(args.find("x")->as_number() == -1.5);
  CHECK(args.find("names")->as_array()[1].as_string() == "\xc3\xa9");
  CHECK(args.find("none")->is_null());
  CHECK(fh::Json::parse(value.dump()).dump() == value.dump());
  CHECK(fh::Json(fh::Json::Object{{"n", 3}, {"s", "line\nbreak"}}).dump() == R"({"n":3,"s":"line\nbreak"})");
  CHECK(fh::Json(static_cast<uint64_t>(1) << 52).dump() == "4503599627370496");
  CHECK(fh::Json::parse(R"("\ud83c\udfed")").as_string() == "\xf0\x9f\x8f\xad");
}

void json_rejects_malformed_input() {
  for (const char* bad : {"", "{", "{\"a\":}", "[1,]", "tru", "\"unterminated", "{\"a\":1} x", "\"\\ud800\"", "1e999", "\"\x01\"",
                          "{\"a\" 1}", "nan"}) {
    CHECK(throws([&] { fh::Json::parse(bad); }));
  }
  std::string deep(100, '[');
  CHECK(throws([&] { fh::Json::parse(deep); }));
}

void typed_arguments_validate_ranges() {
  auto args = fh::Json::parse(R"({"ticks":60,"fraction":1.5,"name":"coal","negative":-1})");
  CHECK(fh::integer_arg(args, "ticks", 1, 1, 100) == 60);
  CHECK(fh::integer_arg(args, "missing", 7, 1, 100) == 7);
  CHECK(throws([&] { fh::integer_arg(args, "fraction", 1, 1, 100); }));
  CHECK(throws([&] { fh::integer_arg(args, "negative", 1, 0, 100); }));
  CHECK(throws([&] { fh::number_arg(args, "name"); }));
  CHECK(fh::string_arg(args, "name") == "coal");
  CHECK(!fh::string_arg(args, "missing"));
}

void read_stream_never_short_reads() {
  fh::game::BufferReadStream stream(std::string("\x01\x02\x03", 3));
  char out[4] = {9, 9, 9, 9};
  CHECK(stream.read(out, 2) == 2 && out[0] == 1 && out[1] == 2);
  CHECK(!stream.overrun() && stream.remaining() == 1 && !stream.eof());
  // Engine loaders throw on short reads; the stream pads and records instead.
  CHECK(stream.read(out, 4) == 4 && out[0] == 3 && out[1] == 0 && out[3] == 0);
  CHECK(stream.overrun() && stream.eof());
}

void deserialiser_never_owns_our_stream() {
  fh::game::Deserialiser deserialiser;
  CHECK(deserialiser.owns_stream != 0);  // 0 would make engine code delete it
}

}  // namespace

int main() {
  json_round_trips_protocol_values();
  json_rejects_malformed_input();
  typed_arguments_validate_ranges();
  read_stream_never_short_reads();
  deserialiser_never_owns_our_stream();
  if (failures) {
    std::fprintf(stderr, "%d check(s) failed\n", failures);
    return EXIT_FAILURE;
  }
  std::puts("bridge unit tests passed");
  return EXIT_SUCCESS;
}
