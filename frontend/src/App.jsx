import { useEffect, useState } from "react";
import {
  analyzeLogs,
  createIdea,
  getIdeas,
  getVersion,
  planEnvironment,
  recommendDeployment,
} from "./api.js";
import { FAILED_LOG, HEALTHY_LOG } from "./samples.js";

export default function App() {
  const [version, setVersion] = useState(null);

  useEffect(() => {
    getVersion().then(setVersion).catch(() => setVersion(null));
  }, []);

  return (
    <div className="page">
      <header className="header">
        <h1>Idea Board</h1>
        <span className="badge">
          {version ? `${version.environment} · ${version.version}` : "backend offline"}
        </span>
      </header>
      <main className="grid">
        <IdeaBoard />
        <div className="stack">
          <AiPanel />
          <EnvPlanner />
        </div>
      </main>
    </div>
  );
}

function IdeaBoard() {
  const [ideas, setIdeas] = useState([]);
  const [content, setContent] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    getIdeas()
      .then(setIdeas)
      .catch((e) => setError(e.message))
      .finally(() => setLoading(false));
  }, []);

  async function onSubmit(e) {
    e.preventDefault();
    if (!content.trim()) return;
    setSaving(true);
    setError("");
    try {
      const idea = await createIdea({ content });
      setIdeas((prev) => [idea, ...prev]);
      setContent("");
    } catch (err) {
      setError(err.message);
    } finally {
      setSaving(false);
    }
  }

  return (
    <section className="card">
      <h2>Ideas</h2>
      <form onSubmit={onSubmit} className="form">
        <textarea
          placeholder="What's your idea?"
          value={content}
          rows={3}
          maxLength={2000}
          onChange={(e) => setContent(e.target.value)}
        />
        <button disabled={saving || !content.trim()}>{saving ? "Saving…" : "Add idea"}</button>
      </form>
      {error && <p className="error">{error}</p>}
      {loading ? (
        <p className="muted">Loading…</p>
      ) : ideas.length === 0 ? (
        <p className="muted">No ideas yet. Add the first one.</p>
      ) : (
        <ul className="ideas">
          {ideas.map((i) => (
            <li key={i.id}>
              <p className="content">{i.content}</p>
              <time>{new Date(i.created_at).toLocaleString()}</time>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function AiPanel() {
  const [logs, setLogs] = useState("");
  const [environment, setEnvironment] = useState("staging");
  const [analysis, setAnalysis] = useState(null);
  const [rec, setRec] = useState(null);
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");

  async function run(kind) {
    setBusy(kind);
    setError("");
    try {
      if (kind === "analyze") {
        setAnalysis(await analyzeLogs(logs, `${environment} deployment`));
      } else {
        setRec(await recommendDeployment({ environment, recent_logs: logs }));
      }
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy("");
    }
  }

  return (
    <section className="card">
      <h2>AI Deployment Assistant</h2>
      <div className="row">
        <button className="secondary" onClick={() => setLogs(FAILED_LOG)}>Load failing logs</button>
        <button className="secondary" onClick={() => setLogs(HEALTHY_LOG)}>Load healthy logs</button>
        <select value={environment} onChange={(e) => setEnvironment(e.target.value)}>
          <option value="development">development</option>
          <option value="staging">staging</option>
          <option value="production">production</option>
        </select>
      </div>
      <textarea
        className="mono"
        rows={9}
        placeholder="Paste deployment logs (kubectl logs / events / docker compose logs)…"
        value={logs}
        onChange={(e) => setLogs(e.target.value)}
      />
      <div className="row">
        <button disabled={!logs.trim() || busy} onClick={() => run("analyze")}>
          {busy === "analyze" ? "Analyzing…" : "Analyze logs"}
        </button>
        <button disabled={busy} onClick={() => run("recommend")}>
          {busy === "recommend" ? "Thinking…" : "Get deployment recommendation"}
        </button>
      </div>
      {error && <p className="error">{error}</p>}

      {analysis && (
        <div className="result">
          <h3>
            Log analysis <Tag value={analysis.status} /> → <Tag value={analysis.recommendation} />
            <small> via {analysis.source}, {analysis.confidence} confidence</small>
          </h3>
          <p>{analysis.summary}</p>
          <p><strong>Root cause:</strong> {analysis.root_cause}</p>
          <List title="Issues" items={analysis.issues} />
          <List title="Suggested fixes" items={analysis.suggested_fixes} />
          {analysis.note && <p className="muted">{analysis.note}</p>}
        </div>
      )}

      {rec && (
        <div className="result">
          <h3>
            Recommendation <Tag value={rec.decision} /> <small>risk {rec.risk_level}, via {rec.source}</small>
          </h3>
          <p>{rec.strategy}</p>
          <List title="Reasons" items={rec.reasons} />
          <List title="Checks" items={rec.pre_deploy_checks} />
          {rec.note && <p className="muted">{rec.note}</p>}
        </div>
      )}
    </section>
  );
}

function EnvPlanner() {
  const [goal, setGoal] = useState("cost-sensitive staging");
  const [plan, setPlan] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  async function run(e) {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      setPlan(await planEnvironment(goal));
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="card">
      <h2>AI Environment Planner</h2>
      <form className="row" onSubmit={run}>
        <input value={goal} onChange={(e) => setGoal(e.target.value)} style={{ flex: 1, minWidth: 0 }} />
        <button disabled={busy || goal.trim().length < 3}>{busy ? "Planning…" : "Plan"}</button>
      </form>
      <div className="row" style={{ marginTop: 8 }}>
        {["cost-sensitive staging", "high-availability production", "high-traffic launch"].map((g) => (
          <button key={g} className="secondary" onClick={() => setGoal(g)}>{g}</button>
        ))}
      </div>
      {error && <p className="error">{error}</p>}
      {plan && (
        <div className="result">
          <h3>
            {plan.profile_name} <small>via {plan.source}</small>
          </h3>
          <ul>
            <li>Cluster: {plan.cluster_flavor}, {plan.node_count} × {plan.node_size} node(s)</li>
            <li>Replicas: backend {plan.backend_replicas}, frontend {plan.frontend_replicas}</li>
            <li>Backend: {plan.backend_cpu_request_millicores}m CPU request, {plan.backend_memory_limit_mib}Mi memory limit</li>
            <li>Database: {plan.db_size}{plan.db_high_availability ? " (high availability)" : ""}</li>
          </ul>
          <List title="Rationale" items={plan.rationale} />
          <List title="Guardrail adjustments" items={plan.adjustments} />
          {plan.note && <p className="muted">{plan.note}</p>}
        </div>
      )}
    </section>
  );
}

const TONE = {
  healthy: "good", proceed: "good", deploy: "good",
  degraded: "warn", investigate: "warn", canary: "warn", hold: "warn",
  failed: "bad", rollback: "bad",
};

function Tag({ value }) {
  return <span className={`tag ${TONE[value] || ""}`}>{value}</span>;
}

function List({ title, items }) {
  if (!items?.length) return null;
  return (
    <>
      <h4>{title}</h4>
      <ul>{items.map((x, i) => <li key={i}>{x}</li>)}</ul>
    </>
  );
}
