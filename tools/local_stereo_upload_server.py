#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import datetime as dt
import threading
from pathlib import Path

from flask import Flask, jsonify, request

app = Flask(__name__)

_OUTPUT_ROOT = Path.home() / "stereo_data"
_CSV_LOCK = threading.Lock()


def _ensure_csv(csv_path: Path) -> None:
    if csv_path.exists():
        return
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "received_at_utc",
                "session_id",
                "camera_label",
                "frame_index",
                "timestamp",
                "original_filename",
                "saved_path",
                "file_size_bytes",
            ]
        )


def _append_csv_row(csv_path: Path, row: list[str]) -> None:
    with _CSV_LOCK:
        _ensure_csv(csv_path)
        with csv_path.open("a", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow(row)


@app.get("/health")
def health() -> tuple[dict, int]:
    return {"ok": True}, 200


@app.post("/upload-file")
def upload_file() -> tuple[dict, int]:
    session_id = (request.form.get("session_id") or "").strip()
    camera_label = (request.form.get("camera_label") or "").strip()
    frame_index = (request.form.get("frame_index") or "").strip()
    timestamp = (request.form.get("timestamp") or "").strip()
    file = request.files.get("file")

    if not session_id:
        return {"ok": False, "error": "missing session_id"}, 400
    if camera_label not in {"cam1", "cam2"}:
        return {"ok": False, "error": "camera_label must be cam1 or cam2"}, 400
    if file is None or not file.filename:
        return {"ok": False, "error": "missing file"}, 400

    session_dir = _OUTPUT_ROOT / session_id
    camera_dir = session_dir / camera_label
    camera_dir.mkdir(parents=True, exist_ok=True)

    safe_timestamp = timestamp.replace(":", "-").replace("/", "-")
    safe_frame = frame_index or "0"
    filename = f"frame_{safe_frame}_{safe_timestamp}.jpg"
    destination = camera_dir / filename
    file.save(destination)

    csv_path = session_dir / "image_log.csv"
    now_utc = dt.datetime.now(dt.timezone.utc).isoformat()
    _append_csv_row(
        csv_path,
        [
            now_utc,
            session_id,
            camera_label,
            safe_frame,
            timestamp,
            file.filename,
            str(destination),
            str(destination.stat().st_size),
        ],
    )

    return (
        jsonify(
            {
                "ok": True,
                "saved_to": str(destination),
                "session_id": session_id,
                "camera_label": camera_label,
                "frame_index": safe_frame,
            }
        ),
        200,
    )


def main() -> None:
    global _OUTPUT_ROOT

    parser = argparse.ArgumentParser(description="Stereo raw upload server")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--output", default=str(_OUTPUT_ROOT))
    args = parser.parse_args()

    _OUTPUT_ROOT = Path(args.output).expanduser().resolve()
    _OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)

    print(f"[stereo-upload] listening on http://{args.host}:{args.port}")
    print(f"[stereo-upload] output root: {_OUTPUT_ROOT}")
    app.run(host=args.host, port=args.port, debug=False)


if __name__ == "__main__":
    main()
