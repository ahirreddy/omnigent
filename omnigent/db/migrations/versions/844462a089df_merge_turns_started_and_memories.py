"""Merge the session turn-count and memories schema branches.

Revision ID: 844462a089df
Revises: a1fc08d02b91, ffeec66eadb5

Both parent revisions remain unchanged. Upgrade and downgrade only reconcile
Alembic's version rows; the merge itself changes no application schema or data.
"""

from __future__ import annotations

revision: str = "844462a089df"
down_revision: tuple[str, ...] = ("a1fc08d02b91", "ffeec66eadb5")
branch_labels: tuple[str, ...] | None = None
depends_on: tuple[str, ...] | None = None


def upgrade() -> None:
    """Join the independently applied parent revisions."""


def downgrade() -> None:
    """Restore both parent version markers without undoing either schema."""
