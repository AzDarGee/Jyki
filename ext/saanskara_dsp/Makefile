UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    EXT := dylib
    LDFLAGS := -dynamiclib -Wl,-install_name,@rpath/libfast_math.dylib
    STRIP_FLAGS := -x
else
    EXT := so
    LDFLAGS := -shared
    STRIP_FLAGS := --strip-unneeded
endif

ifeq ($(origin CC),default)
    CC := $(shell if [ -x /opt/homebrew/opt/llvm/bin/clang ]; then echo /opt/homebrew/opt/llvm/bin/clang; elif [ -x /usr/local/opt/llvm/bin/clang ]; then echo /usr/local/opt/llvm/bin/clang; else echo cc; fi)
endif
C_STD := $(shell if echo 'int main(void){return 0;}' | $(CC) -std=c23 -x c - -o /dev/null >/dev/null 2>&1; then echo -std=c23; else echo -std=c2x; fi)
CFLAGS := $(C_STD) -O3 -ffast-math -fPIC -fvisibility=hidden -Wall -Wextra
TARGET := libfast_math.$(EXT)

.PHONY: all clean

all: $(TARGET)

$(TARGET): fast_math.c Makefile ; $(CC) $(CFLAGS) $(LDFLAGS) fast_math.c -o $(TARGET) && strip $(STRIP_FLAGS) $(TARGET)

clean: ; rm -f *.so *.dylib *.o