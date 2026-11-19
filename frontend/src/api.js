// All calls use relative /api paths. nginx (Docker/K8s) or the Vite dev proxy
// forwards them to the backend, so no backend URL is baked into the build.
async function request(path, options = {}) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const detail = Array.isArray(body.detail)
      ? body.detail.map((d) => d.msg).join("; ")
      : body.detail;
    throw new Error(detail || `Request failed (${res.status})`);
  }
  return body;
}

export const getIdeas = () => request("/api/ideas");
export const createIdea = (idea) =>
  request("/api/ideas", { method: "POST", body: JSON.stringify(idea) });
export const getVersion = () => request("/api/version");
export const analyzeLogs = (logs, context) =>
  request("/api/ai/analyze-logs", { method: "POST", body: JSON.stringify({ logs, context }) });
export const planEnvironment = (goal) =>
  request("/api/ai/environment-plan", { method: "POST", body: JSON.stringify({ goal }) });
export const recommendDeployment = (signals) =>
  request("/api/ai/deployment-recommendation", { method: "POST", body: JSON.stringify(signals) });
