#!/usr/bin/env python3

from __future__ import annotations

import sys
from pathlib import Path

PATH = Path(__file__).parent
# DUMBAI: build helpers live under repo/tool now, so resolve that directory from this file before importing osutil.
BASE = next(
    parent for parent in PATH.parents if (parent / "tool" / "osutil.py").exists()
)
sys.path.append(str(BASE / "tool"))

from osutil import ExampleBuilder

ExampleBuilder(
    PATH=PATH,
    FLAGS=[
        "-thread-count:8",
        "-define:IMGUI=false",
    ],
    DEBUG_FLAGS=[],
    RELEASE_FLAGS=[],
    # DUMBAI: These example builds now stage only vendor artifacts still used by the runtime UI path.
    DEPS=[
        "sdl",
        "sdl/image",
        "ft",
    ],
).build()
