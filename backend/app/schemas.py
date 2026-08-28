from pydantic import BaseModel
from typing import Optional, Dict, Any

class IngestRequest(BaseModel):
    title: str
    content: str
    metadata: Optional[Dict[str, Any]] = None

class QueryRequest(BaseModel):
    query: str
    top_k: Optional[int] = 5
