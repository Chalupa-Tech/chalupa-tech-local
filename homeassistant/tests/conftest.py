"""Make pyscript/ modules importable as plain Python during tests."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "pyscript"))
