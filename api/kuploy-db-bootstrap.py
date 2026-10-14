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

READ THIS BEFORE WRITING THE NEXT MIGRATION.
============================================

`alembic stamp head` asserts that this database is at head. It is at the
MODELS' schema, which is NOT byte-identical to what the 76-revision chain
produces. If you autogenerate a migration, alembic will diff against
whichever of the two your own database came from, and the differences below
will show up as spurious changes — or, worse, a migration that assumes the
chain's shape will be applied to this one.

Measured by diffing information_schema COLUMNS / KEY_COLUMN_USAGE /
STATISTICS between the two, both built on the same server (mariadb:10.6.14)
so builder differences are isolated from version differences.

IDENTICAL:
  * table set — 31 application tables, no table on one side only
  * foreign keys — all 54 relationships match exactly, name-independent.
    (A naive diff shows ~70 differing rows because auto-generated
    `<table>_ibfk_N` names map to different columns on each side. The
    constraint SET is the same; only the labels differ.)

DIFFERENT — the chain is the side that has drifted from the models:
  1. `user` PRIMARY KEY. chain = (id, netid) composite; models = (id),
     with netid as a separate index. The ORM expects the models' version.
  2. `theia_session.network_locked` exists only in the chain. The model
     dropped the column; no migration ever did.
  3. Column widths, where a migration widened or narrowed and the model
     did not follow (or the reverse):
       assigned_student_response.assigned_question_id  36  vs 128
       theia_image.icon                              1024  vs 128
       course.github_org                              text vs varchar(256)
       static_file.filename / path / content_type  varchar vs mediumtext
  4. text vs mediumtext on many columns — the models say mediumtext.
  5. Collation on the JSON-ish longtext columns: chain
     utf8mb4_general_ci, models utf8mb4_bin (theia_options,
     theia_default_options, submission.errors, theia_session.resources).
     This one changes comparison and sort behaviour, not just storage.
  6. `assignment_test.order` — NOT NULL in the chain, nullable in the
     models.

Why ship anyway: a fresh deploy is self-consistent, because create_all and
the running app are built from the same models. The app works. The exposure
is entirely in the future — a migration authored against one shape and
applied to the other.

Note what this says about upstream, too: their own migrated production
database differs from their own models in all six ways above. The drift is
not something this file introduces; it is something this file makes
visible.
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
