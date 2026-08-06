#!/usr/bin/env python3
import glob
import os
import re
import xml.etree.ElementTree as ET
from collections import OrderedDict

HERE = os.path.abspath(os.path.dirname(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
MODEL_DIR = os.path.join(ROOT, "models")
MODELS_XML = os.path.join(ROOT, "models.xml")
OUT_MODELS = os.path.join(HERE, "procedural_models_generated.odin")
OUT_CATALOG = os.path.join(HERE, "procedural_catalog_generated.odin")


def odin_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def indent(text: str, prefix: str) -> str:
    return "\n".join(prefix + line if line else prefix for line in text.splitlines())


def call_expr(func: str, args: list[str], base_indent: str = "") -> str:
    if len(args) == 1 and "\n" not in args[0]:
        return f"{base_indent}{func}({args[0]})"

    lines = [f"{base_indent}{func}("]
    for i, arg in enumerate(args):
        block = indent(arg, base_indent + "    ").splitlines()
        if i < len(args) - 1:
            block[-1] = block[-1] + ","
        lines.extend(block)
    lines.append(f"{base_indent})")
    return "\n".join(lines)


TAG_ENUMS = {
    "one": "mk.Proc_Tag.one",
    "all": "mk.Proc_Tag.all",
    "prl": "mk.Proc_Tag.prl",
    "markov": "mk.Proc_Tag.markov",
    "sequence": "mk.Proc_Tag.sequence",
    "path": "mk.Proc_Tag.path",
    "map": "mk.Proc_Tag.map_",
    "convolution": "mk.Proc_Tag.convolution",
    "convchain": "mk.Proc_Tag.convchain",
    "wfc": "mk.Proc_Tag.wfc",
    "rule": "mk.Proc_Tag.rule",
    "field": "mk.Proc_Tag.field",
    "observe": "mk.Proc_Tag.observe",
    "union": "mk.Proc_Tag.union_",
}

KEY_ENUMS = {
    "values": ".values",
    "origin": ".origin",
    "in": ".in_",
    "out": ".out",
    "fin": ".fin",
    "fout": ".fout",
    "file": ".file",
    "legend": ".legend",
    "comment": ".comment",
    "steps": ".steps",
    "to": ".to",
    "symmetry": ".symmetry",
    "on": ".on",
    "from": ".from_",
    "value": ".value",
    "for": ".for_",
    "sum": ".sum",
    "symbol": ".symbol",
    "color": ".color",
    "p": ".p",
    "recompute": ".recompute",
    "inertia": ".inertia",
    "neighborhood": ".neighborhood",
    "temperature": ".temperature",
    "periodic": ".periodic",
    "tileset": ".tileset",
    "scale": ".scale",
    "sample": ".sample",
    "n": ".n",
    "folder": ".folder",
    "search": ".search",
    "longest": ".longest",
    "limit": ".limit",
    "depthCoefficient": ".depth_coefficient",
    "tiles": ".tiles",
    "d": ".d",
    "outputValues": ".output_values",
    "black": ".black",
    "white": ".white",
    "shannon": ".shannon",
    "essential": ".essential",
    "transparent": ".transparent",
    "overlap": ".overlap",
    "regular": ".regular",
}

BOOL_KEYS = {
    "origin",
    "periodic",
    "recompute",
    "inertia",
    "search",
    "longest",
    "shannon",
    "essential",
    "regular",
}

INT_KEYS = {
    "steps",
    "n",
    "limit",
    "d",
    "overlap",
    "transparent",
}

FLOAT_KEYS = {
    "p",
    "temperature",
    "depthCoefficient",
}


def tag_expr_for(tag: str) -> str:
    return TAG_ENUMS.get(tag, "mk.Proc_Tag.one")


def key_expr_for(key: str) -> str | None:
    return KEY_ENUMS.get(key)


def value_expr_for(key: str, value: str) -> str:
    if key in BOOL_KEYS and value.lower() in {"true", "false"}:
        return "true" if value.lower() == "true" else "false"
    if key in INT_KEYS and re.fullmatch(r"-?[0-9]+", value):
        return value
    if key in FLOAT_KEYS:
        return value
    return odin_str(value)


def attrs_expr(attrs: list[tuple[str, str]]) -> str:
    lines = ["[]mk.Proc_Attr{"]
    for k, v in attrs:
        key_expr = key_expr_for(k)
        value_expr = value_expr_for(k, v)
        if key_expr is None:
            lines.append(f"    mk.attr({odin_str(k)}, {odin_str(v)}),")
        else:
            lines.append(f"    mk.kattr({key_expr}, {value_expr}),")
    lines.append("}")
    return "\n".join(lines)


def node_expr(elem: ET.Element) -> str:
    attrs = list(elem.attrib.items())
    children = [c for c in list(elem) if isinstance(c.tag, str)]

    args: list[str] = [tag_expr_for(elem.tag)]
    if attrs or children:
        args.append(attrs_expr(attrs) if attrs else "nil")
    if children:
        lines = ["[]mk.Proc_Node{"]
        for child in children:
            child_block = node_expr(child)
            child_lines = indent(child_block, "    ").splitlines()
            child_lines[-1] = child_lines[-1] + ","
            lines.extend(child_lines)
        lines.append("}")
        args.append("\n".join(lines))

    return call_expr("mk.node", args)


def sanitize(name: str) -> str:
    s = re.sub(r"[^A-Za-z0-9_]", "_", name)
    if s and s[0].isdigit():
        s = "_" + s
    return s.lower()


def parse_models() -> OrderedDict[str, ET.Element]:
    out: OrderedDict[str, ET.Element] = OrderedDict()
    for path in sorted(glob.glob(os.path.join(MODEL_DIR, "*.xml"))):
        name = os.path.splitext(os.path.basename(path))[0]
        root = ET.parse(path).getroot()
        out[name] = root
    return out


def parse_bool(v: str | None, default: bool = False) -> bool:
    if v is None:
        return default
    return v.lower() == "true"


def parse_int(v: str | None, default: int) -> int:
    if v is None:
        return default
    try:
        return int(v)
    except ValueError:
        return default


def model_defaults() -> dict[str, dict]:
    root = ET.parse(MODELS_XML).getroot()
    defaults: dict[str, dict] = {}

    for elem in root:
        if elem.tag != "model":
            continue
        name = elem.attrib.get("name")
        if not name or name in defaults:
            continue

        sx, sy, sz = 16, 16, 1
        if "size" in elem.attrib:
            s = parse_int(elem.attrib.get("size"), 16)
            sx, sy, sz = s, s, 1
        sx = parse_int(elem.attrib.get("length"), sx)
        sy = parse_int(elem.attrib.get("width"), sy)
        sz = parse_int(elem.attrib.get("height"), sz)
        if parse_int(elem.attrib.get("d"), 0) == 3:
            sz = sx

        gif = parse_bool(elem.attrib.get("gif"), False)
        steps_default = 1000 if gif else 50000
        steps = parse_int(elem.attrib.get("steps"), steps_default)

        colors: list[tuple[str, str]] = []
        for child in elem:
            if child.tag != "color":
                continue
            symbol = child.attrib.get("symbol")
            value = child.attrib.get("value")
            if not symbol or not value:
                continue
            colors.append((symbol, value.lower()))

        defaults[name] = {
            "size": (sx, sy, sz),
            "steps": steps,
            "pixel_size": parse_int(elem.attrib.get("pixelsize"), 4),
            "iso": parse_bool(elem.attrib.get("iso"), False),
            "colors": colors,
        }

    return defaults


def write_models_file(models: OrderedDict[str, ET.Element]) -> None:
    lines: list[str] = []
    lines.append("// Code generated by examples/gen_procedural.py. DO NOT EDIT.")
    lines.append("package example")
    lines.append("")
    lines.append('import mk ".."')
    lines.append("")

    for name, root in models.items():
        fn = f"model_{sanitize(name)}"
        expr = node_expr(root)
        expr_lines = expr.splitlines()

        lines.append(f"{fn} :: proc() -> mk.Proc_Node {{")
        lines.append(f"    return {expr_lines[0]}")
        for line in expr_lines[1:]:
            lines.append(f"    {line}")
        lines.append("}")
        lines.append("")

    lines.append("load_model_node :: proc(name: string) -> (mk.Proc_Node, bool) {")
    lines.append("    switch name {")
    for name in models.keys():
        fn = f"model_{sanitize(name)}"
        lines.append(f"    case {odin_str(name)}:")
        lines.append(f"        return {fn}(), true")
    lines.append("    }")
    lines.append("    return {}, false")
    lines.append("}")
    lines.append("")

    with open(OUT_MODELS, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def write_catalog_file(
    models: OrderedDict[str, ET.Element], defaults: dict[str, dict]
) -> None:
    names = list(models.keys())

    lines: list[str] = []
    lines.append("// Code generated by examples/gen_procedural.py. DO NOT EDIT.")
    lines.append("package example")
    lines.append("")
    lines.append("Model_Config :: struct {")
    lines.append("    size:       [3]int,")
    lines.append("    steps:      int,")
    lines.append("    pixel_size: int,")
    lines.append("    iso:        bool,")
    lines.append("}")
    lines.append("")
    lines.append("MODEL_NAMES := []string{")
    for name in names:
        lines.append(f"    {odin_str(name)},")
    lines.append("}")
    lines.append("")
    lines.append("default_model_config :: proc(name: string) -> (Model_Config, bool) {")
    lines.append("    switch name {")

    for name in names:
        cfg = defaults.get(name)
        if cfg is None:
            cfg = {
                "size": (60, 60, 1),
                "steps": 50000,
                "pixel_size": 4,
                "iso": False,
                "colors": [],
            }

        sx, sy, sz = cfg["size"]
        lines.append(f"    case {odin_str(name)}:")
        lines.append("        return Model_Config{")
        lines.append(f"            size = {{{sx}, {sy}, {sz}}},")
        lines.append(f"            steps = {cfg['steps']},")
        lines.append(f"            pixel_size = {cfg['pixel_size']},")
        lines.append(f"            iso = {'true' if cfg['iso'] else 'false'},")
        lines.append("        }, true")

    lines.append("    }")
    lines.append("    return {}, false")
    lines.append("}")
    lines.append("")

    lines.append(
        "model_override_color :: proc(name: string, symbol: u8) -> (i32, bool) {"
    )
    lines.append("    switch name {")
    for name in names:
        cfg = defaults.get(name)
        if cfg is None:
            continue
        colors: list[tuple[str, str]] = cfg["colors"]
        if not colors:
            continue
        lines.append(f"    case {odin_str(name)}:")
        lines.append("        switch symbol {")
        for symbol, hex_value in colors:
            lines.append(f"        case '{symbol[0]}':")
            lines.append(
                f"            return transmute(i32)u32(0xff000000 | 0x{hex_value}), true"
            )
        lines.append("        }")
    lines.append("    }")
    lines.append("    return 0, false")
    lines.append("}")
    lines.append("")

    with open(OUT_CATALOG, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def main() -> None:
    models = parse_models()
    defaults = model_defaults()
    write_models_file(models)
    write_catalog_file(models, defaults)
    print(f"generated {OUT_MODELS}")
    print(f"generated {OUT_CATALOG}")


if __name__ == "__main__":
    main()
