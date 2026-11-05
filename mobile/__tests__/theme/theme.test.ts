/**
 * Design system integrity.
 *
 * These tests exist because the design system is only centralised if nothing
 * bypasses it. A single hardcoded hex in a screen silently reintroduces the
 * problem the token layer was built to remove, and it is invisible in review.
 */
import { readFileSync } from "fs";
import { join } from "path";

import { darkTheme, theme, createTheme } from "@/theme/theme";
import { fontFamily, palette, spacing, typography } from "@/theme/tokens";
import { interFonts } from "@/theme/fonts";

describe("palette", () => {
  it("is the approved midnight-navy identity", () => {
    expect(palette.background).toBe("#071321");
    expect(palette.surface).toBe("#0B1B2D");
    expect(palette.surfaceElevated).toBe("#10243A");
    expect(palette.primary).toBe("#2478F2");
    expect(palette.textPrimary).toBe("#F4F7FC");
  });
});

describe("theme", () => {
  it("is dark", () => {
    expect(theme.dark).toBe(true);
  });

  it("maps the palette onto MD3 slots", () => {
    expect(theme.colors.background).toBe(palette.background);
    expect(theme.colors.surface).toBe(palette.surface);
    expect(theme.colors.primary).toBe(palette.primary);
    expect(theme.colors.onSurface).toBe(palette.textPrimary);
    expect(theme.colors.outline).toBe(palette.border);
  });

  it("exposes the app-specific colours MD3 has no slot for", () => {
    expect(theme.app.surfaceElevated).toBe(palette.surfaceElevated);
    expect(theme.app.warning).toBe("#F2B544");
    expect(theme.app.danger).toBe("#F15B64");
  });

  it("flattens elevation so surfaces are not tinted away from the palette", () => {
    // A non-transparent level0 would paint every screen a different navy.
    expect(theme.colors.elevation.level0).toBe("transparent");
    expect(theme.colors.elevation.level2).toBe(palette.surfaceElevated);
  });

  it("uses Inter for Paper components, not the platform font", () => {
    expect(theme.fonts.bodyLarge.fontFamily).toBe(fontFamily.regular);
    expect(theme.fonts.titleMedium.fontFamily).toBe(fontFamily.semiBold);
    expect(theme.fonts.labelLarge.fontFamily).toBe(fontFamily.semiBold);
  });

  it("can produce a second theme without touching components", () => {
    // The factory is what makes a future light theme a token swap.
    const alternate = createTheme(
      { ...palette, background: "#FFFFFF" },
      {
        success: "#000000",
        successHighlight: "#000000",
        danger: "#000000",
        warning: "#000000",
        info: "#000000",
        neutral: "#000000",
      },
    );
    expect(alternate.colors.background).toBe("#FFFFFF");
    expect(darkTheme.colors.background).toBe(palette.background);
  });
});

describe("font loading", () => {
  it("registers exactly the weights the typography scale uses", () => {
    expect(Object.keys(interFonts).sort()).toEqual(
      Object.values(fontFamily).sort(),
    );
  });

  it("does not load unused weights", () => {
    // Each weight is a separate asset in the bundle.
    expect(Object.keys(interFonts)).toHaveLength(4);
    expect(interFonts).not.toHaveProperty("Inter_900Black");
  });
});

describe("typography scale", () => {
  it("matches the approved sizes", () => {
    expect(typography.display.fontSize).toBe(30);
    expect(typography.h1.fontSize).toBe(24);
    expect(typography.h2.fontSize).toBe(20);
    expect(typography.h3.fontSize).toBe(16);
    expect(typography.body.fontSize).toBe(14);
    expect(typography.caption.fontSize).toBe(12);
    expect(typography.small.fontSize).toBe(11);
    expect(typography.numericLarge.fontSize).toBe(28);
  });

  it("uses a 4px spacing scale", () => {
    expect(Object.values(spacing).every((value) => value % 4 === 0)).toBe(true);
  });
});

describe("no screen bypasses the tokens", () => {
  // Hex literals inside screens/components are the exact failure this layer
  // exists to prevent, so it is checked mechanically rather than by review.
  const files = [
    "app/(tabs)/index.tsx",
    "app/(tabs)/fixtures/index.tsx",
    "app/(tabs)/settings/system.tsx",
    "app/matches/[id].tsx",
    "src/components/MatchCard.tsx",
    "src/components/MarketCard.tsx",
    "src/components/ProbabilityBar.tsx",
    "src/components/ScreenState.tsx",
    // Screens and components added in the design-system stage. These lost their
    // coverage when the file was reformatted; restored so the token discipline
    // is enforced across the whole app, not just the original screens.
    "app/(tabs)/predictions/index.tsx",
    "app/(tabs)/performance/index.tsx",
    "app/(tabs)/settings/index.tsx",
    "src/components/StatCard.tsx",
    "src/components/SectionHeader.tsx",
    "src/components/AppProviders.tsx",
  ];

  it.each(files)("%s contains no raw hex colour", (relativePath) => {
    const source = readFileSync(
      join(__dirname, "..", "..", relativePath),
      "utf8",
    );
    // Allow the token module itself and comments; screens must not carry colour.
    const matches = source.match(/#[0-9A-Fa-f]{3,8}\b/g) ?? [];
    expect(matches).toEqual([]);
  });
});
