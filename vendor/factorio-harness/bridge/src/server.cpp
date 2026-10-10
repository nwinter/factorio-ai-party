#include "server.hpp"

#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>

namespace fh {
namespace {

constexpr size_t kMaxLine = 1 << 20;
constexpr size_t kMaxConnections = 8;
constexpr size_t kMaxQueued = 256;

Json error_reply(const Json& id, const char* code, const std::string& message) {
  return Json(Json::Object{{"id", id}, {"ok", false}, {"error", Json(Json::Object{{"code", code}, {"message", message}})}});
}

}  // namespace

Server::~Server() { stop(); }

bool Server::start(const std::string& path, Immediate immediate, std::chrono::milliseconds queue_timeout, std::string* error) {
  immediate_ = std::move(immediate);
  queue_timeout_ = queue_timeout;
  sockaddr_un address{};
  if (path.empty() || path.size() >= sizeof address.sun_path) { *error = "socket path is empty or too long"; return false; }
  struct stat existing {};
  if (::lstat(path.c_str(), &existing) == 0) {
    // Only replace a stale socket; never delete another kind of file.
    if (!S_ISSOCK(existing.st_mode) || existing.st_uid != ::getuid()) { *error = "socket path exists and is not our socket"; return false; }
    ::unlink(path.c_str());
  }
  listen_fd_ = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
  if (listen_fd_ < 0) { *error = std::strerror(errno); return false; }
  address.sun_family = AF_UNIX;
  std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
  mode_t previous = ::umask(077);
  int bound = ::bind(listen_fd_, reinterpret_cast<sockaddr*>(&address), sizeof address);
  ::umask(previous);
  if (bound != 0 || ::listen(listen_fd_, 4) != 0 || ::pipe2(wake_fds_, O_CLOEXEC | O_NONBLOCK) != 0) {
    *error = std::strerror(errno);
    ::close(listen_fd_);
    listen_fd_ = -1;
    return false;
  }
  path_ = path;
  struct stat created {};
  if (::stat(path.c_str(), &created) == 0) { socket_device_ = created.st_dev; socket_inode_ = created.st_ino; }
  thread_ = std::thread([this] { run(); });
  return true;
}

void Server::stop() {
  if (!thread_.joinable()) return;
  {
    // reply() checks stopping_ under this lock, so no write can race the close.
    std::lock_guard lock(mutex_);
    stopping_ = true;
  }
  char byte = 1;
  [[maybe_unused]] ssize_t ignored = ::write(wake_fds_[1], &byte, 1);
  thread_.join();
  for (auto& [id, connection] : connections_) ::close(connection.fd);
  connections_.clear();
  std::lock_guard lock(mutex_);
  ::close(listen_fd_);
  ::close(wake_fds_[0]);
  ::close(wake_fds_[1]);
  listen_fd_ = wake_fds_[0] = wake_fds_[1] = -1;
  // A newer process may already own this path; only remove our own socket.
  struct stat current {};
  if (::lstat(path_.c_str(), &current) == 0 && current.st_dev == socket_device_ && current.st_ino == socket_inode_) ::unlink(path_.c_str());
}

void Server::wake() {
  char byte = 1;
  // A full pipe already guarantees a pending wakeup.
  [[maybe_unused]] ssize_t ignored = ::write(wake_fds_[1], &byte, 1);
}

std::vector<Request> Server::take() {
  std::lock_guard lock(mutex_);
  std::vector<Request> taken(std::make_move_iterator(queue_.begin()), std::make_move_iterator(queue_.end()));
  queue_.clear();
  return taken;
}

void Server::reply(uint64_t connection, const Json& message) { reply_raw(connection, message.dump()); }

void Server::reply_raw(uint64_t connection, std::string line) {
  line += '\n';
  std::lock_guard lock(mutex_);
  if (stopping_) return;  // shutting down at process exit
  outbox_.emplace_back(connection, std::move(line));
  wake();
}

void Server::handle_line(uint64_t connection, const std::string& line) {
  Request request;
  request.connection = connection;
  request.received = std::chrono::steady_clock::now();
  request.line = line;
  try {
    Json message = Json::parse(line);
    if (!message.is_object()) throw ArgError("request must be a JSON object");
    if (const Json* id = message.find("id")) {
      if (!id->is_string() && !id->is_null()) throw ArgError("id must be a string");
      request.id = *id;
    }
    const Json* action = message.find("action");
    if (!action || !action->is_string()) throw ArgError("action must be a string");
    request.action = action->as_string();
    const Json* args = message.find("args");
    if (args && !args->is_null() && !args->is_object()) throw ArgError("args must be an object");
    request.args = args && args->is_object() ? *args : Json(Json::Object{});
  } catch (const std::exception& failure) {
    reply(connection, error_reply(request.id, "bad_request", failure.what()));
    return;
  }
  if (auto answer = immediate_(request)) {
    if (!answer->is_null()) reply(connection, *answer);
    return;  // a null answer: the handler replies later
  }
  std::lock_guard lock(mutex_);
  if (queue_.size() >= kMaxQueued) {
    outbox_.emplace_back(connection, error_reply(request.id, "busy", "too many queued requests").dump() + "\n");
    return;
  }
  queue_.push_back(std::move(request));
}

void Server::expire_stale() {
  auto now = std::chrono::steady_clock::now();
  std::lock_guard lock(mutex_);
  while (!queue_.empty() && now - queue_.front().received > queue_timeout_) {
    // Never executed: the game thread takes the whole queue atomically.
    outbox_.emplace_back(queue_.front().connection,
                         error_reply(queue_.front().id, "game_not_running",
                                     "the game did not process input in time (not in a running multiplayer game?); the request was not executed")
                                 .dump() + "\n");
    queue_.pop_front();
  }
}

void Server::run() {
  std::vector<pollfd> fds;
  std::vector<uint64_t> ids;
  while (!stopping_) {
    {
      std::lock_guard lock(mutex_);
      for (auto& [id, text] : outbox_) {
        auto it = connections_.find(id);
        if (it == connections_.end()) continue;
        it->second.output += text;
        if (it->second.pending) --it->second.pending;
      }
      outbox_.clear();
    }
    fds.clear();
    ids.clear();
    fds.push_back({wake_fds_[0], POLLIN, 0});
    fds.push_back({listen_fd_, static_cast<short>(connections_.size() < kMaxConnections ? POLLIN : 0), 0});
    for (auto& [id, connection] : connections_) {
      short events = static_cast<short>((connection.read_closed ? 0 : POLLIN) | (connection.output.empty() ? 0 : POLLOUT));
      fds.push_back({connection.fd, events, 0});
      ids.push_back(id);
    }
    if (::poll(fds.data(), fds.size(), 100) < 0 && errno != EINTR) break;
    expire_stale();
    if (fds[0].revents & POLLIN) {
      char buffer[64];
      while (::read(wake_fds_[0], buffer, sizeof buffer) > 0) {}
    }
    if (fds[1].revents & POLLIN) {
      int fd = ::accept4(listen_fd_, nullptr, nullptr, SOCK_CLOEXEC | SOCK_NONBLOCK);
      if (fd >= 0) connections_[next_connection_++].fd = fd;
    }
    for (size_t i = 0; i < ids.size(); ++i) {
      auto it = connections_.find(ids[i]);
      if (it == connections_.end()) continue;
      Connection& connection = it->second;
      bool closed = (fds[i + 2].revents & (POLLERR | POLLNVAL)) != 0;
      if (!closed && (fds[i + 2].revents & (POLLIN | POLLHUP))) {
        char buffer[65536];
        ssize_t count = ::read(connection.fd, buffer, sizeof buffer);
        if (count > 0) {
          connection.input.append(buffer, static_cast<size_t>(count));
          size_t newline;
          while ((newline = connection.input.find('\n')) != std::string::npos) {
            std::string line = connection.input.substr(0, newline);
            connection.input.erase(0, newline + 1);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (line.empty()) continue;
            ++connection.pending;
            handle_line(ids[i], line);
          }
          if (connection.input.size() > kMaxLine) closed = true;
        } else if (count == 0) {
          connection.read_closed = true;
          // A full hang-up (not a half-close) cannot receive replies, and poll
          // would report it forever: stop now.
          if (fds[i + 2].revents & POLLHUP) closed = true;
        } else if (errno != EAGAIN && errno != EINTR) {
          closed = true;
        }
      }
      if (!closed && !connection.output.empty()) {
        ssize_t count = ::send(connection.fd, connection.output.data(), connection.output.size(), MSG_NOSIGNAL);
        if (count > 0) connection.output.erase(0, static_cast<size_t>(count));
        else if (count < 0 && errno != EAGAIN && errno != EINTR) closed = true;
      }
      if (connection.read_closed && connection.pending == 0 && connection.output.empty()) closed = true;
      if (closed) {
        ::close(connection.fd);
        connections_.erase(it);
      }
    }
  }
}

}  // namespace fh
