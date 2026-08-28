import logging
import os
import sqlite3

from sqlalchemy import create_engine, event
from sqlalchemy.orm import declarative_base, sessionmaker

from .config import settings

logger = logging.getLogger(__name__)

_db_dir = os.path.dirname(os.path.abspath(settings.DB_PATH))
if _db_dir:
    os.makedirs(_db_dir, exist_ok=True)

engine = create_engine(
    settings.DATABASE_URL,
    connect_args={"check_same_thread": False},
    echo=False,
)

VEC_AVAILABLE = False


def _load_vec(dbapi_conn) -> bool:
    """Load the sqlite-vec extension onto a raw DBAPI connection.

    Returns True on success. A failure is logged and reported, never
    swallowed and never presented as success (Rule #37).
    """
    try:
        import sqlite_vec

        dbapi_conn.enable_load_extension(True)
        sqlite_vec.load(dbapi_conn)
        return True
    except Exception as exc:  # extension missing or unloadable
        logger.warning("sqlite-vec extension not loaded: %s", exc)
        return False
    finally:
        try:
            dbapi_conn.enable_load_extension(False)
        except Exception:
            pass


@event.listens_for(engine, "connect")
def _on_connect(dbapi_conn, connection_record):
    global VEC_AVAILABLE
    VEC_AVAILABLE = _load_vec(dbapi_conn)


def get_raw_connection() -> sqlite3.Connection:
    """Raw sqlite3 connection to the SAME file the ORM uses."""
    conn = sqlite3.connect(settings.DB_PATH)
    _load_vec(conn)
    return conn


SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
