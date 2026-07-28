JOLT_VERSION := v5.4.0
JOLT_ROOT := third_party/JoltPhysics
JOLT_BUILD := third_party/jolt/build
.PHONY: test textshape-build canvas-signposts-build physics-deps physics-build physics-test clean

TEXTSHAPE_CFLAGS := $(shell pkg-config --cflags harfbuzz freetype2 2>/dev/null)
TEXTSHAPE_LIBS := $(shell pkg-config --libs harfbuzz freetype2 2>/dev/null)
UNICODE_ROOT := third_party/unicode
SHEENBIDI_ROOT := $(UNICODE_ROOT)/sheenbidi
LIBGRAPHEME_ROOT := $(UNICODE_ROOT)/libgrapheme
UNICODE_CFLAGS := -I$(SHEENBIDI_ROOT)/Headers -I$(SHEENBIDI_ROOT)/Source -I$(LIBGRAPHEME_ROOT)
UNICODE_OBJECTS := \
	$(SHEENBIDI_ROOT)/SheenBidi.o \
	$(LIBGRAPHEME_ROOT)/src/character.o \
	$(LIBGRAPHEME_ROOT)/src/line.o \
	$(LIBGRAPHEME_ROOT)/src/utf8.o \
	$(LIBGRAPHEME_ROOT)/src/util.o \
	$(LIBGRAPHEME_ROOT)/src/word.o

test: textshape-build canvas-signposts-build
	mkdir -p build/tests
	odin test packages/capture -collection:zelda_engine=$(CURDIR)/packages -out:build/tests/capture
	odin test packages/benchmark -collection:zelda_engine=$(CURDIR)/packages
	odin test packages/gltf -collection:zelda_engine=$(CURDIR)/packages
	odin test packages/jobs -collection:zelda_engine=$(CURDIR)/packages
	odin check packages/jsonlines -collection:zelda_engine=$(CURDIR)/packages -no-entry-point
	odin test packages/render2d -collection:zelda_engine=$(CURDIR)/packages
	odin check packages/render3d -collection:zelda_engine=$(CURDIR)/packages -no-entry-point
	odin test packages/canvas2d -collection:zelda_engine=$(CURDIR)/packages \
		-define:ODIN_TEST_THREADS=1 \
		-extra-linker-flags:"$(TEXTSHAPE_LIBS) -Lbuild -lgfx_signposts"
	odin test packages/ui -collection:zelda_engine=$(CURDIR)/packages -extra-linker-flags:"$(TEXTSHAPE_LIBS)"

third_party/textshape/textshape.o: third_party/textshape/textshape.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(TEXTSHAPE_CFLAGS) $(UNICODE_CFLAGS) -c $< -o $@

$(SHEENBIDI_ROOT)/SheenBidi.o: $(SHEENBIDI_ROOT)/Source/SheenBidi.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(UNICODE_CFLAGS) -DSB_CONFIG_UNITY -c $< -o $@

$(LIBGRAPHEME_ROOT)/src/%.o: $(LIBGRAPHEME_ROOT)/src/%.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -std=c99 -I$(LIBGRAPHEME_ROOT) -c $< -o $@

third_party/textshape/libtextshape.a: third_party/textshape/textshape.o $(UNICODE_OBJECTS)
	$(AR) rcs $@ $<
	$(AR) rcs $@ $(UNICODE_OBJECTS)

textshape-build: third_party/textshape/libtextshape.a

build/gfx_signposts.o: packages/canvas2d/gfx_signposts.c
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -O2 -c $< -o $@

build/libgfx_signposts.a: build/gfx_signposts.o
	$(AR) rcs $@ $<

canvas-signposts-build: build/libgfx_signposts.a

physics-deps:
	@if test ! -d $(JOLT_ROOT)/.git; then git clone --depth 1 --branch $(JOLT_VERSION) https://github.com/jrouwe/JoltPhysics.git $(JOLT_ROOT); fi

physics-build: physics-deps
	cmake -S third_party/jolt -B $(JOLT_BUILD) -DCMAKE_BUILD_TYPE=Release
	cmake --build $(JOLT_BUILD) --target zelda_physics

physics-test: physics-build
	odin test packages/physics -collection:zelda_engine=$(CURDIR)/packages

clean:
	$(RM) build/gfx_signposts.o build/libgfx_signposts.a
	$(RM) third_party/textshape/textshape.o third_party/textshape/libtextshape.a
	$(RM) $(UNICODE_OBJECTS)
	$(RM) third_party/jolt/libJolt.a third_party/jolt/libzelda_physics.a
	$(RM) third_party/jolt/libzelda_physics.dylib third_party/jolt/libzelda_physics.so third_party/jolt/zelda_physics.lib
	$(RM) -r third_party/jolt/build
