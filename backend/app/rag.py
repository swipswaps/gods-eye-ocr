import json
import sqlite3
from .database import SessionLocal
from .models import Document
from .config import settings
from langchain.embeddings import OpenAIEmbeddings
import logging

logger = logging.getLogger(__name__)

def get_embedding(text: str) -> list[float]:
    if settings.OPENAI_API_KEY:
        embeddings = OpenAIEmbeddings(openai_api_key=settings.OPENAI_API_KEY)
        return embeddings.embed_query(text)
    else:
        # Dummy random embedding for demo
        import random
        return [random.random() for _ in range(settings.VECTOR_DIM)]

def store_document(title: str, content: str, metadata: dict = None):
    db = SessionLocal()
    embedding = get_embedding(content)
    doc = Document(title=title, content=content, metadata=metadata or {}, embedding=json.dumps(embedding))
    db.add(doc)
    db.commit()
    db.refresh(doc)

    # Insert into sqlite-vec virtual table
    conn = sqlite3.connect(settings.DATABASE_URL.replace("sqlite:///", ""))
    conn.execute("CREATE VIRTUAL TABLE IF NOT EXISTS vec_documents USING vec0(embedding float[1536]);")
    conn.execute("INSERT INTO vec_documents(rowid, embedding) VALUES (?, ?)", (doc.id, json.dumps(embedding)))
    conn.commit()
    conn.close()
    return doc.id

def query_rag(query: str, top_k: int = 5) -> list[dict]:
    embedding = get_embedding(query)
    conn = sqlite3.connect(settings.DATABASE_URL.replace("sqlite:///", ""))
    cursor = conn.execute("""
        SELECT rowid, distance
        FROM vec_documents
        WHERE embedding MATCH ?
        ORDER BY distance
        LIMIT ?
    """, (json.dumps(embedding), top_k))
    results = []
    for rowid, dist in cursor:
        doc = SessionLocal().query(Document).filter(Document.id == rowid).first()
        if doc:
            results.append({
                "id": doc.id,
                "title": doc.title,
                "content": doc.content,
                "distance": dist
            })
    conn.close()
    return results
