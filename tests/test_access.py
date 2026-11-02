"""Cross-origin access and the optional API token."""

from api_support import APIAppTestCase

CANVAS = "http://canvas.local:3000"


class OpenAccessTests(APIAppTestCase):
    async def test_defaults_keep_the_api_open_and_send_no_cors_headers(self):
        response = await self.client.get("/api/presets", headers={"Origin": CANVAS})
        self.assertEqual(response.status, 200)
        self.assertNotIn("Access-Control-Allow-Origin", response.headers)


class TokenAndCorsTests(APIAppTestCase):
    settings_overrides = {"api_token": "s3cret", "cors_origins": (CANVAS,)}

    async def test_api_needs_the_bearer_token_except_health(self):
        # The stub engine cannot report health details; only the access decision matters here.
        self.assertNotEqual((await self.client.get("/api/health")).status, 401)
        for headers in ({}, {"Authorization": "Bearer wrong"}, {"Authorization": "s3cret"}):
            response = await self.client.get("/api/jobs", headers=headers)
            self.assertEqual(response.status, 401, headers)
            self.assertIn("Bearer", response.headers["WWW-Authenticate"])
        response = await self.client.post("/api/jobs", data=self.form(seed=1))
        self.assertEqual(response.status, 401)
        self.assertEqual(self.store.count(), 0)
        auth = {"Authorization": "Bearer s3cret"}
        response = await self.client.post("/api/jobs", data=self.form(seed=1), headers=auth)
        self.assertEqual(response.status, 201, await response.text())
        job = await response.json()
        response = await self.client.get(f"/api/jobs/{job['id']}", headers=auth)
        self.assertEqual(response.status, 200)
        # Media elements cannot send headers; files stay reachable by their unguessable names.
        self.assertEqual((await self.client.get(job["image_url"])).status, 200)

    async def test_listed_origin_gets_preflight_and_cors_headers(self):
        response = await self.client.options(
            "/api/jobs",
            headers={
                "Origin": CANVAS,
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": "authorization",
            },
        )
        self.assertEqual(response.status, 204)
        self.assertEqual(response.headers["Access-Control-Allow-Origin"], CANVAS)
        self.assertIn("Authorization", response.headers["Access-Control-Allow-Headers"])
        self.assertIn("DELETE", response.headers["Access-Control-Allow-Methods"])
        response = await self.client.get(
            "/api/jobs", headers={"Origin": CANVAS, "Authorization": "Bearer s3cret"}
        )
        self.assertEqual(response.headers["Access-Control-Allow-Origin"], CANVAS)
        self.assertIn("X-Total-Count", response.headers["Access-Control-Expose-Headers"])
        # A rejected request still carries CORS headers so the page can read the 401.
        response = await self.client.get("/api/jobs", headers={"Origin": CANVAS})
        self.assertEqual(response.status, 401)
        self.assertEqual(response.headers["Access-Control-Allow-Origin"], CANVAS)
        response = await self.client.get(
            "/api/jobs/missing", headers={"Origin": CANVAS, "Authorization": "Bearer s3cret"}
        )
        self.assertEqual(response.status, 404)
        self.assertEqual(response.headers["Access-Control-Allow-Origin"], CANVAS)

    async def test_unlisted_origin_gets_no_cors_headers(self):
        response = await self.client.options(
            "/api/jobs",
            headers={"Origin": "http://evil.example", "Access-Control-Request-Method": "POST"},
        )
        self.assertNotIn("Access-Control-Allow-Origin", response.headers)
        response = await self.client.get(
            "/api/presets", headers={"Origin": "http://evil.example"}
        )
        self.assertNotIn("Access-Control-Allow-Origin", response.headers)


class WildcardCorsTests(APIAppTestCase):
    settings_overrides = {"cors_origins": ("*",)}

    async def test_wildcard_echoes_the_origin(self):
        response = await self.client.get("/api/presets", headers={"Origin": "http://any.host"})
        self.assertEqual(response.headers["Access-Control-Allow-Origin"], "http://any.host")
        self.assertIn("Origin", response.headers["Vary"])
