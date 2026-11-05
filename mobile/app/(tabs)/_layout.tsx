/**
 * Tab group layout — the five approved destinations.
 *
 * The `(tabs)` folder is a route group: it adds no URL segment, so the routes
 * stay `/`, `/fixtures`, `/predictions`, `/performance` and `/settings`.
 *
 * System Status is NOT a tab. Per the approved decision it lives inside
 * Settings as a nested route (`/settings/system`), so sync and model detail are
 * one level down from the top-level destinations. The existing verified screen
 * was moved, not rewritten.
 */
import React from "react";
import { MaterialCommunityIcons } from "@expo/vector-icons";
import { Tabs } from "expo-router";

import { useAppTheme } from "@/theme/useAppTheme";

type IconName = React.ComponentProps<typeof MaterialCommunityIcons>["name"];

/** The navigator's colour type is branded and unnamed, so accept it structurally. */
function tabIcon(name: IconName) {
  return (props: { color: unknown; size: number }) => (
    <MaterialCommunityIcons
      name={name}
      color={props.color as string}
      size={props.size}
    />
  );
}

export default function TabsLayout() {
  const theme = useAppTheme();

  return (
    <Tabs
      screenOptions={{
        headerTitleAlign: "center",
        headerStyle: { backgroundColor: theme.colors.background },
        headerTintColor: theme.colors.onSurface,
        tabBarStyle: {
          backgroundColor: theme.app.backgroundSecondary,
          borderTopColor: theme.colors.outline,
        },
        tabBarActiveTintColor: theme.colors.primary,
        tabBarInactiveTintColor: theme.app.textMuted,
        // Guarantees the 44px minimum touch target for every tab.
        tabBarItemStyle: { minHeight: 44 },
      }}
    >
      <Tabs.Screen
        name="index"
        options={{
          title: "Home",
          tabBarIcon: tabIcon("view-dashboard-outline"),
          tabBarAccessibilityLabel: "Home",
        }}
      />
      <Tabs.Screen
        name="fixtures"
        options={{
          title: "Fixtures",
          tabBarIcon: tabIcon("soccer"),
          tabBarAccessibilityLabel: "Fixtures",
        }}
      />
      <Tabs.Screen
        name="predictions"
        options={{
          title: "Predictions",
          tabBarIcon: tabIcon("chart-box-outline"),
          tabBarAccessibilityLabel: "Predictions",
        }}
      />
      <Tabs.Screen
        name="performance"
        options={{
          title: "Performance",
          tabBarIcon: tabIcon("chart-line"),
          tabBarAccessibilityLabel: "Performance",
        }}
      />
      <Tabs.Screen
        name="settings"
        options={{
          title: "Settings",
          tabBarIcon: tabIcon("cog-outline"),
          tabBarAccessibilityLabel: "Settings",
        }}
      />
    </Tabs>
  );
}
