"""
Audit logging pipeline for Open WebUI.

Intercepts chat requests/responses and writes audit records to PostgreSQL.
Install via Open WebUI admin panel → Settings → Pipelines.
"""

import json
import os
import logging
from typing import List, Optional

import psycopg2
import psycopg2.pool
from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


MODEL_COST_PER_1K_TOKENS = {
    "gpt-4.1": {"input": 0.002, "output": 0.008},
    "gpt-4.1-mini": {"input": 0.0004, "output": 0.0016},
    "gpt-4o": {"input": 0.0025, "output": 0.01},
    "gpt-4o-mini": {"input": 0.00015, "output": 0.0006},
    "claude-sonnet-4-5": {"input": 0.003, "output": 0.015},
    "claude-opus-4-6": {"input": 0.005, "output": 0.025},
}


def estimate_cost(model: str, prompt_tokens: int, completion_tokens: int) -> float:
    """Estimate cost in USD based on token counts."""
    model_key = model.lower()
    costs = None
    for key in MODEL_COST_PER_1K_TOKENS:
        if key in model_key:
            costs = MODEL_COST_PER_1K_TOKENS[key]
            break

    if not costs:
        return 0.0

    input_cost = (prompt_tokens / 1_000) * costs["input"]
    output_cost = (completion_tokens / 1_000) * costs["output"]
    return round(input_cost + output_cost, 6)


class Pipeline:
    """Open WebUI filter pipeline for audit logging."""

    class Valves(BaseModel):
        """Pipeline configuration."""

        pipelines: List[str] = Field(
            default=["*"],
            description="List of model pipeline IDs this filter applies to. Use ['*'] for all.",
        )
        priority: int = Field(
            default=0,
            description="Filter execution priority (lower = runs first).",
        )
        db_host: str = Field(default="postgres", description="PostgreSQL host")
        db_port: int = Field(default=5432, description="PostgreSQL port")
        db_user: str = Field(default="openwebui", description="PostgreSQL user")
        db_password: str = Field(default="openwebui", description="PostgreSQL password")
        db_name: str = Field(default="openwebui", description="PostgreSQL database name")
        pool_min: int = Field(default=1, description="Minimum connection pool size")
        pool_max: int = Field(default=5, description="Maximum connection pool size")
        enabled: bool = Field(default=True, description="Enable/disable audit logging")
        log_prompt_text: bool = Field(
            default=True, description="Log the full prompt text (disable for privacy)"
        )
        log_response_text: bool = Field(
            default=True, description="Log the full response text (disable for privacy)"
        )

    def __init__(self):
        self.type = "filter"
        self.name = "Audit Logging Pipeline"
        self.valves = self.Valves(
            db_host=os.getenv("AUDIT_DB_HOST", "postgres"),
            db_port=int(os.getenv("AUDIT_DB_PORT", "5432")),
            db_user=os.getenv("AUDIT_DB_USER", "openwebui"),
            db_password=os.getenv("AUDIT_DB_PASSWORD", "openwebui"),
            db_name=os.getenv("AUDIT_DB_NAME", "openwebui"),
            pool_min=int(os.getenv("AUDIT_DB_POOL_MIN", "1")),
            pool_max=int(os.getenv("AUDIT_DB_POOL_MAX", "5")),
        )

        self._pool: Optional[psycopg2.pool.SimpleConnectionPool] = None

    def _get_pool(self) -> psycopg2.pool.SimpleConnectionPool:
        """Lazy-initialize a connection pool."""
        if self._pool is None or self._pool.closed:
            self._pool = psycopg2.pool.SimpleConnectionPool(
                minconn=self.valves.pool_min,
                maxconn=self.valves.pool_max,
                host=self.valves.db_host,
                port=self.valves.db_port,
                user=self.valves.db_user,
                password=self.valves.db_password,
                dbname=self.valves.db_name,
            )
        return self._pool

    def _fetch_usage_from_chat_message(self, chat_id: str) -> dict:
        """Query the Open WebUI chat_message table for the latest assistant
        message's usage data.  Open WebUI stores token counts there after
        streaming completes, so this is the most reliable source."""
        conn = None
        try:
            pool = self._get_pool()
            conn = pool.getconn()
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT usage::text
                    FROM chat_message
                    WHERE chat_id = %s
                      AND role = 'assistant'
                      AND usage IS NOT NULL
                      AND usage::text != 'null'
                    ORDER BY created_at DESC
                    LIMIT 1
                    """,
                    (chat_id,),
                )
                row = cur.fetchone()
                if row and row[0]:
                    return json.loads(row[0])
        except Exception as e:
            logger.warning(f"Audit pipeline – could not fetch usage from chat_message: {e}")
        finally:
            if conn:
                self._get_pool().putconn(conn)
        return {}

    def _write_audit_log(
        self,
        user_id: str,
        user_email: str,
        model: str,
        prompt_text: Optional[str] = None,
        response_text: Optional[str] = None,
        prompt_tokens: Optional[int] = None,
        completion_tokens: Optional[int] = None,
        total_tokens: Optional[int] = None,
        estimated_cost: Optional[float] = None,
        session_id: Optional[str] = None,
    ):
        """Insert a row into the audit_logs table."""
        conn = None
        try:
            pool = self._get_pool()
            conn = pool.getconn()
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO audit_logs
                        (user_id, user_email, model, prompt_text, response_text,
                         prompt_tokens, completion_tokens, total_tokens,
                         estimated_cost, session_id)
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    (
                        user_id,
                        user_email,
                        model,
                        prompt_text,
                        response_text,
                        prompt_tokens,
                        completion_tokens,
                        total_tokens,
                        estimated_cost,
                        session_id,
                    ),
                )
            conn.commit()
        except Exception as e:
            logger.error(f"Audit pipeline – failed to write log: {e}")
            if conn:
                conn.rollback()
        finally:
            if conn:
                self._get_pool().putconn(conn)

    async def on_startup(self):
        """Called when the pipeline is loaded."""
        logger.info("Audit pipeline started.")

    async def on_shutdown(self):
        """Called when the pipeline is stopped."""
        if self._pool and not self._pool.closed:
            self._pool.closeall()
        logger.info("Audit pipeline shut down.")

    async def inlet(self, body: dict, user: Optional[dict] = None) -> dict:
        """Called before request is sent to LLM.

        Injects ``stream_options`` so the LLM provider returns token usage
        counts in the final streaming chunk.  Without this, streaming
        responses never include usage data.
        """
        if body.get("stream", False):
            body["stream_options"] = {"include_usage": True}
        return body

    async def outlet(self, body: dict, user: Optional[dict] = None) -> dict:
        """Called after response is received from LLM.

        Open WebUI passes the conversation payload here, including
        ``messages`` (with the latest user prompt and assistant reply),
        ``model``, and ``chat_id``.

        Token usage is NOT included in the outlet body.  Instead, we query
        the Open WebUI ``chat_message`` table where usage is stored after
        streaming completes.
        """
        if not self.valves.enabled:
            return body

        user_id = user.get("id", "unknown") if user else "unknown"
        user_email = user.get("email", "unknown") if user else "unknown"
        model = body.get("model", "unknown")
        chat_id = body.get("chat_id", "")

        # --- prompt text (last user message) ---
        prompt_text = None
        messages = body.get("messages", [])
        if messages and self.valves.log_prompt_text:
            last_user_msg = next(
                (m for m in reversed(messages) if m.get("role") == "user"), None
            )
            if last_user_msg:
                content = last_user_msg.get("content", "")
                if isinstance(content, list):
                    # Multi-modal messages: extract text parts
                    content = " ".join(
                        part.get("text", "") for part in content if isinstance(part, dict)
                    )
                prompt_text = str(content)[:10000]

        # --- response text (last assistant message) ---
        response_text = None
        if messages and self.valves.log_response_text:
            last_assistant_msg = next(
                (m for m in reversed(messages) if m.get("role") == "assistant"), None
            )
            if last_assistant_msg:
                content = last_assistant_msg.get("content", "")
                if isinstance(content, list):
                    content = " ".join(
                        part.get("text", "") for part in content if isinstance(part, dict)
                    )
                response_text = str(content)[:10000]

        # --- token usage ---
        # First check if usage is in the outlet body (non-streaming responses).
        # For streaming responses, Open WebUI stores usage in the chat_message
        # table, so we query it as a fallback.
        usage = body.get("usage") or {}
        if not usage and chat_id:
            usage = self._fetch_usage_from_chat_message(chat_id)

        prompt_tokens = (
            usage.get("prompt_tokens")
            or usage.get("input_tokens")
        )
        completion_tokens = (
            usage.get("completion_tokens")
            or usage.get("output_tokens")
        )
        total_tokens = usage.get("total_tokens")
        if prompt_tokens and completion_tokens and not total_tokens:
            total_tokens = prompt_tokens + completion_tokens

        # --- estimated cost ---
        cost = None
        if prompt_tokens and completion_tokens:
            cost = estimate_cost(model, prompt_tokens, completion_tokens)

        self._write_audit_log(
            user_id=user_id,
            user_email=user_email,
            model=model,
            prompt_text=prompt_text,
            response_text=response_text,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            total_tokens=total_tokens,
            estimated_cost=cost,
            session_id=chat_id,
        )

        return body
