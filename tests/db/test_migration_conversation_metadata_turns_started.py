"""Tests for the conversation metadata turn-count migration (a1fc08d02b91).

The migration and the ORM model both add ``turns_started`` as a nullable integer
with no database default. Existing rows keep their values and read ``NULL``;
downgrading drops the column and keeps the rows. SQLite does not enforce declared
types, so there a CHECK keeps the column an integer. Cloudflare D1 serves SQLite
under its own dialect name, so every database test also runs this migration and
the model against a SQLite file registered under that name. The earlier
migrations it builds on run as plain SQLite.
"""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

import pytest
import sqlalchemy as sa
from alembic import command
from alembic.ddl.sqlite import SQLiteImpl
from sqlalchemy.dialects import registry
from sqlalchemy.dialects.sqlite.pysqlite import SQLiteDialect_pysqlite

from omnigent.db.db_models import OmnigentBase, SqlConversationMetadata
from omnigent.db.utils import _build_alembic_config, clear_engine_cache

_PREVIOUS = "27d16059fab9"
_REVISION = "a1fc08d02b91"
_TABLE = "omnigent_conversation_metadata"
_SESSION_ID = bytes.fromhex("0123456789abcdef0123456789abcdef")


class _D1OnSqlite(SQLiteDialect_pysqlite):
    """A local SQLite file under Cloudflare D1's dialect name, which is what D1 runs."""

    name = "cloudflare_d1"
    supports_statement_cache = True


class _D1MigrationImpl(SQLiteImpl):
    """Alembic's SQLite behavior for the D1 dialect name."""

    __dialect__ = "cloudflare_d1"


registry.register("cloudflare_d1.turns_sqlite", __name__, "_D1OnSqlite")


def _migrate(uri: str, engine: sa.Engine, step: str, revision: str) -> None:
    config = _build_alembic_config(uri)
    with engine.begin() as conn:
        config.attributes["connection"] = conn
        getattr(command, step)(config, revision)


def _columns(engine: sa.Engine) -> dict[str, dict[str, object]]:
    return {column["name"]: column for column in sa.inspect(engine).get_columns(_TABLE)}


def _insert(engine: sa.Engine, row_id: int, turns_started: object) -> None:
    with engine.begin() as conn:
        conn.execute(
            sa.text(
                f"INSERT INTO {_TABLE} (workspace_id, id, kind, git_branch, turns_started) "
                "VALUES (0, :id, 1, 'main', :value)"
            ),
            {"id": row_id.to_bytes(16, "big"), "value": turns_started},
        )


def _assert_holds_only_integers(engine: sa.Engine) -> None:
    for row_id, value in enumerate((None, 0, 2_147_483_647), start=1):
        _insert(engine, row_id, value)
    for row_id, value in enumerate(("a" * 16_384, b"\x00" * 16_384, 1.5), start=50):
        with pytest.raises(sa.exc.IntegrityError):
            _insert(engine, row_id, value)


@pytest.fixture(params=["sqlite", "cloudflare_d1+turns_sqlite"])
def database(tmp_path: Path, request: pytest.FixtureRequest) -> Iterator[tuple[str, sa.Engine]]:
    """
    One SQLite file under the dialect being tested, already migrated to the
    revision before this one as plain SQLite.
    """
    path = tmp_path / "metadata.db"
    base_uri = f"sqlite:///{path}"
    base = sa.create_engine(base_uri)
    uri = f"{request.param}:///{path}"
    engine = sa.create_engine(uri)
    try:
        _migrate(base_uri, base, "upgrade", _PREVIOUS)
        yield uri, engine
    finally:
        base.dispose()
        engine.dispose()
        clear_engine_cache()


def test_model_declares_a_nullable_integer_without_default() -> None:
    column = SqlConversationMetadata.__table__.c.turns_started
    assert isinstance(column.type, sa.Integer)
    assert column.nullable
    assert column.server_default is None


def test_upgrade_adds_the_column_and_keeps_rows(database: tuple[str, sa.Engine]) -> None:
    uri, engine = database
    with engine.begin() as conn:
        conn.execute(
            sa.text(
                f"INSERT INTO {_TABLE} (workspace_id, id, kind, git_branch) "
                "VALUES (0, :id, 1, 'main')"
            ),
            {"id": _SESSION_ID},
        )

    _migrate(uri, engine, "upgrade", _REVISION)

    column = _columns(engine)["turns_started"]
    assert isinstance(column["type"], sa.Integer)
    assert column["nullable"] is True
    assert column["default"] is None
    with engine.connect() as conn:
        row = conn.execute(sa.text(f"SELECT git_branch, turns_started FROM {_TABLE}")).one()
    assert tuple(row) == ("main", None)
    _assert_holds_only_integers(engine)


def test_model_built_schema_keeps_the_column_an_integer(database: tuple[str, sa.Engine]) -> None:
    _, engine = database
    with engine.begin() as conn:
        conn.execute(sa.text(f"DROP TABLE {_TABLE}"))
    OmnigentBase.metadata.create_all(engine, tables=[SqlConversationMetadata.__table__])

    _assert_holds_only_integers(engine)


def test_downgrade_drops_the_column_and_keeps_rows(database: tuple[str, sa.Engine]) -> None:
    uri, engine = database
    _migrate(uri, engine, "upgrade", _REVISION)
    _insert(engine, 1, 7)

    _migrate(uri, engine, "downgrade", _PREVIOUS)

    assert "turns_started" not in _columns(engine)
    with engine.connect() as conn:
        assert conn.execute(sa.text(f"SELECT git_branch FROM {_TABLE}")).scalar_one() == "main"
