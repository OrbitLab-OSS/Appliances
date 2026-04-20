import asyncio
from abc import ABC, abstractmethod
import json
from pathlib import Path
from typing import Final

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import Response
from starlette.routing import Route
from redis.asyncio import Redis
import uvicorn


class Service(ABC):
    def __init__(self, redis: Redis) -> None:
        self.redis = redis

    async def get_payload(self, request: Request) -> dict | None:
        if payload := await request.json():
            return payload
        return None

    async def send(self, event: str, version: str, payload: dict) -> None:
        fields = {
            "event": event,
            "version": version,
            "payload": json.dumps(payload),
        }
        await self.redis.xadd(name="ol:events", fields=fields, maxlen=5000, approximate=True) # pyright: ignore[reportArgumentType]

    @abstractmethod
    def routes(self) -> list[Route]: ...


class ETCDRoutes(Service):
    async def failover_v1(self, request: Request) -> Response:
        if payload := await self.get_payload(request=request):
            await self.send(event="datacore.etcd.failover", version="v1", payload=payload)
            return Response(status_code=202)
        return Response(status_code=401, content="No payload")

    def routes(self) -> list:
        return [
            Route("/etcd/v1/failover", self.failover_v1, methods=["POST"]),
        ]


class DataCoreRoutes(Service):
    async def event_v1(self, request: Request) -> Response:
        if payload := await self.get_payload(request=request):
            await self.send(event="datacore.cluster.event", version="v1", payload=payload)
            return Response(status_code=202)
        return Response(status_code=401, content="No payload")

    def routes(self) -> list:
        return [
            Route("/datacore/v1/event", self.event_v1, methods=["POST"]),
        ]


class DockFSRoutes(Service):
    async def failover_v1(self, request: Request) -> Response:
        if payload := await self.get_payload(request=request):
            await self.send(event="dockfs.failover", version="v1", payload=payload)
            return Response(status_code=202)
        return Response(status_code=401, content="No payload")

    async def reconcile_v1(self, request: Request) -> Response:
        if payload := await self.get_payload(request=request):
            await self.send(event="dockfs.reconcile", version="v1", payload=payload)
            return Response(status_code=202)
        return Response(status_code=401, content="No payload")

    def routes(self) -> list:
        return [
            Route("/dockfs/v1/failover", self.failover_v1, methods=["POST"]),
            Route("/dockfs/v1/reconcile", self.reconcile_v1, methods=["POST"]),
        ]


class ControlPlaneReciever:
    """Receiver for relaying requests from the OrbitLab Orbital Relay."""
    SOCKET_FILE: Final = "/var/redis/redis-server.sock"
    DEFAULT_DATABASE: Final = 10

    def __init__(self) -> None:
        """Initialize control plane reciever."""
        if not Path(self.SOCKET_FILE).is_file():
            msg = "Socket file `/var/redis/redis-server.sock` not found."
            raise RuntimeError(msg)
        
        self.redis = Redis.from_url(f"{self.SOCKET_FILE}?db={self.DEFAULT_DATABASE}")
        self.etcd = ETCDRoutes(redis=self.redis)
        self.datacore = DataCoreRoutes(redis=self.redis)
        self.dock_fs = DockFSRoutes(redis=self.redis)

    async def run(self) -> None:
        """Run the OrbitalRelay to forward requests to the control plane."""
        routes = []
        routes.extend(self.etcd.routes())
        routes.extend(self.datacore.routes())
        routes.extend(self.dock_fs.routes())

        app = Starlette(debug=False, routes=routes)
        config = uvicorn.Config(app, host="0.0.0.0", port=80, loop="asyncio")  # noqa: S104
        server = uvicorn.Server(config)
        await asyncio.gather(server.serve())


def launch():
    asyncio.run(ControlPlaneReciever().run())
