from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from .database import engine, Base
from .routes import router
import structlog

structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer()
    ]
)
logger = structlog.get_logger()

Base.metadata.create_all(bind=engine)

app = FastAPI(title="GodsEye+OCR Fusion (RAG only)", version="1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)
app.include_router(router)

@app.on_event("startup")
def startup():
    logger.info("Application started")

@app.get("/")
def root():
    return {"status": "RAG Backend"}
