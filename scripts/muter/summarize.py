#!/usr/bin/env python3
"""Prints a one-line summary of the results of compare-regression.py."""
import json
import sys

s = json.load(open(sys.argv[1]))["summary"]
keys = ["muterMutants", "matchedMutants", "sameOutcome", "differentOutcome", "differentOutcomeCoarse", "muterOnly", "xcmutateTotal"]
print(", ".join(f"{k} {s[k]}" for k in keys))
