// Shared helpers for e2e tests that drive the REAL shrdlu Tightbeam gateway.
// NEVER stand up a mock WebSocketServer for integration/e2e coverage — a green
// test on a faked wire is false confidence (see CLAUDE.md + the integration test
// procedure). Every helper here talks to the live gateway.
import { execFileSync } from "node:child_process";
import { expect, type Page } from "@playwright/test";

export const gatewayHttpUrl = "http://100.98.120.22:11373";
export const gatewayWebSocketUrl = "ws://100.98.120.22:11373/ws";

// The gateway's admin cliToken lives in shrdlu's gateway.json; read it over ssh
// as the clu operator so tests can drive operator verbs (inspect, approve-device).
export function readShrdluCliToken(): string {
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

export async function dispatch(cliToken: string, body: unknown): Promise<unknown> {
  const response = await fetch(`${gatewayHttpUrl}/agent/dispatch`, {
    body: JSON.stringify(body),
    headers: {
      authorization: `Bearer ${cliToken}`,
      "content-type": "application/json"
    },
    method: "POST"
  });
  const payload = (await response.json()) as { error?: unknown; result?: unknown };
  if (!response.ok || payload.error) {
    throw new Error(`shrdlu dispatch failed (${response.status}): ${JSON.stringify(payload)}`);
  }
  return payload.result;
}

export async function pollForPendingDevice(cliToken: string, deviceId: string) {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    const result = (await dispatch(cliToken, { verb: "inspect", asUser: "e2e-browser" })) as {
      pendingDevices?: Array<{ claimedName: string; deviceId: string }>;
    };
    if (result.pendingDevices?.some((device) => device.deviceId === deviceId)) {
      return { pendingDevices: result.pendingDevices };
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error("shrdlu did not report the browser as pending within 15 seconds");
}

// Full pair -> operator approval -> connected /chat, against the real gateway.
// Returns the browser's device id. The caller lands on the real chat surface.
export async function pairAndApprove(page: Page, name = "e2e browser"): Promise<string> {
  const cliToken = readShrdluCliToken();

  await page.goto("/pair");
  await page.getByLabel("Name").fill(name);
  await page.getByLabel("Provider address").fill(gatewayWebSocketUrl);
  await page.getByRole("button", { name: "Pair browser" }).click();

  await expect(page.getByText("Awaiting Approval")).toBeVisible();
  const deviceId = (await page.evaluate(() =>
    JSON.parse(window.localStorage.getItem("clawline-web:device-id") ?? "null")
  )) as string;

  const { pendingDevices } = await pollForPendingDevice(cliToken, deviceId);
  const pending = pendingDevices.find((device) => device.deviceId === deviceId);
  if (!pending) throw new Error(`device ${deviceId} not pending on shrdlu`);

  await dispatch(cliToken, {
    verb: "approve-device",
    asUser: "e2e-browser",
    params: { deviceId: pending.deviceId }
  });

  await page.getByRole("button", { name: "Retry pairing" }).click();
  await expect(page).toHaveURL(/\/chat(?:\/|$)/);
  await expect(page.getByLabel("Message")).toBeVisible();
  await expect(page.getByRole("button", { name: "Send" })).toHaveAttribute(
    "data-connection-state",
    "live"
  );
  return deviceId;
}
