from sqlalchemy import Column, Integer, String, Text, DateTime, JSON
from sqlalchemy.sql import func
from .database import Base

class Document(Base):
    __tablename__ = "documents"
    id = Column(Integer, primary_key=True, index=True)
    title = Column(String, nullable=False)
    content = Column(Text, nullable=False)
    metadata = Column(JSON, default={})
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    embedding = Column(Text)  # JSON string of vector
