// A ReadStream and Deserialiser compatible with the engine's, so its own
// loaders can construct InputAction payloads from the network wire format.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

namespace fh::game {

// Matches the engine's ReadStream vtable (Itanium ABI): two destructor slots,
// then read, readByte, eof, remaining. The engine only calls it virtually.
class BufferReadStream {
 public:
  explicit BufferReadStream(std::string bytes) : bytes_(std::move(bytes)) {}
  virtual ~BufferReadStream() = default;

  // Short reads make the engine throw across our frames. Instead, pad with
  // zeros and remember the overrun so the caller can reject the payload.
  virtual size_t read(char* out, size_t size) {
    size_t available = bytes_.size() - position_;
    size_t copied = size < available ? size : available;
    std::memcpy(out, bytes_.data() + position_, copied);
    std::memset(out + copied, 0, size - copied);
    position_ += copied;
    if (copied < size) overrun_ = true;
    return size;
  }
  virtual bool readByte(char* out) { return read(out, 1) == 1; }
  virtual bool eof() const { return position_ == bytes_.size(); }
  virtual size_t remaining() const { return bytes_.size() - position_; }

  bool overrun() const { return overrun_; }

 private:
  std::string bytes_;
  size_t position_ = 0;
  bool overrun_ = false;
};

// Engine Deserialiser: { ownership (0 = owns stream), ReadStream*, flag }.
struct Deserialiser {
  uint32_t owns_stream = 1;  // never let engine code delete our stream
  uint32_t padding = 0;
  BufferReadStream* stream = nullptr;
  uint8_t flag = 0;
  unsigned char reserved[7] = {};
};
static_assert(sizeof(Deserialiser) == 0x18);
static_assert(offsetof(Deserialiser, stream) == 8);

}  // namespace fh::game
