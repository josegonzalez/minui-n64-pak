CC       = $(CROSS_COMPILE)gcc
# INI_MAX_LINE=1024: mupen64plus.cfg has comment lines >200 chars (inih default)
# INI_ALLOW_INLINE_COMMENTS=0: prevent semicolons in values being treated as comments
DEFINES  = -DINI_MAX_LINE=1024 -DINI_ALLOW_INLINE_COMMENTS=0
CFLAGS   = -Os -s -Wl,--gc-sections -I./lib $(DEFINES)
CFLAGS_NATIVE = -Os -I./lib $(DEFINES)
TARGET   = ini
SOURCES  = ini.c lib/ini.c
PRODUCT  = build/$(TARGET)

all:
	mkdir -p build
	$(CC) $(SOURCES) -o $(PRODUCT) $(CFLAGS)

# Build and test natively (for CI / local dev)
test: build-native
	./test.sh

build-native:
	mkdir -p build
	$(CC) $(SOURCES) -o $(PRODUCT) $(CFLAGS_NATIVE)

clean:
	rm -rf build
