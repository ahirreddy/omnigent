"""Count each session's turn starts on conversation metadata.

Revision ID: a1fc08d02b91
Revises: 27d16059fab9

Adds a nullable ``turns_started`` (Integer) to ``omnigent_conversation_metadata``,
beside the other live-state columns so its writes cannot bump
``conversations.updated_at``. The live-status write adds one whenever
``live_status`` goes from idle, failed or ``NULL`` to running or waiting. The
session list serves it, so a client that reads rows every few seconds can tell a
turn started and finished between two reads, which ``live_status`` alone cannot
show.

SQLite does not enforce declared types, so there, and on Cloudflare D1, which
serves SQLite, the column is added with a CHECK that it holds an integer, in one
``ADD COLUMN`` so the table is not rebuilt.

Additive with no default or backfill: ``NULL`` reads as no turns started. Deploy
before the server that writes it; older servers ignore the column. Downgrade
drops it, and clients then see the count restart.
"""

from __future__ import annotations

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "a1fc08d02b91"
down_revision: str | None = "27d16059fab9"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_TABLE = "omnigent_conversation_metadata"
_INTEGER_CHECK = "ck_conversation_metadata_turns_started_integer"
# Dialects that store a value of any type in any column.
_SQLITE_FAMILY = frozenset({"sqlite", "cloudflare_d1"})


def upgrade() -> None:
    """Add ``turns_started``."""
    if op.get_bind().dialect.name in _SQLITE_FAMILY:
        op.execute(
            f"ALTER TABLE {_TABLE} ADD COLUMN turns_started INTEGER "
            f"CONSTRAINT {_INTEGER_CHECK} "
            "CHECK (turns_started IS NULL OR typeof(turns_started) = 'integer')"
        )
    else:
        op.add_column(_TABLE, sa.Column("turns_started", sa.Integer(), nullable=True))


def downgrade() -> None:
    """Remove ``turns_started``."""
    with op.batch_alter_table(_TABLE) as batch_op:
        if op.get_bind().dialect.name in _SQLITE_FAMILY:
            # The rebuilt table would otherwise keep a CHECK on the dropped column.
            batch_op.drop_constraint(_INTEGER_CHECK, type_="check")
        batch_op.drop_column("turns_started")
