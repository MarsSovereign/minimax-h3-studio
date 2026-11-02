"""API contracts and queue dispatch without GPU/model dependencies."""

import io
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from aiohttp import FormData
from aiohttp.test_utils import TestClient, TestServer
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))
import app as server
from server_settings import ServerSettings


class APIAppTestCase(unittest.IsolatedAsyncioTestCase):
    settings_overrides = {}

    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.settings = ServerSettings(
            comfyui=None,
            data=Path(self.temp.name),
            web_dist=Path(self.temp.name) / "web",
            **self.settings_overrides,
        )
        app = server.make_app(
            self.settings, engine=SimpleNamespace(), start_worker=False
        )
        self.store, self.worker = app["store"], app["worker"]
        self.worker.state = "ready"
        self.client = TestClient(TestServer(app))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        self.store._db.close()
        self.temp.cleanup()

    def form(self, *, image=True, **fields):
        form = FormData()
        form.add_field("kind", "3d")
        for k, v in fields.items():
            form.add_field(k, str(v))
        if image:
            png = io.BytesIO()
            Image.new("RGBA", (48, 64), (255, 0, 0, 255)).save(png, format="PNG")
            form.add_field(
                "image", png.getvalue(), filename="object.png", content_type="image/png"
            )
        return form
