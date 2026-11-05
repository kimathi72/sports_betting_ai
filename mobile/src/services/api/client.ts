/**
 * The single Axios instance for every Rails API call.
 *
 * Replaces Kilo's earlier version, which normalised errors by reading
 * `data.message`. Rail's error body is `{ "error": "..." }`, so that behaviour
 * silently degraded every backend message to Axios' generic text ("Request
 * failed with status code 400") and hid the actual reason from the user.
 * Error handling now lives in `errors.ts`, which is unit-tested on its own.
 *
 * There is exactly one instance: a second one would drift on timeout, headers
 * and error handling.
 */
import axios, { AxiosError, AxiosInstance, AxiosResponse } from "axios";

import { config } from "@/config/environment";
import { ApiError, normalizeApiError } from "@/services/api/errors";

/** Requests are short and the API is local; 15s is generous but bounded. */
export const REQUEST_TIMEOUT_MS = 15_000;

// The host only. Every path in `endpoints` already carries `/api/v1`, so
// appending the prefix here too produced `/api/v1/api/v1/...` and a 404 on
// every request. The version is defined once, in `endpoints`.
export const API_BASE_URL = config.apiBaseUrl;

export const apiClient: AxiosInstance = axios.create({
  baseURL: API_BASE_URL,
  timeout: REQUEST_TIMEOUT_MS,
  headers: {
    Accept: "application/json",
    "Content-Type": "application/json",
  },
});

apiClient.interceptors.response.use(
  (response: AxiosResponse) => response,
  (error: AxiosError) => Promise.reject(normalizeApiError(error)),
);

/**
 * Unwraps `response.data`.
 *
 * Kept separate from the hooks so a hook never knows about Axios — swapping the
 * transport later means changing only this file.
 */
export async function getJson<T>(path: string): Promise<T> {
  const response = await apiClient.get<T>(path);
  return response.data;
}

export async function postJson<T>(path: string, body: unknown): Promise<T> {
  const response = await apiClient.post<T>(path, body);
  return response.data;
}

export { ApiError };
