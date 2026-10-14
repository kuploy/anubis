"""
Bring the database to the current schema, for a platform deploy where no
human runs `make`.

WHY NOT JUST `alembic upgrade head`: the chain cannot be replayed from an
empty database. Measured against a fresh MariaDB:

  * 10.6 — dies at revision 61/76 in 4f7efe8d8177 with
    (1832, "Cannot change column 'owner_id': used in a foreign key
     constraint 'assigned_student_question_ibfk_2'")
  * 11.8 — same, and `SET FOREIGN_KEY_CHECKS=0` does NOT suppress it there
    (it does on 10.6, which is exactly the trap: a fix that passes the
    version you test and fails the version you deploy)

Tolerating the refusal (1832, and 1833 when another table references the
column) gets to 70/76 and then hits it again in a later revision. The
offending statements are ~120 hand-written charset ALTERs authored in 2022
against a live database where they were no-ops; several MODIFY columns that
sit in foreign keys, which MariaDB refuses outright whatever the column
already is. This history was never runnable from zero and patching each
revision that trips over it is not a line of work worth being on.

So: a database with no schema does not need the history. It needs the
schema the models describe, and an alembic_version that lets future
revisions apply normally.

  empty database  -> db.create_all(), then `alembic stamp head`
  existing schema -> `alembic upgrade head`, unchanged

The branch is decided by whether alembic_version exists and whether any
model table is present, never by a flag, so there is nothing to set wrong.
"""
import sys

from sqlalchemy import inspect

from anubis.app import create_app
from anubis.models import db

app = create_app()

with app.app_context():
    insp = inspect(db.engine)
    existing = set(insp.get_table_names())
    model_tables = set(db.metadata.tables.keys())
    has_schema = bool(existing & model_tables)
    has_version = "alembic_version" in existing

    if has_schema or has_version:
        print(
            f"bootstrap: {len(existing & model_tables)} model table(s) present, "
            f"alembic_version={'yes' if has_version else 'no'} -> upgrade",
            flush=True,
        )
        sys.exit(10)  # the caller runs `alembic upgrade head`

    print(f"bootstrap: empty database -> create_all ({len(model_tables)} tables)", flush=True)
    db.create_all()
    created = set(inspect(db.engine).get_table_names())
    missing = model_tables - created
    if missing:
        raise RuntimeError(f"create_all did not create: {sorted(missing)}")
    print(f"bootstrap: created {len(created & model_tables)} tables", flush=True)
    sys.exit(11)  # the caller runs `alembic stamp head`
