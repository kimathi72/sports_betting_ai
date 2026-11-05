/**
 * Centralized environment configuration for the mobile application.
 *
 * Reads required environment variables at startup and validates them.
 * Fails fast with clear messages if configuration is invalid.
 */

const API_BASE_URL = process.env.EXPO_PUBLIC_API_BASE_URL;

if (!API_BASE_URL) {
  throw new Error(
    'EXPO_PUBLIC_API_BASE_URL is not configured. ' +
    'Set it in your .env file or environment. ' +
    'Example: EXPO_PUBLIC_API_BASE_URL=http://localhost:3000'
  );
}

// Normalize: remove trailing slash
const normalizedBaseUrl = API_BASE_URL.replace(/\/+$/, '');

// Validate URL format
try {
  new URL(normalizedBaseUrl);
} catch {
  throw new Error(
    `EXPO_PUBLIC_API_BASE_URL is not a valid URL: "${API_BASE_URL}"`
  );
}

const API_PREFIX = '/api/v1';

export const config = {
  apiBaseUrl: normalizedBaseUrl,
  apiUrl: `${normalizedBaseUrl}${API_PREFIX}`,
  appVersion: process.env.EXPO_PUBLIC_APP_VERSION || '1.0.0',
  appEnv: process.env.EXPO_PUBLIC_APP_ENV || 'development',
} as const;

export type Config = typeof config;

/**
 * Platform-specific URL guidance for development.
 * Use the correct URL for your execution environment:
 * - Expo web: http://localhost:3000
 * - iOS simulator: http://localhost:3000
 * - Android emulator: http://10.0.2.2:3000
 * - Physical device: http://YOUR_LAN_IP:3000
 * - Production: https://your-production-api.example.com
 */
export const platformUrlGuide = {
  expoWeb: 'http://localhost:3000',
  iosSimulator: 'http://localhost:3000',
  androidEmulator: 'http://10.0.2.2:3000',
  physicalDevice: 'http://YOUR_LAN_IP:3000',
} as const;