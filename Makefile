JOLT_VERSION := v5.4.0
JOLT_ROOT := third_party/JoltPhysics
JOLT_BUILD := third_party/jolt/build
.PHONY: test textshape-build physics-deps physics-build physics-test clean

TEXTSHAPE_CFLAGS := $(shell pkg-config --cflags harfbuzz freetype2 2>/dev/null)
TEXTSHAPE_LIBS := $(shell pkg-config --libs harfbuzz freetype2 2>/dev/null)

test: textshape-build
	odin test packages/gltf -collection:zelda_engine=$(CURDIR)/packages
	odin test packages/ui -collection:zelda_engine=$(CURDIR)/packages -extra-linker-flags:"$(TEXTSHAPE_LIBS)"

third_party/textshape/textshape.o: third_party/textshape/textshape.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(TEXTSHAPE_CFLAGS) -c $< -o $@

third_party/textshape/libtextshape.a: third_party/textshape/textshape.o
	$(AR) rcs $@ $<

textshape-build: third_party/textshape/libtextshape.a

physics-deps:
	@if test ! -d $(JOLT_ROOT)/.git; then git clone --depth 1 --branch $(JOLT_VERSION) https://github.com/jrouwe/JoltPhysics.git $(JOLT_ROOT); fi

physics-build: physics-deps
	cmake -S third_party/jolt -B $(JOLT_BUILD) -DCMAKE_BUILD_TYPE=Release
	cmake --build $(JOLT_BUILD) --target zelda_physics

physics-test: physics-build
	odin test packages/physics -collection:zelda_engine=$(CURDIR)/packages

clean:
	$(RM) third_party/textshape/textshape.o third_party/textshape/libtextshape.a
	$(RM) third_party/jolt/libJolt.a third_party/jolt/libzelda_physics.a
	$(RM) third_party/jolt/libzelda_physics.dylib third_party/jolt/libzelda_physics.so third_party/jolt/zelda_physics.lib
	$(RM) -r third_party/jolt/build
