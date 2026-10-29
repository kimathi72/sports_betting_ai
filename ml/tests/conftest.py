"""Make the ``ml`` package importable when running tests from ``ml/``.

This is a tiny shim so pytest can resolve ``from ml.app.features import ...``
whether the tests are invoked from the repository root or from inside
``ml/``.  It does not alter any other behaviour.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)