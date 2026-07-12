# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Nebula contributors
"""Phase 0 bake prototype for Nebula (dev-only, never shipped).

Mirrors the Swift `NebulaCore` structure so the emitted `manifest.json` matches
`NebulaCore.Manifest` exactly. Once the bake is proven here, Phase 3 re-issues
the same Siril commands from Swift and the AI steps move in-process to CoreML.
"""

__all__ = ["headers", "siril", "ai", "manifest"]
