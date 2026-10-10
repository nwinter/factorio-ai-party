# Builds the client bridge: a stable loader preloaded into Factorio with
# LD_PRELOAD, and the logic library it hot-swaps (bridge_reload).
CXX ?= g++
CXXFLAGS ?= -O2 -g
CXXFLAGS += -std=c++20 -fPIC -fvisibility=hidden -fvisibility-inlines-hidden -Wall -Wextra -Wpedantic
LDFLAGS += -shared -static-libstdc++ -static-libgcc -Wl,--exclude-libs,ALL -Wl,-z,defs -pthread

BUILD := ../dist/bridge
LOADER_SOURCES := src/loader.cpp src/server.cpp src/image.cpp src/json.cpp
LOGIC_SOURCES := src/logic.cpp src/game.cpp src/image.cpp src/json.cpp
HEADERS := $(wildcard src/*.hpp src/*.h)

all: $(BUILD)/libfh-bridge.so $(BUILD)/libfh-logic.so

$(BUILD)/libfh-bridge.so: $(LOADER_SOURCES:src/%.cpp=$(BUILD)/%.o) exports.map
	$(CXX) $(LDFLAGS) -Wl,--version-script=exports.map -o $@ $(filter %.o,$^) -ldl

$(BUILD)/libfh-logic.so: $(LOGIC_SOURCES:src/%.cpp=$(BUILD)/%.o) logic-exports.map
	$(CXX) $(LDFLAGS) -Wl,--version-script=logic-exports.map -o $@.tmp $(filter %.o,$^)
	mv -f $@.tmp $@  # atomic: a running loader may copy it at any moment

$(BUILD)/%.o: src/%.cpp $(HEADERS) | $(BUILD)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(BUILD):
	mkdir -p $@

$(BUILD)/unit_test: tests/unit_test.cpp src/json.cpp $(HEADERS) | $(BUILD)
	$(CXX) $(CXXFLAGS) -fsanitize=address,undefined -o $@ tests/unit_test.cpp src/json.cpp

test: $(BUILD)/unit_test
	$(BUILD)/unit_test

clean:
	rm -rf $(BUILD)

.PHONY: all clean test
