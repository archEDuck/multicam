#!/usr/bin/env python3
"""Convert ONNX Constant node tensors from FLOAT16 to FLOAT32.

Usage:
  python tools/fix_onnx_constant_fp16_to_fp32.py \
    --input assets/foundation_stereo_cleaned_fp32.onnx \
    --output assets/foundation_stereo_cleaned_fp32.onnx
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, numpy_helper


def convert_constants_fp16_to_fp32(model: onnx.ModelProto) -> int:
    changed = 0
    for node in model.graph.node:
        if node.op_type != "Constant":
            continue
        for attr in node.attribute:
            if attr.name != "value" or not attr.HasField("t"):
                continue
            if attr.t.data_type != TensorProto.FLOAT16:
                continue

            values = numpy_helper.to_array(attr.t).astype(np.float32)
            tensor_name = attr.t.name if attr.t.name else ""
            attr.t.CopyFrom(numpy_helper.from_array(values, name=tensor_name))
            changed += 1
    return changed


def count_constant_fp16(model: onnx.ModelProto) -> int:
    count = 0
    for node in model.graph.node:
        if node.op_type != "Constant":
            continue
        for attr in node.attribute:
            if attr.name == "value" and attr.HasField("t") and attr.t.data_type == TensorProto.FLOAT16:
                count += 1
    return count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, help="Input ONNX path")
    parser.add_argument("--output", required=True, help="Output ONNX path")
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Allow overwriting output file if it exists",
    )
    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output)

    if not input_path.exists():
        raise FileNotFoundError(f"Input model not found: {input_path}")

    if output_path.exists() and not args.overwrite:
        raise FileExistsError(
            f"Output already exists: {output_path} (use --overwrite to replace)",
        )

    model = onnx.load(str(input_path), load_external_data=True)
    before = count_constant_fp16(model)
    changed = convert_constants_fp16_to_fp32(model)
    onnx.save(model, str(output_path))

    fixed = onnx.load(str(output_path), load_external_data=True)
    after = count_constant_fp16(fixed)

    print(f"Input : {input_path}")
    print(f"Output: {output_path}")
    print(f"Changed constant tensors: {changed}")
    print(f"FP16 constants before: {before}, after: {after}")

    if after != 0:
        raise RuntimeError("Conversion incomplete: some FP16 Constant tensors remain")

    onnx.checker.check_model(fixed)
    print("ONNX checker: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
