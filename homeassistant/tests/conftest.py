"""Make pyscript modules importable as plain Python during tests.

Pyscript loads importable modules from `pyscript/modules/`, not from
`pyscript/` itself — top-level files there are trigger scripts.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "pyscript" / "modules"))
