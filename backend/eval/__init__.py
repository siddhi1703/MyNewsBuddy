"""Offline evaluation harness for hyperlocal source routing and retrieval.

This package measures how well the deterministic local router selects the
correct trusted sources for a question. It runs without a Gemini API key or
network access so the numbers are reproducible in CI and in interviews.

Entry point: ``python -m eval.run_eval`` (from the ``backend`` directory).
"""
