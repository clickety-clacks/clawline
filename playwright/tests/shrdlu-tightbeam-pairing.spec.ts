import { execFileSync } from "node:child_process";
import { expect, test } from "@playwright/test";

const gatewayHttpUrl = "http://100.98.120.22:11373";
const gatewayWebSocketUrl = "ws://100.98.120.22:11373/ws";

test("pairs through the real shrdlu Tightbeam gateway after operator approval", async ({
  page
}) => {
  const cliToken = readShrdluCliToken();
  const dispatchProof: Array<{ verb: string; response: unknown }> = [];

  await page.goto("/pair");
  await page.getByLabel("Name").fill("e2e browser");
  await page.getByLabel("Provider address").fill(gatewayWebSocketUrl);
  await page.getByRole("button", { name: "Pair browser" }).click();

  await expect(page.getByText("Awaiting Approval")).toBeVisible();
  const deviceId = await page.evaluate(() =>
    JSON.parse(window.localStorage.getItem("clawline-web:device-id") ?? "null")
  );
  expect(deviceId).toMatch(
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  );

  const inspect = await pollForPendingDevice(cliToken, deviceId);
  dispatchProof.push({ verb: "inspect", response: inspect });
  const pendingDevice = inspect.pendingDevices.find((device) => device.deviceId === deviceId);
  expect(pendingDevice).toBeDefined();

  const approval = await dispatch(cliToken, {
    verb: "approve-device",
    asUser: "e2e-browser",
    params: { deviceId: pendingDevice!.deviceId }
  });
  dispatchProof.push({ verb: "approve-device", response: approval });
  expect(approval).toEqual({
    approved: {
      deviceId: pendingDevice!.deviceId,
      isAdmin: true,
      userId: "e2e-browser"
    }
  });

  await page.getByRole("button", { name: "Retry pairing" }).click();
  await expect(page).toHaveURL(/\/chat(?:\/|$)/);
  await expect(page.getByLabel("Message")).toBeVisible();
  await expect(page.getByRole("button", { name: "Manage streams" })).toBeVisible();

  console.log(
    JSON.stringify({
      approvalRoundTrip: dispatchProof,
      gatewayWebSocketUrl
    })
  );
});

function readShrdluCliToken() {
  return execFileSync(
    "ssh",
    [
      "-i",
      `${process.env.HOME}/.ssh/id_ed25519_clu`,
      "clu@shrdlu",
      "python3 -c 'import json; print(json.load(open(\"/home/clu/.tightbeam-beam/gateway.json\"))[\"cliToken\"])'"
    ],
    { encoding: "utf8" }
  ).trim();
}

async function pollForPendingDevice(cliToken: string, deviceId: string) {
  const deadline = Date.now() + 15_000;

  while (Date.now() < deadline) {
    const result = await dispatch(cliToken, {
      verb: "inspect",
      asUser: "e2e-browser"
    });
    const inspect = result as {
      pendingDevices?: Array<{
        claimedName: string;
        deviceId: string;
      }>;
    };

    if (inspect.pendingDevices?.some((device) => device.deviceId === deviceId)) {
      return {
        pendingDevices: inspect.pendingDevices
      };
    }

    await new Promise((resolve) => setTimeout(resolve, 250));
  }

  throw new Error("shrdlu did not report the e2e browser as pending within 15 seconds");
}

async function dispatch(cliToken: string, body: unknown) {
  const response = await fetch(`${gatewayHttpUrl}/agent/dispatch`, {
    body: JSON.stringify(body),
    headers: {
      authorization: `Bearer ${cliToken}`,
      "content-type": "application/json"
    },
    method: "POST"
  });
  const payload = (await response.json()) as {
    error?: unknown;
    result?: unknown;
  };

  if (!response.ok || payload.error) {
    throw new Error(
      `shrdlu dispatch failed (${response.status}): ${JSON.stringify(payload)}`
    );
  }

  return payload.result;
}
