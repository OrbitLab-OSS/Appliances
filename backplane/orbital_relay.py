import asyncio
from abc import ABC, abstractmethod
from datetime import UTC, datetime
import json
from pathlib import Path
import sys
from typing import Final

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import Response
from starlette.routing import Route
from redis.asyncio import Redis
import uvicorn


class Service(ABC):
    LOG_STREAM: Final = "ol:logs:system"

    def __init__(self, redis: Redis) -> None:
        self.redis = redis

    async def log_request(
        self,
        *,
        level: str,
        message: str,
        trace: str,
    ) -> None:
        fields = {
            "timestamp": datetime.now(UTC).isoformat(),
            "level": level,
            "trace": trace,
            "message": message,
        }

        try:
            await self.redis.xadd(
                name=self.LOG_STREAM,
                fields=fields,
                maxlen=5000,
                approximate=True,
            )  # pyright: ignore[reportArgumentType]
        except Exception as exc:
            sys.stderr.write(f"failed to write relay log entry: {exc}\n")

    async def handle(self, request: Request, event: str, version: str, trace: str) -> Response:
        try:
            payload = await request.json()
        except json.JSONDecodeError:
            await self.log_request(
                level="Warn",
                message=f"Rejected malformed JSON for {request.method} {request.url.path} ({event}/{version})",
                trace=trace,
            )
            return Response(status_code=400, content="Malformed JSON payload")

        if payload:
            fields = {
                "event": event,
                "version": version,
                "payload": json.dumps(payload),
            }
            await self.redis.xadd(
                name="ol:events", fields=fields, maxlen=5000, approximate=True
            )  # pyright: ignore[reportArgumentType]
            await self.log_request(
                level="Info",
                message=f"Accepted {request.method} {request.url.path} into ol:events as {event}/{version}",
                trace=trace,
            )
            return Response(status_code=202)

        await self.log_request(
            level="Warn",
            message=f"Rejected empty payload for {request.method} {request.url.path} ({event}/{version})",
            trace=trace,
        )
        return Response(status_code=401, content="No payload")

    @abstractmethod
    def routes(self) -> list[Route]: ...


class InfraRoutes(Service):
    async def probe_v1(self, request: Request) -> Response:
        return await self.handle(
            request=request,
            event="infrastructure.probe-relay",
            version="v1",
            trace="backplane.orbital_relay.InfraRoutes.probe_v1",
        )

    def routes(self) -> list[Route]:
        return [
            Route("/infra/v1/probe", self.probe_v1, methods=["POST"]),
        ]


class ETCDRoutes(Service):
    async def failover_v1(self, request: Request) -> Response:
        return await self.handle(
            request=request,
            event="etcd.failover",
            version="v1",
            trace="backplane.orbital_relay.ETCDRoutes.failover_v1",
        )

    def routes(self) -> list[Route]:
        return [
            Route("/etcd/v1/failover", self.failover_v1, methods=["POST"]),
        ]


class DataCoreRoutes(Service):
    async def event_v1(self, request: Request) -> Response:
        return await self.handle(
            request=request,
            event="datacore.cluster.event",
            version="v1",
            trace="backplane.orbital_relay.DataCoreRoutes.event_v1",
        )

    def routes(self) -> list[Route]:
        return [
            Route("/datacore/v1/event", self.event_v1, methods=["POST"]),
        ]


class DockFSRoutes(Service):
    async def reconcile_v1(self, request: Request) -> Response:
        return await self.handle(
            request=request,
            event="dockfs.reconcile",
            version="v1",
            trace="backplane.orbital_relay.DockFSRoutes.reconcile_v1",
        )

    def routes(self) -> list[Route]:
        return [
            Route("/dockfs/v1/reconcile", self.reconcile_v1, methods=["POST"]),
        ]


class DNSRoutes(Service):
    async def dhcp_record_event(self, request: Request) -> Response:
        return await self.handle(
            request=request,
            event="instance.dhcp",
            version="v1",
            trace="backplane.orbital_relay.DNSRoutes.dhcp_record_event",
        )

    def routes(self) -> list[Route]:
        return [
            Route("/dns/v1/dhcp", self.dhcp_record_event, methods=["POST"]),
        ]


class ConduitRoutes(Service):
    async def health_status(self, request: Request) -> Response:
        return await self.handle(
            request=request,
            event="conduit.health",
            version="v1",
            trace="backplane.orbital_relay.ConduitRoutes.health_status",
        )

    def routes(self) -> list[Route]:
        return [
            Route("/conduit/v1/health", self.health_status, methods=["POST"]),
        ]


class NotificationRoutes(Service):
    VALID_LEVELS: Final = frozenset({"INFO", "WARN", "ERROR"})

    async def event_v1(self, request: Request) -> Response:
        try:
            payload = await request.json()
        except json.JSONDecodeError:
            await self.log_request(
                level="Warn",
                message=f"Rejected malformed JSON for {request.method} {request.url.path}",
                trace="backplane.orbital_relay.NotificationRoutes.event_v1",
            )
            return Response(status_code=400, content="Malformed JSON payload")

        if not isinstance(payload, dict):
            await self.log_request(
                level="Warn",
                message=f"Rejected non-object notification payload for {request.method} {request.url.path}",
                trace="backplane.orbital_relay.NotificationRoutes.event_v1",
            )
            return Response(status_code=400, content="Payload must be an object")

        level = payload.get("level")
        message = payload.get("message")
        if level not in self.VALID_LEVELS or not isinstance(message, str) or not message:
            await self.log_request(
                level="Warn",
                message=f"Rejected invalid notification payload for {request.method} {request.url.path}",
                trace="backplane.orbital_relay.NotificationRoutes.event_v1",
            )
            return Response(status_code=400, content="Payload must include a valid level and message")

        await self.redis.xadd(
            name="ol:notifications",
            fields={"level": level, "message": message},
            maxlen=5000,
            approximate=True,
        )  # pyright: ignore[reportArgumentType]
        await self.log_request(
            level="Info",
            message=f"Accepted {request.method} {request.url.path} into ol:notifications",
            trace="backplane.orbital_relay.NotificationRoutes.event_v1",
        )
        return Response(status_code=202)

    def routes(self) -> list[Route]:
        return [
            Route("/notifications/v1/event", self.event_v1, methods=["POST"]),
        ]


class ControlPlaneReciever:
    """Receiver for relaying requests from the OrbitLab Orbital Relay."""

    SOCKET_FILE: Final = "/var/redis/redis-server.sock"
    DEFAULT_DATABASE: Final = 10

    def __init__(self) -> None:
        """Initialize control plane reciever."""
        if not Path(self.SOCKET_FILE).exists():
            msg = "Socket file `/var/redis/redis-server.sock` not found."
            raise RuntimeError(msg)

        self.redis = Redis.from_url(
            f"unix://{self.SOCKET_FILE}?db={self.DEFAULT_DATABASE}"
        )
        self.services: list[Service] = [
            InfraRoutes(redis=self.redis),
            ETCDRoutes(redis=self.redis),
            DataCoreRoutes(redis=self.redis),
            DockFSRoutes(redis=self.redis),
            DNSRoutes(redis=self.redis),
            ConduitRoutes(redis=self.redis),
            NotificationRoutes(redis=self.redis),
        ]

    async def run(self) -> None:
        """Run the OrbitalRelay to forward requests to the control plane."""
        routes: list[Route] = []
        for service in self.services:
            routes.extend(service.routes())

        app = Starlette(debug=False, routes=routes)
        config = uvicorn.Config(app, host="0.0.0.0", port=80, loop="asyncio")  # noqa: S104
        server = uvicorn.Server(config)
        await asyncio.gather(server.serve())


def main() -> None:
    asyncio.run(ControlPlaneReciever().run())
