/**
 * Settings stack.
 *
 * A nested Stack is what makes `/settings/system` a real child route rather
 * than a tab. The parent tab keeps its own header, so the child disables its
 * header and relies on the pushed screen's back affordance.
 */
import { Stack } from "expo-router";

export default function SettingsLayout() {
  return (
    <Stack screenOptions={{ headerShown: false }}>
      <Stack.Screen name="index" />
      <Stack.Screen name="system" />
    </Stack>
  );
}
