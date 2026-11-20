"""Workflow actions: one WorkflowAction subclass per action, auto-discovered."""

from app.workflow.actions.base import ActionResult, CompositeStep, WorkflowAction, discover

__all__ = ["ActionResult", "CompositeStep", "WorkflowAction", "discover"]
