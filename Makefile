APP      := UsageQ
VERSION  := 1.2.0
BUILD    := build
BUNDLE   := $(BUILD)/$(APP).app
ICON     := resources/$(APP).icns
PREFIX   ?= /Applications
BINDIR   ?= $(HOME)/.local/bin
MINOS    := 27.0

CXX      := clang++
# Apple silicon only.
FLAGS    := -arch arm64 -mcpu=apple-m1 -mmacosx-version-min=$(MINOS) -DUQ_VERSION='"$(VERSION)"'
CXXFLAGS := -std=c++20 -Os -Wall -Wextra -Wno-unused-parameter -fvisibility=hidden $(FLAGS)
OBJCXX   := -fobjc-arc
LDFLAGS  := -arch arm64 -mmacosx-version-min=$(MINOS) -Wl,-dead_strip

CORE     := $(wildcard src/core/*.cpp)
CORE_OBJ := $(CORE:src/%.cpp=$(BUILD)/obj/%.o)
HEADERS  := $(wildcard src/core/*.hpp)

.PHONY: all app cli dev test leakcheck clicktest icon install uninstall run clean

all: app cli

app: $(BUNDLE)
cli: $(BUILD)/usageq

# The Makefile is a prerequisite so a new VERSION or new flags rebuild everything.
$(BUILD)/obj/%.o: src/%.cpp $(HEADERS) Makefile
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD)/obj/app/main.o: src/app/main.mm $(HEADERS) Makefile
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(OBJCXX) -c $< -o $@

$(BUILD)/usageq: $(CORE_OBJ) $(BUILD)/obj/cli/main.o
	$(CXX) $(LDFLAGS) $^ -o $@
	strip -x $@

$(BUNDLE): $(CORE_OBJ) $(BUILD)/obj/app/main.o $(BUILD)/usageq Info.plist resources/InfoPlist.strings $(ICON)
	@rm -rf $@
	@mkdir -p $@/Contents/MacOS $@/Contents/Helpers $@/Contents/Resources/en.lproj
	$(CXX) $(LDFLAGS) $(CORE_OBJ) $(BUILD)/obj/app/main.o -framework AppKit -framework ServiceManagement -framework UserNotifications \
		-o $@/Contents/MacOS/$(APP)
	strip -x $@/Contents/MacOS/$(APP)
	cp $(BUILD)/usageq $@/Contents/Helpers/usageq
	sed 's/__VERSION__/$(VERSION)/g' Info.plist > $@/Contents/Info.plist
	cp resources/InfoPlist.strings $@/Contents/Resources/en.lproj/InfoPlist.strings
	cp $(ICON) $@/Contents/Resources/$(APP).icns
	printf 'APPL????' > $@/Contents/PkgInfo
	codesign --force --sign - $@/Contents/Helpers/usageq
	codesign --force --sign - $@

# Unit tests for the core, built with AddressSanitizer and UBSan.
test: $(BUILD)/tests
	@$(BUILD)/tests

$(BUILD)/tests: tests/core_tests.cpp $(CORE) $(HEADERS)
	@mkdir -p $(BUILD)
	$(CXX) -std=c++20 -O1 -g -Wall -Wextra -Wno-unused-parameter $(FLAGS) -fsanitize=address,undefined \
		-fno-omit-frame-pointer tests/core_tests.cpp $(CORE) -o $@

# Dev build: debuggable, with test hooks (--soak N, --click-test, --notify-test, --render out.png [--dark]).
DEV := $(BUILD)/dev/$(APP).app
dev: $(CORE_OBJ) $(BUILD)/usageq src/app/main.mm Info.plist dev.entitlements $(ICON)
	@mkdir -p $(DEV)/Contents/MacOS $(DEV)/Contents/Resources
	cp $(ICON) $(DEV)/Contents/Resources/$(APP).icns
	$(CXX) $(CXXFLAGS) $(OBJCXX) -DUQ_DEV -c src/app/main.mm -o $(BUILD)/dev/main.o
	$(CXX) $(LDFLAGS) $(CORE_OBJ) $(BUILD)/dev/main.o -framework AppKit -framework ServiceManagement -framework UserNotifications \
		-o $(DEV)/Contents/MacOS/$(APP)
	sed 's/__VERSION__/$(VERSION)-dev/g' Info.plist > $(DEV)/Contents/Info.plist
	codesign --force --sign - --entitlements dev.entitlements $(DEV)
	cp $(BUILD)/usageq $(BUILD)/dev/usageq
	codesign --force --sign - --entitlements dev.entitlements $(BUILD)/dev/usageq

# Leak check: the CLI once, then the app through 100 cycles of hover and Settings on demo numbers
# (no API calls, so the usage endpoint's rate limit is never hit). Quits a running UsageQ.
# The app run always lists 417 objects (26 KB) from AppIntents' NSXPCConnection, which an empty
# AppKit app reports too, so its exit status is ignored.
leakcheck: dev
	@pkill -x $(APP) 2>/dev/null; sleep 1; true
	MallocStackLogging=1 leaks --atExit -- $(BUILD)/dev/usageq
	-MallocStackLogging=1 leaks --atExit -- $(DEV)/Contents/MacOS/$(APP) --soak 100 --demo

# Click test: opens the menu on demo data and uses the card (Settings, typing in Notify at, a refresh
# interval, Done, hover), then checks that the power button and ⌘Q quit. Quits a running UsageQ.
clicktest: dev
	@pkill -x $(APP) 2>/dev/null; sleep 1; true
	$(DEV)/Contents/MacOS/$(APP) --click-test
	$(DEV)/Contents/MacOS/$(APP) --click-test quit && echo "pass  the power button quits"
	$(DEV)/Contents/MacOS/$(APP) --click-test cmdq && echo "pass  ⌘Q quits"

# Redraws the app icon (resources/UsageQ.icns) from tools/icon.cpp.
icon: tools/icon.cpp
	@rm -rf $(BUILD)/icon.iconset && mkdir -p $(BUILD)/icon.iconset
	$(CXX) $(FLAGS) -std=c++20 -O2 $< -o $(BUILD)/icon -framework CoreGraphics -framework ImageIO -framework CoreFoundation
	@$(BUILD)/icon $(BUILD)/icon.iconset
	@iconutil -c icns $(BUILD)/icon.iconset -o $(ICON)
	@echo "Wrote $(ICON)"

install: app
	@pkill -x $(APP) 2>/dev/null; sleep 0.5; true
	rm -rf "$(PREFIX)/$(APP).app"
	ditto $(BUNDLE) "$(PREFIX)/$(APP).app"
	@mkdir -p "$(BINDIR)"
	ln -sf "$(PREFIX)/$(APP).app/Contents/Helpers/usageq" "$(BINDIR)/usageq"
	open "$(PREFIX)/$(APP).app"
	@echo "Installed $(PREFIX)/$(APP).app and $(BINDIR)/usageq"

uninstall:
	@pkill -x $(APP) 2>/dev/null; true
	rm -rf "$(PREFIX)/$(APP).app" "$(BINDIR)/usageq"

run: app
	@pkill -x $(APP) 2>/dev/null; sleep 0.3; true
	open $(BUNDLE)

clean:
	rm -rf $(BUILD)
