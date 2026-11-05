/**
 * Environment configuration.
 *
 * The API base URL is the single most common cause of "the app shows nothing"
 * in this project: localhost, 10.0.2.2 and a LAN IP are correct in different
 * contexts and there is no way to detect the right one automatically. The
 * configuration therefore states its choice explicitly and never silently falls
 * back to a hardcoded host.
 */
describe("environment configuration", () => {
  const ORIGINAL_ENV = process.env;

  beforeEach(() => {
    // The API client (loaded by jest.setup for other specs) imports this module
    // eagerly. Without clearing the whole registry, `require` below would return
    // that already-evaluated copy and the env changes would have no effect.
    jest.resetModules();
    jest.isolateModules(() => {});
    process.env = { ...ORIGINAL_ENV };
  });

  afterAll(() => {
    process.env = ORIGINAL_ENV;
  });

  it("builds the versioned API URL from the base URL", () => {
    process.env.EXPO_PUBLIC_API_BASE_URL = "http://localhost:3000";
    const { config } = require("@/config/environment");

    expect(config.apiBaseUrl).toBe("http://localhost:3000");
    expect(config.apiUrl).toBe("http://localhost:3000/api/v1");
  });

  it("strips a trailing slash so paths never double up", () => {
    process.env.EXPO_PUBLIC_API_BASE_URL = "http://localhost:3000/";
    const { config } = require("@/config/environment");

    expect(config.apiUrl).toBe("http://localhost:3000/api/v1");
  });

  it("accepts an https production URL", () => {
    process.env.EXPO_PUBLIC_API_BASE_URL = "https://api.example.com";
    const { config } = require("@/config/environment");

    expect(config.apiUrl).toBe("https://api.example.com/api/v1");
  });

  it("throws a clear error when the base URL is missing", () => {
    // `delete` can be undone by babel-preset-expo's env shim, which restores
    // values from the original environment object. Assigning `undefined` is the
    // reliable way to simulate an unconfigured build.
    process.env.EXPO_PUBLIC_API_BASE_URL = undefined as unknown as string;

    expect(() => require("@/config/environment")).toThrow(
      /EXPO_PUBLIC_API_BASE_URL is not configured/,
    );
  });

  it("throws when the base URL is not a valid URL", () => {
    process.env.EXPO_PUBLIC_API_BASE_URL = "not-a-url";

    expect(() => require("@/config/environment")).toThrow(/not a valid URL/);
  });

  it("exposes the documented development hosts for each runtime", () => {
    process.env.EXPO_PUBLIC_API_BASE_URL = "http://localhost:3000";
    const { platformUrlGuide } = require("@/config/environment");

    // Android emulators reach the host machine at 10.0.2.2, never localhost.
    expect(platformUrlGuide.androidEmulator).toBe("http://10.0.2.2:3000");
    expect(platformUrlGuide.expoWeb).toBe("http://localhost:3000");
  });
});
