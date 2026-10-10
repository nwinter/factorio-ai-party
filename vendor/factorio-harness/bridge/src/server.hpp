// Unix-socket JSON-lines server. Requests are parsed on the server thread and
// handed to the game thread, which replies through reply().
#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include <sys/types.h>
#include <vector>

#include "json.hpp"

namespace fh {

struct Request {
  uint64_t connection = 0;
  Json id;
  std::string action;
  Json args;
  std::string line;  // the request as received
  std::chrono::steady_clock::time_point received;
};

class Server {
 public:
  // Answers requests that must not wait for the game thread (e.g. bridge status);
  // returns nullopt to queue the request for the game thread instead, or a
  // null Json when it took the request and will reply() later itself.
  using Immediate = std::function<std::optional<Json>(const Request&)>;

  Server() = default;
  ~Server();
  Server(const Server&) = delete;
  Server& operator=(const Server&) = delete;

  bool start(const std::string& path, Immediate immediate, std::chrono::milliseconds queue_timeout, std::string* error);
  void stop();

  // Game thread: take every pending request.
  std::vector<Request> take();
  // Any thread: send one reply line to a connection (dropped if it has closed).
  void reply(uint64_t connection, const Json& message);
  // Same, for an already serialised JSON line (without newline).
  void reply_raw(uint64_t connection, std::string line);

 private:
  struct Connection {
    int fd = -1;
    std::string input;
    std::string output;
    size_t pending = 0;       // requests accepted but not yet answered
    bool read_closed = false;  // peer finished sending; flush answers, then close
  };

  void run();
  void wake();
  void handle_line(uint64_t id, const std::string& line);
  void expire_stale();

  std::string path_;
  dev_t socket_device_ = 0;  // identity of the socket file we created
  ino_t socket_inode_ = 0;
  Immediate immediate_;
  std::chrono::milliseconds queue_timeout_{0};
  int listen_fd_ = -1;
  int wake_fds_[2] = {-1, -1};
  std::atomic<bool> stopping_{false};
  std::thread thread_;

  std::mutex mutex_;  // guards queue_ and outbox_
  std::deque<Request> queue_;
  std::vector<std::pair<uint64_t, std::string>> outbox_;

  // Server thread only.
  std::map<uint64_t, Connection> connections_;
  uint64_t next_connection_ = 1;
};

}  // namespace fh
