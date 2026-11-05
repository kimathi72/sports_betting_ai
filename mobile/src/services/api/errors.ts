/**
 * One error shape for the whole app.
 *
 * Every failure — HTTP, network, timeout, or a plain thrown Error — becomes an
 * `ApiError`, so a screen never has to guess whether it is holding an
 * AxiosError, a string or undefined. `kind` drives the presentation and
 * `isRetryable` decides whether offering a "Try again" button is honest.
 */
import { AxiosError } from "axios";

export type ApiErrorKind =
  | "timeout"
  | "network"
  | "client"
  | "server"
  | "unknown";

export class ApiError extends Error {
  readonly status?: number;
  readonly kind: ApiErrorKind;
  readonly isRetryable: boolean;

  constructor(
    message: string,
    kind: ApiErrorKind,
    options: { status?: number; isRetryable?: boolean } = {},
  ) {
    super(message);
    this.name = "ApiError";
    this.kind = kind;
    if (options.status !== undefined) {
      this.status = options.status;
    }
    this.isRetryable = options.isRetryable ?? kind !== "client";
    // Required so `instanceof` works when the target is ES5.
    Object.setPrototypeOf(this, ApiError.prototype);
  }
}

/** Rails returns `{ error: "..." }`. Anything else is not shown to the user. */
function extractServerMessage(data: unknown): string | null {
  if (data && typeof data === "object" && "error" in data) {
    const value = (data as { error?: unknown }).error;
    if (typeof value === "string" && value.trim().length > 0) {
      return value;
    }
  }
  return null;
}

export function normalizeApiError(error: unknown): ApiError {
  if (error instanceof ApiError) {
    return error;
  }

  if (error instanceof AxiosError) {
    // Timeout: the server may be fine, the connection was just too slow.
    if (error.code === "ECONNABORTED" || error.code === "ETIMEDOUT") {
      return new ApiError(
        "Request timed out. Please check your network connection and try again.",
        "timeout",
        { isRetryable: true },
      );
    }

    // No response at all: DNS failure, refused connection, offline device.
    if (!error.response) {
      return new ApiError(
        "Unable to connect to the server. Please check your network connection.",
        "network",
        { isRetryable: true },
      );
    }

    const { status, data } = error.response;
    const serverMessage = extractServerMessage(data);

    if (status >= 500) {
      return new ApiError(
        serverMessage ?? "The server is temporarily unavailable.",
        "server",
        {
          status,
          isRetryable: true,
        },
      );
    }

    if (status >= 400) {
      // A 4xx will answer the same way forever; retrying is not offered.
      return new ApiError(
        serverMessage ?? "The request could not be completed.",
        "client",
        {
          status,
          isRetryable: false,
        },
      );
    }

    return new ApiError(
      serverMessage ?? "The request could not be completed.",
      "unknown",
      {
        status,
      },
    );
  }

  return new ApiError("An unexpected error occurred.", "unknown");
}
