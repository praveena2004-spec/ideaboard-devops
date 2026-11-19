from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


# ---------- Ideas ----------
class IdeaCreate(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    description: str = Field(default="", max_length=5000)


class IdeaOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    title: str
    description: str
    created_at: datetime


# ---------- AI: log analysis ----------
class LogAnalysisRequest(BaseModel):
    logs: str = Field(min_length=1)
    context: str = Field(default="", max_length=2000, description="e.g. 'staging rollout of backend:abc123'")


class LogAnalysis(BaseModel):
    status: Literal["healthy", "degraded", "failed"]
    summary: str
    root_cause: str
    issues: list[str]
    suggested_fixes: list[str]
    recommendation: Literal["proceed", "investigate", "rollback"]
    confidence: Literal["low", "medium", "high"]


class LogAnalysisOut(LogAnalysis):
    source: Literal["llm", "rules"]
    note: str = ""


# ---------- AI: deployment recommendation ----------
class DeploymentSignals(BaseModel):
    environment: Literal["development", "staging", "production"] = "staging"
    change_summary: str = Field(default="", max_length=5000)
    error_rate_percent: float = Field(default=0.0, ge=0)
    p95_latency_ms: float = Field(default=0.0, ge=0)
    pod_restarts: int = Field(default=0, ge=0)
    tests_passed: bool = True
    recent_logs: str = Field(default="", description="optional log excerpt from the current rollout")


class DeploymentRecommendation(BaseModel):
    decision: Literal["deploy", "canary", "hold", "rollback"]
    strategy: str
    risk_level: Literal["low", "medium", "high"]
    reasons: list[str]
    pre_deploy_checks: list[str]


class DeploymentRecommendationOut(DeploymentRecommendation):
    source: Literal["llm", "rules"]
    note: str = ""
