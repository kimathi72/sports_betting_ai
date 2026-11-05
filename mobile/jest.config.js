/**
 * Jest configuration for the Expo app.
 *
 * `jest-expo` is the officially supported preset for an Expo SDK project: it
 * wires the React Native transform, module resolution and the platform mocks
 * that RN components require. Replacing it with a hand-rolled babel-jest setup
 * is the usual source of "cannot find module" noise in Expo test suites.
 */
module.exports = {
  preset: 'jest-expo',
  setupFilesAfterEnv: ['<rootDir>/jest.setup.ts'],
  // `@/` mirrors the tsconfig `paths` alias so specs import modules exactly as
  // the app does. A test that imports by relative path would stop catching a
  // broken alias.
  moduleNameMapper: {
    '^@/(.*)$': '<rootDir>/src/$1',
  },
  testPathIgnorePatterns: ['/node_modules/', '/.expo/', '/dist/'],
  transformIgnorePatterns: [
    'node_modules/(?!((jest-)?react-native|@react-native(-community)?)|expo(nent)?|@expo(nent)?/.*|@expo-google-fonts/.*|@expo-google-fonts/.*|react-navigation|@react-navigation/.*|@sentry/react-native|native-base|react-native-svg|react-native-paper|react-native-safe-area-context|expo-font)',
  ],
  collectCoverageFrom: ['src/**/*.{ts,tsx}', '!src/**/*.d.ts'],
};
