"""
Application entry point for the Banking Transfer System with Audit Logging.

This module wires together all layers:
- Domain models and invariant validators
- Infrastructure (database, metrics)
- Middleware (authentication, authorization)
- API routes
"""

from __future__ import annotations

import structlog
from fastapi import FastAPI, Request, status
from fastapi.responses import JSONResponse
from prometheus_client import make_asgi_app

from src.api.routes import router
from src.config import settings
from src.domain.invariants import InvariantViolation
from src.domain.models import Base
from src.infrastructure.database import engine

structlog.configure(
    processors=[
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer(),
    ],
)

logger = structlog.get_logger()


def create_app() -> FastAPI:
    """Create and configure the FastAPI application."""
    app = FastAPI(
        title="Banking Transfer System",
        description="Banking Transfer System with Audit Logging — Specification-Led Implementation",
        version="1.0.0",
        docs_url="/api/docs",
        openapi_url="/api/openapi.json",
    )

    # Register API routes
    app.include_router(router)

    # Mount Prometheus metrics endpoint
    metrics_app = make_asgi_app()
    app.mount("/metrics", metrics_app)

    # Global exception handler for invariant violations
    @app.exception_handler(InvariantViolation)
    async def invariant_violation_handler(
        request: Request, exc: InvariantViolation
    ) -> JSONResponse:
        logger.warning(
            "invariant_violation",
            fact=exc.fact_name,
            detail=str(exc),
        )
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content={"detail": str(exc), "error_code": exc.fact_name},
        )

    # Startup: create tables
    @app.on_event("startup")
    async def on_startup() -> None:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        logger.info("database_tables_created")

    # Shutdown: dispose engine
    @app.on_event("shutdown")
    async def on_shutdown() -> None:
        await engine.dispose()
        logger.info("database_engine_disposed")

    # Health check
    @app.get("/health")
    async def health() -> dict:
        return {"status": "ok"}

    return app


app = create_app()


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "src.main:app",
        host=settings.host,
        port=settings.port,
        reload=True,
    )
