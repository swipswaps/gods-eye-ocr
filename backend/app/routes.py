import logging

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import text
from sqlalchemy.orm import Session

from . import schemas
from .database import get_db
from .rag import query_rag, store_document

router = APIRouter(prefix="/api")
logger = logging.getLogger(__name__)


@router.get("/health")
def health(db: Session = Depends(get_db)):
    try:
        # SQLAlchemy 2.0 requires an executable construct, not a raw string.
        db.execute(text("SELECT 1"))
        return {"status": "ok", "database": "connected"}
    except Exception as exc:
        logger.error("Health check failed: %s", exc)
        raise HTTPException(status_code=503, detail="Database unavailable")


@router.post("/ingest")
def ingest_document(payload: schemas.IngestRequest):
    try:
        doc_id = store_document(payload.title, payload.content, payload.metadata)
    except Exception as exc:
        logger.error("Ingest failed: %s", exc)
        raise HTTPException(status_code=500, detail=f"Ingest failed: {exc}")
    return {"id": doc_id, "message": "Document stored"}


@router.post("/query")
def rag_query(request: schemas.QueryRequest):
    try:
        results = query_rag(request.query, top_k=request.top_k or 5)
    except Exception as exc:
        logger.error("Query failed: %s", exc)
        raise HTTPException(status_code=500, detail=f"Query failed: {exc}")
    return {"results": results}
