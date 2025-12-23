#!/usr/bin/env python3
"""
Hybrid App Backend API
A FastAPI application demonstrating hybrid cloud architecture with:
- PostgreSQL database connection (running in KubeVirt VM)
- Redis caching layer (container)
- REST API endpoints for data retrieval
"""

import os
import logging
from datetime import datetime
from typing import Optional, Dict, Any

import psycopg2
from psycopg2.extras import RealDictCursor
import redis
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# Configure logging
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Initialize FastAPI app
app = FastAPI(
    title="Hybrid App Backend",
    description="Backend API for hybrid cloud application demo",
    version="1.0.0"
)

# Enable CORS for frontend
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Database configuration
POSTGRES_HOST = os.getenv("POSTGRES_HOST", "postgresql-vm")
POSTGRES_PORT = int(os.getenv("POSTGRES_PORT", "5432"))
POSTGRES_USER = os.getenv("POSTGRES_USER", "appuser")
POSTGRES_PASSWORD = os.getenv("POSTGRES_PASSWORD", "apppassword")
POSTGRES_DB = os.getenv("POSTGRES_DB", "appdb")

# Redis configuration
REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))

# Connection pools (initialized on startup)
redis_client: Optional[redis.Redis] = None


class HealthResponse(BaseModel):
    status: str
    timestamp: str
    services: Dict[str, str]


class DataResponse(BaseModel):
    data: list
    source: str
    cached: bool
    timestamp: str


def get_db_connection():
    """Create a new PostgreSQL connection"""
    try:
        conn = psycopg2.connect(
            host=POSTGRES_HOST,
            port=POSTGRES_PORT,
            user=POSTGRES_USER,
            password=POSTGRES_PASSWORD,
            database=POSTGRES_DB,
            cursor_factory=RealDictCursor,
            connect_timeout=5
        )
        logger.debug(f"Connected to PostgreSQL at {POSTGRES_HOST}:{POSTGRES_PORT}")
        return conn
    except Exception as e:
        logger.error(f"Failed to connect to PostgreSQL: {e}")
        raise


@app.on_event("startup")
async def startup_event():
    """Initialize connections on startup"""
    global redis_client

    # Initialize Redis client
    try:
        redis_client = redis.Redis(
            host=REDIS_HOST,
            port=REDIS_PORT,
            decode_responses=True,
            socket_timeout=5
        )
        redis_client.ping()
        logger.info(f"Connected to Redis at {REDIS_HOST}:{REDIS_PORT}")
    except Exception as e:
        logger.warning(f"Redis connection failed: {e}. Continuing without cache.")
        redis_client = None

    # Test PostgreSQL connection
    try:
        conn = get_db_connection()
        conn.close()
        logger.info(f"PostgreSQL connection verified at {POSTGRES_HOST}:{POSTGRES_PORT}")
    except Exception as e:
        logger.warning(f"PostgreSQL connection failed: {e}")


@app.get("/", response_model=Dict[str, str])
async def root():
    """Root endpoint"""
    return {
        "service": "Hybrid App Backend API",
        "version": "1.0.0",
        "endpoints": "/health, /api/data, /api/cache-stats"
    }


@app.get("/health", response_model=HealthResponse)
async def health_check():
    """Health check endpoint - verifies all service connections"""
    services = {}

    # Check PostgreSQL
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT version();")
            result = cur.fetchone()
        conn.close()
        services["postgresql"] = "healthy"
        logger.debug(f"PostgreSQL health check: OK")
    except Exception as e:
        services["postgresql"] = f"unhealthy: {str(e)}"
        logger.error(f"PostgreSQL health check failed: {e}")

    # Check Redis
    try:
        if redis_client:
            redis_client.ping()
            services["redis"] = "healthy"
            logger.debug(f"Redis health check: OK")
        else:
            services["redis"] = "not configured"
    except Exception as e:
        services["redis"] = f"unhealthy: {str(e)}"
        logger.error(f"Redis health check failed: {e}")

    # Overall status
    all_healthy = all(status == "healthy" for status in services.values() if status != "not configured")
    status = "healthy" if all_healthy else "degraded"

    return HealthResponse(
        status=status,
        timestamp=datetime.utcnow().isoformat(),
        services=services
    )


@app.get("/api/data", response_model=DataResponse)
async def get_data():
    """
    Get application data - demonstrates hybrid architecture:
    - Checks Redis cache first
    - Falls back to PostgreSQL VM if cache miss
    - Caches result for future requests
    """
    cache_key = "app:data:all"
    cached = False

    # Try cache first
    if redis_client:
        try:
            cached_data = redis_client.get(cache_key)
            if cached_data:
                import json
                data = json.loads(cached_data)
                logger.info("Cache HIT: Data retrieved from Redis")
                return DataResponse(
                    data=data,
                    source="redis_cache",
                    cached=True,
                    timestamp=datetime.utcnow().isoformat()
                )
        except Exception as e:
            logger.warning(f"Cache read failed: {e}")

    # Cache miss - query PostgreSQL
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute("""
                SELECT id, name, description, created_at::text
                FROM app_data
                ORDER BY id
                LIMIT 100;
            """)
            rows = cur.fetchall()
        conn.close()

        data = [dict(row) for row in rows]
        logger.info(f"Cache MISS: Data retrieved from PostgreSQL ({len(data)} rows)")

        # Cache the result
        if redis_client:
            try:
                import json
                redis_client.setex(cache_key, 300, json.dumps(data))  # 5 min TTL
                logger.debug("Data cached in Redis")
            except Exception as e:
                logger.warning(f"Cache write failed: {e}")

        return DataResponse(
            data=data,
            source="postgresql_vm",
            cached=False,
            timestamp=datetime.utcnow().isoformat()
        )

    except Exception as e:
        logger.error(f"Failed to query PostgreSQL: {e}")
        raise HTTPException(status_code=500, detail=f"Database query failed: {str(e)}")


@app.get("/api/cache-stats", response_model=Dict[str, Any])
async def cache_stats():
    """Get cache statistics"""
    if not redis_client:
        return {"status": "disabled", "message": "Redis cache not configured"}

    try:
        info = redis_client.info("stats")
        return {
            "status": "active",
            "total_connections_received": info.get("total_connections_received", 0),
            "total_commands_processed": info.get("total_commands_processed", 0),
            "keyspace_hits": info.get("keyspace_hits", 0),
            "keyspace_misses": info.get("keyspace_misses", 0),
            "hit_rate": round(
                info.get("keyspace_hits", 0) /
                max(1, info.get("keyspace_hits", 0) + info.get("keyspace_misses", 0)) * 100,
                2
            )
        }
    except Exception as e:
        logger.error(f"Failed to get cache stats: {e}")
        raise HTTPException(status_code=500, detail=f"Cache stats failed: {str(e)}")


@app.delete("/api/cache")
async def clear_cache():
    """Clear all cached data"""
    if not redis_client:
        return {"status": "disabled", "message": "Redis cache not configured"}

    try:
        redis_client.flushdb()
        logger.info("Cache cleared successfully")
        return {"status": "success", "message": "Cache cleared"}
    except Exception as e:
        logger.error(f"Failed to clear cache: {e}")
        raise HTTPException(status_code=500, detail=f"Cache clear failed: {str(e)}")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000, log_level=LOG_LEVEL.lower())
