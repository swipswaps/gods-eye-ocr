from typing import Any, Dict, Optional

from pydantic import BaseModel, Field


class IngestRequest(BaseModel):
    title: str = Field(min_length=1)
    content: str = Field(min_length=1)
    metadata: Optional[Dict[str, Any]] = None


class QueryRequest(BaseModel):
    query: str = Field(min_length=1)
    top_k: Optional[int] = 5
