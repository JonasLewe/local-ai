#!/usr/bin/env python3
"""Patch Open WebUI RAG configuration in sqlite.

Called by local-ai.sh during install to ensure RAG settings are current,
even when the Podman volume already has a config row (where env vars are
ignored by Open WebUI's PersistentConfig).
"""
import argparse
import json
import sqlite3
import sys

DB_PATH = "/app/backend/data/webui.db"


def main():
    parser = argparse.ArgumentParser(description="Patch Open WebUI RAG config")
    parser.add_argument("--embedding-model", required=True)
    parser.add_argument("--ollama-url", required=True)
    parser.add_argument("--top-k", type=int, required=True)
    parser.add_argument("--chunk-size", type=int, required=True)
    parser.add_argument("--chunk-overlap", type=int, required=True)
    parser.add_argument("--reranking-model", default="")
    parser.add_argument("--top-k-reranker", type=int, default=0)
    args = parser.parse_args()

    conn = sqlite3.connect(DB_PATH)
    row = conn.execute(
        "SELECT id, data FROM config ORDER BY id DESC LIMIT 1"
    ).fetchone()

    if not row:
        print("no config row yet — skipping (will apply on next install run)")
        sys.exit(0)

    cfg_id, raw = row
    cfg = json.loads(raw)
    rag = cfg.setdefault("rag", {})

    rag.update({
        "embedding_engine": "ollama",
        "embedding_model": args.embedding_model,
        "top_k": args.top_k,
        "chunk_size": args.chunk_size,
        "chunk_overlap": args.chunk_overlap,
    })

    if args.reranking_model:
        rag["enable_hybrid_search"] = True
        rag["reranking_model"] = args.reranking_model
        rag["top_k_reranker"] = args.top_k_reranker
    else:
        rag["enable_hybrid_search"] = False
        rag["top_k_reranker"] = 0
        rag.pop("reranking_model", None)

    rag.setdefault("ollama", {})["url"] = args.ollama_url

    conn.execute(
        "UPDATE config SET data = ? WHERE id = ?", (json.dumps(cfg), cfg_id)
    )
    conn.commit()
    conn.close()
    print("ok")


if __name__ == "__main__":
    main()
