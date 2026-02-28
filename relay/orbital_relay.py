"""OrbitLab's Orbital Relay."""

from abc import ABC, abstractmethod
import asyncio

import httpx
import uvicorn
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import Response
from starlette.routing import Route


class Service(ABC):

    def __init__(self, transport, base_url) -> None:
        self._transport = transport
        self._base_url = base_url

    async def send(self, event: str, version: str, payload: dict) -> None:
        async with httpx.AsyncClient(transport=self._transport, base_url=self._base_url, timeout=10.0) as client:
            response = await client.post("/orbital-relay", json={"event": event, "version": version, "payload": payload})
        response.raise_for_status()

    @abstractmethod
    def routes(self) -> list[Route]: ...


class ETCDRoutes(Service):
    async def failover_v1(self, request: Request) -> Response:
        payload = request.json()
        if not payload:
            return Response(status_code=401, content="No payload")

        await self.send(event="datacore.etcd.failover", version="v1", payload=payload)
        return Response()

    def routes(self) -> list:
        return [
            Route("/etcd/v1/failover", self.failover_v1, methods=["POST"]),
        ]


class DataCoreRoutes(Service):
    async def event_v1(self, request: Request) -> Response:
        payload = request.json()
        if not payload:
            return Response(status_code=401, content="No payload")

        await self.send(event="datacore.cluster.event", version="v1", payload=payload)
        return Response()

    def routes(self) -> list:
        return [
            Route("/datacore/v1/event", self.event_v1, methods=["POST"]),
        ]


class DockFSRoutes(Service):
    async def failover_v1(self, request: Request) -> Response:
        payload = request.json()
        if not payload:
            return Response(status_code=401, content="No payload")

        await self.send(event="dockfs.failover", version="v1", payload=payload)
        return Response()
    
    async def reconcile_v1(self, request: Request) -> Response:
        payload = request.json()
        if not payload:
            return Response(status_code=401, content="No payload")

        await self.send(event="dockfs.reconcile", version="v1", payload=payload)
        return Response()

    def routes(self) -> list:
        return [
            Route("/dockfs/v1/failover", self.failover_v1, methods=["POST"]),
            Route("/dockfs/v1/reconcile", self.reconcile_v1, methods=["POST"]),
        ]


class OrbitalRelay:
    """Client for relaying requests to the OrbitLab Control Plane."""

    def __init__(self) -> None:
        """Initialize client."""
        base_url = "http://orbital-relay"
        transport = httpx.AsyncHTTPTransport(uds="/orbitlab/proxy.sock")
        self.etcd = ETCDRoutes(transport=transport, base_url=base_url)
        self.datacore = DataCoreRoutes(transport=transport, base_url=base_url)
        self.dock_fs = DockFSRoutes(transport=transport, base_url=base_url)

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


def main() -> None:
    asyncio.run(OrbitalRelay().run())
