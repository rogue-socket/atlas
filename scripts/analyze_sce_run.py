#!/usr/bin/env python3
import argparse
import base64
import json
import re
import sys
import tempfile
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


def node_document_urls(node: dict) -> set[str]:
    return {
        anchor.get("documentURL")
        for anchor in node.get("sourceAnchors", [])
        if anchor.get("documentURL")
    }


def is_cross_document_edge(edge: dict, node_docs: dict[str, set[str]]) -> bool:
    source_docs = node_docs.get(edge.get("sourceNodeID"), set())
    target_docs = node_docs.get(edge.get("targetNodeID"), set())
    return bool(source_docs and target_docs and source_docs != target_docs)


def graph_stats(graphs_dir: Path) -> dict[str, int]:
    stats = {
        "files": 0,
        "nodes": 0,
        "edges": 0,
        "sce_typed_edges": 0,
        "cross_doc_sce_typed_edges": 0,
        "multi_doc_nodes": 0,
    }
    for path in sorted(graphs_dir.glob("*.json")):
        payload = graph_payload(path)
        stats["files"] += 1
        nodes = payload.get("nodes", [])
        edges = payload.get("edges", [])
        node_docs = {node.get("id"): node_document_urls(node) for node in nodes if node.get("id")}

        stats["nodes"] += len(nodes)
        stats["edges"] += len(edges)
        for edge in edges:
            if edge.get("type") not in SCE_EDGE_TYPES:
                continue
            stats["sce_typed_edges"] += 1
            if is_cross_document_edge(edge, node_docs):
                stats["cross_doc_sce_typed_edges"] += 1

        for node in nodes:
            docs = node_document_urls(node)
            if len(docs) > 1:
                stats["multi_doc_nodes"] += 1
    return stats


def write_graph_wrapper(path: Path, payload: dict) -> None:
    encoded = base64.b64encode(json.dumps(payload).encode("utf-8")).decode("ascii")
    path.write_text(json.dumps({"payload": encoded}), encoding="utf-8")


def make_self_test_run(root: Path, *, cross_doc: bool) -> Path:
    run_dir = root / ("cross-doc" if cross_doc else "same-doc")
    graphs_dir = run_dir / "graphs-result"
    graphs_dir.mkdir(parents=True)
    (run_dir / "atlas-run.log").write_text(
        "[SCE] doc=b.pdf pages=1-1 match_summary: claims=1 renames=0 merges=0 typed_edges=1 typed_rejected_direction=0\n"
        "[Headless] all done in 1.0s; live graph 2n/1e\n",
        encoding="utf-8",
    )
    (run_dir / "sidecar.log").write_text("[extract] model=x in=10ch status=ok out=20ch 30ms\n", encoding="utf-8")

    target_doc = "file:///tmp/a.pdf" if cross_doc else "file:///tmp/b.pdf"
    write_graph_wrapper(
        graphs_dir / "graph.json",
        {
            "nodes": [
                {
                    "id": "11111111-1111-1111-1111-111111111111",
                    "sourceAnchors": [{"documentURL": "file:///tmp/b.pdf"}],
                },
                {
                    "id": "22222222-2222-2222-2222-222222222222",
                    "sourceAnchors": [{"documentURL": target_doc}],
                },
            ],
            "edges": [
                {
                    "sourceNodeID": "11111111-1111-1111-1111-111111111111",
                    "targetNodeID": "22222222-2222-2222-2222-222222222222",
                    "type": "instanceOf",
                }
            ],
        },
    )
    return run_dir


def run_self_test() -> int:
    with tempfile.TemporaryDirectory(prefix="atlas-sce-analyzer-") as tmp:
        root = Path(tmp)
        good = make_self_test_run(root, cross_doc=True)
        bad = make_self_test_run(root, cross_doc=False)
        if analyze_run(good, emit=False) != 0:
            print("FAIL: self-test cross-doc fixture unexpectedly failed")
            return 1
        if analyze_run(bad, emit=False) == 0:
            print("FAIL: self-test same-doc fixture unexpectedly passed")
            return 1
    print("SCE_ANALYZER_SELF_TEST_PASSED")
    return 0


def analyze_run(run_dir: Path, *, emit: bool = True) -> int:
    atlas_log = run_dir / "atlas-run.log"
    sidecar_log = run_dir / "sidecar.log"
    graphs_dir = run_dir / "graphs-result"

    failures: list[str] = []
    for required in [atlas_log, sidecar_log, graphs_dir]:
        if not required.exists():
            failures.append(f"missing {required}")
    if failures:
        if emit:
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
    if match_totals["typed_edges"] > 0 and graphs["cross_doc_sce_typed_edges"] == 0:
        failures.append("SCE typed edges were logged but none persisted across document anchors")

    if emit:
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
            f"multi_doc_nodes={graphs['multi_doc_nodes']} sce_typed_edges={graphs['sce_typed_edges']} "
            f"cross_doc_sce_typed_edges={graphs['cross_doc_sce_typed_edges']}"
        )

        for failure in failures:
            print(f"FAIL: {failure}")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Check an Atlas SCE headless run directory.")
    parser.add_argument("run_dir", nargs="?", type=Path)
    parser.add_argument("--self-test", action="store_true", help="run synthetic analyzer fixtures")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()
    if args.run_dir is None:
        parser.error("run_dir is required unless --self-test is set")
    return analyze_run(args.run_dir)


if __name__ == "__main__":
    sys.exit(main())
