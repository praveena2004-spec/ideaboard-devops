// Demo log excerpts for the AI panel (same content as samples/logs/*.log).
export const FAILED_LOG = `Normal   Started    pod/backend-7c9d8f6b5-xk2lp  Started container backend
INFO:     Waiting for application startup.
ERROR:    Traceback (most recent call last):
sqlalchemy.exc.OperationalError: (psycopg2.OperationalError) could not connect to server: Connection refused
	Is the server running on host "postgres-wrong" and accepting TCP/IP connections on port 5432?
ERROR:    Application startup failed. Exiting.
Warning  Unhealthy  Readiness probe failed: dial tcp 10.244.1.17:8000: connect: connection refused
Warning  BackOff    Back-off restarting failed container backend (CrashLoopBackOff)
error: deployment "backend" exceeded its progress deadline`;

export const HEALTHY_LOG = `Normal   Pulled     Successfully pulled image "ghcr.io/example/ideaboard-backend:9e8d7c6"
INFO:     Application startup complete.
INFO:     10.244.1.1:51234 - "GET /ready HTTP/1.1" 200 OK
INFO:     10.244.2.9:40112 - "GET /api/ideas HTTP/1.1" 200 OK
deployment "backend" successfully rolled out`;
