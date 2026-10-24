"""Builds dq1_fixture.bin + dq1_fixture.json: a slice of real EmbeddingGemma 2 vectors and
what dq1.py's own functions compute on it, so the Dart decider can be held to the reference.

Inputs (not in this repository; they are the decision measurements' own files):
  --vectors  vectors_litert.npz of the 2026-10-07 few-shot run (fs2): CLINC150 rows embedded by
             Google's int4 embeddinggemma-2-text-270m.litertlm through LiteRT-LM 0.18.0's
             EmbeddingEngine, prompt "task: classification | query: ", float16.
  --dq1      the directory holding dq1.py (2026-10-13-decision-open-questions); its functions
             are imported, not copied, so the expected numbers are dq1's by construction.

The slice: 4 near-neighbour intents — the first intent (by index) together with the three whose
30-shot centroids are closest to it, such that dq1's C1 temperature on the slice is inside the
grid for both classifiers (the slice has errors to calibrate on; an easy slice puts the
temperature on the grid's floor and tests nothing) — their first 7 examples (rank 0-6, so the 5-fold cross-fit has two
uneven folds), 10 test rows each, 12 test rows of other intents, 8 calibration rows each.
Vectors are stored as the float16 they were saved as; dq1 and the Dart test both renormalise.

Run: python3 -I make_dq1_fixture.py --vectors <npz> --dq1 <dir> --out <this dir>
"""

import argparse
import json
import os
import sys

import numpy as np

SEED = 20261013
N_OPT, K, N_TEST, N_OUT, N_CAL = 4, 7, 10, 12, 8


def _interior_temperatures(z, intents, dq1):
    remap = {t: i for i, t in enumerate(intents)}
    m = np.isin(z["y_train"], intents) & (z["rank"] < K)
    ex = dq1.unit(z["train"][m])
    ey = np.array([remap[int(t)] for t in z["y_train"][m]])
    cal = np.concatenate([z["calib"][np.nonzero(z["y_calib"] == t)[0][:N_CAL]] for t in intents])
    cx, cy = dq1.unit(cal), np.repeat(np.arange(N_OPT), N_CAL)
    c = dq1.centroids(ex, ey, N_OPT)
    W, b = dq1.fit_linear(ex, ey, N_OPT, 1e-5)
    floor, ceiling = 1e-3 * (1 + 1e-9), 10 * (1 - 1e-9)
    return all(floor < dq1.fit_temperature(s, cy) < ceiling for s in (cx @ c.T, cx @ W + b))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--vectors", required=True)
    p.add_argument("--dq1", required=True)
    p.add_argument("--out", required=True)
    a = p.parse_args()
    sys.path.insert(0, a.dq1)
    import dq1  # noqa: E402

    z = np.load(a.vectors)
    rng = np.random.default_rng(SEED)
    all_c = dq1.centroids(dq1.unit(z["train"]), z["y_train"].astype(np.int64), 150)
    for seed_intent in range(150):
        intents = sorted(int(t) for t in np.argsort(-(all_c @ all_c[seed_intent]), kind="stable")[:N_OPT])
        if _interior_temperatures(z, intents, dq1):
            break
    remap = {t: i for i, t in enumerate(intents)}

    def rows(split, label_key, take, extra=None):
        out, labels = [], []
        for t in intents:
            idx = np.nonzero(z[label_key] == t)[0]
            if extra is not None:
                idx = idx[z["rank"][idx] < take]
            else:
                idx = idx[:take]
            out.append(z[split][idx])
            labels += [remap[t]] * len(idx)
        return np.concatenate(out), np.array(labels)

    ex16, ex_y = rows("train", "y_train", K, extra=True)
    ex_rank = np.tile(np.arange(K), N_OPT)
    te16, te_y = rows("test", "y_test", N_TEST)
    other = np.nonzero(~np.isin(z["y_test"], intents))[0]
    out16 = z["test"][rng.choice(other, size=N_OUT, replace=False)]
    cal16, cal_y = rows("calib", "y_calib", N_CAL)

    ex_x, te_x, out_x, cal_x = (dq1.unit(v) for v in (ex16, te16, out16, cal16))
    probe_x = np.concatenate([te_x, out_x])

    # Centroids, and the C3ii cross-fit exactly as run_setting computes it for signal (b).
    c_all = dq1.centroids(ex_x, ex_y, N_OPT)
    folds = ex_rank % 5
    oof_b = np.zeros(len(ex_y))
    for f in range(5):
        tr, held = folds != f, folds == f
        if not held.any():
            continue
        cf = dq1.centroids(ex_x[tr], ex_y[tr], N_OPT)
        oof_b[held] = (ex_x[held] @ cf.T).max(1)
    c3ii = dq1.keep95(oof_b)

    # The linear layer at the fixed decay.
    W, b = dq1.fit_linear(ex_x, ex_y, N_OPT, 1e-5)
    import torch

    X, Y = torch.tensor(ex_x), torch.tensor(ex_y)
    loss = float(torch.nn.functional.cross_entropy(X @ torch.tensor(W) + torch.tensor(b), Y)
                 + 1e-5 * (torch.tensor(W) ** 2).sum())

    # C1 on the calibration rows: temperature by NLL, then the 5 % error-budget threshold on (b).
    expected_c1 = {}
    for clf, model in (("centroid", lambda x: x @ c_all.T), ("linear", lambda x: x @ W + b)):
        s = model(cal_x)
        temp = dq1.fit_temperature(s, cal_y)
        pred = s.argmax(1)
        conf_b = (cal_x @ c_all.T).max(1)
        thr = dq1.threshold_rows(conf_b, pred, pred == cal_y, N_OPT)
        expected_c1[clf] = {"temperature": temp, "threshold": thr,
                            "probe_probabilities": dq1.softmax_rows(model(probe_x), temp).tolist()}

    blob = np.concatenate([ex16, te16, out16, cal16]).astype("<f2")
    with open(os.path.join(a.out, "dq1_fixture.bin"), "wb") as f:
        f.write(blob.tobytes())
    json.dump({
        "source": "dq1.py functions on fs2 vectors_litert.npz (CLINC150), make_dq1_fixture.py",
        "intents": intents, "dimension": int(ex16.shape[1]), "encoding": "float16 little-endian, row-major",
        "examples": {"rows": len(ex_y), "labels": ex_y.tolist(), "ranks": ex_rank.tolist()},
        "probe": {"rows": len(probe_x), "in_scope_labels": te_y.tolist(), "out_of_scope_rows": N_OUT},
        "calibration": {"rows": len(cal_y), "labels": cal_y.tolist()},
        "expected": {
            "centroid_cosines": (probe_x @ c_all.T).tolist(),
            "crossfit_oof_signal": oof_b.tolist(),
            "crossfit_threshold_keep95": c3ii,
            "linear_logits": (probe_x @ W + b).tolist(),
            "linear_loss": loss,
            "labelled": expected_c1,
        },
    }, open(os.path.join(a.out, "dq1_fixture.json"), "w"), indent=1)
    print("intents", intents, "c3ii", c3ii, "loss", loss, "bytes", blob.nbytes)


if __name__ == "__main__":
    main()
