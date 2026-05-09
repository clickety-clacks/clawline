import { getOrCreateDeviceId } from "./authSessionStore";

describe("authSessionStore device identity", () => {
  const UUID_V4_REGEX =
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

  beforeEach(() => {
    window.localStorage.clear();
    vi.restoreAllMocks();
  });

  it("reuses the same persisted device id before auth completes", () => {
    const firstDeviceId = getOrCreateDeviceId();
    const secondDeviceId = getOrCreateDeviceId();

    expect(firstDeviceId).toBe(secondDeviceId);
  });

  it("persists an existing session device id for later reuse", () => {
    const sessionDeviceId = "9F6A1A72-3FE2-4B89-87D8-95D813B01234";

    expect(getOrCreateDeviceId(sessionDeviceId)).toBe(sessionDeviceId);
    expect(getOrCreateDeviceId()).toBe(sessionDeviceId);
  });

  it("generates a valid uuid when randomUUID is unavailable", () => {
    const originalCrypto = globalThis.crypto;
    const randomBytes = Uint8Array.from([
      0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0x00, 0xde,
      0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde
    ]);

    Object.defineProperty(globalThis, "crypto", {
      configurable: true,
      value: {
        getRandomValues(target: Uint8Array) {
          target.set(randomBytes);
          return target;
        }
      }
    });

    const deviceId = getOrCreateDeviceId();
    expect(deviceId).toBe("12345678-9abc-40de-b012-3456789abcde");
    expect(UUID_V4_REGEX.test(deviceId)).toBe(true);

    Object.defineProperty(globalThis, "crypto", {
      configurable: true,
      value: originalCrypto
    });
  });

  it("replaces an invalid persisted device id with a valid uuid", () => {
    window.localStorage.setItem(
      "clawline-web:device-id",
      JSON.stringify("browser-deadbeef")
    );

    const deviceId = getOrCreateDeviceId();

    expect(UUID_V4_REGEX.test(deviceId)).toBe(true);
    expect(deviceId).not.toBe("browser-deadbeef");
    expect(getOrCreateDeviceId()).toBe(deviceId);
  });
});
