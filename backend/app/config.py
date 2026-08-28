from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # Single source of truth for the database location. Both the SQLAlchemy
    # engine and the raw sqlite3 connections used for sqlite-vec derive from
    # this one value, so they can never diverge.
    DB_PATH: str = "./data/app.db"
    OPENAI_API_KEY: str = ""
    VECTOR_DIM: int = 1536

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    @property
    def DATABASE_URL(self) -> str:
        return f"sqlite:///{self.DB_PATH}"


settings = Settings()
