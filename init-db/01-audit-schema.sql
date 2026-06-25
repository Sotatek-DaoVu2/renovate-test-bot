-- ═══════════════════════════════════════════════
-- Audit Logs Schema
-- Tracks every chat request/response for traceability
-- ═══════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS audit_logs (
    id              SERIAL PRIMARY KEY,
    user_id         VARCHAR(255) NOT NULL,
    user_email      VARCHAR(255),
    timestamp       TIMESTAMPTZ  DEFAULT NOW(),
    model           VARCHAR(255),
    prompt_text     TEXT,
    response_text   TEXT,
    prompt_tokens   INTEGER,
    completion_tokens INTEGER,
    total_tokens    INTEGER,
    estimated_cost  DECIMAL(10, 6),
    session_id      VARCHAR(255)
);

-- Index on user_id for per-user audit queries
CREATE INDEX IF NOT EXISTS idx_audit_user ON audit_logs(user_id);

-- Index on timestamp for time-range audit queries
CREATE INDEX IF NOT EXISTS idx_audit_timestamp ON audit_logs(timestamp);

-- Index on model for per-model usage reports
CREATE INDEX IF NOT EXISTS idx_audit_model ON audit_logs(model);
