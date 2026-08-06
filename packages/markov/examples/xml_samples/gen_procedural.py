#!/usr/bin/env python3
import glob
import os
import re
import xml.etree.ElementTree as ET
from collections import OrderedDict
from dataclasses import dataclass
from typing import Optional

HERE = os.path.abspath(os.path.dirname(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "../.."))
MODEL_DIR = os.path.join(ROOT, "models")
MODELS_XML = os.path.join(ROOT, "models.xml")
OUT_MODELS_REGISTRY = os.path.join(HERE, "procedural_models_registry_generated.odin")
OUT_MODEL_PREFIX = "procedural_model_"
OUT_MODEL_SUFFIX = "_generated.odin"
OUT_CATALOG_SHARED = os.path.join(HERE, "procedural_catalog_shared_generated.odin")
OUT_CATALOG_REGISTRY = os.path.join(HERE, "procedural_catalog_registry_generated.odin")
OUT_CATALOG_MODEL_PREFIX = "procedural_catalog_model_"
OUT_CATALOG_MODEL_SUFFIX = "_generated.odin"
SAFE_INTERNAL_SYMBOLS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()+,-.:;<=>?@[]^_`{}~"
RESERVED_INTERNAL_SYMBOLS = set(["\x00", "*", "/", "|", " ", "\t", "\n", "\r"])


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

TAG_WRAPPERS = {
    "one": "mk.one",
    "all": "mk.all",
    "prl": "mk.prl",
    "markov": "mk.markov_node",
    "sequence": "mk.sequence",
    "path": "mk.path_node",
    "map": "mk.map_node",
    "convolution": "mk.convolution_node",
    "convchain": "mk.convchain_node",
    "wfc": "mk.wfc_node",
    "rule": "mk.rule_node",
    "field": "mk.field_node",
    "observe": "mk.observe_node",
    "union": "mk.union_node",
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

PATTERN_NODE_TAGS = {"one", "all", "prl"}
PATTERN_RULE_PARENT_TAGS = {"one", "all", "prl", "map"}


@dataclass(frozen=True)
class GridCtx:
    symbols: str
    value_index: dict[str, int]
    union_waves: dict[str, int]


_internal_symbols_cache: dict[int, str] = {}


def odin_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def indent(text: str, prefix: str) -> str:
    return "\n".join(prefix + line if line else prefix for line in text.splitlines())


def call_expr(func: str, args: list[str], base_indent: str = "") -> str:
    inline = f"{base_indent}{func}({', '.join(args)})"
    if all("\n" not in arg for arg in args) and len(inline) <= 100:
        return inline

    lines = [f"{base_indent}{func}("]
    for i, arg in enumerate(args):
        block = indent(arg, base_indent + "    ").splitlines()
        if i < len(args) - 1:
            block[-1] = block[-1] + ","
        lines.extend(block)
    lines.append(f"{base_indent})")
    return "\n".join(lines)


def array_expr(type_expr: str, elems: list[str], base_indent: str = "") -> str:
    inline = f"{base_indent}{type_expr}{{{', '.join(elems)}}}"
    if all("\n" not in elem for elem in elems) and len(inline) <= 100:
        return inline

    lines = [f"{base_indent}{type_expr}{{"]
    for i, elem in enumerate(elems):
        block = indent(elem, base_indent + "    ").splitlines()
        if i < len(elems) - 1:
            block[-1] = block[-1] + ","
        lines.extend(block)
    lines.append(f"{base_indent}}}")
    return "\n".join(lines)


def int_row_expr(cells: list[str]) -> str:
    return array_expr("[]int", cells)


def int_layer_expr(rows: list[list[str]]) -> str:
    return array_expr("[][]int", [int_row_expr(row) for row in rows])


def tag_expr_for(tag: str) -> str:
    return TAG_ENUMS.get(tag, "mk.Proc_Tag.one")


def tag_wrapper_for(tag: str) -> Optional[str]:
    return TAG_WRAPPERS.get(tag)


def key_expr_for(key: str) -> Optional[str]:
    return KEY_ENUMS.get(key)


def normalize_symbols(value: str) -> str:
    return "".join(ch for ch in value if not ch.isspace())


def build_value_index(symbols: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for i, ch in enumerate(symbols):
        if ch not in out:
            out[ch] = i
    return out


def collect_union_waves(
    scope_root: ET.Element, value_index: dict[str, int]
) -> dict[str, int]:
    waves: dict[str, int] = {}
    queue: list[ET.Element] = [scope_root]
    qi = 0
    while qi < len(queue):
        current = queue[qi]
        qi += 1

        if current is not scope_root and current.tag == "union":
            symbol = current.attrib.get("symbol", "")
            values = normalize_symbols(current.attrib.get("values", ""))
            if symbol and symbol[0] not in waves:
                mask = 0
                ok = True
                for ch in values:
                    idx = value_index.get(ch)
                    if idx is None:
                        ok = False
                        break
                    mask |= 1 << idx
                if ok and mask != 0:
                    waves[symbol[0]] = mask

        for child in list(current):
            if not isinstance(child.tag, str):
                continue
            if child.tag in {"markov", "sequence", "union"}:
                queue.append(child)

    return waves


def make_grid_ctx(scope_root: ET.Element, symbols: str) -> GridCtx:
    value_index = build_value_index(symbols)
    union_waves = collect_union_waves(scope_root, value_index)
    return GridCtx(symbols=symbols, value_index=value_index, union_waves=union_waves)


def bit_indices(mask: int) -> list[int]:
    out: list[int] = []
    i = 0
    m = mask
    while m > 0:
        if m & 1:
            out.append(i)
        m >>= 1
        i += 1
    return out


def mask_expr(mask: int) -> str:
    bits = bit_indices(mask)
    if not bits:
        return "0"
    args = [f"mk.sym({i})" for i in bits]
    return call_expr("mk.one_of", args)


def split_symbol_tokens(value: str, allow_pipes: bool = False) -> Optional[list[str]]:
    if allow_pipes or "|" in value:
        parts = [p.strip() for p in value.split("|") if p.strip()]
        if not parts:
            return None
        tokens: list[str] = []
        for part in parts:
            if len(part) != 1:
                return None
            tokens.append(part)
        return tokens

    cleaned = normalize_symbols(value)
    if not cleaned:
        return None
    return list(cleaned)


def symbol_index(ch: str, ctx: GridCtx, allow_union: bool) -> Optional[int]:
    idx = ctx.value_index.get(ch)
    if idx is not None:
        return idx
    if not allow_union:
        return None

    wave = ctx.union_waves.get(ch)
    if wave is None:
        return None
    bits = bit_indices(wave)
    if len(bits) != 1:
        return None
    return bits[0]


def wave_mask(ch: str, ctx: GridCtx, allow_union: bool) -> Optional[int]:
    idx = ctx.value_index.get(ch)
    if idx is not None:
        return 1 << idx
    if not allow_union:
        return None
    return ctx.union_waves.get(ch)


def internal_symbols_for_count(count: int) -> str:
    cached = _internal_symbols_cache.get(count)
    if cached is not None:
        return cached

    if count <= 0:
        _internal_symbols_cache[count] = ""
        return ""

    result: list[str] = []
    used = set(SAFE_INTERNAL_SYMBOLS)
    used.update(RESERVED_INTERNAL_SYMBOLS)

    for ch in SAFE_INTERNAL_SYMBOLS:
        if ch in RESERVED_INTERNAL_SYMBOLS:
            continue
        result.append(ch)
        if len(result) == count:
            out = "".join(result)
            _internal_symbols_cache[count] = out
            return out

    for i in range(1, 256):
        ch = chr(i)
        if ch in used or ch in RESERVED_INTERNAL_SYMBOLS:
            continue
        result.append(ch)
        if len(result) == count:
            out = "".join(result)
            _internal_symbols_cache[count] = out
            return out

    out = "".join(result)
    _internal_symbols_cache[count] = out
    return out


def remap_symbol_char(ch: str, ctx: GridCtx) -> Optional[str]:
    idx = ctx.value_index.get(ch)
    if idx is None:
        return None
    symbols = internal_symbols_for_count(len(ctx.symbols))
    if idx < 0 or idx >= len(symbols):
        return None
    return symbols[idx]


def remap_symbol_string(
    value: str, primary: GridCtx, secondary: Optional[GridCtx] = None
) -> str:
    out: list[str] = []
    for ch in value:
        if ch.isspace() or ch == "*":
            out.append(ch)
            continue

        mapped = remap_symbol_char(ch, primary)
        if mapped is None and secondary is not None:
            mapped = remap_symbol_char(ch, secondary)

        out.append(mapped if mapped is not None else ch)
    return "".join(out)


def symbol_expr(value: str, ctx: GridCtx) -> Optional[str]:
    tokens = split_symbol_tokens(value)
    if tokens is None or len(tokens) != 1:
        return None
    idx = symbol_index(tokens[0], ctx, allow_union=False)
    if idx is None:
        return None
    return f"mk.sym({idx})"


def wave_expr(
    value: str, ctx: GridCtx, allow_union: bool, allow_pipes: bool = False
) -> Optional[str]:
    tokens = split_symbol_tokens(value, allow_pipes=allow_pipes)
    if tokens is None:
        return None

    mask = 0
    for token in tokens:
        m = wave_mask(token, ctx, allow_union=allow_union)
        if m is None:
            return None
        mask |= m

    return mask_expr(mask)


def parse_scale_component(value: str) -> tuple[int, int]:
    if "/" in value:
        parts = value.split("/", 1)
        if len(parts) == 2:
            try:
                n = int(parts[0])
                d = int(parts[1])
                if d != 0:
                    return n, d
            except ValueError:
                return 1, 1
    try:
        return int(value), 1
    except ValueError:
        return 1, 1


def symmetry_expr(name: str, is_2d: bool) -> Optional[str]:
    if is_2d:
        constants: dict[str, str] = {
            "()": "mk.SYMMETRY_2D_IDENTITY",
            "(x)": "mk.SYMMETRY_2D_X",
            "(y)": "mk.SYMMETRY_2D_Y",
            "(x)(y)": "mk.SYMMETRY_2D_XY_FLIPS",
            "(xy+)": "mk.SYMMETRY_2D_XY_PLUS",
            "(xy)": "mk.SYMMETRY_2D_ALL",
        }
        if const := constants.get(name):
            return f"mk.symmetry_mask({const})"
        return None

    constants_3d: dict[str, str] = {
        "()": "mk.SYMMETRY_3D_IDENTITY",
        "(x)": "mk.SYMMETRY_3D_X",
        "(z)": "mk.SYMMETRY_3D_Z",
        "(xy)": "mk.SYMMETRY_3D_XY",
        "(xyz+)": "mk.SYMMETRY_3D_XYZ_PLUS",
        "(xyz)": "mk.SYMMETRY_3D_ALL",
    }
    if const := constants_3d.get(name):
        return f"mk.symmetry_mask({const})"
    return None


def parse_pattern_layers(value: str) -> Optional[list[list[str]]]:
    if not value:
        return None

    layers = value.split(" ")
    if any(layer == "" for layer in layers):
        return None

    parsed: list[list[str]] = []
    for layer in layers:
        rows = layer.split("/")
        if any(row == "" for row in rows):
            return None
        parsed.append(rows)

    return parsed


def direct_pattern_expr(
    key: str,
    value: str,
    in_ctx: GridCtx,
    out_ctx: GridCtx,
) -> Optional[str]:
    layers = parse_pattern_layers(value)
    if layers is None:
        return None

    # parse_pattern flips z-layers, so we emit direct layers in reverse order.
    ordered_layers = list(reversed(layers))

    if key == "in":
        exact_layers: list[list[list[int]]] = []
        exact_ok = True
        raw_layers: list[list[list[str]]] = []
        for rows in ordered_layers:
            exact_rows: list[list[int]] = []
            raw_rows: list[list[str]] = []
            for row in rows:
                exact_row: list[int] = []
                raw_row: list[str] = []
                for ch in row:
                    if ch == "*":
                        exact_ok = False
                        raw_row.append("mk.IN_ANY")
                        continue
                    idx = symbol_index(ch, in_ctx, allow_union=True)
                    if idx is None:
                        exact_ok = False
                        break
                    exact_row.append(idx)
                    raw_row.append(str(idx))
                if not exact_ok:
                    break
                exact_rows.append(exact_row)
                raw_rows.append(raw_row)
            if not exact_ok:
                break
            exact_layers.append(exact_rows)
            raw_layers.append(raw_rows)

        if exact_ok:
            int_layers = [
                [[str(cell) for cell in row] for row in layer] for layer in exact_layers
            ]
            if len(exact_layers) == 1:
                return call_expr(
                    "mk.in_exact_layer", [int_row_expr(row) for row in int_layers[0]]
                )
            return call_expr(
                "mk.in_exact_layers", [int_layer_expr(layer) for layer in int_layers]
            )

        raw_layers = []
        for rows in ordered_layers:
            raw_rows: list[list[str]] = []
            for row in rows:
                raw_row: list[str] = []
                for ch in row:
                    if ch == "*":
                        raw_row.append("mk.IN_ANY")
                        continue
                    idx = symbol_index(ch, in_ctx, allow_union=True)
                    if idx is None:
                        return None
                    raw_row.append(str(idx))
                raw_rows.append(raw_row)
            raw_layers.append(raw_rows)

        if len(raw_layers) == 1:
            return call_expr(
                "mk.in_exact_layer", [int_row_expr(row) for row in raw_layers[0]]
            )
        return call_expr(
            "mk.in_exact_layers", [int_layer_expr(layer) for layer in raw_layers]
        )

    if key == "out":
        exact_layers = []
        exact_ok = True
        raw_layers: list[list[list[str]]] = []
        for rows in ordered_layers:
            exact_rows: list[list[int]] = []
            raw_rows: list[list[str]] = []
            for row in rows:
                exact_row: list[int] = []
                raw_row: list[str] = []
                for ch in row:
                    if ch == "*":
                        exact_ok = False
                        raw_row.append("mk.OUT_KEEP")
                        continue
                    idx = out_ctx.value_index.get(ch)
                    if idx is None:
                        exact_ok = False
                        break
                    exact_row.append(idx)
                    raw_row.append(str(idx))
                if not exact_ok:
                    break
                exact_rows.append(exact_row)
                raw_rows.append(raw_row)
            if not exact_ok:
                break
            exact_layers.append(exact_rows)
            raw_layers.append(raw_rows)

        if exact_ok:
            int_layers = [
                [[str(cell) for cell in row] for row in layer] for layer in exact_layers
            ]
            if len(exact_layers) == 1:
                return call_expr(
                    "mk.out_exact_layer", [int_row_expr(row) for row in int_layers[0]]
                )
            return call_expr(
                "mk.out_exact_layers", [int_layer_expr(layer) for layer in int_layers]
            )

        raw_layers = []
        for rows in ordered_layers:
            raw_rows: list[list[str]] = []
            for row in rows:
                raw_row: list[str] = []
                for ch in row:
                    if ch == "*":
                        raw_row.append("mk.OUT_KEEP")
                        continue
                    idx = out_ctx.value_index.get(ch)
                    if idx is None:
                        return None
                    raw_row.append(str(idx))
                raw_rows.append(raw_row)
            raw_layers.append(raw_rows)

        if len(raw_layers) == 1:
            return call_expr(
                "mk.out_exact_layer", [int_row_expr(row) for row in raw_layers[0]]
            )
        return call_expr(
            "mk.out_exact_layers", [int_layer_expr(layer) for layer in raw_layers]
        )

    return None


def value_expr_for(
    elem: ET.Element,
    key: str,
    value: str,
    grid_ctx: GridCtx,
    dim_z: int,
    parent_tag: Optional[str],
    is_root: bool,
    rule_in_ctx: Optional[GridCtx],
    rule_out_ctx: Optional[GridCtx],
    wfc_rule_kind: Optional[str],
) -> str:
    if key == "values":
        if is_root or elem.tag in {"map", "wfc"}:
            cleaned = normalize_symbols(value)
            if cleaned:
                return f"mk.values_count({len(cleaned)})"
        if elem.tag == "union" or (elem.tag == "rule" and parent_tag == "convolution"):
            if expr := wave_expr(value, grid_ctx, allow_union=True):
                return expr

    if key in {"in", "out"}:
        if elem.tag in PATTERN_NODE_TAGS or (
            elem.tag == "rule" and parent_tag in PATTERN_RULE_PARENT_TAGS
        ):
            in_ctx = rule_in_ctx or grid_ctx
            out_ctx = rule_out_ctx or grid_ctx
            if expr := direct_pattern_expr(key, value, in_ctx, out_ctx):
                return expr

        if elem.tag == "rule" and parent_tag == "convolution":
            if expr := symbol_expr(value, grid_ctx):
                return expr

        if elem.tag == "rule" and parent_tag == "wfc":
            if key == "in":
                in_ctx = rule_in_ctx or grid_ctx
                if expr := symbol_expr(value, in_ctx):
                    return expr
            elif wfc_rule_kind == "sample":
                out_ctx = rule_out_ctx or grid_ctx
                if expr := wave_expr(
                    value, out_ctx, allow_union=False, allow_pipes=True
                ):
                    return expr

    if elem.tag == "field":
        if key == "for":
            if expr := symbol_expr(value, grid_ctx):
                return expr
        if key in {"on", "from", "to"}:
            if expr := wave_expr(value, grid_ctx, allow_union=True):
                return expr

    if elem.tag == "observe":
        if key in {"value", "from"}:
            if expr := symbol_expr(value, grid_ctx):
                return expr
        if key == "to":
            if expr := wave_expr(value, grid_ctx, allow_union=True):
                return expr

    if elem.tag == "path":
        if key == "color":
            if expr := symbol_expr(value, grid_ctx):
                return expr
        if key in {"from", "to", "on"}:
            if expr := wave_expr(value, grid_ctx, allow_union=True):
                return expr

    if key == "symmetry":
        if expr := symmetry_expr(value, is_2d=(dim_z == 1)):
            return expr

    if key == "legend":
        primary_ctx = grid_ctx
        secondary_ctx: Optional[GridCtx] = None
        if elem.tag == "rule" and parent_tag in {"map", "wfc"}:
            has_file = "file" in elem.attrib
            has_fin = "fin" in elem.attrib
            has_fout = "fout" in elem.attrib

            if has_fout and not has_fin and not has_file:
                if rule_out_ctx is not None:
                    primary_ctx = rule_out_ctx
                secondary_ctx = rule_in_ctx
            elif has_fin and not has_fout and not has_file:
                if rule_in_ctx is not None:
                    primary_ctx = rule_in_ctx
                secondary_ctx = rule_out_ctx
            else:
                if rule_in_ctx is not None:
                    primary_ctx = rule_in_ctx
                secondary_ctx = rule_out_ctx
        return odin_str(remap_symbol_string(value, primary_ctx, secondary_ctx))

    if key in BOOL_KEYS and value.lower() in {"true", "false"}:
        return "true" if value.lower() == "true" else "false"
    if key in INT_KEYS and re.fullmatch(r"-?[0-9]+", value):
        return value
    if key in FLOAT_KEYS:
        return value

    return odin_str(value)


def attrs_items(
    attrs: list[tuple[str, str]],
    elem: ET.Element,
    grid_ctx: GridCtx,
    dim_z: int,
    parent_tag: Optional[str],
    is_root: bool,
    rule_in_ctx: Optional[GridCtx],
    rule_out_ctx: Optional[GridCtx],
    wfc_rule_kind: Optional[str],
) -> list[str]:
    items: list[str] = []
    for k, v in attrs:
        key_expr = key_expr_for(k)
        value_expr = value_expr_for(
            elem,
            k,
            v,
            grid_ctx,
            dim_z,
            parent_tag,
            is_root,
            rule_in_ctx,
            rule_out_ctx,
            wfc_rule_kind,
        )
        if key_expr is None:
            items.append(f"mk.attr({odin_str(k)}, {odin_str(v)})")
        else:
            items.append(f"mk.kattr({key_expr}, {value_expr})")
    return items


def attr_expr_item(
    elem: ET.Element,
    key: str,
    value: str,
    grid_ctx: GridCtx,
    dim_z: int,
    parent_tag: Optional[str],
    is_root: bool,
    rule_in_ctx: Optional[GridCtx],
    rule_out_ctx: Optional[GridCtx],
    wfc_rule_kind: Optional[str],
) -> tuple[Optional[str], str]:
    key_expr = key_expr_for(key)
    value_expr = value_expr_for(
        elem,
        key,
        value,
        grid_ctx,
        dim_z,
        parent_tag,
        is_root,
        rule_in_ctx,
        rule_out_ctx,
        wfc_rule_kind,
    )
    return key_expr, value_expr


def rule_node_expr(
    elem: ET.Element,
    attrs: list[tuple[str, str]],
    grid_ctx: GridCtx,
    dim_z: int,
    parent_tag: Optional[str],
    is_root: bool,
    rule_in_ctx: Optional[GridCtx],
    rule_out_ctx: Optional[GridCtx],
    wfc_rule_kind: Optional[str],
) -> Optional[str]:
    in_expr: Optional[str] = None
    out_expr: Optional[str] = None
    extra_args: list[str] = []

    for key, value in attrs:
        key_expr, value_expr = attr_expr_item(
            elem,
            key,
            value,
            grid_ctx,
            dim_z,
            parent_tag,
            is_root,
            rule_in_ctx,
            rule_out_ctx,
            wfc_rule_kind,
        )
        if key_expr == ".in_" and in_expr is None:
            in_expr = value_expr
            continue
        if key_expr == ".out" and out_expr is None:
            out_expr = value_expr
            continue
        if key_expr is None:
            extra_args.append(f"mk.attr({odin_str(key)}, {odin_str(value)})")
        else:
            extra_args.append(f"mk.kattr({key_expr}, {value_expr})")

    if in_expr is None or out_expr is None:
        return None
    return call_expr("mk.rule", [in_expr, out_expr, *extra_args])


def node_expr(
    elem: ET.Element,
    grid_ctx: GridCtx,
    dim_z: int,
    parent_tag: Optional[str] = None,
    is_root: bool = False,
    rule_in_ctx: Optional[GridCtx] = None,
    rule_out_ctx: Optional[GridCtx] = None,
    wfc_rule_kind: Optional[str] = None,
) -> str:
    attrs = list(elem.attrib.items())
    children = [c for c in list(elem) if isinstance(c.tag, str)]

    map_child_ctx = grid_ctx
    map_child_dim_z = dim_z
    if elem.tag == "map":
        values_attr = elem.attrib.get("values")
        if values_attr is not None:
            values_symbols = normalize_symbols(values_attr)
            if values_symbols:
                map_child_ctx = make_grid_ctx(elem, values_symbols)
        scale_attr = elem.attrib.get("scale")
        if scale_attr:
            scale_parts = scale_attr.split(" ")
            if len(scale_parts) == 3:
                nz, dz = parse_scale_component(scale_parts[2])
                if dz != 0:
                    map_child_dim_z = (dim_z * nz) // dz
                    if map_child_dim_z < 1:
                        map_child_dim_z = 1

    wfc_child_ctx = grid_ctx
    local_wfc_rule_kind: Optional[str] = None
    if elem.tag == "wfc":
        values_attr = elem.attrib.get("values")
        if values_attr is not None:
            values_symbols = normalize_symbols(values_attr)
            if values_symbols:
                wfc_child_ctx = make_grid_ctx(elem, values_symbols)
            else:
                wfc_child_ctx = make_grid_ctx(elem, grid_ctx.symbols)
        else:
            wfc_child_ctx = make_grid_ctx(elem, grid_ctx.symbols)

        if "sample" in elem.attrib:
            local_wfc_rule_kind = "sample"
        elif "tileset" in elem.attrib:
            local_wfc_rule_kind = "tileset"

    if elem.tag == "rule" and not children:
        expr = rule_node_expr(
            elem,
            attrs,
            grid_ctx,
            dim_z,
            parent_tag,
            is_root,
            rule_in_ctx,
            rule_out_ctx,
            wfc_rule_kind,
        )
        if expr is not None:
            return expr

    wrapper = tag_wrapper_for(elem.tag)
    use_wrapper = wrapper is not None
    args: list[str] = []
    if not use_wrapper:
        args.append(tag_expr_for(elem.tag))

    attr_args = (
        attrs_items(
            attrs,
            elem,
            grid_ctx,
            dim_z,
            parent_tag,
            is_root,
            rule_in_ctx,
            rule_out_ctx,
            wfc_rule_kind,
        )
        if attrs
        else []
    )
    args.extend(attr_args)

    if children:
        child_exprs: list[str] = []
        for child in children:
            child_grid = grid_ctx
            child_dim_z = dim_z
            child_rule_in: Optional[GridCtx] = None
            child_rule_out: Optional[GridCtx] = None
            child_wfc_rule_kind: Optional[str] = None

            if elem.tag == "map":
                if child.tag == "rule":
                    child_grid = grid_ctx
                    child_dim_z = dim_z
                    child_rule_in = grid_ctx
                    child_rule_out = map_child_ctx
                else:
                    child_grid = map_child_ctx
                    child_dim_z = map_child_dim_z
            elif elem.tag == "wfc":
                if child.tag == "rule":
                    child_grid = wfc_child_ctx
                    child_dim_z = dim_z
                    child_rule_in = grid_ctx
                    if local_wfc_rule_kind == "sample":
                        child_rule_out = wfc_child_ctx
                    child_wfc_rule_kind = local_wfc_rule_kind
                else:
                    child_grid = wfc_child_ctx
                    child_dim_z = dim_z

            child_block = node_expr(
                child,
                child_grid,
                child_dim_z,
                parent_tag=elem.tag,
                is_root=False,
                rule_in_ctx=child_rule_in,
                rule_out_ctx=child_rule_out,
                wfc_rule_kind=child_wfc_rule_kind,
            )
            child_exprs.append(child_block)
        args.extend(child_exprs)

    if use_wrapper:
        return call_expr(wrapper, args)
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


def parse_bool(v: Optional[str], default: bool = False) -> bool:
    if v is None:
        return default
    return v.lower() == "true"


def parse_int(v: Optional[str], default: int) -> int:
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


def model_file_path(name: str) -> str:
    return os.path.join(HERE, f"{OUT_MODEL_PREFIX}{sanitize(name)}{OUT_MODEL_SUFFIX}")


def catalog_model_file_path(name: str) -> str:
    return os.path.join(
        HERE, f"{OUT_CATALOG_MODEL_PREFIX}{sanitize(name)}{OUT_CATALOG_MODEL_SUFFIX}"
    )


def cleanup_model_files() -> None:
    legacy = os.path.join(HERE, "procedural_models_generated.odin")
    if os.path.exists(legacy):
        os.remove(legacy)
    if os.path.exists(OUT_MODELS_REGISTRY):
        os.remove(OUT_MODELS_REGISTRY)
    shared_legacy = os.path.join(HERE, "procedural_models_shared_generated.odin")
    if os.path.exists(shared_legacy):
        os.remove(shared_legacy)
    for path in glob.glob(os.path.join(HERE, f"{OUT_MODEL_PREFIX}*{OUT_MODEL_SUFFIX}")):
        os.remove(path)


def write_model_file(name: str, root: ET.Element, defaults: dict[str, dict]) -> None:
    fn = f"model_{sanitize(name)}"

    values_attr = root.attrib.get("values", "")
    root_symbols = normalize_symbols(values_attr)
    root_ctx = (
        make_grid_ctx(root, root_symbols) if root_symbols else GridCtx("", {}, {})
    )
    cfg = defaults.get(name)
    root_dim_z = cfg["size"][2] if cfg is not None else 1

    expr = node_expr(root, root_ctx, root_dim_z, parent_tag=None, is_root=True)
    expr_lines = expr.splitlines()

    lines: list[str] = []
    lines.append("// Code generated by examples/gen_procedural.py. DO NOT EDIT.")
    lines.append("package example")
    lines.append("")
    lines.append('import mk "../.."')
    lines.append("")
    lines.append(f"{fn} :: proc() -> mk.Proc_Node {{")
    lines.append(f"    return {expr_lines[0]}")
    for line in expr_lines[1:]:
        lines.append(f"    {line}")
    lines.append("}")
    lines.append("")

    with open(model_file_path(name), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def write_models_registry_file(models: OrderedDict[str, ET.Element]) -> None:
    lines: list[str] = []
    lines.append("// Code generated by examples/gen_procedural.py. DO NOT EDIT.")
    lines.append("package example")
    lines.append("")
    lines.append('import mk "../.."')
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
    with open(OUT_MODELS_REGISTRY, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def write_models_file(
    models: OrderedDict[str, ET.Element], defaults: dict[str, dict]
) -> list[str]:
    cleanup_model_files()
    written = [OUT_MODELS_REGISTRY]
    for name, root in models.items():
        path = model_file_path(name)
        write_model_file(name, root, defaults)
        written.append(path)

    write_models_registry_file(models)
    return written


def write_catalog_file(
    models: OrderedDict[str, ET.Element], defaults: dict[str, dict]
) -> list[str]:
    def cleanup_catalog_files() -> None:
        legacy = os.path.join(HERE, "procedural_catalog_generated.odin")
        if os.path.exists(legacy):
            os.remove(legacy)
        if os.path.exists(OUT_CATALOG_SHARED):
            os.remove(OUT_CATALOG_SHARED)
        if os.path.exists(OUT_CATALOG_REGISTRY):
            os.remove(OUT_CATALOG_REGISTRY)
        for path in glob.glob(
            os.path.join(HERE, f"{OUT_CATALOG_MODEL_PREFIX}*{OUT_CATALOG_MODEL_SUFFIX}")
        ):
            os.remove(path)

    def write_catalog_shared_file(names: list[str]) -> None:
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
        with open(OUT_CATALOG_SHARED, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))

    def write_catalog_model_file(
        name: str, root: Optional[ET.Element], cfg: dict
    ) -> str:
        if cfg is None:
            cfg = {
                "size": (60, 60, 1),
                "steps": 50000,
                "pixel_size": 4,
                "iso": False,
                "colors": [],
            }
        sx, sy, sz = cfg["size"]
        colors: list[tuple[str, str]] = cfg["colors"]
        model_values = (
            normalize_symbols(root.attrib.get("values", "")) if root is not None else ""
        )
        value_index = build_value_index(model_values)
        sn = sanitize(name)
        path = catalog_model_file_path(name)

        lines: list[str] = []
        lines.append("// Code generated by examples/gen_procedural.py. DO NOT EDIT.")
        lines.append("package example")
        lines.append("")
        lines.append(f"default_model_config_{sn} :: proc() -> Model_Config {{")
        lines.append("    return Model_Config{")
        lines.append(f"        size = {{{sx}, {sy}, {sz}}},")
        lines.append(f"        steps = {cfg['steps']},")
        lines.append(f"        pixel_size = {cfg['pixel_size']},")
        lines.append(f"        iso = {'true' if cfg['iso'] else 'false'},")
        lines.append("    }")
        lines.append("}")
        lines.append("")

        lines.append(f"model_palette_symbol_{sn} :: proc(value: int) -> (u8, bool) {{")
        if model_values:
            lines.append(f"    values := {odin_str(model_values)}")
            lines.append("    if value >= 0 && value < len(values) {")
            lines.append("        return values[value], true")
            lines.append("    }")
        lines.append("    return 0, false")
        lines.append("}")
        lines.append("")

        lines.append(f"model_override_color_{sn} :: proc(value: int) -> (i32, bool) {{")
        if colors:
            lines.append("    switch value {")
            for symbol, hex_value in colors:
                if len(symbol) == 0:
                    continue
                idx = value_index.get(symbol[0])
                if idx is None:
                    continue
                lines.append(f"    case {idx}:")
                lines.append(
                    f"        return transmute(i32)u32(0xff000000 | 0x{hex_value}), true"
                )
            lines.append("    }")
        lines.append("    return 0, false")
        lines.append("}")
        lines.append("")

        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
        return path

    def write_catalog_registry_file(names: list[str]) -> None:
        lines: list[str] = []
        lines.append("// Code generated by examples/gen_procedural.py. DO NOT EDIT.")
        lines.append("package example")
        lines.append("")
        lines.append(
            "default_model_config :: proc(name: string) -> (Model_Config, bool) {"
        )
        lines.append("    switch name {")
        for name in names:
            sn = sanitize(name)
            lines.append(f"    case {odin_str(name)}:")
            lines.append(f"        return default_model_config_{sn}(), true")
        lines.append("    }")
        lines.append("    return {}, false")
        lines.append("}")
        lines.append("")

        lines.append(
            "model_palette_symbol :: proc(name: string, value: int) -> (u8, bool) {"
        )
        lines.append("    switch name {")
        for name in names:
            sn = sanitize(name)
            lines.append(f"    case {odin_str(name)}:")
            lines.append(f"        return model_palette_symbol_{sn}(value)")
        lines.append("    }")
        lines.append("    return 0, false")
        lines.append("}")
        lines.append("")

        lines.append(
            "model_override_color :: proc(name: string, value: int) -> (i32, bool) {"
        )
        lines.append("    switch name {")
        for name in names:
            sn = sanitize(name)
            lines.append(f"    case {odin_str(name)}:")
            lines.append(f"        return model_override_color_{sn}(value)")
        lines.append("    }")
        lines.append("    return 0, false")
        lines.append("}")
        lines.append("")

        with open(OUT_CATALOG_REGISTRY, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))

    cleanup_catalog_files()
    names = list(models.keys())
    write_catalog_shared_file(names)
    written = [OUT_CATALOG_SHARED, OUT_CATALOG_REGISTRY]
    for name in names:
        written.append(
            write_catalog_model_file(name, models.get(name), defaults.get(name))
        )
    write_catalog_registry_file(names)
    return written


def main() -> None:
    models = parse_models()
    defaults = model_defaults()
    model_paths = write_models_file(models, defaults)
    catalog_paths = write_catalog_file(models, defaults)
    print(f"generated {OUT_MODELS_REGISTRY}")
    print(f"generated {len(model_paths) - 1} model files")
    print(f"generated {OUT_CATALOG_SHARED}")
    print(f"generated {OUT_CATALOG_REGISTRY}")
    print(f"generated {len(catalog_paths) - 2} catalog model files")


if __name__ == "__main__":
    main()
