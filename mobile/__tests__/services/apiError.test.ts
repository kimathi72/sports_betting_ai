/**
 * Error normalisation.
 *
 * Rails returns `{"error": "..."}` for every failure. The UI must show that
 * message, not "Request failed with status code 400", and must tell a network
 * failure (retry may help) apart from a validation failure (retrying will not).
 * This is the contract every screen depends on.
 */
import { AxiosError, AxiosHeaders } from "axios";
import { normalizeApiError, ApiError } from "@/services/api/errors";

function axiosErrorWith(overrides: {
  status?: number;
  data?: unknown;
  code?: string;
  message?: string;
  noResponse?: boolean;
}): AxiosError {
  const error = new AxiosError(
    overrides.message ?? "Request failed",
    overrides.code,
    undefined,
    undefined,
    overrides.noResponse
      ? undefined
      : {
          status: overrides.status ?? 500,
          statusText: "",
          data: overrides.data,
          headers: new AxiosHeaders(),
          config: { headers: new AxiosHeaders() },
        },
  );
  return error;
}

describe("normalizeApiError", () => {
  it("uses the Rails error message", () => {
    const result = normalizeApiError(
      axiosErrorWith({ status: 400, data: { error: "markets is required" } }),
    );

    expect(result).toBeInstanceOf(ApiError);
    expect(result.message).toBe("markets is required");
    expect(result.status).toBe(400);
    expect(result.kind).toBe("client");
    expect(result.isRetryable).toBe(false);
  });

  it("treats a timeout as a retryable network problem", () => {
    const result = normalizeApiError(
      axiosErrorWith({ code: "ECONNABORTED", noResponse: true }),
    );

    expect(result.kind).toBe("timeout");
    expect(result.isRetryable).toBe(true);
    expect(result.status).toBeUndefined();
    expect(result.message).toMatch(/timed out/i);
  });

  it("treats a missing response as a network failure", () => {
    const result = normalizeApiError(axiosErrorWith({ noResponse: true }));

    expect(result.kind).toBe("network");
    expect(result.isRetryable).toBe(true);
    expect(result.message).toMatch(/connect/i);
  });

  it("marks a 5xx as retryable", () => {
    const result = normalizeApiError(
      axiosErrorWith({
        status: 503,
        data: { error: "ML service unavailable" },
      }),
    );

    expect(result.kind).toBe("server");
    expect(result.isRetryable).toBe(true);
    expect(result.message).toBe("ML service unavailable");
  });

  it("falls back to the HTTP status when the body is not JSON", () => {
    const result = normalizeApiError(
      axiosErrorWith({ status: 502, data: "<html>" }),
    );

    expect(result.message).toMatch(/server is temporarily unavailable/i);
    expect(result.message).not.toContain("<html>");
  });

  it("never surfaces a stack trace or internal detail", () => {
    const result = normalizeApiError(
      axiosErrorWith({ status: 500, message: "boom at /app.rb:12" }),
    );

    expect(result.message).not.toContain("/app.rb");
  });

  it("normalises a non-Axios error so callers always get an ApiError", () => {
    const result = normalizeApiError(new Error("weird"));

    expect(result).toBeInstanceOf(ApiError);
    expect(result.kind).toBe("unknown");
  });
});
