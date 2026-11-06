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

CC ?= cc
CFLAGS := -O3 -fPIC -fvisibility=hidden -Wall -Wextra
TARGET := libfast_math.$(EXT)

.PHONY: all clean

all: $(TARGET)

$(TARGET): fast_math.c ; $(CC) $(CFLAGS) $(LDFLAGS) fast_math.c -o $(TARGET) && strip $(STRIP_FLAGS) $(TARGET)

clean: ; rm -f *.so *.dylib *.o