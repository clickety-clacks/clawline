import { expect, test } from "@playwright/test";
import { pairAndApprove } from "../support/shrdlu-gateway";

// REAL end-to-end: pair -> approve -> connected -> send -> transcript persists
// across reload, all against the live shrdlu Tightbeam gateway. NO mock wire —
// the previous version stood up an in-process WebSocketServer and a hardcoded
// transcript, which proved nothing about the product path and is now forbidden
// (see docs/testing/clawline-web-integration-test-procedure.md). The narrow real
// pairing round-trip is also covered by shrdlu-tightbeam-pairing.spec.ts.
test("pair -> approve -> send -> reload -> transcript persists (real shrdlu)", async ({
  page
}) => {
  await pairAndApprove(page, "phase1 browser");

  // A message the user sends must appear in the transcript and survive a reload.
  const text = `phase1 e2e ${Date.now()}`;
  await page.getByLabel("Message").fill(text);
  await page.getByRole("button", { name: "Send" }).click();

  // The user's own message is echoed into the transcript deterministically.
  await expect(page.getByText(text)).toBeVisible();
  // Not stuck mid-send once the gateway has accepted it.
  await expect(page.getByText("Sending...")).toHaveCount(0, { timeout: 15_000 });

  // Reload: the connected session replays its real transcript from the gateway.
  await page.reload();
  await expect(page).toHaveURL(/\/chat(?:\/|$)/);
  await expect(page.getByText(text)).toBeVisible();
});
