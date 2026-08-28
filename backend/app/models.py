from sqlalchemy import JSON, Column, DateTime, Integer, String, Text
from sqlalchemy.sql import func

from .database import Base


class Document(Base):
    __tablename__ = "documents"

    id = Column(Integer, primary_key=True, index=True)
    title = Column(String, nullable=False)
    content = Column(Text, nullable=False)
    # NOTE: attribute MUST NOT be called `metadata` - that name is reserved
    # for the MetaData instance on any declarative class.
    doc_metadata = Column("doc_metadata", JSON, default=dict)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    embedding = Column(Text)  # JSON string of the vector, for reference
