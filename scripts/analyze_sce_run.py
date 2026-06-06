#!/usr/bin/env python3
import argparse
import base64
import json
import re
import sys
from pathlib import Path

SCE_EDGE_TYPES = {"instanceOf", "attributeOf", "processFor"}


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def parse_match_summaries(log_text: str) -> dict[str, int]:
    totals = {"claims": 0, "renames": 0, "merges": 0, "typed_edges": 0}
    pattern = re.compile(
        r"match_summary: claims=(\d+) renames=(\d+) merges=(\d+) typed_edges=(\d+)"
    )
    for match in pattern.finditer(log_text):
        totals["claims"] += int(match.group(1))
        totals["renames"] += int(match.group(2))
        totals["merges"] += int(match.group(3))
        totals["typed_edges"] += int(match.group(4))
    return totals


def parse_final_graph(log_text: str) -> tuple[int, int] | None:
    match = re.search(r"all done .* live graph (\d+)n/(\d+)e", log_text)
    if not match:
        return None
    return int(match.group(1)), int(match.group(2))


def parse_sidecar(sidecar_text: str) -> dict[str, int]:
    calls = 0
    input_chars = 0
    output_chars = 0
    total_ms = 0
    pattern = re.compile(r"^\[extract\].* in=(\d+)ch .* out=(\d+)ch (\d+)ms$", re.MULTILINE)
    for match in pattern.finditer(sidecar_text):
        calls += 1
        input_chars += int(match.group(1))
        output_chars += int(match.group(2))
        total_ms += int(match.group(3))
    return {
        "calls": calls,
        "input_chars": input_chars,
        "output_chars": output_chars,
        "total_ms": total_ms,
    }


def graph_payload(path: Path) -> dict:
    wrapper = json.loads(path.read_text(encoding="utf-8"))
    payload = base64.b64decode(wrapper["payload"])
    return json.loads(payload)


def graph_stats(graphs_dir: Path) -> dict[str, int]:
    stats = {
        "files": 0,
        "nodes": 0,
        "edges": 0,
        "sce_typed_edges": 0,
        "multi_doc_nodes": 0,
    }
    for path in sorted(graphs_dir.glob("*.json")):
        payload = graph_payload(path)
        stats["files"] += 1
        stats["nodes"] += len(payload.get("nodes", []))
        stats["edges"] += len(payload.get("edges", []))
        stats["sce_typed_edges"] += sum(
            1 for edge in payload.get("edges", []) if edge.get("type") in SCE_EDGE_TYPES
        )
        for node in payload.get("nodes", []):
            docs = {
                anchor.get("documentURL")
                for anchor in node.get("sourceAnchors", [])
                if anchor.get("documentURL")
            }
            if len(docs) > 1:
                stats["multi_doc_nodes"] += 1
    return stats


def main() -> int:
    parser = argparse.ArgumentParser(description="Check an Atlas SCE headless run directory.")
    parser.add_argument("run_dir", type=Path)
    args = parser.parse_args()

    atlas_log = args.run_dir / "atlas-run.log"
    sidecar_log = args.run_dir / "sidecar.log"
    graphs_dir = args.run_dir / "graphs-result"

    failures: list[str] = []
    for required in [atlas_log, sidecar_log, graphs_dir]:
        if not required.exists():
            failures.append(f"missing {required}")
    if failures:
        print("\n".join(f"FAIL: {failure}" for failure in failures))
        return 1

    atlas_text = read_text(atlas_log)
    sidecar_text = read_text(sidecar_log)
    match_totals = parse_match_summaries(atlas_text)
    final_graph = parse_final_graph(atlas_text)
    sidecar = parse_sidecar(sidecar_text)
    graphs = graph_stats(graphs_dir)

    if final_graph is None:
        failures.append("missing headless all-done final graph line")
    if re.search(r"HTTP error|\bFAILED\b|\bfailed\b|HTTP 5\d\d", atlas_text + "\n" + sidecar_text):
        failures.append("run contains HTTP/server failure text")
    if sidecar["calls"] == 0:
        failures.append("sidecar made zero extract calls")
    if match_totals["typed_edges"] > 0 and graphs["sce_typed_edges"] == 0:
        failures.append("SCE typed edges were logged but none persisted in graphs-result")

    print(f"sidecar_calls={sidecar['calls']} input_chars={sidecar['input_chars']} output_chars={sidecar['output_chars']} total_ms={sidecar['total_ms']}")
    if final_graph:
        print(f"final_live_graph={final_graph[0]}n/{final_graph[1]}e")
    print(
        "match_summary="
        f"claims={match_totals['claims']} renames={match_totals['renames']} "
        f"merges={match_totals['merges']} typed_edges={match_totals['typed_edges']}"
    )
    print(
        "graphs_result="
        f"files={graphs['files']} nodes={graphs['nodes']} edges={graphs['edges']} "
        f"multi_doc_nodes={graphs['multi_doc_nodes']} sce_typed_edges={graphs['sce_typed_edges']}"
    )

    for failure in failures:
        print(f"FAIL: {failure}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
