import json
import logging
import random

from .config import settings
from .database import SessionLocal, get_raw_connection
from .models import Document

logger = logging.getLogger(__name__)


def _serialize(vector: list[float]):
    """sqlite-vec accepts a packed float32 blob; fall back to JSON text."""
    try:
        import sqlite_vec

        return sqlite_vec.serialize_float32(vector)
    except Exception:
        return json.dumps(vector)


def init_vec_schema() -> bool:
    """Create the vec0 virtual table once, at startup."""
    conn = get_raw_connection()
    try:
        conn.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS vec_documents "
            f"USING vec0(embedding float[{settings.VECTOR_DIM}]);"
        )
        conn.commit()
        return True
    except Exception as exc:
        logger.warning("vec_documents table unavailable: %s", exc)
        return False
    finally:
        conn.close()


def get_embedding(text: str) -> list[float]:
    if settings.OPENAI_API_KEY:
        # Imported lazily: the app must start even when the OpenAI stack is
        # not configured or not installed.
        from langchain_openai import OpenAIEmbeddings

        embeddings = OpenAIEmbeddings(
            api_key=settings.OPENAI_API_KEY,
            dimensions=settings.VECTOR_DIM,
        )
        return embeddings.embed_query(text)
    # Deterministic-length dummy embedding for local demo use.
    return [random.random() for _ in range(settings.VECTOR_DIM)]


def store_document(title: str, content: str, metadata: dict | None = None) -> int:
    embedding = get_embedding(content)

    db = SessionLocal()
    try:
        doc = Document(
            title=title,
            content=content,
            doc_metadata=metadata or {},
            embedding=json.dumps(embedding),
        )
        db.add(doc)
        db.commit()
        db.refresh(doc)
        doc_id = doc.id
    finally:
        db.close()

    conn = get_raw_connection()
    try:
        conn.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS vec_documents "
            f"USING vec0(embedding float[{settings.VECTOR_DIM}]);"
        )
        conn.execute(
            "INSERT INTO vec_documents(rowid, embedding) VALUES (?, ?)",
            (doc_id, _serialize(embedding)),
        )
        conn.commit()
    finally:
        conn.close()

    return doc_id


def query_rag(query: str, top_k: int = 5) -> list[dict]:
    embedding = get_embedding(query)

    conn = get_raw_connection()
    try:
        rows = conn.execute(
            """
            SELECT rowid, distance
            FROM vec_documents
            WHERE embedding MATCH ?
            ORDER BY distance
            LIMIT ?
            """,
            (_serialize(embedding), top_k),
        ).fetchall()
    except Exception as exc:
        logger.error("vector search failed: %s", exc)
        raise
    finally:
        conn.close()

    if not rows:
        return []

    ids = [rowid for rowid, _ in rows]
    distances = dict(rows)

    db = SessionLocal()
    try:
        docs = db.query(Document).filter(Document.id.in_(ids)).all()
        by_id = {d.id: d for d in docs}
    finally:
        db.close()

    results = []
    for rowid in ids:
        doc = by_id.get(rowid)
        if doc:
            results.append(
                {
                    "id": doc.id,
                    "title": doc.title,
                    "content": doc.content,
                    "distance": distances[rowid],
                }
            )
    return results
