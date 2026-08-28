from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    DATABASE_URL: str = "sqlite:///./app.db?enable_load_extension=1"
    OPENAI_API_KEY: str = ""
    VECTOR_DIM: int = 1536

    class Config:
        env_file = ".env"

settings = Settings()
