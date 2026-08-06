#!/usr/bin/env python3

from __future__ import annotations

import sys
from pathlib import Path

PATH = Path(__file__).parent
sys.path.append(str(PATH.parents[3] / "scripts"))

from osutil import ExampleBuilder, execute, jsc_bindgen_step, v8_bindgen_step

RT_LIB: str = "markov"


def run_bindgen(*, dry_run: bool) -> None:
    # DUMBAI: keep generated registrars in sync before compiling JS-engine usage examples for this library.
    for step in (
        jsc_bindgen_step(lib=RT_LIB, name="jsc-bindgen:markov"),
        v8_bindgen_step(lib=RT_LIB, name="v8-bindgen:markov"),
    ):
        print(f"Running build step '{step.name}'...")
        execute(step.command, cwd=step.cwd or PATH, dry_run=dry_run)


builder = ExampleBuilder(
    PATH=PATH,
    # DUMBAI: keep JS smoke builds aligned with native example flags/deps so runtime shared libraries resolve.
    FLAGS=[
        "-thread-count:8",
        "-define:IMGUI=false",
    ],
    DEBUG_FLAGS=["-debug", "-o:none"],
    RELEASE_FLAGS=["-o:speed"],
    # DUMBAI: JS examples should stage only still-linked vendor libraries for these smoke builds.
    DEPS=[
        "sdl",
        "sdl/image",
        "ft",
        "msdf",
    ],
    EXAMPLE_FLAGS={
        "markov_jsc": ["-define:JSC_BINDINGS=true"],
        "markov_v8": ["-define:V8_BINDINGS=true"],
    },
)

if not (builder.args.clean or builder.args.list or builder.args.list_json):
    run_bindgen(dry_run=builder.args.dry_run)

raise SystemExit(builder.build())
