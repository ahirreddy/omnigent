"""Merge the session turn-count and workflow-shares schema branches.

Revision ID: d82de8347bf0
Revises: 844462a089df, d3bda6dbade3

Both parent revisions remain unchanged. Upgrade and downgrade only reconcile
Alembic's version rows; the merge itself changes no application schema or data.
"""

from __future__ import annotations

revision: str = "d82de8347bf0"
down_revision: tuple[str, ...] = ("844462a089df", "d3bda6dbade3")
branch_labels: tuple[str, ...] | None = None
depends_on: tuple[str, ...] | None = None


def upgrade() -> None:
    """Join the independently applied parent revisions."""


def downgrade() -> None:
    """Restore both parent version markers without undoing either schema."""
