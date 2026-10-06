#!/usr/bin/env python3
"""Convert the official Apollo checkpoint (Hugging Face JusperLee/Apollo, pytorch_model.bin)
into the safetensors layout the Swift ApolloMLX model loads.

    python convert_weights.py pytorch_model.bin apollo-mlx.safetensors

Mirrors Sources/ApolloMLX/WeightConversion.swift exactly (the Swift prepare() does the same
conversion without Python); this script exists for Linux reference work and as a fallback.
Layout: channels-last, every 1x1 conv becomes an [in, out] matmul weight, the 79 equal
5-bin bands are stacked into one batched tensor, band 79 (47 bins) is kept separate.
Weights: CC BY-SA 4.0, Kai Li and Yi Luo, https://github.com/JusperLee/Apollo
"""
import sys

import numpy as np
import torch
from safetensors.numpy import save_file

NB = 79  # bands of equal width; the 80th band is the remainder


def convert(sd: dict) -> dict:
    g = lambda k: sd[k].detach().float().numpy()
    out = {}
    # Band-split bottleneck: RMSNorm(2*bw+1) -> Conv1d(2*bw+1, 256, 1)
    out["bn.norm"] = np.stack([g(f"BN.{i}.0.weight") for i in range(NB)])               # 79, 11
    out["bn.w"] = np.stack([g(f"BN.{i}.1.weight")[:, :, 0].T for i in range(NB)])       # 79, 11, 256
    out["bn.b"] = np.stack([g(f"BN.{i}.1.bias") for i in range(NB)])                    # 79, 256
    out["bn_last.norm"] = g(f"BN.{NB}.0.weight")                                        # 95
    out["bn_last.w"] = g(f"BN.{NB}.1.weight")[:, :, 0].T                                # 95, 256
    out["bn_last.b"] = g(f"BN.{NB}.1.bias")                                             # 256
    layers = sorted({int(k.split(".")[1]) for k in sd if k.startswith("net.")})
    for l in layers:
        p, q = f"net.{l}.band_net.", f"layers.{l}.band."
        out[q + "norm"] = g(p + "input_norm.weight")
        out[q + "qkv"] = g(p + "weight.weight")[:, :, 0].T                              # 256, 768
        out[q + "out"] = g(p + "output.weight")[:, :, 0].T                              # 256, 256
        out[q + "mlp_norm"] = g(p + "MLP.0.weight")
        out[q + "mlp_in"] = g(p + "MLP.1.weight")[:, :, 0].T                            # 256, 2048
        out[q + "mlp_out"] = g(p + "MLP_output.weight")[:, :, 0].T                      # 1024, 256
        for j in range(3):
            p, q = f"net.{l}.seq_net.blocks.{j}.conv.", f"layers.{l}.seq.{j}."
            out[q + "dw_w"] = g(p + "0.weight")[:, 0, :].T                              # 7, 256
            out[q + "dw_b"] = g(p + "0.bias")
            out[q + "norm"] = g(p + "1.weight")
            out[q + "fc1_w"] = g(p + "2.weight")[:, :, 0].T                             # 256, 1024
            out[q + "fc1_b"] = g(p + "2.bias")
            out[q + "fc2_w"] = g(p + "4.weight")[:, :, 0].T                             # 1024, 256
            out[q + "fc2_b"] = g(p + "4.bias")
    # RoPE tables (identical in every layer); only the first 80 positions are ever used.
    out["rope.cos"] = g("net.0.band_net.cos_freq")[:80]                                 # 80, 32
    out["rope.sin"] = g("net.0.band_net.sin_freq")[:80]
    # Output heads: RMSNorm(256) -> Conv1d(256, 4*bw, 1) -> GLU
    out["head.norm"] = np.stack([g(f"output.{i}.0.weight") for i in range(NB)])         # 79, 256
    out["head.w"] = np.stack([g(f"output.{i}.1.weight")[:, :, 0].T for i in range(NB)]) # 79, 256, 20
    out["head.b"] = np.stack([g(f"output.{i}.1.bias") for i in range(NB)])              # 79, 20
    out["head_last.norm"] = g(f"output.{NB}.0.weight")
    out["head_last.w"] = g(f"output.{NB}.1.weight")[:, :, 0].T                          # 256, 188
    out["head_last.b"] = g(f"output.{NB}.1.bias")
    return {k: np.ascontiguousarray(v, dtype=np.float32) for k, v in out.items()}


def load_state_dict(path: str) -> dict:
    try:
        conf = torch.load(path, map_location="cpu", weights_only=True)
    except Exception:
        conf = torch.load(path, map_location="cpu", weights_only=False)
    return conf["state_dict"] if "state_dict" in conf else conf


if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    tensors = convert(load_state_dict(src))
    save_file(tensors, dst, metadata={"format": "apollo-mlx", "version": "1",
                                      "source": "huggingface.co/JusperLee/Apollo@c68bd80"})
    print(f"wrote {len(tensors)} tensors to {dst}")
