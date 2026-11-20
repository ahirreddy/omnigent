"""Merge the session turn-count and scheduled-task Smart Routing schema branches.

Revision ID: 40c09d23bfbf
Revises: d82de8347bf0, 5ab01aaca219

Both parent revisions remain unchanged. Upgrade and downgrade only reconcile
Alembic's version rows; the merge itself changes no application schema or data.
"""

from __future__ import annotations

revision: str = "40c09d23bfbf"
down_revision: tuple[str, ...] = ("d82de8347bf0", "5ab01aaca219")
branch_labels: tuple[str, ...] | None = None
depends_on: tuple[str, ...] | None = None


def upgrade() -> None:
    """Join the independently applied parent revisions."""


def downgrade() -> None:
    """Restore both parent version markers without undoing either schema."""
