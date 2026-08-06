#!/usr/bin/env python3
"""Summarize catermujo-compatible flame graph sidecars."""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


DEFAULT_TOP_N = 8
DEFAULT_SPIKE_PERCENTILE = 95.0


@dataclass
class ScopeRow:
    name: str
    color: int = 0
    total_ms: float = 0.0
    max_ms: float = 0.0
    max_frame_id: int = 0
    seen_frames: int = 0


@dataclass
class FrameRow:
    frame_id: int
    total_ms: float
    wait_ms: float
    cpu_ms: float
    gpu_ms: float
    gpu_valid: bool
    other_ms: float
    dropped_slots: int = 0
    scopes: list[dict[str, Any]] = field(default_factory=list)
    top_scope_name: str = ""
    top_scope_ms: float = 0.0


@dataclass
class Analysis:
    path: Path
    frames: list[FrameRow]
    scopes: list[ScopeRow]
    freq_hz: int
    header: dict[str, Any]


def source_candidates(path: str) -> list[Path]:
    requested = Path(path).expanduser()
    candidates = [requested]
    name = requested.name
    if name.endswith(".scopes.ndjson"):
        candidates.append(requested.with_name(name.removesuffix(".scopes.ndjson") + ".frames.ndjson"))
    elif name.endswith(".frames.ndjson"):
        candidates.append(requested.with_name(name.removesuffix(".frames.ndjson") + ".scopes.ndjson"))
    elif name.endswith(".graph"):
        candidates.append(requested.with_name(name.removesuffix(".graph") + ".scopes.ndjson"))
    else:
        candidates.extend(
            [
                requested.with_name(name + ".scopes.ndjson"),
                requested.with_name(name + ".graph"),
                requested.with_name(name + ".frames.ndjson"),
            ]
        )

    unique: list[Path] = []
    for candidate in candidates:
        if candidate not in unique:
            unique.append(candidate)
    return unique


def resolve_source(path: str) -> Path:
    for candidate in source_candidates(path):
        if candidate.is_file():
            if candidate.name.endswith(".frames.ndjson"):
                sibling = candidate.with_name(candidate.name.removesuffix(".frames.ndjson") + ".scopes.ndjson")
                if sibling.is_file():
                    return sibling
            return candidate
    searched = ", ".join(str(candidate) for candidate in source_candidates(path))
    raise FileNotFoundError(f"flame_dump: scopes dump not found; searched {searched}")


def number(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def integer(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def frame_from_record(record: dict[str, Any]) -> FrameRow:
    scopes = record.get("scopes", record.get("slots", [])) or []
    normalized_scopes: list[dict[str, Any]] = []
    for scope in scopes:
        if not isinstance(scope, dict):
            continue
        normalized_scopes.append(
            {
                "name": str(scope.get("name", "?")),
                "color": integer(scope.get("color")),
                "duration_ms": number(scope.get("duration_ms")),
            }
        )

    total_ms = number(record.get("total_ms"))
    cpu_ms = number(record.get("cpu_ms"))
    wait_ms = number(record.get("wait_ms"))
    other_ms = number(record.get("other_ms"), max(total_ms - cpu_ms - wait_ms, 0.0))
    row = FrameRow(
        frame_id=integer(record.get("frame_id")),
        total_ms=total_ms,
        wait_ms=wait_ms,
        cpu_ms=cpu_ms,
        gpu_ms=number(record.get("gpu_ms")),
        gpu_valid=bool(record.get("gpu_valid", False)),
        other_ms=other_ms,
        dropped_slots=integer(record.get("dropped_slots")),
        scopes=normalized_scopes,
    )
    for scope in normalized_scopes:
        if scope["duration_ms"] > row.top_scope_ms:
            row.top_scope_name = scope["name"]
            row.top_scope_ms = scope["duration_ms"]
    return row


def derived_header(frames: list[FrameRow], freq_hz: int) -> dict[str, Any]:
    if not frames:
        return {
            "kind": "history_header",
            "freq_hz": freq_hz,
            "frame_count": 0,
            "first_frame_id": 0,
            "last_frame_id": 0,
            "worst_frame_id": 0,
            "total_ms": 0.0,
            "avg_ms": 0.0,
            "total_wait_ms": 0.0,
            "avg_wait_ms": 0.0,
            "total_cpu_ms": 0.0,
            "avg_cpu_ms": 0.0,
            "total_gpu_ms": 0.0,
            "avg_gpu_ms": 0.0,
            "worst_gpu_ms": 0.0,
            "gpu_frame_count": 0,
            "worst_gpu_frame_id": 0,
            "dropped_slots": 0,
        }
    total_ms = sum(frame.total_ms for frame in frames)
    total_wait_ms = sum(frame.wait_ms for frame in frames)
    total_cpu_ms = sum(frame.cpu_ms for frame in frames)
    gpu_frames = [frame for frame in frames if frame.gpu_valid]
    worst = max(frames, key=lambda frame: (frame.total_ms, -frame.frame_id))
    worst_gpu = max(gpu_frames, key=lambda frame: (frame.gpu_ms, -frame.frame_id), default=None)
    count = len(frames)
    return {
        "kind": "history_header",
        "freq_hz": freq_hz,
        "frame_count": count,
        "first_frame_id": frames[0].frame_id,
        "last_frame_id": frames[-1].frame_id,
        "worst_frame_id": worst.frame_id,
        "total_ms": total_ms,
        "avg_ms": total_ms / count,
        "total_wait_ms": total_wait_ms,
        "avg_wait_ms": total_wait_ms / count,
        "total_cpu_ms": total_cpu_ms,
        "avg_cpu_ms": total_cpu_ms / count,
        "total_gpu_ms": sum(frame.gpu_ms for frame in gpu_frames),
        "avg_gpu_ms": sum(frame.gpu_ms for frame in gpu_frames) / max(len(gpu_frames), 1),
        "worst_gpu_ms": worst_gpu.gpu_ms if worst_gpu else 0.0,
        "gpu_frame_count": len(gpu_frames),
        "worst_gpu_frame_id": worst_gpu.frame_id if worst_gpu else 0,
        "dropped_slots": sum(frame.dropped_slots for frame in frames),
    }


def load_analysis(path: str) -> Analysis:
    resolved = resolve_source(path)
    lines = [line for line in resolved.read_text().splitlines() if line.strip()]
    if not lines:
        raise ValueError(f"flame_dump: empty dump: {resolved}")

    first = json.loads(lines[0])
    frames: list[FrameRow] = []
    if resolved.name.endswith(".json"):
        records = first.get("frames", []) if isinstance(first, dict) else []
        frames = [frame_from_record(record) for record in records if isinstance(record, dict)]
        source_header = {}
        freq_hz = 1_000_000_000
    else:
        source_header = first if isinstance(first, dict) else {}
        freq_hz = integer(source_header.get("freq_hz"), 1_000_000_000)
        for line in lines[1:]:
            record = json.loads(line)
            if isinstance(record, dict) and record.get("kind") == "frame_scopes":
                frames.append(frame_from_record(record))

    scopes: dict[str, ScopeRow] = {}
    for frame in frames:
        for scope in frame.scopes:
            row = scopes.setdefault(scope["name"], ScopeRow(scope["name"], scope["color"]))
            row.total_ms += scope["duration_ms"]
            row.seen_frames += 1
            if scope["duration_ms"] > row.max_ms:
                row.max_ms = scope["duration_ms"]
                row.max_frame_id = frame.frame_id

    header = derived_header(frames, freq_hz)
    header.update({key: value for key, value in source_header.items() if key in header})
    return Analysis(resolved, frames, list(scopes.values()), freq_hz, header)


def sorted_frames(analysis: Analysis) -> list[FrameRow]:
    return sorted(analysis.frames, key=lambda frame: (-frame.total_ms, frame.frame_id))


def sorted_scopes(analysis: Analysis) -> list[ScopeRow]:
    return sorted(analysis.scopes, key=lambda scope: (-scope.total_ms, scope.name))


def print_summary(analysis: Analysis, top_n: int) -> None:
    header = analysis.header
    frame_count = len(analysis.frames)
    print(f"dump: {analysis.path}")
    print(
        f"frames: {frame_count} ({header.get('first_frame_id', 0)}.."
        f"{header.get('last_frame_id', 0)})"
    )
    avg_ms = number(header.get("avg_ms"))
    print(f"avg frame: {avg_ms:.2f} ms ({1000 / avg_ms:.2f} FPS)" if avg_ms > 0 else "avg frame: 0.00 ms (0.00 FPS)")
    print(f"avg cpu:   {number(header.get('avg_cpu_ms')):.2f} ms")
    print(f"avg wait:  {number(header.get('avg_wait_ms')):.2f} ms")
    dropped_slots = integer(header.get("dropped_slots"))
    if dropped_slots > 0:
        print(f"warning:   trace truncated; {dropped_slots} function slots were dropped")
    if integer(header.get("gpu_frame_count")) > 0:
        print(f"avg gpu:   {number(header.get('avg_gpu_ms')):.2f} ms ({integer(header.get('gpu_frame_count'))} frames)")
    else:
        print("avg gpu:   n/a")

    worst_id = integer(header.get("worst_frame_id"))
    worst = next((frame for frame in analysis.frames if frame.frame_id == worst_id), None)
    if worst:
        print(
            f"worst:     #{worst.frame_id}  total {worst.total_ms:.2f} ms  "
            f"cpu {worst.cpu_ms:.2f}  wait {worst.wait_ms:.2f}  "
            f"top {worst.top_scope_name} {worst.top_scope_ms:.2f}"
        )

    print(f"\ntop scopes ({min(top_n, len(analysis.scopes))}):")
    denominator = max(frame_count, 1)
    for index, scope in enumerate(sorted_scopes(analysis)[:top_n], 1):
        print(
            f"{index}. {scope.name}  avg {scope.total_ms / denominator:.2f} ms  "
            f"total {scope.total_ms:.2f}  max {scope.max_ms:.2f} @{scope.max_frame_id}  "
            f"seen {scope.seen_frames}/{frame_count}"
        )

    print(f"\nworst frames ({min(top_n, len(analysis.frames))}):")
    for index, frame in enumerate(sorted_frames(analysis)[:top_n], 1):
        print(
            f"{index}. #{frame.frame_id}  total {frame.total_ms:.2f} ms  "
            f"cpu {frame.cpu_ms:.2f}  wait {frame.wait_ms:.2f}  "
            f"gpu {frame.gpu_ms:.2f}  other {frame.other_ms:.2f}  "
            f"top {frame.top_scope_name} {frame.top_scope_ms:.2f}"
        )


def spike_threshold(analysis: Analysis, args: argparse.Namespace) -> tuple[float, str]:
    if args.ms is not None and args.percentile is not None:
        raise ValueError("flame_dump: use either --ms or --percentile, not both")
    if args.ms is not None:
        if args.ms < 0:
            raise ValueError("flame_dump: --ms must be non-negative")
        return args.ms, f"spikes >= {args.ms:.2f} ms"
    percentile = DEFAULT_SPIKE_PERCENTILE if args.percentile is None else args.percentile
    if percentile <= 0 or percentile > 100:
        raise ValueError("flame_dump: percentile must be in (0, 100]")
    totals = sorted(frame.total_ms for frame in analysis.frames)
    if not totals:
        threshold = 0.0
    else:
        rank = max(0, min(math.ceil(percentile * len(totals) / 100.0) - 1, len(totals) - 1))
        threshold = totals[rank]
    return threshold, f"spikes at/above p{percentile:.2f} threshold ({threshold:.2f} ms)"


def print_spikes(analysis: Analysis, top_n: int, args: argparse.Namespace) -> None:
    threshold, label = spike_threshold(analysis, args)
    frames = sorted(
        (frame for frame in analysis.frames if frame.total_ms >= threshold),
        key=lambda frame: (-frame.total_ms, frame.frame_id),
    )
    print(f"dump: {analysis.path}")
    print(f"{label}: {len(frames)}")
    for index, frame in enumerate(frames[:top_n], 1):
        print(
            f"{index}. #{frame.frame_id}  total {frame.total_ms:.2f} ms  "
            f"cpu {frame.cpu_ms:.2f}  wait {frame.wait_ms:.2f}  "
            f"gpu {frame.gpu_ms:.2f}  other {frame.other_ms:.2f}  "
            f"top {frame.top_scope_name} {frame.top_scope_ms:.2f}"
        )


def print_frame(analysis: Analysis, frame_id: int, top_n: int) -> None:
    frame = next((row for row in analysis.frames if row.frame_id == frame_id), None)
    if frame is None:
        raise ValueError(f"flame_dump: frame #{frame_id} not found in {analysis.path}")
    print(f"dump: {analysis.path}")
    print(f"frame: #{frame.frame_id}")
    print(f"total: {frame.total_ms:.2f} ms")
    print(f"cpu:   {frame.cpu_ms:.2f} ms")
    print(f"wait:  {frame.wait_ms:.2f} ms")
    print(f"gpu:   {frame.gpu_ms:.2f} ms ({'valid' if frame.gpu_valid else 'n/a'})")
    print(f"other: {frame.other_ms:.2f} ms")
    print(f"scopes ({min(top_n, len(frame.scopes))}):")
    for index, scope in enumerate(sorted(frame.scopes, key=lambda item: (-item["duration_ms"], item["name"]))[:top_n], 1):
        print(f"{index}. {scope['name']}  {scope['duration_ms']:.2f} ms")


def add_common_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("path", nargs="?", help="path to .graph, .scopes.ndjson, or .frames.ndjson")
    parser.add_argument("-path", "--path", dest="path_option", help=argparse.SUPPRESS)
    parser.add_argument("-top", "--top", type=int, default=DEFAULT_TOP_N)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="flame_dump")
    commands = parser.add_subparsers(dest="command", required=True)

    summary = commands.add_parser("summary")
    add_common_arguments(summary)

    spikes = commands.add_parser("spikes")
    add_common_arguments(spikes)
    spikes.add_argument("-ms", "--ms", type=float)
    spikes.add_argument("-min_ms", "--min-ms", dest="ms", type=float)
    spikes.add_argument("-p", "--percentile", type=float)

    frame = commands.add_parser("frame")
    add_common_arguments(frame)
    frame.add_argument("-frame_id", "--frame-id", dest="frame_id", type=int, required=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    path = args.path_option or args.path
    if not path:
        print("flame_dump: missing dump path", file=sys.stderr)
        return 2
    if args.top <= 0:
        print("flame_dump: --top must be positive", file=sys.stderr)
        return 2
    try:
        analysis = load_analysis(path)
        if args.command == "summary":
            print_summary(analysis, args.top)
        elif args.command == "spikes":
            print_spikes(analysis, args.top, args)
        else:
            print_frame(analysis, args.frame_id, args.top)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
