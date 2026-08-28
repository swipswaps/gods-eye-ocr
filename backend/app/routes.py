from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from .database import get_db
from .models import Document
from .rag import store_document, query_rag
from . import schemas
import logging

router = APIRouter(prefix="/api")
logger = logging.getLogger(__name__)

@router.get("/health")
def health(db: Session = Depends(get_db)):
    try:
        db.execute("SELECT 1")
        return {"status": "ok", "database": "connected"}
    except Exception as e:
        logger.error("Health check failed: %s", e)
        raise HTTPException(status_code=503, detail="Database unavailable")

@router.post("/ingest")
def ingest_document(payload: schemas.IngestRequest, db: Session = Depends(get_db)):
    doc_id = store_document(payload.title, payload.content, payload.metadata)
    return {"id": doc_id, "message": "Document stored"}

@router.post("/query")
def rag_query(request: schemas.QueryRequest, db: Session = Depends(get_db)):
    results = query_rag(request.query, top_k=request.top_k or 5)
    return {"results": results}
