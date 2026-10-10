#include "image.hpp"

#include <elf.h>
#include <fcntl.h>
#include <link.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstring>
#include <unordered_set>

namespace fh {
namespace {

struct MainObject {
  uintptr_t bias = 0;
  const ElfW(Phdr)* phdr = nullptr;
  int phnum = 0;
  bool found = false;
};

int find_main(dl_phdr_info* info, size_t, void* data) {
  auto* main = static_cast<MainObject*>(data);
  // The first entry is always the main program, whose name is empty.
  main->bias = info->dlpi_addr;
  main->phdr = info->dlpi_phdr;
  main->phnum = info->dlpi_phnum;
  main->found = true;
  return 1;
}

std::string read_build_id(const MainObject& main) {
  for (int i = 0; i < main.phnum; ++i) {
    const ElfW(Phdr)& header = main.phdr[i];
    if (header.p_type != PT_NOTE) continue;
    auto* cursor = reinterpret_cast<const unsigned char*>(main.bias + header.p_vaddr);
    const unsigned char* end = cursor + header.p_memsz;
    while (cursor + sizeof(ElfW(Nhdr)) <= end) {
      auto* note = reinterpret_cast<const ElfW(Nhdr)*>(cursor);
      const unsigned char* name = cursor + sizeof(ElfW(Nhdr));
      const unsigned char* desc = name + ((note->n_namesz + 3) & ~3u);
      if (note->n_type == NT_GNU_BUILD_ID && note->n_namesz == 4 && std::memcmp(name, "GNU", 4) == 0) {
        static const char digits[] = "0123456789abcdef";
        std::string id;
        for (unsigned j = 0; j < note->n_descsz; ++j) {
          id += digits[desc[j] >> 4];
          id += digits[desc[j] & 15];
        }
        return id;
      }
      cursor = desc + ((note->n_descsz + 3) & ~3u);
    }
  }
  return {};
}

class MappedFile {
 public:
  explicit MappedFile(const char* path) {
    int fd = ::open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    struct stat info {};
    if (::fstat(fd, &info) == 0 && info.st_size > 0) {
      void* data = ::mmap(nullptr, static_cast<size_t>(info.st_size), PROT_READ, MAP_PRIVATE, fd, 0);
      if (data != MAP_FAILED) { data_ = static_cast<const unsigned char*>(data); size_ = static_cast<size_t>(info.st_size); }
    }
    ::close(fd);
  }
  ~MappedFile() { if (data_) ::munmap(const_cast<unsigned char*>(data_), size_); }
  MappedFile(const MappedFile&) = delete;
  MappedFile& operator=(const MappedFile&) = delete;

  const unsigned char* data() const { return data_; }
  size_t size() const { return size_; }
  bool contains(size_t offset, size_t length) const { return data_ && offset <= size_ && length <= size_ - offset; }

 private:
  const unsigned char* data_ = nullptr;
  size_t size_ = 0;
};

}  // namespace

Image Image::inspect_self(const std::vector<std::string_view>& wanted_symbols) {
  Image image;
  MainObject main;
  dl_iterate_phdr(find_main, &main);
  if (!main.found) { image.error_ = "main executable not found"; return image; }
  image.bias_ = main.bias;
  image.build_id_ = read_build_id(main);

  // Factorio's functions are local symbols: only .symtab has them, and it is
  // not mapped at runtime, so read it from the executable file.
  MappedFile file("/proc/self/exe");
  if (!file.data() || !file.contains(0, sizeof(ElfW(Ehdr)))) { image.error_ = "cannot map /proc/self/exe"; return image; }
  auto* header = reinterpret_cast<const ElfW(Ehdr)*>(file.data());
  if (std::memcmp(header->e_ident, ELFMAG, SELFMAG) != 0 || header->e_ident[EI_CLASS] != ELFCLASS64 ||
      header->e_shentsize != sizeof(ElfW(Shdr)) ||
      !file.contains(header->e_shoff, static_cast<size_t>(header->e_shnum) * sizeof(ElfW(Shdr)))) {
    image.error_ = "unexpected executable format";
    return image;
  }
  auto* sections = reinterpret_cast<const ElfW(Shdr)*>(file.data() + header->e_shoff);
  std::unordered_set<std::string_view> wanted(wanted_symbols.begin(), wanted_symbols.end());
  for (unsigned i = 0; i < header->e_shnum; ++i) {
    const ElfW(Shdr)& table = sections[i];
    if (table.sh_type != SHT_SYMTAB || table.sh_link >= header->e_shnum || table.sh_entsize != sizeof(ElfW(Sym))) continue;
    const ElfW(Shdr)& strings = sections[table.sh_link];
    if (!file.contains(table.sh_offset, table.sh_size) || !file.contains(strings.sh_offset, strings.sh_size)) continue;
    auto* symbols = reinterpret_cast<const ElfW(Sym)*>(file.data() + table.sh_offset);
    const char* names = reinterpret_cast<const char*>(file.data() + strings.sh_offset);
    size_t count = table.sh_size / sizeof(ElfW(Sym));
    for (size_t j = 0; j < count; ++j) {
      const ElfW(Sym)& symbol = symbols[j];
      if (symbol.st_name >= strings.sh_size || symbol.st_value == 0) continue;
      const char* name = names + symbol.st_name;
      size_t length = strnlen(name, strings.sh_size - symbol.st_name);
      std::string_view view(name, length);
      if (wanted.count(view)) image.symbols_.emplace(std::string(view), main.bias + symbol.st_value);
    }
  }
  for (std::string_view name : wanted_symbols) {
    if (!image.symbols_.count(std::string(name))) {
      image.error_ = "missing symbol " + std::string(name);
      break;
    }
  }
  return image;
}

uintptr_t Image::address(std::string_view mangled) const {
  auto it = symbols_.find(std::string(mangled));
  return it == symbols_.end() ? 0 : it->second;
}

bool patch_pointer(void** slot, void* replacement, void** previous) {
  long page = sysconf(_SC_PAGESIZE);
  auto start = reinterpret_cast<uintptr_t>(slot) & ~static_cast<uintptr_t>(page - 1);
  auto end = (reinterpret_cast<uintptr_t>(slot + 1) + page - 1) & ~static_cast<uintptr_t>(page - 1);
  // Vtables live in RELRO, which is read-only after relocation.
  if (::mprotect(reinterpret_cast<void*>(start), end - start, PROT_READ | PROT_WRITE) != 0) return false;
  if (previous) *previous = __atomic_load_n(slot, __ATOMIC_ACQUIRE);
  __atomic_store_n(slot, replacement, __ATOMIC_RELEASE);
  return ::mprotect(reinterpret_cast<void*>(start), end - start, PROT_READ) == 0;
}

}  // namespace fh
