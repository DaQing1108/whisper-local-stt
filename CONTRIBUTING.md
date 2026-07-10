# Contributing

## Workflow

1. Confirm scope before making a non-trivial change.
2. Branch from `main`.
3. Keep changes focused and reviewable.
4. Run the repo's relevant checks before opening a pull request.
5. Open a pull request with verification details.

## Recommended Checks

For normal code changes, run:

- `python3 -m py_compile app.py routes.py whisper_core.py integrations.py llm_post.py sse.py gui.py`
- `python3 -m pytest tests/unit -q`

When the change touches server flows, packaging, or UI behavior, also consider:

- integration tests in `tests/integration/`
- e2e tests in `tests/e2e/`
- packaging via `bash package.sh`
- manual validation via `tests/manual_checklist.md`

## Documentation

Update documentation when setup, workflows, or user-facing behavior changes.
