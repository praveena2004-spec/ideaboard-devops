"""Idea Board API.

Endpoints
  GET  /health                         liveness  - is the process alive?
  GET  /ready                          readiness - can it serve traffic (DB reachable)?
  GET  /api/version                    release info (used to verify deploys/rollbacks)
  GET  /api/ideas                      list ideas
  POST /api/ideas                      create an idea
  POST /api/ai/analyze-logs            AI deployment log analysis
  POST /api/ai/deployment-recommendation  AI deploy/canary/hold/rollback decision
  POST /api/ai/environment-plan        AI goal -> environment sizing (validated)
"""
import logging
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException, Response, status
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import select, text
from sqlalchemy.orm import Session

from . import ai
from .config import settings
from .database import Base, engine, get_db
from .models import Idea
from .schemas import (
    DeploymentRecommendationOut,
    DeploymentSignals,
    EnvironmentGoal,
    EnvironmentPlanOut,
    IdeaCreate,
    IdeaOut,
    LogAnalysisOut,
    LogAnalysisRequest,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("ideaboard")


_schema_ready = False


def ensure_schema() -> bool:
    """Create the table if needed. Never raises: if the database isn't reachable
    yet (e.g. it starts after the backend), the pod just stays not-ready and
    /ready retries - instead of crashing into CrashLoopBackOff.
    For a real product you'd use Alembic migrations; create_all is idempotent."""
    global _schema_ready
    if not _schema_ready:
        try:
            Base.metadata.create_all(bind=engine)
            _schema_ready = True
        except Exception as exc:  # noqa: BLE001
            log.warning("Database not available yet (%s); will retry on /ready", type(exc).__name__)
    return _schema_ready


@asynccontextmanager
async def lifespan(_: FastAPI):
    ensure_schema()
    log.info("Started env=%s version=%s ai=%s", settings.app_env, settings.app_version,
             "llm" if settings.anthropic_api_key else "rules")
    yield


app = FastAPI(title="Idea Board API", version=settings.app_version, lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type"],
)


# ---------- Health checks (used by Docker, Kubernetes and the pipeline) ----------
@app.get("/health")
def health():
    """Liveness: no dependencies, so a DB outage doesn't cause restart storms."""
    return {"status": "ok"}


@app.get("/ready")
def ready(response: Response, db: Session = Depends(get_db)):
    """Readiness: only route traffic here when the database answers."""
    if settings.simulate_unhealthy:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "unhealthy", "reason": "SIMULATE_UNHEALTHY=true"}
    try:
        db.execute(text("SELECT 1"))
    except Exception as exc:  # noqa: BLE001
        log.error("Readiness check failed: %s", exc)
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "unhealthy", "reason": "database unreachable"}
    if not ensure_schema():
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "unhealthy", "reason": "schema not initialised"}
    return {"status": "ready"}


@app.get("/api/version")
def version():
    return {"version": settings.app_version, "environment": settings.app_env}


# ---------- Ideas ----------
@app.get("/api/ideas", response_model=list[IdeaOut])
def list_ideas(db: Session = Depends(get_db)):
    return db.scalars(select(Idea).order_by(Idea.created_at.desc(), Idea.id.desc())).all()


@app.post("/api/ideas", response_model=IdeaOut, status_code=status.HTTP_201_CREATED)
def create_idea(payload: IdeaCreate, db: Session = Depends(get_db)):
    content = payload.content.strip()
    if not content:
        raise HTTPException(status_code=422, detail="content must not be blank")
    idea = Idea(content=content)
    db.add(idea)
    db.commit()
    db.refresh(idea)
    return idea


# ---------- AI ----------
@app.post("/api/ai/analyze-logs", response_model=LogAnalysisOut)
def analyze_logs(payload: LogAnalysisRequest):
    try:
        return ai.analyze_logs(payload.logs, payload.context)
    except ai.LogTooLargeError as exc:
        raise HTTPException(status_code=413, detail=str(exc)) from exc


@app.post("/api/ai/environment-plan", response_model=EnvironmentPlanOut)
def environment_plan(payload: EnvironmentGoal):
    return ai.plan_environment(payload.goal)


@app.post("/api/ai/deployment-recommendation", response_model=DeploymentRecommendationOut)
def deployment_recommendation(payload: DeploymentSignals):
    try:
        return ai.recommend_deployment(payload)
    except ai.LogTooLargeError as exc:
        raise HTTPException(status_code=413, detail=str(exc)) from exc
